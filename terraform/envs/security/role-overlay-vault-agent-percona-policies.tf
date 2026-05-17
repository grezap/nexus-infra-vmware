/*
 * role-overlay-vault-agent-percona-policies.tf -- Phase 0.G.3 setup
 *
 * One narrow Vault policy per percona/proxysql node Vault Agent, with
 * differentiated KV grants between PXC nodes and ProxySQL nodes:
 *
 *   nexus-agent-pxc-1        -- PXC Galera node 1 (initial bootstrap)
 *   nexus-agent-pxc-2        -- PXC Galera node 2
 *   nexus-agent-pxc-3        -- PXC Galera node 3
 *   nexus-agent-proxysql-1   -- ProxySQL inst 1 (keepalived MASTER candidate for VIP .50)
 *   nexus-agent-proxysql-2   -- ProxySQL inst 2 (keepalived BACKUP for VIP .50)
 *
 * Permissions matrix (PXC vs ProxySQL):
 *
 *   PXC nodes (nexus-agent-pxc-{1,2,3}):
 *     - PKI issue on pki_int/issue/<percona_role>           (all 3)
 *     - KV read on nexus/data/oltp/percona/cluster-password (all 3 -- wsrep_sst)
 *     - KV read on nexus/data/oltp/percona/monitor-password (all 3 -- clustercheck)
 *     - KV read on nexus/data/oltp/percona/root-password    (all 3 -- mysql root)
 *     - token self-lookup + self-renew                      (all 3)
 *
 *   ProxySQL nodes (nexus-agent-proxysql-{1,2}):
 *     - PKI issue on pki_int/issue/<percona_role>                 (both)
 *     - KV read on nexus/data/oltp/percona/cluster-password       (both -- to dial PXC backends)
 *     - KV read on nexus/data/oltp/percona/monitor-password       (both -- clustercheck)
 *     - KV read on nexus/data/oltp/percona/proxysql-admin-password (both -- :6032 admin)
 *     - token self-lookup + self-renew                            (both)
 *
 * The KV paths use the v2 secrets engine convention: `nexus/data/oltp/
 * percona/<name>-password` is the policy capability path (KV-v2 inserts
 * the `/data/` segment); `nexus/oltp/percona/<name>-password` is the
 * CLI-facing path. The percona-cluster-creds-seed overlay seeds the CLI
 * paths; these policies grant read on the corresponding policy paths.
 *
 * Idempotency: vault policy write is upsert.
 *
 * Selective ops: var.enable_percona_agent_setup (master) AND
 *                var.enable_percona_agent_policies.
 */

locals {
  percona_agent_policy_specs = {
    "nexus-agent-pxc-1"      = { host = "pxc-node-1", role = "pxc" }
    "nexus-agent-pxc-2"      = { host = "pxc-node-2", role = "pxc" }
    "nexus-agent-pxc-3"      = { host = "pxc-node-3", role = "pxc" }
    "nexus-agent-proxysql-1" = { host = "proxysql-1", role = "proxysql" }
    "nexus-agent-proxysql-2" = { host = "proxysql-2", role = "proxysql" }
  }
}

resource "null_resource" "vault_agent_percona_policies" {
  count = var.enable_vault_cluster && var.enable_vault_init && var.enable_percona_agent_setup && var.enable_percona_agent_policies ? 1 : 0

  triggers = {
    post_init_id               = null_resource.vault_post_init[0].id
    percona_role_id            = length(null_resource.vault_pki_percona_role) > 0 ? null_resource.vault_pki_percona_role[0].id : "disabled"
    percona_role_name          = var.vault_pki_percona_role_name
    creds_seed_id              = length(null_resource.vault_percona_cluster_creds_seed) > 0 ? null_resource.vault_percona_cluster_creds_seed[0].id : "disabled"
    percona_policies_overlay_v = "1" # v1 (0.G.3) = initial 5 narrow policies (3 PXC + 2 ProxySQL) with role-differentiated KV grants.
  }

  depends_on = [
    null_resource.vault_post_init,
    null_resource.vault_pki_percona_role,
    null_resource.vault_percona_cluster_creds_seed,
  ]

  provisioner "local-exec" {
    when        = create
    interpreter = ["pwsh", "-NoProfile", "-Command"]
    command     = <<-PWSH
      $ip          = '${local.vault_1_ip}'
      $user        = '${local.ssh_user}'
      $keysFileRaw = '${var.vault_init_keys_file}'
      $keysFile    = $ExecutionContext.InvokeCommand.ExpandString($keysFileRaw.Replace('$HOME', $env:USERPROFILE))

      if (-not (Test-Path $keysFile)) { throw "[percona-policies] keys file $keysFile missing" }
      $rootToken = (Get-Content $keysFile | ConvertFrom-Json).root_token

      # Two policy bodies -- PXC nodes get root-password KV grant, ProxySQL
      # nodes get proxysql-admin-password KV grant. Cluster + monitor are
      # shared by all 5. Body assembled per-spec below.

      $pxcPolicy = @"
# Phase 0.G.3 setup -- agent policy for PXC Galera nodes (HOSTNAME placeholder
# substituted per-policy below). Grants PKI leaf issuance + KV reads on the
# 3 PXC-relevant creds + token self-mgmt.
path "pki_int/issue/${var.vault_pki_percona_role_name}" {
  capabilities = ["create", "update"]
}
path "nexus/data/oltp/percona/cluster-password" {
  capabilities = ["read"]
}
path "nexus/data/oltp/percona/monitor-password" {
  capabilities = ["read"]
}
path "nexus/data/oltp/percona/root-password" {
  capabilities = ["read"]
}
path "auth/token/lookup-self" {
  capabilities = ["read"]
}
path "auth/token/renew-self" {
  capabilities = ["update"]
}
"@

      $proxysqlPolicy = @"
# Phase 0.G.3 setup -- agent policy for ProxySQL nodes (HOSTNAME placeholder
# substituted per-policy below). Grants PKI leaf issuance + KV reads on the
# cluster + monitor (to dial PXC backends + run clustercheck) + proxysql-admin
# (for the :6032 admin interface) + token self-mgmt.
path "pki_int/issue/${var.vault_pki_percona_role_name}" {
  capabilities = ["create", "update"]
}
path "nexus/data/oltp/percona/cluster-password" {
  capabilities = ["read"]
}
path "nexus/data/oltp/percona/monitor-password" {
  capabilities = ["read"]
}
path "nexus/data/oltp/percona/proxysql-admin-password" {
  capabilities = ["read"]
}
path "auth/token/lookup-self" {
  capabilities = ["read"]
}
path "auth/token/renew-self" {
  capabilities = ["update"]
}
"@

      $specs = @(
%{for name, spec in local.percona_agent_policy_specs~}
        @{ Name = '${name}'; Host = '${spec.host}'; Role = '${spec.role}' },
%{endfor~}
        $null
      ) | Where-Object { $_ -ne $null }

      foreach ($s in $specs) {
        $name = $s.Name
        $hostName = $s.Host
        $role = $s.Role
        $policyBody = if ($role -eq 'pxc') { $pxcPolicy } else { $proxysqlPolicy }
        $bodyRendered = $policyBody -replace 'HOSTNAME', $hostName

        $bodyBytes = [System.Text.UTF8Encoding]::new($false).GetBytes($bodyRendered)
        $bodyB64   = [Convert]::ToBase64String($bodyBytes)

        $remoteBash = @"
set -euo pipefail
export VAULT_TOKEN='$rootToken'
export VAULT_SKIP_VERIFY=true
export VAULT_ADDR=https://127.0.0.1:8200
echo '$bodyB64' | base64 -d | vault policy write $name - >/dev/null
echo "[percona-policies] wrote policy $name ($role)"
"@
        $remoteBytes = [System.Text.UTF8Encoding]::new($false).GetBytes($remoteBash)
        $remoteB64   = [Convert]::ToBase64String($remoteBytes)

        Write-Host "[percona-policies] writing $name ($role policy for $hostName)"
        $output = ssh -o ConnectTimeout=15 -o BatchMode=yes -o StrictHostKeyChecking=no $user@$ip "echo '$remoteB64' | base64 -d | bash" 2>&1 | Out-String
        if ($LASTEXITCODE -ne 0) {
          Write-Host $output.Trim()
          throw "[percona-policies] failed writing $name (rc=$LASTEXITCODE)"
        }
        Write-Host $output.Trim()
      }

      Write-Host "[percona-policies] all $($specs.Count) percona/proxysql policies written"
    PWSH
  }
}
