/*
 * role-overlay-vault-agent-sqlserver-policies.tf -- Phase 0.G.7 setup
 *
 * One narrow Vault policy per SQL Server node Vault Agent, with role-
 * differentiated KV grants across FCI nodes vs AG replica nodes:
 *
 *   nexus-agent-sql-fci-1     -- FCI node 1 (WSFC + iSCSI initiator)
 *   nexus-agent-sql-fci-2     -- FCI node 2 (WSFC + iSCSI initiator)
 *   nexus-agent-sql-ag-rep-1  -- AG async replica 1 (WSFC; no iSCSI)
 *   nexus-agent-sql-ag-rep-2  -- AG async replica 2 (WSFC; no iSCSI)
 *
 * Permissions matrix (FCI vs AG-replica):
 *
 *   FCI nodes (nexus-agent-sql-fci-{1,2}):
 *     - PKI issue on pki_int/issue/<sqlserver_role>                 (both)
 *     - KV read on nexus/data/oltp/sqlserver/sa-password            (both -- emergency operator)
 *     - KV read on nexus/data/oltp/sqlserver/ag-endpoint-cert-password (both -- AG endpoint cert PFX)
 *     - KV read on nexus/data/oltp/sqlserver/wsfc-cluster-admin-password (both -- WSFC bootstrap break-glass)
 *     - KV read on nexus/data/oltp/sqlserver/iscsi-chap-secret      (both -- iSCSI initiator auth)
 *     - KV read on nexus/data/oltp/sqlserver/listener-cert-password (both -- Listener cert PFX import)
 *     - KV read on nexus/data/oltp/sqlserver/gmsa-info              (both -- SQL service GMSA pointer)
 *     - token self-lookup + self-renew                              (both)
 *
 *   AG-replica nodes (nexus-agent-sql-ag-rep-{1,2}):
 *     - PKI issue on pki_int/issue/<sqlserver_role>                 (both)
 *     - KV read on nexus/data/oltp/sqlserver/sa-password            (both)
 *     - KV read on nexus/data/oltp/sqlserver/ag-endpoint-cert-password (both)
 *     - KV read on nexus/data/oltp/sqlserver/listener-cert-password (both)
 *     - KV read on nexus/data/oltp/sqlserver/gmsa-info              (both)
 *     - token self-lookup + self-renew                              (both)
 *     (NO iSCSI, NO WSFC-cluster-admin -- AG replicas use local storage
 *     and inherit cluster admin via domain Group Policy after join.)
 *
 * The KV paths use the v2 secrets engine convention: `nexus/data/oltp/
 * sqlserver/<name>-password` is the policy capability path (KV-v2 inserts
 * the `/data/` segment); `nexus/oltp/sqlserver/<name>-password` is the
 * CLI-facing path. The sqlserver-cluster-creds-seed overlay seeds the CLI
 * paths; these policies grant read on the corresponding policy paths.
 *
 * Idempotency: vault policy write is upsert.
 *
 * Selective ops: var.enable_sqlserver_agent_setup (master) AND
 *                var.enable_sqlserver_agent_policies.
 */

locals {
  sqlserver_agent_policy_specs = {
    "nexus-agent-sql-fci-1"    = { host = "sql-fci-1", role = "fci" }
    "nexus-agent-sql-fci-2"    = { host = "sql-fci-2", role = "fci" }
    "nexus-agent-sql-ag-rep-1" = { host = "sql-ag-rep-1", role = "ag-replica" }
    "nexus-agent-sql-ag-rep-2" = { host = "sql-ag-rep-2", role = "ag-replica" }
  }
}

resource "null_resource" "vault_agent_sqlserver_policies" {
  count = var.enable_vault_cluster && var.enable_vault_init && var.enable_sqlserver_agent_setup && var.enable_sqlserver_agent_policies ? 1 : 0

  triggers = {
    post_init_id                 = null_resource.vault_post_init[0].id
    sqlserver_role_id            = length(null_resource.vault_pki_sqlserver_role) > 0 ? null_resource.vault_pki_sqlserver_role[0].id : "disabled"
    sqlserver_role_name          = var.vault_pki_sqlserver_role_name
    creds_seed_id                = length(null_resource.vault_sqlserver_cluster_creds_seed) > 0 ? null_resource.vault_sqlserver_cluster_creds_seed[0].id : "disabled"
    sqlserver_policies_overlay_v = "2" # v2 (0.G.7 cold-rebuild 2026-06-15) = FCI policy gains read on operator-password (nexus-cluster-admin SQL login; nexus-cli v0.6.6). v1 = initial 4 narrow policies (2 FCI + 2 AG-replica) role-differentiated; FCI full 7-KV bundle, AG-replicas drop iscsi + wsfc-cluster-admin.
  }

  depends_on = [
    null_resource.vault_post_init,
    null_resource.vault_pki_sqlserver_role,
    null_resource.vault_sqlserver_cluster_creds_seed,
  ]

  provisioner "local-exec" {
    when        = create
    interpreter = ["pwsh", "-NoProfile", "-Command"]
    command     = <<-PWSH
      $ip          = '${local.vault_1_ip}'
      $user        = '${local.ssh_user}'
      $keysFileRaw = '${var.vault_init_keys_file}'
      $keysFile    = $ExecutionContext.InvokeCommand.ExpandString($keysFileRaw.Replace('$HOME', $env:USERPROFILE))

      if (-not (Test-Path $keysFile)) { throw "[sqlserver-policies] keys file $keysFile missing" }
      $rootToken = (Get-Content $keysFile | ConvertFrom-Json).root_token

      $fciPolicy = @"
# Phase 0.G.7 setup -- agent policy for SQL Server FCI nodes (HOSTNAME
# placeholder substituted per-policy below). Grants PKI leaf issuance + KV
# reads on the 7 FCI-relevant creds (sa, ag-endpoint-cert, wsfc-cluster-admin,
# iscsi-chap-secret, listener-cert, gmsa-info) + token self-mgmt.
path "pki_int/issue/${var.vault_pki_sqlserver_role_name}" {
  capabilities = ["create", "update"]
}
path "nexus/data/oltp/sqlserver/sa-password" {
  capabilities = ["read"]
}
path "nexus/data/oltp/sqlserver/ag-endpoint-cert-password" {
  capabilities = ["read"]
}
path "nexus/data/oltp/sqlserver/wsfc-cluster-admin-password" {
  capabilities = ["read"]
}
path "nexus/data/oltp/sqlserver/iscsi-chap-secret" {
  capabilities = ["read"]
}
path "nexus/data/oltp/sqlserver/listener-cert-password" {
  capabilities = ["read"]
}
path "nexus/data/oltp/sqlserver/gmsa-info" {
  capabilities = ["read"]
}
# operator-password (nexus-cluster-admin SQL login; nexus-cli v0.6.6 SqlFci/SqlAg
# adapters). The oltp-sqlserver operator-login overlay reads it via sql-fci-1's
# AppRole token on the build host. FCI-only grant (the login lives on the FCI; the
# standalone replicas are Windows-auth-only). Added 2026-06-15 -- the cold-rebuild
# surfaced the missing grant (Invoke-RestMethod permission denied at operator_login).
path "nexus/data/oltp/sqlserver/operator-password" {
  capabilities = ["read"]
}
path "auth/token/lookup-self" {
  capabilities = ["read"]
}
path "auth/token/renew-self" {
  capabilities = ["update"]
}
"@

      $agReplicaPolicy = @"
# Phase 0.G.7 setup -- agent policy for SQL Server AG async replica nodes
# (HOSTNAME placeholder substituted per-policy below). Grants PKI leaf
# issuance + KV reads on the 5 AG-replica-relevant creds (sa, ag-endpoint-cert,
# listener-cert, gmsa-info) + token self-mgmt. NO iscsi-chap (local storage,
# no iSCSI initiator) + NO wsfc-cluster-admin (inherits cluster admin via
# Domain Admins after AD join).
path "pki_int/issue/${var.vault_pki_sqlserver_role_name}" {
  capabilities = ["create", "update"]
}
path "nexus/data/oltp/sqlserver/sa-password" {
  capabilities = ["read"]
}
path "nexus/data/oltp/sqlserver/ag-endpoint-cert-password" {
  capabilities = ["read"]
}
path "nexus/data/oltp/sqlserver/listener-cert-password" {
  capabilities = ["read"]
}
path "nexus/data/oltp/sqlserver/gmsa-info" {
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
%{for name, spec in local.sqlserver_agent_policy_specs~}
        @{ Name = '${name}'; Host = '${spec.host}'; Role = '${spec.role}' },
%{endfor~}
        $null
      ) | Where-Object { $_ -ne $null }

      foreach ($s in $specs) {
        $name = $s.Name
        $hostName = $s.Host
        $role = $s.Role
        $policyBody = switch ($role) {
          'fci'        { $fciPolicy }
          'ag-replica' { $agReplicaPolicy }
        }
        $bodyRendered = $policyBody -replace 'HOSTNAME', $hostName

        $bodyBytes = [System.Text.UTF8Encoding]::new($false).GetBytes($bodyRendered)
        $bodyB64   = [Convert]::ToBase64String($bodyBytes)

        $remoteBash = @"
set -euo pipefail
export VAULT_TOKEN='$rootToken'
export VAULT_SKIP_VERIFY=true
export VAULT_ADDR=https://127.0.0.1:8200
echo '$bodyB64' | base64 -d | vault policy write $name - >/dev/null
echo "[sqlserver-policies] wrote policy $name ($role)"
"@
        $remoteBytes = [System.Text.UTF8Encoding]::new($false).GetBytes($remoteBash)
        $remoteB64   = [Convert]::ToBase64String($remoteBytes)

        Write-Host "[sqlserver-policies] writing $name ($role policy for $hostName)"
        $output = ssh -o ConnectTimeout=15 -o BatchMode=yes -o StrictHostKeyChecking=no $user@$ip "echo '$remoteB64' | base64 -d | bash" 2>&1 | Out-String
        if ($LASTEXITCODE -ne 0) {
          Write-Host $output.Trim()
          throw "[sqlserver-policies] failed writing $name (rc=$LASTEXITCODE)"
        }
        Write-Host $output.Trim()
      }

      Write-Host "[sqlserver-policies] all $($specs.Count) SQL Server policies written"
    PWSH
  }
}
