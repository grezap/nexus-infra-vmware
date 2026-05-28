/*
 * role-overlay-dc-nexus-2-promotion.tf -- Phase 0.M (2nd AD DC promotion).
 *
 * Promotes dc-nexus-2 into a REPLICA domain controller of the existing
 * nexus.lab forest (originally promoted on dc-nexus in Phase 0.C.2). Foundation
 * HA partner -- replication mesh ensures auth/DNS survive single-DC loss.
 *
 * Seven sequential null_resources mirroring the dc-nexus + jumpbox combined
 * shape (since this VM both joins the domain AND promotes to a DC):
 *
 *   1. rename        -- Rename-Computer dc-nexus-2 + reboot.
 *   2. wait_renamed  -- poll `hostname` over SSH until 'dc-nexus-2'.
 *   3. join          -- patch sshd_config + Add-Computer -DomainName nexus.lab
 *                       -Credential NEXUS\nexusadmin -Force -Restart.
 *   4. wait_joined   -- poll PartOfDomain=True && Domain=nexus.lab.
 *   5. promote       -- Install-ADDSDomainController -DomainName nexus.lab
 *                       -Credential NEXUS\nexusadmin -SafeModeAdministratorPassword <DSRM>
 *                       -ReplicationSourceDC dc-nexus.nexus.lab -SiteName Default-First-Site-Name
 *                       -InstallDns:$true -CreateDnsDelegation:$false -Force:$true
 *                       -NoRebootOnCompletion:$false (auto-reboots).
 *   6. wait_promoted -- poll (Get-ADDomain).Forest == nexus.lab on dc-nexus-2.
 *   7. verify        -- emit Get-ADDomainController dc-nexus-2 (from dc-nexus) +
 *                       repadmin /showrepl (from dc-nexus-2 to dc-nexus, both directions).
 *
 * IP allocation decision (2026-05-28 -- Greg confirmed):
 *   - dc-nexus-2 grabs 192.168.70.242 from the DHCP smoke pool (next free
 *     after dc-nexus@.240 + jumpbox@.241). NO dhcp-host reservation -- mirrors
 *     the actual reality of dc-nexus/jumpbox (vms.yaml's canonical .10/.11
 *     slots remain a pre-existing canon-vs-reality drift, deferred to a
 *     future canon-realignment ticket). vms.yaml row updated .11 -> .242 to
 *     reflect actual IP. The .11 slot is owned by sql-fci-1 via the existing
 *     gateway-oltp-reservations overlay; touching it would have wide blast
 *     radius into the PROVEN OLTP cold-rebuild state.
 *
 * Idempotency:
 *   - Rename: no-op if hostname matches.
 *   - Join: skips if (Get-WmiObject Win32_ComputerSystem).PartOfDomain == True
 *           AND .Domain == nexus.lab.
 *   - Promote: short-circuits via Get-ADDomainController -Identity dc-nexus-2
 *              -ErrorAction SilentlyContinue (returns the DC if already
 *              promoted; null otherwise).
 *
 * Cross-env coupling:
 *   - dc-nexus must already be promoted (the existing forest); enforced via
 *     depends_on null_resource.dc_nexus_verify.
 *   - depends_on null_resource.gateway_dns_forward so nexus.lab queries
 *     resolve to dc-nexus during the initial domain-join (mirrors jumpbox).
 *   - depends_on null_resource.dc_rotate_bootstrap_creds (when present) so
 *     KV's nexusadmin password matches the live AD value before we try to
 *     Add-Computer using it. Without this edge, a KV-update between forest
 *     creation and this apply would mean Add-Computer fails with
 *     credential-rejected even though KV looks right.
 *   - DSRM password for dc-nexus-2: reused from the existing DSRM Vault KV
 *     path nexus/foundation/dc-nexus/dsrm (shared between DCs by AD
 *     convention -- DSRM is per-DC but our lab uses a single intended value).
 *
 * Reachability invariant (per memory/feedback_lab_host_reachability.md):
 * sshd_config patch removes `AllowUsers nexusadmin` (post-domain-join the
 * user appears as NEXUS\nexusadmin which doesn't match the bare-username
 * directive). Same fix the jumpbox-domainjoin overlay applies. SSH/22 +
 * RDP/3389 from build host stay intact across the cycle.
 */

locals {
  dc_nexus_2_ip       = "192.168.70.242"
  dc_nexus_2_hostname = "dc-nexus-2"
}

# ─── 1. Rename WIN-XXX -> dc-nexus-2 ──────────────────────────────────────
resource "null_resource" "dc_nexus_2_rename" {
  count = var.enable_dc_nexus_2 && var.enable_dc_nexus_2_promotion ? 1 : 0

  triggers = {
    target_vmx       = length(module.dc_nexus_2) > 0 ? module.dc_nexus_2[0].vm_path : "disabled"
    target_hostname  = local.dc_nexus_2_hostname
    rename_overlay_v = "1"
  }

  depends_on = [module.dc_nexus_2]

  provisioner "local-exec" {
    when        = create
    interpreter = ["pwsh", "-NoProfile", "-Command"]
    command     = <<-PWSH
      $ip   = '${local.dc_nexus_2_ip}'
      $name = '${local.dc_nexus_2_hostname}'

      # SSH ECHO probe (per memory/feedback_windows_ssh_automation.md rule #3)
      Write-Host "[dc-nexus-2 rename] probing ssh on $ip (echo ok)..."
      $bootDeadline = (Get-Date).AddMinutes(10); $sshReady = $false
      while ((Get-Date) -lt $bootDeadline) {
        $probe = (ssh -o ConnectTimeout=5 -o ConnectionAttempts=1 -o BatchMode=yes -o StrictHostKeyChecking=no nexusadmin@$ip "echo ok" 2>&1 | Out-String).Trim()
        if ($probe -eq 'ok') { $sshReady = $true; break }
        Start-Sleep -Seconds 15
      }
      if (-not $sshReady) { throw "[dc-nexus-2 rename] ssh echo probe never succeeded on $ip after 10m -- clone may have failed to boot, or DHCP gave a different IP than $ip (check `vmrun list` + dnsmasq leases on nexus-gateway)" }
      Start-Sleep -Seconds 30

      # Idempotency: skip if hostname already matches
      $cur = (ssh -o BatchMode=yes -o StrictHostKeyChecking=no nexusadmin@$ip "hostname" 2>&1 | Out-String).Trim()
      if ($cur -ieq $name) { Write-Host "[dc-nexus-2 rename] hostname already $name; skipping"; exit 0 }

      Write-Host "[dc-nexus-2 rename] current hostname: '$cur' -> renaming to $name"

      # Rename via base64-encoded PowerShell (per feedback_windows_ssh_automation.md rule #2)
      $script = "Rename-Computer -NewName '$name' -Force; Start-Sleep -Seconds 2; Restart-Computer -Force"
      $b64 = [Convert]::ToBase64String([System.Text.UnicodeEncoding]::Unicode.GetBytes($script))

      $maxAttempts = 5
      $issued = $false
      for ($i = 1; $i -le $maxAttempts; $i++) {
        $sshOutput = ssh -o ConnectTimeout=15 nexusadmin@$ip "powershell -NoProfile -EncodedCommand $b64" 2>&1 | Out-String
        $rc = $LASTEXITCODE
        if ($sshOutput -notmatch "Connection (timed out|refused)" -and $sshOutput -notmatch "port 22:") {
          Write-Host "[dc-nexus-2 rename] attempt $i succeeded (ssh exit=$rc)"
          $issued = $true; break
        }
        Write-Host "[dc-nexus-2 rename] attempt $i failed: $($sshOutput.Trim())"
        Start-Sleep -Seconds 10
      }
      if (-not $issued) { throw "[dc-nexus-2 rename] all $maxAttempts attempts failed" }
      Write-Host "[dc-nexus-2 rename] rename + reboot triggered"
    PWSH
  }
}

# ─── 2. Wait for rename + reboot to settle ────────────────────────────────
resource "null_resource" "dc_nexus_2_wait_renamed" {
  count = var.enable_dc_nexus_2 && var.enable_dc_nexus_2_promotion ? 1 : 0

  triggers = {
    rename_id      = null_resource.dc_nexus_2_rename[0].id
    wait_overlay_v = "1"
  }

  depends_on = [null_resource.dc_nexus_2_rename]

  provisioner "local-exec" {
    when        = create
    interpreter = ["pwsh", "-NoProfile", "-Command"]
    command     = <<-PWSH
      $ip      = '${local.dc_nexus_2_ip}'
      $name    = '${local.dc_nexus_2_hostname}'
      $timeout = ${var.dc_promotion_timeout_minutes}

      Start-Sleep -Seconds 60  # let the reboot start
      Write-Host "[dc-nexus-2 wait_renamed] polling hostname on $ip until == $name (timeout: $${timeout}m)..."
      $deadline = (Get-Date).AddMinutes($timeout); $ok = $false
      while ((Get-Date) -lt $deadline) {
        $raw = ssh -o ConnectTimeout=5 -o BatchMode=yes -o StrictHostKeyChecking=no nexusadmin@$ip "hostname" 2>$null
        $cur = if ($raw) { $raw.Trim() } else { '' }
        if ($cur -ieq $name) { $ok = $true; break }
        Write-Host "[dc-nexus-2 wait_renamed] hostname='$cur', retrying..."
        Start-Sleep -Seconds 15
      }
      if (-not $ok) { throw "[dc-nexus-2 wait_renamed] hostname never reached '$name' within $${timeout}m" }
      Write-Host "[dc-nexus-2 wait_renamed] hostname == $name"
    PWSH
  }
}

# ─── 3. Domain-join to nexus.lab (sshd_config patch + Add-Computer + reboot) ─
resource "null_resource" "dc_nexus_2_join" {
  count = var.enable_dc_nexus_2 && var.enable_dc_nexus_2_promotion ? 1 : 0

  triggers = {
    wait_id        = null_resource.dc_nexus_2_wait_renamed[0].id
    ad_domain      = var.ad_domain
    creds_hash     = sha256("${local.foundation_creds.nexusadmin}")
    join_overlay_v = "2" # v2 = live ratification (Vault KV cred pull + Add-Computer + sshd_config patch). v1 = scaffold-only (throw).
  }

  # Cross-env edges:
  #   - dc_nexus_verify: forest must exist before we can join it.
  #   - gateway_dns_forward: gateway's dnsmasq must forward nexus.lab -> dc-nexus
  #     so Add-Computer can resolve _ldap._tcp.nexus.lab SRV.
  #   - dc_rotate_bootstrap_creds (if present): KV's nexusadmin password must
  #     match live AD before Add-Computer attempts it.
  depends_on = [
    null_resource.dc_nexus_2_wait_renamed,
    null_resource.dc_nexus_verify,
    null_resource.gateway_dns_forward,
    null_resource.dc_rotate_bootstrap_creds,
  ]

  provisioner "local-exec" {
    when        = create
    interpreter = ["pwsh", "-NoProfile", "-Command"]
    command     = <<-PWSH
      $ip             = '${local.dc_nexus_2_ip}'
      $domain         = '${var.ad_domain}'
      $netbios        = '${var.ad_netbios}'
      $nexusadmin_pwd = '${local.foundation_creds.nexusadmin}'

      Write-Host "[dc-nexus-2 join] probing ssh on $ip (echo ok)..."
      $deadline = (Get-Date).AddMinutes(10); $sshReady = $false
      while ((Get-Date) -lt $deadline) {
        $probe = (ssh -o ConnectTimeout=5 -o BatchMode=yes -o StrictHostKeyChecking=no nexusadmin@$ip "echo ok" 2>&1 | Out-String).Trim()
        if ($probe -eq 'ok') { $sshReady = $true; break }
        Start-Sleep -Seconds 15
      }
      if (-not $sshReady) { throw "[dc-nexus-2 join] ssh echo probe never succeeded on $ip after 10m" }
      Start-Sleep -Seconds 15

      # Idempotency: skip if already joined to nexus.lab
      $check_script = "(Get-WmiObject Win32_ComputerSystem).PartOfDomain.ToString() + '|' + (Get-WmiObject Win32_ComputerSystem).Domain"
      $checkB64 = [Convert]::ToBase64String([System.Text.UnicodeEncoding]::Unicode.GetBytes($check_script))
      $state = ssh -o ConnectTimeout=10 nexusadmin@$ip "powershell -NoProfile -EncodedCommand $checkB64" 2>$null
      if ($state) {
        $parts = $state.Trim() -split '\|'
        if ($parts.Length -eq 2 -and $parts[0] -eq 'True' -and $parts[1] -ieq $domain) {
          Write-Host "[dc-nexus-2 join] already joined to $domain; skipping"
          exit 0
        }
      }

      Write-Host "[dc-nexus-2 join] dispatching sshd_config patch + Add-Computer (NEXUS\nexusadmin) via -EncodedCommand"

      # Patch sshd_config to remove `AllowUsers nexusadmin` BEFORE the reboot
      # (post-join the user appears as NEXUS\nexusadmin which doesn't match
      # the bare-username directive; sshd would reject SSH after join).
      # Same fix the jumpbox-domainjoin overlay applies. Then Add-Computer
      # with -Restart -- the post-reboot sshd loads the patched config so
      # the next SSH (wait_joined poll) lands.
      $remote = "`$cfg = Get-Content 'C:\ProgramData\ssh\sshd_config'; `$cfg = `$cfg -replace '^\s*AllowUsers.*$', '# AllowUsers (removed for AD-joined posture: trust = pubkey + Administrators group membership)'; `$cfg | Set-Content 'C:\ProgramData\ssh\sshd_config' -Encoding ascii; `$cred = New-Object System.Management.Automation.PSCredential('$netbios\nexusadmin', (ConvertTo-SecureString '$nexusadmin_pwd' -AsPlainText -Force)); Add-Computer -DomainName '$domain' -Credential `$cred -Force -Restart"
      $b64 = [Convert]::ToBase64String([System.Text.UnicodeEncoding]::Unicode.GetBytes($remote))

      $maxAttempts = 5
      $issued = $false
      for ($i = 1; $i -le $maxAttempts; $i++) {
        $sshOutput = ssh -o ConnectTimeout=15 nexusadmin@$ip "powershell -NoProfile -EncodedCommand $b64" 2>&1 | Out-String
        $rc = $LASTEXITCODE
        if ($sshOutput -notmatch "Connection (timed out|refused)" -and $sshOutput -notmatch "port 22:") {
          Write-Host "[dc-nexus-2 join] attempt $i succeeded (ssh exit=$rc)"
          if ($sshOutput.Trim()) { Write-Host "[dc-nexus-2 join] ssh output: $($sshOutput.Trim())" }
          $issued = $true; break
        }
        Write-Host "[dc-nexus-2 join] attempt $i failed: $($sshOutput.Trim())"
        Start-Sleep -Seconds 10
      }
      if (-not $issued) { throw "[dc-nexus-2 join] all $maxAttempts attempts failed -- Add-Computer did not fire" }
      Write-Host "[dc-nexus-2 join] command dispatched; reboot will follow. wait_joined will poll for domain membership."
    PWSH
  }
}

# ─── 4. Wait for the domain join + reboot to complete ────────────────────
resource "null_resource" "dc_nexus_2_wait_joined" {
  count = var.enable_dc_nexus_2 && var.enable_dc_nexus_2_promotion ? 1 : 0

  triggers = {
    join_id               = null_resource.dc_nexus_2_join[0].id
    wait_joined_overlay_v = "1"
  }

  depends_on = [null_resource.dc_nexus_2_join]

  provisioner "local-exec" {
    when        = create
    interpreter = ["pwsh", "-NoProfile", "-Command"]
    command     = <<-PWSH
      $ip       = '${local.dc_nexus_2_ip}'
      $domain   = '${var.ad_domain}'
      $timeout  = ${var.dc_promotion_timeout_minutes}
      $deadline = (Get-Date).AddMinutes($timeout)

      Start-Sleep -Seconds 60
      Write-Host "[dc-nexus-2 wait_joined] polling PartOfDomain=True, Domain=$domain (timeout: $${timeout}m)"
      while ((Get-Date) -lt $deadline) {
        Start-Sleep -Seconds 20
        $check = "(Get-WmiObject Win32_ComputerSystem).PartOfDomain.ToString() + '|' + (Get-WmiObject Win32_ComputerSystem).Domain"
        $b64 = [Convert]::ToBase64String([System.Text.UnicodeEncoding]::Unicode.GetBytes($check))
        $raw = ssh -o ConnectTimeout=5 nexusadmin@$ip "powershell -NoProfile -EncodedCommand $b64" 2>$null
        if ($raw) {
          $parts = $raw.Trim() -split '\|'
          if ($parts.Length -eq 2 -and $parts[0] -eq 'True' -and $parts[1] -ieq $domain) {
            Write-Host "[dc-nexus-2 wait_joined] joined to $domain"
            exit 0
          }
          Write-Host "[dc-nexus-2 wait_joined] not ready (PartOfDomain=$($parts[0]), Domain=$($parts[1])), retrying..."
        } else {
          Write-Host "[dc-nexus-2 wait_joined] no response (rebooting?), retrying..."
        }
      }
      throw "[dc-nexus-2 wait_joined] timed out after $${timeout}m -- never joined $domain"
    PWSH
  }
}

# ─── 5. Promote to replica DC (Install-ADDSDomainController + auto-reboot) ─
resource "null_resource" "dc_nexus_2_promote" {
  count = var.enable_dc_nexus_2 && var.enable_dc_nexus_2_promotion ? 1 : 0

  triggers = {
    wait_joined_id    = null_resource.dc_nexus_2_wait_joined[0].id
    ad_domain         = var.ad_domain
    creds_hash        = sha256("${local.foundation_creds.nexusadmin}|${local.foundation_creds.dsrm}")
    promote_overlay_v = "2" # v2 = $source_dc literal-string bug fix (v1 rendered `'dc-nexus.${domain}'` via single-quoted PowerShell, which is LITERAL not interpolation, so Install-ADDSDomainController saw a bogus -ReplicationSourceDC of literal 'dc-nexus.${domain}' and exited silently; box stayed a Member Server. Fix = terraform-side interpolation. Transient M1, handbook §3.M.1).
  }

  depends_on = [null_resource.dc_nexus_2_wait_joined]

  provisioner "local-exec" {
    when        = create
    interpreter = ["pwsh", "-NoProfile", "-Command"]
    command     = <<-PWSH
      $ip             = '${local.dc_nexus_2_ip}'
      $domain         = '${var.ad_domain}'
      $netbios        = '${var.ad_netbios}'
      $hostname       = '${local.dc_nexus_2_hostname}'
      $nexusadmin_pwd = '${local.foundation_creds.nexusadmin}'
      $dsrm_pwd       = '${local.foundation_creds.dsrm}'
      # v2 bug fix: $source_dc must be a literal FQDN at terraform render time.
      # v1 had 'dc-nexus.$${domain}' (terraform escape -> 'dc-nexus.$${domain}'),
      # but PowerShell single quotes are LITERAL — no variable expansion. The
      # promote script then passed -ReplicationSourceDC 'dc-nexus.$${domain}'
      # to Install-ADDSDomainController, which couldn't resolve that hostname
      # and exited silently. Use terraform interpolation directly here so the
      # variable substitution happens at render time, not PowerShell runtime.
      $source_dc      = 'dc-nexus.${var.ad_domain}'

      Write-Host "[dc-nexus-2 promote] probing ssh on $ip (echo ok)..."
      $deadline = (Get-Date).AddMinutes(10); $sshReady = $false
      while ((Get-Date) -lt $deadline) {
        $probe = (ssh -o ConnectTimeout=5 -o BatchMode=yes -o StrictHostKeyChecking=no nexusadmin@$ip "echo ok" 2>&1 | Out-String).Trim()
        if ($probe -eq 'ok') { $sshReady = $true; break }
        Start-Sleep -Seconds 15
      }
      if (-not $sshReady) { throw "[dc-nexus-2 promote] ssh echo probe never succeeded on $ip after 10m" }

      # Idempotency: ask the EXISTING DC (dc-nexus) if dc-nexus-2 is already
      # registered as a replica DC. Get-ADDomainController is the canonical
      # cross-DC visibility primitive; we run it on dc-nexus where ADWS auth
      # works for the local SSH session.
      $existing = ssh nexusadmin@${local.dc_nexus_ip} "powershell -NoProfile -Command `"try { (Get-ADDomainController -Identity '$hostname' -ErrorAction Stop).HostName } catch { '' }`"" 2>$null
      if ($existing) { $existing = $existing.Trim() }
      if ($existing -match "$hostname") {
        Write-Host "[dc-nexus-2 promote] $hostname already registered as DC ($existing); skipping promote"
        exit 0
      }

      # Build a single-line script for -EncodedCommand transit (per
      # feedback_windows_ssh_automation.md rule #2). Install AD-DS feature
      # then Install-ADDSDomainController with -NoRebootOnCompletion:$false
      # to auto-reboot at the end. SSH session drops; wait_promoted polls
      # for Get-ADDomain to come back live.
      $remote = "Install-WindowsFeature AD-Domain-Services -IncludeManagementTools | Out-Null; Import-Module ADDSDeployment; `$dsrm = ConvertTo-SecureString '$dsrm_pwd' -AsPlainText -Force; `$cred = New-Object System.Management.Automation.PSCredential('$netbios\nexusadmin', (ConvertTo-SecureString '$nexusadmin_pwd' -AsPlainText -Force)); Install-ADDSDomainController -DomainName '$domain' -Credential `$cred -SafeModeAdministratorPassword `$dsrm -InstallDns:`$true -CreateDnsDelegation:`$false -ReplicationSourceDC '$source_dc' -SiteName 'Default-First-Site-Name' -DatabasePath 'C:\Windows\NTDS' -LogPath 'C:\Windows\NTDS' -SysvolPath 'C:\Windows\SYSVOL' -Force:`$true -NoRebootOnCompletion:`$false"
      $b64 = [Convert]::ToBase64String([System.Text.UnicodeEncoding]::Unicode.GetBytes($remote))

      Write-Host "[dc-nexus-2 promote] dispatching Install-ADDSDomainController via -EncodedCommand (script bytes: $($remote.Length))"
      # SSH stays alive while Install-ADDSDomainController runs (~5-10 min)
      # then auto-reboot kicks. SSH exit may be 0 (clean) or 255 (drop).
      ssh -o ConnectTimeout=30 nexusadmin@$ip "powershell -NoProfile -EncodedCommand $b64"
      $rc = $LASTEXITCODE
      Write-Host "[dc-nexus-2 promote] command issued (ssh exit=$rc); reboot will follow"
    PWSH
  }
}

# ─── 6. Wait for AD DS to come up post-promotion reboot ──────────────────
resource "null_resource" "dc_nexus_2_wait_promoted" {
  count = var.enable_dc_nexus_2 && var.enable_dc_nexus_2_promotion ? 1 : 0

  triggers = {
    promote_id              = null_resource.dc_nexus_2_promote[0].id
    wait_promoted_overlay_v = "1"
  }

  depends_on = [null_resource.dc_nexus_2_promote]

  provisioner "local-exec" {
    when        = create
    interpreter = ["pwsh", "-NoProfile", "-Command"]
    command     = <<-PWSH
      $ip       = '${local.dc_nexus_2_ip}'
      $domain   = '${var.ad_domain}'
      # Promotion takes longer than rename/join -- 2x the standard timeout.
      $timeout  = ${var.dc_promotion_timeout_minutes * 2}
      $deadline = (Get-Date).AddMinutes($timeout)

      Start-Sleep -Seconds 120  # AD DS bootstrap takes minutes
      Write-Host "[dc-nexus-2 wait_promoted] polling (Get-ADDomain).Forest == $domain on $ip (timeout: $${timeout}m)"
      while ((Get-Date) -lt $deadline) {
        Start-Sleep -Seconds 30
        $raw = ssh -o ConnectTimeout=10 nexusadmin@$ip 'powershell -NoProfile -Command "try { (Get-ADDomain -ErrorAction Stop).Forest } catch { }"' 2>$null
        $f   = if ($raw) { $raw.Trim() } else { '' }
        if ($f -ieq $domain) {
          Write-Host "[dc-nexus-2 wait_promoted] domain $domain live on $ip"
          exit 0
        }
        Write-Host "[dc-nexus-2 wait_promoted] not ready (got: '$f'), retrying..."
      }
      throw "[dc-nexus-2 wait_promoted] timed out after $${timeout}m -- AD DS never came up on $ip"
    PWSH
  }
}

# ─── 7. Verify replication health (Get-ADDomainController + repadmin) ────
resource "null_resource" "dc_nexus_2_verify" {
  count = var.enable_dc_nexus_2 && var.enable_dc_nexus_2_promotion ? 1 : 0

  triggers = {
    wait_promoted_id = null_resource.dc_nexus_2_wait_promoted[0].id
    verify_overlay_v = "1"
  }

  depends_on = [null_resource.dc_nexus_2_wait_promoted]

  provisioner "local-exec" {
    when        = create
    interpreter = ["pwsh", "-NoProfile", "-Command"]
    command     = <<-PWSH
      $dc1_ip = '${local.dc_nexus_ip}'
      $dc2_ip = '${local.dc_nexus_2_ip}'

      Write-Host "[dc-nexus-2 verify] === Get-ADDomainController -Identity dc-nexus-2 (from dc-nexus) ==="
      ssh nexusadmin@$dc1_ip 'powershell -NoProfile -Command "Get-ADDomainController -Identity dc-nexus-2 | Format-List HostName, IPv4Address, Site, IsGlobalCatalog, OperatingSystem"'

      Write-Host "[dc-nexus-2 verify] === Get-ADDomain (from dc-nexus-2 itself) ==="
      ssh nexusadmin@$dc2_ip 'powershell -NoProfile -Command "Get-ADDomain | Format-List Forest, DomainMode, NetBIOSName, DistinguishedName"'

      Write-Host "[dc-nexus-2 verify] === repadmin /showrepl (from dc-nexus, both directions) ==="
      # Brief settle so the first replication cycle has a chance to complete.
      Start-Sleep -Seconds 60
      ssh nexusadmin@$dc1_ip 'powershell -NoProfile -Command "repadmin /showrepl /csv | Select-Object -First 30"'

      Write-Host "[dc-nexus-2 verify] === forest replication status (Get-ADReplicationPartnerMetadata) ==="
      ssh nexusadmin@$dc1_ip 'powershell -NoProfile -Command "Get-ADReplicationPartnerMetadata -Target dc-nexus.nexus.lab -PartnerType Both -ErrorAction SilentlyContinue | Format-Table Partner, LastReplicationSuccess, LastReplicationResult"'
    PWSH
  }
}
