/*
 * role-overlay-dc-gmsa-sqlserver.tf -- Phase 0.G.7 setup
 *
 * Creates the SQL Server-specific GMSA infrastructure on dc-nexus:
 *
 *   1. AD group `nexus-sql-cluster-members` in OU=Groups -- the SQL FCI+AG
 *      cluster member computer accounts (sql-fci-1$, sql-fci-2$,
 *      sql-ag-rep-1$, sql-ag-rep-2$) will be members of this group after
 *      they domain-join. The group is created EMPTY here; the oltp env's
 *      role-overlay-sqlserver-domain-join.tf populates membership post-join.
 *
 *   2. GMSA `gmsa-sql-engine$` in OU=ServiceAccounts with
 *      PrincipalsAllowedToRetrieveManagedPassword = nexus-sql-cluster-members.
 *      This is the SQL Server service account identity. Once the 4 SQL nodes
 *      are domain-joined + added to the consumer group, they call
 *      `Install-ADServiceAccount -Identity gmsa-sql-engine` and SQL Server
 *      runs as nexus.lab\gmsa-sql-engine$.
 *
 * Why GMSA over a regular AD service account: GMSA passwords are AD-managed
 * (rotated every 30 days by the KDS root key from 0.D.5 -- though that
 * was scaffolded with a known structural issue on Server 2025 per
 * memory/feedback_kds_rootkey_server2025_ssh.md). Operator never sees the
 * password; it's never in a config file or KV; lateral-movement attacker
 * who pops one SQL node gets a 30-day-bounded credential, not a static
 * one. The cross-domain-controller password sync of GMSA is the canonical
 * AD pattern for service accounts; this is the first NexusPlatform
 * consumer (the 0.D.5 `gmsa-nexus-demo$` was the scaffolding proof).
 *
 * Why both FCI nodes + AG-replica nodes consume the SAME GMSA: SQL Server
 * AG synchronous-commit relies on all replicas seeing the same security
 * principal as the database engine identity. Using one GMSA across all 4
 * means the AG endpoint cert-auth + the Windows-side service identity
 * agree on `who is the engine?` -- no per-node service-account drift, no
 * per-node SPN registration headaches.
 *
 * Pre-req (foundation env):
 *   - dc-nexus promoted + nexus.lab forest exists
 *   - OU=Groups + OU=ServiceAccounts exist (role-overlay-dc-ous.tf)
 *   - KDS root key present in CN=Master Root Keys (manually if Server
 *     2025; auto on Server 2022 or earlier)
 *   - nexusadmin EA membership (role-overlay-dc-nexusadmin-membership.tf)
 *
 * Selective ops: var.enable_sqlserver_gmsa (default true).
 *
 * Reachability invariant: pure AD object management. No firewall or
 * sshd_config changes on dc-nexus.
 */

resource "null_resource" "dc_gmsa_sqlserver" {
  count = var.enable_sqlserver_gmsa ? 1 : 0

  triggers = {
    dc_ip           = "192.168.70.240"
    gmsa_name       = "gmsa-sql-engine"
    consumers_group = "nexus-sql-cluster-members"
    gmsa_overlay_v  = "2" # v2 (0.G.7 ratify 2026-05-20) = trimmed remote PS script to dodge Windows cmdline limit on `powershell -EncodedCommand` (transient #2; handbook §3.5). v1 was verbose multi-step with try/catch -- exceeded 8191 chars when UTF-16+base64'd.
  }

  provisioner "local-exec" {
    when        = create
    interpreter = ["pwsh", "-NoProfile", "-Command"]
    command     = <<-PWSH
      $ip             = '192.168.70.240'
      $gmsa           = 'gmsa-sql-engine'
      $consumersGrp   = 'nexus-sql-cluster-members'

      Write-Host "[dc-gmsa-sqlserver] ensuring AD group $consumersGrp + GMSA $gmsa exist on dc-nexus ($ip)"

      # Compact remote script -- the verbose version hit Windows' 8191-char
      # cmdline limit on `powershell -EncodedCommand <base64>` (UTF-16
      # encoding doubles the byte count, base64 adds ~33%, so a 4KB script
      # source becomes a ~10KB cmdline arg). Transient #2 at 0.G.7 ratify
      # 2026-05-20 (handbook §3.5). Fix: trim to the minimal Group + GMSA
      # creates; rely on the standalone KDS probe in §0 pre-flight rather
      # than re-checking inline.
      $remote = @"
Import-Module ActiveDirectory; `$ErrorActionPreference='Stop';
if (-not (Get-ADGroup -Filter "Name -eq 'nexus-sql-cluster-members'" -EA 0)) { New-ADGroup -Name 'nexus-sql-cluster-members' -GroupScope DomainLocal -GroupCategory Security -Path 'OU=Groups,DC=nexus,DC=lab' -Description 'Phase 0.G.7 SQL cluster members'; Write-Output 'GROUP_CREATED' } else { Write-Output 'GROUP_PRESENT' }
`$g = Get-ADServiceAccount -Filter "Name -eq 'gmsa-sql-engine'" -EA 0
if (`$g) { Set-ADServiceAccount -Identity 'gmsa-sql-engine' -PrincipalsAllowedToRetrieveManagedPassword 'nexus-sql-cluster-members'; Write-Output 'GMSA_RECONFIGURED' } else { New-ADServiceAccount -Name 'gmsa-sql-engine' -DNSHostName 'sql-fci-cluster.nexus.lab' -PrincipalsAllowedToRetrieveManagedPassword 'nexus-sql-cluster-members' -Path 'OU=ServiceAccounts,DC=nexus,DC=lab' -ManagedPasswordIntervalInDays 30; Write-Output 'GMSA_CREATED' }
"@
      $bytes  = [System.Text.Encoding]::Unicode.GetBytes($remote)
      $b64    = [Convert]::ToBase64String($bytes)
      $output = ssh -o ConnectTimeout=30 -o BatchMode=yes -o StrictHostKeyChecking=no nexusadmin@$ip "powershell -NoProfile -EncodedCommand $b64" 2>&1 | Out-String
      $rc = $LASTEXITCODE
      Write-Host $output.Trim()
      if ($rc -ne 0) {
        throw "[dc-gmsa-sqlserver] script failed (rc=$rc)"
      }
      # KDS root key probe is in §0 pre-flight (handbook s3.5); the
      # standalone probe at top-of-handbook is the canonical place to
      # check, not inline in this overlay. If the key is missing,
      # New-ADServiceAccount throws + rc!=0; the script_failed check
      # above surfaces that.
    PWSH
  }
}
