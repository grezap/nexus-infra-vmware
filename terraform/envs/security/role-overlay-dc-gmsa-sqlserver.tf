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
    dc_ip            = "192.168.70.240"
    gmsa_name        = "gmsa-sql-engine"
    consumers_group  = "nexus-sql-cluster-members"
    gmsa_overlay_v   = "1" # v1 (0.G.7) = initial gmsa-sql-engine + nexus-sql-cluster-members group; group is empty at security-apply time; populated by oltp env's domain-join overlay.
  }

  provisioner "local-exec" {
    when        = create
    interpreter = ["pwsh", "-NoProfile", "-Command"]
    command     = <<-PWSH
      $ip             = '192.168.70.240'
      $gmsa           = 'gmsa-sql-engine'
      $consumersGrp   = 'nexus-sql-cluster-members'

      Write-Host "[dc-gmsa-sqlserver] ensuring AD group $consumersGrp + GMSA $gmsa exist on dc-nexus ($ip)"

      # The remote script runs on dc-nexus as nexusadmin (who is a member
      # of Enterprise Admins per 0.D.5 role-overlay-dc-nexusadmin-membership).
      # Both creates are idempotent via Get-ADGroup / Get-ADServiceAccount
      # ErrorAction SilentlyContinue probes.
      $remote = @"
        Import-Module ActiveDirectory;
        `$ErrorActionPreference = 'Stop';

        # ── Step 1: nexus-sql-cluster-members AD group in OU=Groups ──────
        `$existingGroup = Get-ADGroup -Filter 'Name -eq ''nexus-sql-cluster-members''' -ErrorAction SilentlyContinue;
        if (`$existingGroup) {
          Write-Output ('GROUP_PRESENT: ' + `$existingGroup.DistinguishedName);
        } else {
          New-ADGroup -Name 'nexus-sql-cluster-members' ``
            -GroupScope DomainLocal ``
            -GroupCategory Security ``
            -Path 'OU=Groups,DC=nexus,DC=lab' ``
            -Description 'SQL Server FCI+AG (Phase 0.G.7) cluster member computer accounts -- PrincipalsAllowedToRetrieveManagedPassword for gmsa-sql-engine. Populated by oltp env role-overlay-sqlserver-domain-join.tf after node domain-join.';
          Write-Output ('GROUP_CREATED: CN=nexus-sql-cluster-members,OU=Groups,DC=nexus,DC=lab');
        }

        # ── Step 2: KDS root key probe (warn but proceed; manual ops if
        #    Server 2025 + missing per memory feedback) ──
        `$kds = Get-KdsRootKey -ErrorAction SilentlyContinue;
        if (-not `$kds -or `$kds.Count -eq 0) {
          Write-Output 'KDS_ROOT_MISSING: GMSA creation may succeed but Test-ADServiceAccount + Install-ADServiceAccount will fail until manual add. RDP dc-nexus + Add-KdsRootKey -EffectiveTime ((Get-Date).AddHours(-10))';
        } else {
          Write-Output ('KDS_ROOT_PRESENT: ' + `$kds[0].KeyId);
        }

        # ── Step 3: gmsa-sql-engine GMSA in OU=ServiceAccounts ──────────
        `$existingGmsa = Get-ADServiceAccount -Filter 'Name -eq ''gmsa-sql-engine''' -ErrorAction SilentlyContinue;
        if (`$existingGmsa) {
          Write-Output ('GMSA_PRESENT: ' + `$existingGmsa.DistinguishedName);
          # Re-set PrincipalsAllowedToRetrieveManagedPassword to ensure the
          # consumer group is the (one) allowed retriever -- idempotent.
          Set-ADServiceAccount -Identity 'gmsa-sql-engine' ``
            -PrincipalsAllowedToRetrieveManagedPassword 'nexus-sql-cluster-members';
          Write-Output ('GMSA_RECONFIGURED: PrincipalsAllowedToRetrieveManagedPassword = nexus-sql-cluster-members');
        } else {
          # New-ADServiceAccount requires the DNSHostName parameter even for
          # GMSAs that are service-account-only (the sAMAccountName itself
          # ends in `$`; DNSHostName is what services advertise). Use the
          # FCI virtual server name as the DNS hostname -- it's the
          # canonical SQL identity that clients connect to.
          try {
            New-ADServiceAccount -Name 'gmsa-sql-engine' ``
              -DNSHostName 'sql-fci-cluster.nexus.lab' ``
              -PrincipalsAllowedToRetrieveManagedPassword 'nexus-sql-cluster-members' ``
              -Path 'OU=ServiceAccounts,DC=nexus,DC=lab' ``
              -Description 'SQL Server service identity for the 02-sqlserver tier FCI+AG cluster (Phase 0.G.7). Consumed by sql-fci-1/2 + sql-ag-rep-1/2 after they join nexus-sql-cluster-members. Password rotated by AD every 30 days.' ``
              -ManagedPasswordIntervalInDays 30;
            Write-Output ('GMSA_CREATED: CN=gmsa-sql-engine,OU=ServiceAccounts,DC=nexus,DC=lab');
          } catch {
            Write-Output ('GMSA_CREATE_FAILED: ' + `$_.Exception.Message);
            if (`$_.Exception.Message -match 'Key does not exist' -or `$_.Exception.Message -match 'KDS') {
              Write-Output 'GMSA_CREATE_FAILED_REASON: KDS root key missing (see KDS_ROOT_MISSING above). Manually add the key via RDP then re-apply.';
              exit 1;
            }
            throw;
          }
        }
"@
      $bytes  = [System.Text.Encoding]::Unicode.GetBytes($remote)
      $b64    = [Convert]::ToBase64String($bytes)
      $output = ssh -o ConnectTimeout=30 -o BatchMode=yes -o StrictHostKeyChecking=no nexusadmin@$ip "powershell -NoProfile -EncodedCommand $b64" 2>&1 | Out-String
      $rc = $LASTEXITCODE
      Write-Host $output.Trim()
      if ($rc -ne 0) {
        throw "[dc-gmsa-sqlserver] script failed (rc=$rc)"
      }
      if ($output -match 'GMSA_CREATE_FAILED_REASON: KDS root key missing') {
        throw "[dc-gmsa-sqlserver] GMSA creation blocked by missing KDS root key. Manual ops required (see operator output above + memory/feedback_kds_rootkey_server2025_ssh.md)."
      }
      if ($output -match 'KDS_ROOT_MISSING') {
        Write-Host "[dc-gmsa-sqlserver] WARN: KDS root key is absent on dc-nexus. GMSA gmsa-sql-engine may exist as an AD object but Test-ADServiceAccount will FAIL on the 4 SQL nodes until manual add. RDP dc-nexus as Administrator + run: Add-KdsRootKey -EffectiveTime ((Get-Date).AddHours(-10))"
      }
    PWSH
  }
}
