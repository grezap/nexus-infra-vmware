/*
 * role-overlay-dc-gmsa.tf -- Phase 0.D.5 step 3/5
 *
 * GMSA infrastructure scaffolding (no actual consumers yet):
 *   1. Add KDS root key on the forest (one-time per forest; enables GMSA
 *      infrastructure).
 *   2. Create AD group `nexus-gmsa-consumers` in OU=Groups -- principals
 *      permitted to retrieve managed passwords for any future GMSA.
 *   3. Create sample GMSA `gmsa-nexus-demo$` in OU=ServiceAccounts with
 *      PrincipalsAllowedToRetrieveManagedPassword set to the consumers
 *      group. Proves the infrastructure works; no actual service
 *      consumes it yet.
 *
 * Why scaffold without consumers: the lab has no SQL Server / IIS /
 * scheduled-task workload that needs GMSA today (NexusPlatform's
 * `02-sqlserver` tier is Phase 0.G+). Setting up the KDS root key now
 * means the first real GMSA consumer (SQL Server service account) just
 * adds itself to nexus-gmsa-consumers and uses
 * Install-ADServiceAccount on the consuming host.
 *
 * Why KDS root key with -EffectiveImmediately: production AD requires
 * waiting 10 hours after Add-KdsRootKey before AD replicates the seed
 * to all DCs (avoids a race where one DC has the root key but another
 * doesn't). In a single-DC lab there's no replication delay, so
 * EffectiveTime can be Get-Date - 10 hours which is functionally
 * "available now". -EffectiveImmediately uses the same trick.
 *
 * Selective ops: enable_dc_promotion + enable_dc_ous (need OU=Groups +
 *                OU=ServiceAccounts) + enable_dc_gmsa (master) +
 *                per-step toggles.
 *
 * Reachability invariant: pure AD object management. No firewall or
 * sshd_config changes; build-host SSH/RDP unaffected.
 */

resource "null_resource" "dc_gmsa_kds_root" {
  count = var.enable_dc_promotion && var.enable_dc_ous && var.enable_dc_gmsa && var.enable_dc_gmsa_kds_root ? 1 : 0

  triggers = {
    dc_verify_id  = null_resource.dc_nexus_verify[0].id
    ous_id        = null_resource.dc_ous[0].id
    membership_id = length(null_resource.dc_nexusadmin_membership) > 0 ? null_resource.dc_nexusadmin_membership[0].id : "disabled"
    kds_overlay_v = "3" # v3 = probe-only + WARN+skip when missing (Server 2025 Add-KdsRootKey returns success GUIDs without persisting -- structural cmdlet bug, manual ops required). v2 = depends_on dc_nexusadmin_membership. v1 = original auto-add (silently no-op'd).
  }

  depends_on = [null_resource.dc_nexus_verify, null_resource.dc_ous, null_resource.dc_nexusadmin_membership]

  provisioner "local-exec" {
    when        = create
    interpreter = ["pwsh", "-NoProfile", "-Command"]
    command     = <<-PWSH
      $ip = '${local.dc_nexus_ip}'

      Write-Host "[dc-gmsa-kds] probing KDS root key state on $ip (auto-add SKIPPED -- structural Server 2025 cmdlet bug)"

      # Diagnostic 2026-05-02: Add-KdsRootKey on Server 2025 returns
      # ERROR_NOT_SUPPORTED (HRESULT 0x80070032) when called as a Domain
      # or Enterprise Admin via SSH. Tested:
      #   - nexusadmin direct (after EA membership): FAIL_DIRECT (0x80070032)
      #   - Administrator via Invoke-Command -ComputerName localhost: returns
      #     a GUID but Get-KdsRootKey still reads count=0 (the key is NOT
      #     persisted to CN=Master Root Keys,CN=Group Key Distribution
      #     Service,CN=Services,CN=Configuration,DC=nexus,DC=lab).
      #   - 64-bit PS via sysnative: FAIL_64BIT (path doesn't exist on
      #     OpenSSH-driven sessions).
      # Both Microsoft.KeyDistributionService cmdlet and the underlying
      # ADSI calls fail under SSH on Server 2025 even with full
      # Enterprise Admin token. Documented in
      # memory/feedback_kds_rootkey_server2025_ssh.md.
      #
      # Workaround: operator runs Add-KdsRootKey from the DC's RDP/console
      # session (where it works). This overlay PROBES current state and
      # warns if the key is missing; it doesn't fail apply.
      $remote = @"
        Import-Module ActiveDirectory;
        `$existing = Get-KdsRootKey -ErrorAction SilentlyContinue;
        if (`$existing -and `$existing.Count -gt 0) {
          Write-Output ('KDS_ROOT_PRESENT: ' + `$existing[0].KeyId);
        } else {
          Write-Output 'KDS_ROOT_MISSING: no KDS root key in the forest. GMSA password retrieval will not work until manual ops adds one. See docs/handbook.md s 1k.2.';
        }
"@
      $bytes = [System.Text.Encoding]::Unicode.GetBytes($remote)
      $b64   = [Convert]::ToBase64String($bytes)
      $output = ssh -o ConnectTimeout=30 -o BatchMode=yes -o StrictHostKeyChecking=no nexusadmin@$ip "powershell -NoProfile -EncodedCommand $b64" 2>&1 | Out-String
      if ($LASTEXITCODE -ne 0 -or -not ($output -match 'KDS_ROOT_(PRESENT|MISSING):')) {
        throw "[dc-gmsa-kds] probe failed (rc=$LASTEXITCODE). Output:`n$output"
      }
      Write-Host "[dc-gmsa-kds] $($output.Trim())"
      if ($output -match 'KDS_ROOT_MISSING') {
        Write-Host "[dc-gmsa-kds] WARN: KDS root key is absent. Sample GMSA gmsa-nexus-demo will exist as an AD object but Test-ADServiceAccount will fail until manual add. RDP into dc-nexus (192.168.70.240) as Administrator + run: Add-KdsRootKey -EffectiveTime ((Get-Date).AddHours(-10))"
      }
    PWSH
  }
}

resource "null_resource" "dc_gmsa_consumers_group" {
  count = var.enable_dc_promotion && var.enable_dc_ous && var.enable_dc_gmsa && var.enable_dc_gmsa_demo_account ? 1 : 0

  triggers = {
    dc_verify_id        = null_resource.dc_nexus_verify[0].id
    ous_id              = null_resource.dc_ous[0].id
    consumers_group     = var.gmsa_consumers_group
    consumers_overlay_v = "1"
  }

  depends_on = [null_resource.dc_nexus_verify, null_resource.dc_ous]

  provisioner "local-exec" {
    when        = create
    interpreter = ["pwsh", "-NoProfile", "-Command"]
    command     = <<-PWSH
      $ip            = '${local.dc_nexus_ip}'
      $dnRoot        = '${local.ad_dn_root}'
      $consumersGrp  = '${var.gmsa_consumers_group}'

      Write-Host "[dc-gmsa-consumers] ensuring AD group $consumersGrp exists in OU=Groups"

      $remote = @"
        Import-Module ActiveDirectory;
        `$grp = Get-ADGroup -Filter "Name -eq '$consumersGrp'" -ErrorAction SilentlyContinue;
        if (`$grp) {
          Write-Output ('GROUP_PRESENT: ' + `$grp.DistinguishedName);
        } else {
          New-ADGroup -Name '$consumersGrp' ``
            -GroupScope Global ``
            -GroupCategory Security ``
            -Path "OU=Groups,$dnRoot" ``
            -Description 'GMSA consumers -- members can retrieve managed passwords for any GMSA whose PrincipalsAllowedToRetrieveManagedPassword includes this group';
          Write-Output ('GROUP_CREATED: CN=$consumersGrp,OU=Groups,$dnRoot');
        }
"@
      $bytes = [System.Text.Encoding]::Unicode.GetBytes($remote)
      $b64   = [Convert]::ToBase64String($bytes)
      $output = ssh -o ConnectTimeout=30 -o BatchMode=yes -o StrictHostKeyChecking=no nexusadmin@$ip "powershell -NoProfile -EncodedCommand $b64" 2>&1 | Out-String
      if ($LASTEXITCODE -ne 0 -or -not ($output -match 'GROUP_(PRESENT|CREATED):')) {
        throw "[dc-gmsa-consumers] group provisioning failed. Output:`n$output"
      }
      Write-Host "[dc-gmsa-consumers] $($output.Trim())"
    PWSH
  }
}

resource "null_resource" "dc_gmsa_demo_account" {
  count = var.enable_dc_promotion && var.enable_dc_ous && var.enable_dc_gmsa && var.enable_dc_gmsa_demo_account ? 1 : 0

  triggers = {
    dc_verify_id    = null_resource.dc_nexus_verify[0].id
    kds_id          = null_resource.dc_gmsa_kds_root[0].id
    consumers_id    = null_resource.dc_gmsa_consumers_group[0].id
    membership_id   = length(null_resource.dc_nexusadmin_membership) > 0 ? null_resource.dc_nexusadmin_membership[0].id : "disabled"
    account_name    = var.gmsa_demo_account_name
    consumers_group = var.gmsa_consumers_group
    demo_overlay_v  = "3" # v3 = tolerant of KDS-root-missing state (Server 2025 cmdlet bug). GMSA object can be created + Principals set even without KDS root; Test-ADServiceAccount only fails until KDS root is added manually. v2 = idempotent Set-Principals after create-or-existing. v1 = create-only.
  }

  depends_on = [
    null_resource.dc_nexus_verify,
    null_resource.dc_ous,
    null_resource.dc_gmsa_kds_root,
    null_resource.dc_gmsa_consumers_group,
    null_resource.dc_nexusadmin_membership,
  ]

  provisioner "local-exec" {
    when        = create
    interpreter = ["pwsh", "-NoProfile", "-Command"]
    command     = <<-PWSH
      $ip            = '${local.dc_nexus_ip}'
      $dnRoot        = '${local.ad_dn_root}'
      $accountName   = '${var.gmsa_demo_account_name}'
      $consumersGrp  = '${var.gmsa_consumers_group}'

      Write-Host "[dc-gmsa-demo] ensuring sample GMSA $accountName$ exists in OU=ServiceAccounts"

      # GMSA naming convention: samAccountName ends with `$`; AD adds it
      # automatically when the Name doesn't include it. Keep -Name without
      # the dollar sign; -SamAccountName with it (explicit) prevents
      # ambiguity.
      $remote = @"
        Import-Module ActiveDirectory;
        `$gmsa = Get-ADServiceAccount -Filter "Name -eq '$accountName'" -Properties PrincipalsAllowedToRetrieveManagedPassword -ErrorAction SilentlyContinue;
        if (-not `$gmsa) {
          # DNSHostName is required for GMSA -- AD uses it as a service
          # principal target. Use the lab-canonical ad_domain pattern.
          New-ADServiceAccount -Name '$accountName' ``
            -SamAccountName ('$accountName' + '$') ``
            -DNSHostName ('$accountName' + '.${local.ad_domain}') ``
            -PrincipalsAllowedToRetrieveManagedPassword '$consumersGrp' ``
            -Path "OU=ServiceAccounts,$dnRoot" ``
            -Description 'Phase 0.D.5 sample GMSA (scaffold; no real consumer yet)' ``
            -Enabled `$true;
          Write-Output ('GMSA_CREATED: CN=$accountName,OU=ServiceAccounts,$dnRoot');
          # Re-fetch for the Principals-list verification below
          `$gmsa = Get-ADServiceAccount -Filter "Name -eq '$accountName'" -Properties PrincipalsAllowedToRetrieveManagedPassword -ErrorAction Stop;
        }

        # Idempotent: ensure consumers group is in PrincipalsAllowedToRetrieveManagedPassword.
        # Some New-ADServiceAccount calls silently drop this when the
        # caller lacks Enterprise Admins (diagnostic 2026-05-02). Set-* it
        # post-create regardless. Get-ADGroup needed because the parameter
        # accepts ADPrincipal objects; a string sAMAccountName works for
        # New- but Set- is stricter.
        `$grpObj = Get-ADGroup -Identity '$consumersGrp' -ErrorAction Stop;
        `$existingPrincipals = `$gmsa.PrincipalsAllowedToRetrieveManagedPassword;
        `$alreadyHasGrp = `$false;
        if (`$existingPrincipals) {
          foreach (`$p in `$existingPrincipals) {
            if (`$p -eq `$grpObj.DistinguishedName) { `$alreadyHasGrp = `$true; break }
          }
        }
        if (`$alreadyHasGrp) {
          Write-Output ('GMSA_PRINCIPALS_OK: ' + `$consumersGrp + ' already in PrincipalsAllowedToRetrieveManagedPassword');
        } else {
          Set-ADServiceAccount -Identity `$gmsa -PrincipalsAllowedToRetrieveManagedPassword `$grpObj.DistinguishedName -ErrorAction Stop;
          Write-Output ('GMSA_PRINCIPALS_SET: ' + `$consumersGrp + ' added to PrincipalsAllowedToRetrieveManagedPassword');
        }
"@
      $bytes = [System.Text.Encoding]::Unicode.GetBytes($remote)
      $b64   = [Convert]::ToBase64String($bytes)
      $output = ssh -o ConnectTimeout=30 -o BatchMode=yes -o StrictHostKeyChecking=no nexusadmin@$ip "powershell -NoProfile -EncodedCommand $b64" 2>&1 | Out-String
      if ($LASTEXITCODE -ne 0 -or -not ($output -match 'GMSA_PRINCIPALS_(OK|SET):')) {
        throw "[dc-gmsa-demo] GMSA provisioning failed (Principals not confirmed). Output:`n$output"
      }
      Write-Host "[dc-gmsa-demo] $($output.Trim())"
    PWSH
  }
}
