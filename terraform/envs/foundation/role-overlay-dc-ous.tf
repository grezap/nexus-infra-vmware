/*
 * role-overlay-dc-ous.tf -- canonical OU layout under DC=nexus,DC=lab + move
 * nexus-jumpbox out of the default CN=Computers container into OU=Servers.
 *
 * Phase 0.C.4 layer running on top of:
 *   - null_resource.dc_nexus_verify   (DC must be promoted before AD writes)
 *   - null_resource.jumpbox_verify    (jumpbox must be domain-registered before
 *                                      we can move its computer object)
 *
 * The depends_on list includes both. When enable_jumpbox_domain_join=false the
 * jumpbox_verify resource has count=0 -- terraform's depends_on accepts an empty
 * collection cleanly, and the move-jumpbox phase below short-circuits when
 * Get-ADComputer returns nothing.
 *
 * One null_resource, two phases inside the same encoded script:
 *
 *   PHASE A -- Create OUs (idempotent: Get-ADOrganizationalUnit -ErrorAction
 *              SilentlyContinue probe before each New-ADOrganizationalUnit).
 *
 *     OU=Servers,DC=nexus,DC=lab
 *     OU=Workstations,DC=nexus,DC=lab
 *     OU=ServiceAccounts,DC=nexus,DC=lab
 *     OU=Groups,DC=nexus,DC=lab
 *
 *   PHASE B -- Move nexus-jumpbox from CN=Computers,DC=nexus,DC=lab to
 *              OU=Servers,DC=nexus,DC=lab. Idempotent: skip if already in
 *              OU=Servers; skip silently if computer object doesn't exist
 *              (i.e. when enable_jumpbox_domain_join=false).
 *
 * dc-nexus is intentionally NOT moved -- domain controllers MUST remain in the
 * built-in CN=Domain Controllers container for replication + GPO scoping (this
 * is a Microsoft hard rule, not a convention).
 *
 * Run point: AD-authenticated cmdlets execute on the DC, not the jumpbox. SSH
 * to a member server runs as the local SAM `nexusadmin`, which has no AD
 * context -- Get-ADComputer / Move-ADObject would fail "Unable to contact the
 * server" even with healthy ADWS. See feedback_addsforest_post_promotion.md
 * (last entry).
 *
 * Selective ops (memory/feedback_selective_provisioning.md):
 *   - var.enable_dc_ous (default true) gates the entire overlay.
 *   - Independently `-target`-able:
 *       terraform apply -target=null_resource.dc_ous -auto-approve
 *
 * Reachability invariant (memory/feedback_lab_host_reachability.md):
 *   - This overlay is pure AD object management. It does NOT touch Windows
 *     Firewall, sshd_config, or RDP settings. SSH and RDP from the build host
 *     are unaffected.
 */

resource "null_resource" "dc_ous" {
  count = var.enable_dc_ous ? 1 : 0

  triggers = {
    dc_verify_id     = null_resource.dc_nexus_verify[0].id
    ad_domain        = local.ad_domain
    ad_dn_root       = local.ad_dn_root
    jumpbox_hostname = local.jumpbox_hostname
    ous_overlay_v    = "2" # v2 = wrap Get-ADOrganizationalUnit in try/catch (not -ErrorAction SilentlyContinue) -- on Server 2025 / Win PS 5.1, SilentlyContinue still leaks "Directory object not found" to stderr; try/catch suppresses cleanly. v1 = initial implementation.
  }

  depends_on = [
    null_resource.dc_nexus_verify,
    null_resource.jumpbox_verify,
  ]

  provisioner "local-exec" {
    when        = create
    interpreter = ["pwsh", "-NoProfile", "-Command"]
    command     = <<-PWSH
      $ip          = '${local.dc_nexus_ip}'
      $dnRoot      = '${local.ad_dn_root}'
      $jumpboxName = '${local.jumpbox_hostname}'
      $ouNames     = @('Servers', 'Workstations', 'ServiceAccounts', 'Groups')
      $ouNamesCsv  = ($ouNames | ForEach-Object { "'$_'" }) -join ','

      Write-Host "[dc-ous] dispatching OU layout + jumpbox move on $ip"

      # Single PowerShell script combining BOTH phases. Idempotent across the board.
      # Phase A: ensure each OU exists. Phase B: move jumpbox if computer object
      # exists and is not already in OU=Servers.
      # NOTE: Get-ADOrganizationalUnit is wrapped in try/catch (NOT
      # -ErrorAction SilentlyContinue). On Win PS 5.1 (Server 2025 default)
      # SilentlyContinue still leaks "Directory object not found" to
      # stderr which then surfaces as cosmetic noise in terraform output.
      # try/catch with -ErrorAction Stop converts to terminating, which
      # the catch block silently swallows. Same trick used elsewhere in
      # this repo for AD cmdlets.
      $remote = @"
        Import-Module ActiveDirectory;
        `$created = @();
        `$skipped = @();
        foreach (`$ou in @($ouNamesCsv)) {
          `$dn = "OU=`$ou,$dnRoot";
          `$existing = `$null;
          try { `$existing = Get-ADOrganizationalUnit -Identity `$dn -ErrorAction Stop } catch { `$existing = `$null };
          if (`$existing) {
            `$skipped += `$ou;
          } else {
            New-ADOrganizationalUnit -Name `$ou -Path '$dnRoot' -ProtectedFromAccidentalDeletion `$true;
            `$created += `$ou;
          }
        };
        Write-Output ('OUs created: ' + (`$created -join ',' | Out-String).Trim());
        Write-Output ('OUs already present: ' + (`$skipped -join ',' | Out-String).Trim());
        `$jb = `$null;
        try { `$jb = Get-ADComputer -Filter "Name -eq '$jumpboxName'" -ErrorAction Stop } catch { `$jb = `$null };
        if (-not `$jb) {
          Write-Output 'jumpbox computer object not found (enable_jumpbox_domain_join=false?), skipping move';
        } else {
          `$targetOU = "OU=Servers,$dnRoot";
          if (`$jb.DistinguishedName -like "*,`$targetOU") {
            Write-Output ('jumpbox already in ' + `$targetOU + ', skipping move');
          } else {
            Move-ADObject -Identity `$jb.DistinguishedName -TargetPath `$targetOU;
            `$jbAfter = Get-ADComputer -Identity `$jumpboxName;
            Write-Output ('jumpbox moved to ' + `$jbAfter.DistinguishedName);
          }
        }
"@
      $bytes = [System.Text.Encoding]::Unicode.GetBytes($remote)
      $b64   = [Convert]::ToBase64String($bytes)

      $maxAttempts = 5
      $issued = $false
      for ($i = 1; $i -le $maxAttempts; $i++) {
        $sshOutput = ssh -o ConnectTimeout=15 nexusadmin@$ip "powershell -NoProfile -EncodedCommand $b64" 2>&1 | Out-String
        $rc = $LASTEXITCODE
        if ($sshOutput -notmatch "Connection (timed out|refused)" -and $sshOutput -notmatch "port 22:") {
          Write-Host "[dc-ous] attempt $i succeeded (ssh exit=$rc)"
          if ($sshOutput.Trim()) { Write-Host "[dc-ous] ssh output:`n$($sshOutput.Trim())" }
          $issued = $true
          break
        }
        Write-Host "[dc-ous] attempt $i failed: $($sshOutput.Trim())"
        Start-Sleep -Seconds 10
      }
      if (-not $issued) {
        throw "[dc-ous] all $maxAttempts attempts failed -- OU layout + jumpbox move did not run. Last output: $sshOutput"
      }
    PWSH
  }
}
