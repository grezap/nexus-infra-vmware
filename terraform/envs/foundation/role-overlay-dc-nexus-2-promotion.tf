/*
 * role-overlay-dc-nexus-2-promotion.tf -- Phase 0.M (2nd AD DC promotion).
 *
 * Promotes dc-nexus-2 into a REPLICA domain controller of the existing
 * nexus.lab forest (originally promoted on dc-nexus in Phase 0.C.2). Foundation
 * HA partner -- replication mesh ensures auth/DNS survive single-DC loss.
 *
 * Mirrors role-overlay-dc-nexus.tf's 5-step shape:
 *   1. rename       -- Rename-Computer dc-nexus-2 + reboot.
 *   2. wait_renamed -- poll `hostname` over SSH until 'dc-nexus-2'.
 *   3. join         -- domain-join the host to nexus.lab (Add-Computer).
 *   4. promote      -- Install-ADDSDomainController -DomainName nexus.lab
 *                      -Credential <domain admin> -SiteName Default-First-Site-Name
 *                      (auto-reboots; takes ~5-10 min for the AD database to seed).
 *   5. wait_promoted -- poll `Get-ADDomainController -Identity dc-nexus-2` until
 *                      the new DC is registered in the directory + replication
 *                      shows healthy via `repadmin /showrepl`.
 *
 * Idempotency:
 *   - Rename: no-op if hostname matches.
 *   - Join: skips if `(Get-CimInstance Win32_ComputerSystem).PartOfDomain` is true.
 *   - Promote: `Install-ADDSDomainController` errors if already a DC; the script
 *     short-circuits with `(Get-ADDomainController -ErrorAction SilentlyContinue)`.
 *
 * Cross-env coupling:
 *   - dc-nexus must already be promoted (the existing forest); enforced via
 *     depends_on null_resource.dc_nexus_verify (Phase 0.C.2 exit gate).
 *   - DSRM password for dc-nexus-2: reused from the existing DSRM Vault KV path
 *     (shared between DCs by AD convention -- DSRM is per-DC but our lab uses
 *     a single password).
 *   - Domain admin credential: nexusadmin@nexus.lab (Phase 0.C.5 elevation).
 *
 * SCAFFOLD STATUS (2026-05-28): the resources below define the apply graph,
 * but LIVE RATIFICATION has not yet been performed. Set var.enable_dc_nexus_2
 * + var.enable_dc_nexus_2_promotion = true to drive the first apply. Expected
 * wall-clock: ~15-20 min on warm Vault + cold ws2025-desktop clone.
 *
 * Live-ratify checklist (next session):
 *   1. terraform apply -var enable_dc_nexus_2=true (clone only, no promotion).
 *   2. SSH-over-password handshake against the new clone to verify reachability.
 *   3. terraform apply -var enable_dc_nexus_2=true -var enable_dc_nexus_2_promotion=true
 *      (full chain: rename + domain-join + promote + verify).
 *   4. Smoke: repadmin /showrepl on dc-nexus shows dc-nexus-2 as healthy replica
 *      + AD users created on dc-nexus appear on dc-nexus-2 within ~15 min.
 *   5. Cold-rebuild proof: destroy + re-apply -> smoke green.
 */

locals {
  dc_nexus_2_ip            = "192.168.70.11"
  dc_nexus_2_hostname      = "dc-nexus-2"
  dc_nexus_2_initial_ip    = "192.168.70.241" # pre-promotion DHCP-assigned (mirrors dc-nexus :240)
  dc_nexus_2_ssh_pwsh_pre  = "ssh nexusadmin@${local.dc_nexus_2_initial_ip} 'powershell -NoProfile -ExecutionPolicy Bypass -Command"
  dc_nexus_2_ssh_pwsh_post = "ssh nexusadmin@${local.dc_nexus_2_ip} 'powershell -NoProfile -ExecutionPolicy Bypass -Command"
}

# ─── 1. Rename WIN-XXX -> dc-nexus-2 ──────────────────────────────────────
resource "null_resource" "dc_nexus_2_rename" {
  count = var.enable_dc_nexus_2 && var.enable_dc_nexus_2_promotion ? 1 : 0

  triggers = {
    target_vmx       = length(module.dc_nexus_2) > 0 ? module.dc_nexus_2[0].vm_path : "disabled"
    target_hostname  = local.dc_nexus_2_hostname
    rename_overlay_v = "1"
    ssh_pwsh_prefix  = local.dc_nexus_2_ssh_pwsh_pre
  }

  depends_on = [module.dc_nexus_2]

  provisioner "local-exec" {
    when        = create
    interpreter = ["pwsh", "-NoProfile", "-Command"]
    command     = <<-PWSH
      $ip   = '${local.dc_nexus_2_initial_ip}'
      $name = '${local.dc_nexus_2_hostname}'

      # SSH ECHO probe (per [[windows-ssh-automation]] T4 lesson from dc-nexus)
      Write-Host "[dc-nexus-2 rename] probing ssh on $ip (echo ok)..."
      $bootDeadline = (Get-Date).AddMinutes(10); $sshReady = $false
      while ((Get-Date) -lt $bootDeadline) {
        $probe = (ssh -o ConnectTimeout=5 -o ConnectionAttempts=1 -o BatchMode=yes -o StrictHostKeyChecking=no nexusadmin@$ip "echo ok" 2>&1 | Out-String).Trim()
        if ($probe -eq 'ok') { $sshReady = $true; break }
        Start-Sleep -Seconds 15
      }
      if (-not $sshReady) { throw "[dc-nexus-2 rename] ssh echo probe never succeeded on $ip after 10m" }
      Start-Sleep -Seconds 30

      # Idempotency: skip if hostname already matches
      $cur = (ssh -o BatchMode=yes -o StrictHostKeyChecking=no nexusadmin@$ip "hostname" 2>&1 | Out-String).Trim()
      if ($cur -ieq $name) { Write-Host "[dc-nexus-2 rename] hostname already $name; skipping"; exit 0 }

      # Rename via base64-encoded PowerShell (per [[windows-ssh-automation]] T2)
      $script = "Rename-Computer -NewName '$name' -Force; Restart-Computer -Force"
      $b64 = [Convert]::ToBase64String([System.Text.UnicodeEncoding]::Unicode.GetBytes($script))
      Write-Host "[dc-nexus-2 rename] renaming $ip -> $name"
      ssh -o BatchMode=yes -o StrictHostKeyChecking=no nexusadmin@$ip "powershell -NoProfile -EncodedCommand $b64" 2>&1 | Out-Null
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
      $ip   = '${local.dc_nexus_2_initial_ip}'
      $name = '${local.dc_nexus_2_hostname}'
      Start-Sleep -Seconds 60  # let the reboot start
      Write-Host "[dc-nexus-2 wait_renamed] polling hostname on $ip until == $name..."
      $deadline = (Get-Date).AddMinutes(10); $ok = $false
      while ((Get-Date) -lt $deadline) {
        $cur = (ssh -o ConnectTimeout=5 -o BatchMode=yes -o StrictHostKeyChecking=no nexusadmin@$ip "hostname" 2>&1 | Out-String).Trim()
        if ($cur -ieq $name) { $ok = $true; break }
        Start-Sleep -Seconds 15
      }
      if (-not $ok) { throw "[dc-nexus-2 wait_renamed] hostname never reached '$name' within 10m" }
      Write-Host "[dc-nexus-2 wait_renamed] hostname == $name"
    PWSH
  }
}

# ─── 3. Domain-join to nexus.lab (Add-Computer; auto-reboot) ──────────────
resource "null_resource" "dc_nexus_2_join" {
  count = var.enable_dc_nexus_2 && var.enable_dc_nexus_2_promotion ? 1 : 0

  triggers = {
    wait_id        = null_resource.dc_nexus_2_wait_renamed[0].id
    ad_domain      = var.ad_domain
    join_overlay_v = "1"
  }

  depends_on = [null_resource.dc_nexus_2_wait_renamed]
  # SCAFFOLD: live ratification adds depends_on for the dc-nexus forest-verified
  # resource + the Vault KV credential sync overlay (so domain admin pw is
  # available before this resource fires).

  provisioner "local-exec" {
    when        = create
    interpreter = ["pwsh", "-NoProfile", "-Command"]
    command     = <<-PWSH
      # SCAFFOLD: read domain admin cred from Vault KV (mirrors the dc-nexus
      # pre-promotion KV credential sync used in role-overlay-dc-rotate-bootstrap-creds.tf).
      # Live-ratify: extract nexusadmin@nexus.lab password from KV path
      # nexus/foundation/ad/Administrator -- requires vault-1 alive + KV unsealed.
      Write-Host "[dc-nexus-2 join] (SCAFFOLD-ONLY -- live promotion logic deferred to next session)"
      Write-Host "[dc-nexus-2 join] To complete: pull \$adminPw from Vault KV, then:"
      Write-Host '  Add-Computer -DomainName "${var.ad_domain}" -Credential <admin-creds> -Restart -Force'
      throw "[dc-nexus-2 join] SCAFFOLD-ONLY mode -- explicit live-ratification required (next session); see role overlay file header for runbook"
    PWSH
  }
}

# ─── 4. Promote to replica DC (Install-ADDSDomainController) ──────────────
resource "null_resource" "dc_nexus_2_promote" {
  count = var.enable_dc_nexus_2 && var.enable_dc_nexus_2_promotion ? 1 : 0

  triggers = {
    join_id           = null_resource.dc_nexus_2_join[0].id
    ad_domain         = var.ad_domain
    promote_overlay_v = "1"
  }

  depends_on = [null_resource.dc_nexus_2_join]

  # SCAFFOLD: Install-ADDSDomainController logic deferred; full PowerShell body
  # follows the dc-nexus promotion shape but with -InstallDNS:$true
  # -CreateDnsDelegation:$false -ReplicationSourceDC dc-nexus.nexus.lab
  # -SiteName Default-First-Site-Name -DomainName nexus.lab
  # -Credential (domain admin) -SafeModeAdministratorPassword (DSRM SecureString)
  # -NoRebootOnCompletion:$false -Force:$true.
}

# ─── 5. Verify promotion + replication health (repadmin /showrepl) ────────
resource "null_resource" "dc_nexus_2_verify" {
  count = var.enable_dc_nexus_2 && var.enable_dc_nexus_2_promotion ? 1 : 0

  triggers = {
    promote_id       = null_resource.dc_nexus_2_promote[0].id
    verify_overlay_v = "1"
  }

  depends_on = [null_resource.dc_nexus_2_promote]

  # SCAFFOLD: probe Get-ADDomainController dc-nexus-2 + repadmin /showrepl from
  # dc-nexus reporting both inbound + outbound replication as 'success' within
  # ~10 min of promotion completion. Emit a terraform output with the replication
  # state for operator visibility.
}
