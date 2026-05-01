/*
 * role-overlay-jumpbox-domainjoin.tf -- join nexus-jumpbox to nexus.lab.
 *
 * Phase 0.C.3 layer running on top of:
 *   - module.nexus_admin_jumpbox  (the bare ws2025-desktop clone from 0.C.1)
 *   - null_resource.dc_nexus_verify (the live DC from 0.C.2)
 *
 * Three sequential null_resources (top-level, independently `-target`-able):
 *
 *   1. jumpbox_domain_join  -- single base64-encoded SSH command that:
 *        a. Patches sshd_config to remove `AllowUsers nexusadmin` BEFORE the
 *           reboot. Lesson #4 from feedback_addsforest_post_promotion.md:
 *           on a domain-joined box, sshd receives the user as `<NETBIOS>\<user>`
 *           which doesn't match the bare-username AllowUsers directive. Patch
 *           applies BEFORE the reboot so the new config is loaded by the
 *           post-reboot sshd, but Restart-Service sshd here also reloads
 *           immediately (defensive -- if Add-Computer's -Restart somehow
 *           doesn't reboot, sshd is still patched).
 *        b. Add-Computer -DomainName nexus.lab -NewName nexus-jumpbox
 *           -Credential <NEXUS\nexusadmin> -Force -Restart
 *           (single cmdlet renames the local hostname AND adds to domain).
 *
 *   2. jumpbox_wait_rejoined  -- polls (Get-WmiObject Win32_ComputerSystem)
 *      until PartOfDomain=True and Domain=nexus.lab. Wall-clock ~3-7 min.
 *
 *   3. jumpbox_verify  -- emits domain membership info + Get-ADComputer
 *      registration confirmation, AND verifies nltest /dsgetdc:nexus.lab
 *      now works from the jumpbox (Netlogon auto-starts post-join).
 *
 * Selective ops (memory/feedback_selective_provisioning.md):
 *   - var.enable_jumpbox_domain_join (default true) gates the entire overlay.
 *   - depends_on null_resource.dc_nexus_verify -- this overlay is a no-op
 *     when enable_dc_promotion=false (DC must exist first, obviously).
 *   - Each null_resource is `-target`-able for ad-hoc iteration:
 *       terraform apply -target=null_resource.jumpbox_domain_join -auto-approve
 *
 * Idempotency:
 *   - jumpbox_domain_join checks (Get-WmiObject).PartOfDomain first; no-op
 *     if already joined to nexus.lab.
 *   - Triggers key off ad_domain so changing the domain (rare) re-fires.
 *
 * Why not nested in module.nexus_admin_jumpbox: same reason as 0.C.2's
 * dc-nexus overlay -- top-level resources are independently targetable;
 * iterating on the join logic shouldn't force a re-clone of the underlying
 * VM.
 */

locals {
  jumpbox_ip       = "192.168.70.241"
  jumpbox_hostname = "nexus-jumpbox"
}

# ─── 1. Domain-join + rename + reboot ─────────────────────────────────────
resource "null_resource" "jumpbox_domain_join" {
  count = var.enable_jumpbox_domain_join ? 1 : 0

  triggers = {
    target_vmx      = module.nexus_admin_jumpbox.vm_path
    target_hostname = local.jumpbox_hostname
    ad_domain       = local.ad_domain
    domainjoin_v    = "5" # v5 = SSH echo probe (not Test-NetConnection) + retry loop on Add-Computer SSH (matches dc_nexus_rename v4). v4 trusted Test-NetConnection but real SSH connections still flaked. v3 = 13-char hostname (NetBIOS limit). v2 dropped inline Restart-Service sshd. v1 = inline cmd.exe quoting.
  }

  # The DC must be alive before we can join. dc_nexus_verify is the last
  # resource in the dc-nexus chain and only exists when enable_dc_promotion
  # is true -- so this overlay implicitly requires both flags.
  depends_on = [null_resource.dc_nexus_verify]

  provisioner "local-exec" {
    when        = create
    interpreter = ["pwsh", "-NoProfile", "-Command"]
    command     = <<-PWSH
      $ip             = '${local.jumpbox_ip}'
      $newname        = '${local.jumpbox_hostname}'
      $domain         = '${local.ad_domain}'
      # Phase 0.D.4 -- nexusadmin pwd from Vault KV when enabled, else var fallback.
      $nexusadmin_pwd = '${local.foundation_creds.nexusadmin}'
      $netbios        = '${local.ad_netbios}'

      # ─── Pre-flight: wait for END-TO-END ssh to work ───────────────────
      # Test-NetConnection -Port 22 returns True as soon as Windows opens
      # the listening socket -- BEFORE sshd is fully ready to accept
      # sessions. v4 trusted Test-NetConnection and saw connections fail
      # seconds later. v5 uses a real ssh echo probe for end-to-end check.
      Write-Host "[jumpbox domain_join] probing ssh on $ip (echo ok)..."
      $bootDeadline = (Get-Date).AddMinutes(10)
      $sshReady = $false
      while ((Get-Date) -lt $bootDeadline) {
        $probe = (ssh -o ConnectTimeout=5 -o ConnectionAttempts=1 -o BatchMode=yes -o StrictHostKeyChecking=no nexusadmin@$ip "echo ok" 2>&1 | Out-String).Trim()
        if ($probe -eq 'ok') { $sshReady = $true; break }
        Start-Sleep -Seconds 15
      }
      if (-not $sshReady) {
        throw "[jumpbox domain_join] ssh echo probe never succeeded on $ip after 10m -- clone may have failed to boot"
      }
      Start-Sleep -Seconds 30  # grace for WMI/OS settling
      Write-Host "[jumpbox domain_join] ssh ready"

      # ─── Idempotency: skip if jumpbox is already joined ────────────────
      $check_script = "(Get-WmiObject Win32_ComputerSystem).PartOfDomain.ToString() + '|' + (Get-WmiObject Win32_ComputerSystem).Domain"
      $bytes = [System.Text.Encoding]::Unicode.GetBytes($check_script)
      $b64   = [Convert]::ToBase64String($bytes)
      $state = ssh -o ConnectTimeout=10 nexusadmin@$ip "powershell -NoProfile -EncodedCommand $b64" 2>$null
      if ($state) {
        $parts = $state.Trim() -split '\|'
        if ($parts.Length -eq 2 -and $parts[0] -eq 'True' -and $parts[1] -eq $domain) {
          Write-Host "[jumpbox domain_join] already joined to $domain, skipping."
          exit 0
        }
      }

      # ─── Issue join script via base64-encoded transit ──────────────────
      # Patch sshd_config first (so the post-reboot sshd allows domain users)
      # -- but DO NOT inline-restart sshd. Lesson from domainjoin_v=1:
      # Restart-Service sshd kills the active SSH session running this
      # script, so Add-Computer never executes. The post-Add-Computer
      # reboot starts sshd fresh with the patched config anyway.
      $remote = "`$cfg = Get-Content 'C:\ProgramData\ssh\sshd_config'; `$cfg = `$cfg -replace '^\s*AllowUsers.*$', '# AllowUsers (removed for AD-joined posture: trust = pubkey + Administrators group membership)'; `$cfg | Set-Content 'C:\ProgramData\ssh\sshd_config' -Encoding ascii; `$cred = New-Object System.Management.Automation.PSCredential('$netbios\nexusadmin', (ConvertTo-SecureString '$nexusadmin_pwd' -AsPlainText -Force)); Add-Computer -DomainName '$domain' -NewName '$newname' -Credential `$cred -Force -Restart"
      $bytes = [System.Text.Encoding]::Unicode.GetBytes($remote)
      $b64   = [Convert]::ToBase64String($bytes)

      Write-Host "[jumpbox domain_join] dispatching sshd_config patch + Add-Computer (rename + join) via -EncodedCommand (script bytes: $($remote.Length))..."
      # Retry loop: sshd may briefly flake even after our probe succeeded.
      $maxAttempts = 5
      $issued = $false
      for ($i = 1; $i -le $maxAttempts; $i++) {
        $sshOutput = ssh -o ConnectTimeout=15 nexusadmin@$ip "powershell -NoProfile -EncodedCommand $b64" 2>&1 | Out-String
        $rc = $LASTEXITCODE
        if ($sshOutput -notmatch "Connection (timed out|refused)" -and $sshOutput -notmatch "port 22:") {
          Write-Host "[jumpbox domain_join] attempt $i succeeded (ssh exit=$rc)"
          if ($sshOutput.Trim()) { Write-Host "[jumpbox domain_join] ssh output: $($sshOutput.Trim())" }
          $issued = $true
          break
        }
        Write-Host "[jumpbox domain_join] attempt $i failed: $($sshOutput.Trim())"
        Start-Sleep -Seconds 10
      }
      if (-not $issued) {
        throw "[jumpbox domain_join] all $maxAttempts attempts failed -- Add-Computer did not fire. Last output: $sshOutput"
      }
      Write-Host "[jumpbox domain_join] command dispatched; reboot will follow. wait_rejoined will poll for domain membership."
    PWSH
  }
}

# ─── 2. Wait for the domain join + reboot to complete ────────────────────
resource "null_resource" "jumpbox_wait_rejoined" {
  count = var.enable_jumpbox_domain_join ? 1 : 0

  triggers = {
    join_id = null_resource.jumpbox_domain_join[0].id
  }

  depends_on = [null_resource.jumpbox_domain_join]

  provisioner "local-exec" {
    when        = create
    interpreter = ["pwsh", "-NoProfile", "-Command"]
    command     = <<-PWSH
      $ip       = '${local.jumpbox_ip}'
      $domain   = '${local.ad_domain}'
      $timeout  = ${var.dc_promotion_timeout_minutes}
      $deadline = (Get-Date).AddMinutes($timeout)

      Write-Host "[jumpbox wait_rejoined] polling PartOfDomain=True, Domain=$domain (timeout: $${timeout}m)"
      while ((Get-Date) -lt $deadline) {
        Start-Sleep -Seconds 30
        # Use base64 for the same cmd.exe-quoting reason as elsewhere.
        $check = "(Get-WmiObject Win32_ComputerSystem).PartOfDomain.ToString() + '|' + (Get-WmiObject Win32_ComputerSystem).Domain"
        $bytes = [System.Text.Encoding]::Unicode.GetBytes($check)
        $b64   = [Convert]::ToBase64String($bytes)
        $raw = ssh -o ConnectTimeout=5 nexusadmin@$ip "powershell -NoProfile -EncodedCommand $b64" 2>$null
        if ($raw) {
          $parts = $raw.Trim() -split '\|'
          if ($parts.Length -eq 2 -and $parts[0] -eq 'True' -and $parts[1] -eq $domain) {
            Write-Host "[jumpbox wait_rejoined] joined to $domain."
            exit 0
          }
          Write-Host "[jumpbox wait_rejoined] not ready (PartOfDomain=$($parts[0]), Domain=$($parts[1])), retrying..."
        } else {
          Write-Host "[jumpbox wait_rejoined] no response (rebooting?), retrying..."
        }
      }
      throw "[jumpbox wait_rejoined] timed out after $${timeout}m -- jumpbox never joined $domain"
    PWSH
  }
}

# ─── 3. Verify domain membership + emit info ─────────────────────────────
resource "null_resource" "jumpbox_verify" {
  count = var.enable_jumpbox_domain_join ? 1 : 0

  triggers = {
    wait_id = null_resource.jumpbox_wait_rejoined[0].id
  }

  depends_on = [null_resource.jumpbox_wait_rejoined]

  provisioner "local-exec" {
    when        = create
    interpreter = ["pwsh", "-NoProfile", "-Command"]
    command     = <<-PWSH
      $ip    = '${local.jumpbox_ip}'
      $dc_ip = '${local.dc_nexus_ip}'

      Write-Host "[jumpbox verify] === Win32_ComputerSystem (from jumpbox) ==="
      ssh nexusadmin@$ip 'powershell -NoProfile -Command "Get-WmiObject Win32_ComputerSystem | Format-List Name, Domain, PartOfDomain, DomainRole"'

      Write-Host "[jumpbox verify] === nltest /dsgetdc (from jumpbox -- proves Netlogon is live post-join) ==="
      ssh nexusadmin@$ip 'powershell -NoProfile -Command "nltest /dsgetdc:nexus.lab"'

      # Query Get-ADComputer FROM THE DC, not from the jumpbox. Reason:
      # SSH to the jumpbox runs as the LOCAL `nexusadmin` user (the local
      # SAM account, not the domain user). RSAT's Get-ADComputer needs to
      # authenticate to ADWS on port 9389; without domain creds in the
      # session it fails with "Unable to contact the server" even though
      # the DC's ADWS is healthy. Running from the DC sidesteps this --
      # the DC's Administrator (which is also the local SSH user) has
      # integrated auth to its own ADWS.
      Write-Host "[jumpbox verify] === Get-ADComputer (from DC -- proves jumpbox is registered in AD) ==="
      ssh nexusadmin@$dc_ip 'powershell -NoProfile -Command "Get-ADComputer nexus-jumpbox | Format-List Name, DNSHostName, DistinguishedName, Enabled"'
    PWSH
  }
}
