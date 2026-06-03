/*
 * role-overlay-vault-agent-citus-policies.tf -- Phase 0.P setup
 *
 * One narrow Vault policy per Citus-tier node Vault Agent, role-differentiated
 * across pg (coordinator + worker) vs etcd:
 *
 *   nexus-agent-citus-etcd-{1,2,3}        -- etcd DCS members
 *   nexus-agent-citus-coord-{1,2}         -- coordinator Patroni pair
 *   nexus-agent-citus-worker1-{1,2}       -- worker-group-1 Patroni pair
 *   nexus-agent-citus-worker2-{1,2}       -- worker-group-2 Patroni pair
 *
 * Permissions matrix:
 *   pg   (6): PKI issue + KV read on ALL 4 PG creds (superuser, replication,
 *             patroni-restapi, citus-app) -- every PG node renders patroni.yml
 *             with the superuser + replication + REST creds; the coordinator
 *             pair additionally creates the citus_app role. Coordinator and
 *             worker share one policy shape (both are full Patroni PG nodes;
 *             the Citus role is decided at the SQL layer, not by Vault perms).
 *   etcd (3): PKI issue + token self-mgmt only (DCS store, no PG creds).
 *
 * KV-v2 path convention: `nexus/data/citus/<name>-password` is the policy
 * capability path (KV-v2 inserts `/data/`); `nexus/citus/<name>-password` is
 * the CLI path the creds-seed overlay writes.
 *
 * Idempotency: vault policy write is upsert.
 * Selective ops: var.enable_citus_agent_setup AND var.enable_citus_agent_policies.
 */

locals {
  citus_agent_policy_specs = {
    "nexus-agent-citus-etcd-1"    = { host = "citus-etcd-1", role = "etcd" }
    "nexus-agent-citus-etcd-2"    = { host = "citus-etcd-2", role = "etcd" }
    "nexus-agent-citus-etcd-3"    = { host = "citus-etcd-3", role = "etcd" }
    "nexus-agent-citus-coord-1"   = { host = "citus-coord-1", role = "pg" }
    "nexus-agent-citus-coord-2"   = { host = "citus-coord-2", role = "pg" }
    "nexus-agent-citus-worker1-1" = { host = "citus-worker1-1", role = "pg" }
    "nexus-agent-citus-worker1-2" = { host = "citus-worker1-2", role = "pg" }
    "nexus-agent-citus-worker2-1" = { host = "citus-worker2-1", role = "pg" }
    "nexus-agent-citus-worker2-2" = { host = "citus-worker2-2", role = "pg" }
  }
}

resource "null_resource" "vault_agent_citus_policies" {
  count = var.enable_vault_cluster && var.enable_vault_init && var.enable_citus_agent_setup && var.enable_citus_agent_policies ? 1 : 0

  triggers = {
    post_init_id             = null_resource.vault_post_init[0].id
    citus_role_id            = length(null_resource.vault_pki_citus_role) > 0 ? null_resource.vault_pki_citus_role[0].id : "disabled"
    citus_role_name          = var.vault_pki_citus_role_name
    creds_seed_id            = length(null_resource.vault_citus_cluster_creds_seed) > 0 ? null_resource.vault_citus_cluster_creds_seed[0].id : "disabled"
    citus_policies_overlay_v = "1" # v1 (0.P) = 9 narrow policies (3 etcd + 6 pg) with role-differentiated KV grants.
  }

  depends_on = [
    null_resource.vault_post_init,
    null_resource.vault_pki_citus_role,
    null_resource.vault_citus_cluster_creds_seed,
  ]

  provisioner "local-exec" {
    when        = create
    interpreter = ["pwsh", "-NoProfile", "-Command"]
    command     = <<-PWSH
      $ip          = '${local.vault_1_ip}'
      $user        = '${local.ssh_user}'
      $keysFileRaw = '${var.vault_init_keys_file}'
      $keysFile    = $ExecutionContext.InvokeCommand.ExpandString($keysFileRaw.Replace('$HOME', $env:USERPROFILE))

      if (-not (Test-Path $keysFile)) { throw "[citus-policies] keys file $keysFile missing" }
      $rootToken = (Get-Content $keysFile | ConvertFrom-Json).root_token

      $pgPolicy = @"
# Phase 0.P -- agent policy for Citus PG nodes (coordinator + worker). PKI leaf
# issuance + KV reads on all 4 PG creds + token self-mgmt.
path "pki_int/issue/${var.vault_pki_citus_role_name}" {
  capabilities = ["create", "update"]
}
path "nexus/data/citus/superuser-password" {
  capabilities = ["read"]
}
path "nexus/data/citus/replication-password" {
  capabilities = ["read"]
}
path "nexus/data/citus/patroni-restapi-password" {
  capabilities = ["read"]
}
path "nexus/data/citus/citus-app-password" {
  capabilities = ["read"]
}
path "auth/token/lookup-self" {
  capabilities = ["read"]
}
path "auth/token/renew-self" {
  capabilities = ["update"]
}
"@

      $etcdPolicy = @"
# Phase 0.P -- agent policy for Citus etcd DCS nodes. PKI leaf issuance +
# token self-mgmt (DCS store, no PG creds).
path "pki_int/issue/${var.vault_pki_citus_role_name}" {
  capabilities = ["create", "update"]
}
path "auth/token/lookup-self" {
  capabilities = ["read"]
}
path "auth/token/renew-self" {
  capabilities = ["update"]
}
"@

      $specs = @(
%{for name, spec in local.citus_agent_policy_specs~}
        @{ Name = '${name}'; Host = '${spec.host}'; Role = '${spec.role}' },
%{endfor~}
        $null
      ) | Where-Object { $_ -ne $null }

      foreach ($s in $specs) {
        $name = $s.Name
        $role = $s.Role
        $policyBody = switch ($role) {
          'pg'   { $pgPolicy }
          'etcd' { $etcdPolicy }
        }

        $bodyBytes = [System.Text.UTF8Encoding]::new($false).GetBytes($policyBody)
        $bodyB64   = [Convert]::ToBase64String($bodyBytes)

        $remoteBash = @"
set -euo pipefail
export VAULT_TOKEN='$rootToken'
export VAULT_SKIP_VERIFY=true
export VAULT_ADDR=https://127.0.0.1:8200
echo '$bodyB64' | base64 -d | vault policy write $name - >/dev/null
echo "[citus-policies] wrote policy $name ($role)"
"@
        $remoteBytes = [System.Text.UTF8Encoding]::new($false).GetBytes($remoteBash)
        $remoteB64   = [Convert]::ToBase64String($remoteBytes)

        Write-Host "[citus-policies] writing $name ($role policy)"
        $output = ssh -o ConnectTimeout=15 -o BatchMode=yes -o StrictHostKeyChecking=no $user@$ip "echo '$remoteB64' | base64 -d | bash" 2>&1 | Out-String
        if ($LASTEXITCODE -ne 0) {
          Write-Host $output.Trim()
          throw "[citus-policies] failed writing $name (rc=$LASTEXITCODE)"
        }
        Write-Host $output.Trim()
      }

      Write-Host "[citus-policies] all $($specs.Count) Citus-tier policies written"
    PWSH
  }
}
