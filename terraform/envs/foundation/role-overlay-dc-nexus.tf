/*
 * role-overlay-dc-nexus.tf -- promote dc-nexus into a real domain controller for nexus.lab.
 *
 * Phase 0.C.2 layer that runs ON TOP of module.dc_nexus (the bare ws2025-desktop clone
 * landed by Phase 0.C.1). Five sequential null_resources, each driving a single SSH-over-
 * password / SSH-over-key step against the running clone:
 *
 *   1. rename       -- Rename-Computer dc-nexus + reboot (gives the future DC a stable
 *                      hostname BEFORE promotion; renaming AFTER promotion is messy).
 *   2. wait_renamed -- poll `hostname` over SSH until it returns 'dc-nexus' (~60-120s).
 *   3. promote      -- Install-ADDSForest -DomainName nexus.lab (auto-reboots).
 *   4. wait_promoted -- poll `Get-ADDomain` until DC promotion completes (~3-6 min).
 *   5. verify       -- emit Forest/DomainMode/NetBIOSName for terraform output.
 *
 * Why top-level resources (not nested in module.dc_nexus): per
 * memory/feedback_selective_provisioning.md, role overlays must be independently
 * targetable so iteration loops can taint+re-apply just the overlay without re-cloning
 * the underlying VM. Compose-via-module would force a full module rebuild on every
 * overlay tweak.
 *
 * Selective ops:
 *   - var.enable_dc_promotion (default true) gates the entire overlay.
 *     `terraform apply -var enable_dc_promotion=false` lands the bare clone only.
 *   - Each null_resource is also independently `-target`-able for ad-hoc iteration:
 *       terraform apply -target=null_resource.dc_nexus_promote -auto-approve
 *
 * Idempotency:
 *   - Rename: `Rename-Computer` is a no-op once the hostname matches.
 *   - Promote: `Install-ADDSForest` errors if the forest already exists; the script
 *     short-circuits with `(Get-ADDomain -ErrorAction SilentlyContinue)` first so
 *     re-applies don't fail. The `triggers` block keys off the cloned vmx_path, so
 *     the overlay only re-runs when the underlying VM is replaced.
 *
 * Constraints honored:
 *   - SafeMode admin password lives in var.dsrm_password (sensitive, plaintext default
 *     pre-Phase-0.D; Vault-backed in Phase 0.D).
 *   - SSH passes through ssh-agent / ~/.ssh/config (handbook §0.4 setup). The
 *     local-exec provisioners use bare ssh; if §0.4 isn't done, set the SSH_OPTS
 *     env var to "-i $HOME\.ssh\nexus_gateway_ed25519" before applying.
 */

locals {
  dc_nexus_ip       = "192.168.70.240"
  dc_nexus_hostname = "dc-nexus"
  ad_domain         = var.ad_domain
  ad_netbios        = var.ad_netbios

  # Wrap a remote PowerShell command for Win32-OpenSSH (defaults to cmd.exe shell).
  # Caller passes the inner script; we pre-format the ssh argv so bare PowerShell
  # is invoked NoProfile + bypass execution policy.
  ssh_pwsh_prefix = "ssh nexusadmin@${local.dc_nexus_ip} 'powershell -NoProfile -ExecutionPolicy Bypass -Command"
}

# ─── 1. Rename the random WIN-XXX hostname to dc-nexus ────────────────────
resource "null_resource" "dc_nexus_rename" {
  count = var.enable_dc_promotion ? 1 : 0

  # Re-fire when the underlying VM is replaced (vmx path changes on re-clone).
  triggers = {
    target_vmx       = module.dc_nexus.vm_path
    target_hostname  = local.dc_nexus_hostname
    rename_overlay_v = "1" # bump to force re-rename
  }

  depends_on = [module.dc_nexus]

  provisioner "local-exec" {
    when        = create
    interpreter = ["pwsh", "-NoProfile", "-Command"]
    command     = <<-PWSH
      $ip   = '${local.dc_nexus_ip}'
      $name = '${local.dc_nexus_hostname}'

      # Idempotent: skip rename if the box already reports dc-nexus.
      $current = (ssh nexusadmin@$ip 'powershell -NoProfile -Command "hostname"' 2>$null).Trim()
      if ($current -eq $name) {
        Write-Host "[dc-nexus rename] already $name, skipping rename + reboot."
        exit 0
      }

      Write-Host "[dc-nexus rename] current hostname: $current -> renaming to $name"
      ssh nexusadmin@$ip "powershell -NoProfile -Command `"Rename-Computer -NewName '$name' -Force; Start-Sleep -Seconds 2; Restart-Computer -Force`""
      # SSH connection drops as the box reboots; that's expected.
      Write-Host "[dc-nexus rename] reboot triggered."
    PWSH
  }
}

# ─── 2. Wait for the rename + reboot to complete ─────────────────────────
resource "null_resource" "dc_nexus_wait_renamed" {
  count = var.enable_dc_promotion ? 1 : 0

  triggers = {
    rename_id = null_resource.dc_nexus_rename[0].id
  }

  depends_on = [null_resource.dc_nexus_rename]

  provisioner "local-exec" {
    when        = create
    interpreter = ["pwsh", "-NoProfile", "-Command"]
    command     = <<-PWSH
      $ip       = '${local.dc_nexus_ip}'
      $name     = '${local.dc_nexus_hostname}'
      $timeout  = ${var.dc_promotion_timeout_minutes}
      $deadline = (Get-Date).AddMinutes($timeout)

      Write-Host "[dc-nexus wait_renamed] polling for hostname=$name (timeout: $${timeout}m)"
      while ((Get-Date) -lt $deadline) {
        Start-Sleep -Seconds 15
        # Null-safe Trim: ssh returns empty stdout while port 22 is briefly down
        # during the rename reboot; .Trim() on $null throws InvalidOperation.
        $raw = ssh -o ConnectTimeout=5 nexusadmin@$ip 'powershell -NoProfile -Command "hostname"' 2>$null
        $h   = if ($raw) { $raw.Trim() } else { '' }
        if ($h -eq $name) {
          Write-Host "[dc-nexus wait_renamed] hostname is now $name."
          exit 0
        }
        Write-Host "[dc-nexus wait_renamed] hostname='$h', retrying..."
      }
      throw "[dc-nexus wait_renamed] timed out after $${timeout}m -- hostname never became $name"
    PWSH
  }
}

# ─── 3. Promote to a domain controller (Install-ADDSForest) ───────────────
resource "null_resource" "dc_nexus_promote" {
  count = var.enable_dc_promotion ? 1 : 0

  triggers = {
    wait_id    = null_resource.dc_nexus_wait_renamed[0].id
    ad_domain  = local.ad_domain
    ad_netbios = local.ad_netbios
    promote_v  = "4" # v4 = also bakes post-promotion remediation (nexusadmin password reset + Domain Admins + sshd_config AllowUsers fix)
  }

  depends_on = [null_resource.dc_nexus_wait_renamed]

  provisioner "local-exec" {
    when        = create
    interpreter = ["pwsh", "-NoProfile", "-Command"]
    command     = <<-PWSH
      $ip            = '${local.dc_nexus_ip}'
      $domain        = '${local.ad_domain}'
      $netbios       = '${local.ad_netbios}'
      $dsrm_pwd      = '${var.dsrm_password}'
      $admin_pwd     = '${var.local_administrator_password}'
      $nexusadmin_pwd = '${var.nexusadmin_password}'

      # Idempotency: skip if the forest already exists. Wrap in try/catch
      # because Get-ADDomain throws ResourceUnavailable on workgroup boxes,
      # which -ErrorAction SilentlyContinue doesn't always suppress cleanly
      # over SSH (the WARNING leaks through PowerShell's stderr).
      $existing = ssh nexusadmin@$ip 'powershell -NoProfile -Command "try { (Get-ADDomain -ErrorAction Stop).Forest } catch { }"' 2>$null
      if ($existing) { $existing = $existing.Trim() }
      if ($existing -eq $domain) {
        Write-Host "[dc-nexus promote] forest $domain already exists, skipping promotion."
        exit 0
      }

      # Build install script as a SINGLE LINE then ship via base64-encoded
      # transit (-EncodedCommand).
      #
      # Lessons baked in from promote_v=1..3 attempts:
      #
      # v1 (failed): multi-line `@"..."@` heredoc with backtick line-continuations
      #   got mangled crossing pwsh -> ssh -> cmd.exe -> remote-powershell.
      #   cmd.exe truncated at the first newline. -EncodedCommand sidesteps it.
      #
      # v2 (failed): Install-ADDSForest's prereq check rejected promotion with
      #   "local Administrator password is blank, which might lead to security
      #   issues" because the local Administrator becomes the domain
      #   Administrator on forest creation, and sysprep generalize wipes the
      #   unattend-provided password on every clone. We Set-LocalUser +
      #   Enable-LocalUser BEFORE Install-ADDSForest so the prereq check passes.
      #
      # v3 (incomplete): Install-ADDSForest succeeded but post-promotion the
      #   env was inaccessible -- AD DS converts the local SAM into the AD DB.
      #   The local nexusadmin user survives as a migrated domain user, but:
      #     a) Its password is wiped (similar to lesson #9 from 0.B.6)
      #     b) It's NOT in Domain Admins
      #     c) sshd_config's `AllowUsers nexusadmin` doesn't match the
      #        domain-prefixed `nexus\nexusadmin` form used post-promotion
      #   Result: SSH rejected every login with "not allowed because not
      #   listed in AllowUsers" (visible in OpenSSH/Operational event log).
      #
      # v4 fixes all three by appending these steps to the promote script,
      # AFTER Install-ADDSForest completes but BEFORE the reboot:
      #   - Set-ADAccountPassword nexusadmin -Reset -NewPassword <bootstrap>
      #   - Add-ADGroupMember 'Domain Admins' -Members nexusadmin
      #   - Patch sshd_config: comment out `AllowUsers nexusadmin` line
      #     (trust = pubkey + Administrators group membership; no need to
      #     enumerate users post-AD)
      #   - Restart-Service sshd to load the new sshd_config
      $remote = "Set-LocalUser -Name 'Administrator' -Password (ConvertTo-SecureString '$admin_pwd' -AsPlainText -Force) -PasswordNeverExpires `$true; Enable-LocalUser -Name 'Administrator'; Install-WindowsFeature AD-Domain-Services -IncludeManagementTools | Out-Null; Import-Module ADDSDeployment; `$securePwd = ConvertTo-SecureString '$dsrm_pwd' -AsPlainText -Force; Install-ADDSForest -DomainName '$domain' -DomainNetbiosName '$netbios' -SafeModeAdministratorPassword `$securePwd -InstallDns -CreateDnsDelegation:`$false -DatabasePath 'C:\Windows\NTDS' -LogPath 'C:\Windows\NTDS' -SysvolPath 'C:\Windows\SYSVOL' -Force -NoRebootOnCompletion; Start-Sleep -Seconds 10; Import-Module ActiveDirectory; Set-ADAccountPassword -Identity nexusadmin -Reset -NewPassword (ConvertTo-SecureString '$nexusadmin_pwd' -AsPlainText -Force); Enable-ADAccount -Identity nexusadmin; Add-ADGroupMember -Identity 'Domain Admins' -Members nexusadmin; `$cfg = Get-Content 'C:\ProgramData\ssh\sshd_config'; `$cfg = `$cfg -replace '^\s*AllowUsers.*$', '# AllowUsers (removed post-AD-promotion: trust = pubkey + Administrators group membership)'; `$cfg | Set-Content 'C:\ProgramData\ssh\sshd_config' -Encoding ascii; Restart-Service sshd -Force; Start-Sleep -Seconds 5; shutdown /r /t 0"
      $bytes = [System.Text.Encoding]::Unicode.GetBytes($remote)
      $b64   = [Convert]::ToBase64String($bytes)

      Write-Host "[dc-nexus promote] dispatching Install-ADDSForest + post-promotion remediation via -EncodedCommand (script bytes: $($remote.Length))..."
      # SSH session stays alive while Install-ADDSForest runs (~3-5 min) +
      # post-promotion AD ops (~10 sec) then we explicitly shutdown /r.
      # SSH may exit 0 (clean) or 255 (connection dropped during reboot kick).
      ssh nexusadmin@$ip "powershell -NoProfile -EncodedCommand $b64"
      $rc = $LASTEXITCODE
      Write-Host "[dc-nexus promote] command issued (ssh exit=$rc); reboot will follow. wait_promoted will poll for AD DS to come back."
    PWSH
  }
}

# ─── 4. Wait for AD DS to be live after the promotion reboot ─────────────
resource "null_resource" "dc_nexus_wait_promoted" {
  count = var.enable_dc_promotion ? 1 : 0

  triggers = {
    promote_id = null_resource.dc_nexus_promote[0].id
  }

  depends_on = [null_resource.dc_nexus_promote]

  provisioner "local-exec" {
    when        = create
    interpreter = ["pwsh", "-NoProfile", "-Command"]
    command     = <<-PWSH
      $ip       = '${local.dc_nexus_ip}'
      $domain   = '${local.ad_domain}'
      $timeout  = ${var.dc_promotion_timeout_minutes}
      $deadline = (Get-Date).AddMinutes($timeout)

      Write-Host "[dc-nexus wait_promoted] polling Get-ADDomain.Forest == $domain (timeout: $${timeout}m)"
      while ((Get-Date) -lt $deadline) {
        Start-Sleep -Seconds 30
        # Wrap Get-ADDomain in try/catch -- on a workgroup or freshly-rebooting
        # box it throws ResourceUnavailable, and -ErrorAction SilentlyContinue
        # leaves a WARNING that confuses the empty-string check.
        $raw = ssh -o ConnectTimeout=5 nexusadmin@$ip 'powershell -NoProfile -Command "try { (Get-ADDomain -ErrorAction Stop).Forest } catch { }"' 2>$null
        $f   = if ($raw) { $raw.Trim() } else { '' }
        if ($f -eq $domain) {
          Write-Host "[dc-nexus wait_promoted] domain $domain is live."
          exit 0
        }
        Write-Host "[dc-nexus wait_promoted] not ready yet (got: '$f'), retrying..."
      }
      throw "[dc-nexus wait_promoted] timed out after $${timeout}m -- AD DS never came up"
    PWSH
  }
}

# ─── 5. Capture domain info for terraform output ─────────────────────────
resource "null_resource" "dc_nexus_verify" {
  count = var.enable_dc_promotion ? 1 : 0

  triggers = {
    wait_promoted_id = null_resource.dc_nexus_wait_promoted[0].id
  }

  depends_on = [null_resource.dc_nexus_wait_promoted]

  provisioner "local-exec" {
    when        = create
    interpreter = ["pwsh", "-NoProfile", "-Command"]
    command     = <<-PWSH
      $ip = '${local.dc_nexus_ip}'
      Write-Host "[dc-nexus verify] === Get-ADDomain ==="
      ssh nexusadmin@$ip 'powershell -NoProfile -Command "Get-ADDomain | Format-List Forest, DomainMode, ForestMode, NetBIOSName, DistinguishedName"'
      Write-Host "[dc-nexus verify] === Get-ADForest ==="
      ssh nexusadmin@$ip 'powershell -NoProfile -Command "Get-ADForest | Format-List Name, ForestMode, RootDomain, GlobalCatalogs"'
    PWSH
  }
}
