/*
 * role-overlay-jumpbox-domainjoin.tf -- join nexus-admin-jumpbox to nexus.lab.
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
 *        b. Add-Computer -DomainName nexus.lab -NewName nexus-admin-jumpbox
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
  jumpbox_hostname = "nexus-admin-jumpbox"
}

# ─── 1. Domain-join + rename + reboot ─────────────────────────────────────
resource "null_resource" "jumpbox_domain_join" {
  count = var.enable_jumpbox_domain_join ? 1 : 0

  triggers = {
    target_vmx      = module.nexus_admin_jumpbox.vm_path
    target_hostname = local.jumpbox_hostname
    ad_domain       = local.ad_domain
    domainjoin_v    = "1"
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
      $nexusadmin_pwd = '${var.nexusadmin_password}'
      $netbios        = '${local.ad_netbios}'

      # Idempotency: skip if jumpbox is already joined to nexus.lab.
      $check_script = "(Get-WmiObject Win32_ComputerSystem).PartOfDomain.ToString() + '|' + (Get-WmiObject Win32_ComputerSystem).Domain"
      $bytes = [System.Text.Encoding]::Unicode.GetBytes($check_script)
      $b64   = [Convert]::ToBase64String($bytes)
      $state = ssh nexusadmin@$ip "powershell -NoProfile -EncodedCommand $b64" 2>$null
      if ($state) {
        $parts = $state.Trim() -split '\|'
        if ($parts.Length -eq 2 -and $parts[0] -eq 'True' -and $parts[1] -eq $domain) {
          Write-Host "[jumpbox domain_join] already joined to $domain, skipping."
          exit 0
        }
      }

      # Build the join script: patch sshd_config first (so the post-reboot
      # sshd allows domain users), restart sshd to load it immediately,
      # then Add-Computer with rename + restart in one atomic call.
      $remote = "`$cfg = Get-Content 'C:\ProgramData\ssh\sshd_config'; `$cfg = `$cfg -replace '^\s*AllowUsers.*$', '# AllowUsers (removed for AD-joined posture: trust = pubkey + Administrators group membership)'; `$cfg | Set-Content 'C:\ProgramData\ssh\sshd_config' -Encoding ascii; Restart-Service sshd -Force; Start-Sleep -Seconds 2; `$cred = New-Object System.Management.Automation.PSCredential('$netbios\nexusadmin', (ConvertTo-SecureString '$nexusadmin_pwd' -AsPlainText -Force)); Add-Computer -DomainName '$domain' -NewName '$newname' -Credential `$cred -Force -Restart"
      $bytes = [System.Text.Encoding]::Unicode.GetBytes($remote)
      $b64   = [Convert]::ToBase64String($bytes)

      Write-Host "[jumpbox domain_join] dispatching sshd_config patch + Add-Computer (rename + join) via -EncodedCommand (script bytes: $($remote.Length))..."
      # Add-Computer -Restart kicks the reboot synchronously. SSH session may
      # exit 0 (clean) or 255 (connection dropped during reboot). Both OK.
      ssh nexusadmin@$ip "powershell -NoProfile -EncodedCommand $b64"
      $rc = $LASTEXITCODE
      Write-Host "[jumpbox domain_join] command issued (ssh exit=$rc); reboot will follow. wait_rejoined will poll for domain membership."
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
      $ip = '${local.jumpbox_ip}'
      Write-Host "[jumpbox verify] === Win32_ComputerSystem ==="
      ssh nexusadmin@$ip 'powershell -NoProfile -Command "Get-WmiObject Win32_ComputerSystem | Format-List Name, Domain, PartOfDomain, DomainRole"'
      Write-Host "[jumpbox verify] === nltest /dsgetdc (Netlogon should be live now) ==="
      ssh nexusadmin@$ip 'powershell -NoProfile -Command "nltest /dsgetdc:nexus.lab"'
      Write-Host "[jumpbox verify] === Get-ADComputer (jumpbox registered in AD?) ==="
      ssh nexusadmin@$ip 'powershell -NoProfile -Command "Get-ADComputer nexus-admin-jumpbox | Format-List Name, DNSHostName, DistinguishedName, Enabled"'
    PWSH
  }
}
