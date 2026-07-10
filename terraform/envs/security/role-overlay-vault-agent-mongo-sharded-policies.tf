/*
 * role-overlay-vault-agent-mongo-sharded-policies.tf -- Phase 0.N.1
 *
 * One narrow Vault policy per sharded-mongo-node Vault Agent (11 nodes).
 * Mirrors the 0.G.2 `nexus-agent-mongo-*` shape, scaled to the sharded
 * topology:
 *
 *   nexus-agent-mongo-sharded-mongo-cfg-{1,2,3}       -- config-server RS
 *   nexus-agent-mongo-sharded-mongo-shard-1-{1,2,3}   -- shard-1 RS
 *   nexus-agent-mongo-sharded-mongo-shard-2-{1,2,3}   -- shard-2 RS
 *   nexus-agent-mongo-sharded-mongo-mongos-{1,2}      -- query routers
 *
 * Permissions:
 *   - PKI issue on pki_int/issue/<mongo_sharded_role>  (all 11 -- TLS leaf)
 *   - KV read on nexus/data/oltp/mongo/keyfile         (all 11 -- RS internal
 *       auth shared secret; ALSO the nexus-sharded-admin operator password)
 *   - token self-lookup + self-renew                   (all 11)
 *
 * No smoke-user-password / operator-password grants: the sharded cluster's
 * operator (nexus-sharded-admin) authenticates with the keyFile content as its
 * SCRAM password (per the 0.N keyFile-localhost-exception bootstrap), so the
 * single keyfile KV grant covers both member auth and operator auth.
 *
 * Selective ops: var.enable_mongo_sharded_agent_setup AND
 *                var.enable_mongo_sharded_agent_policies.
 */

locals {
  mongo_sharded_agent_policy_specs = {
    "nexus-agent-mongo-sharded-mongo-cfg-1"     = { host = "mongo-cfg-1" }
    "nexus-agent-mongo-sharded-mongo-cfg-2"     = { host = "mongo-cfg-2" }
    "nexus-agent-mongo-sharded-mongo-cfg-3"     = { host = "mongo-cfg-3" }
    "nexus-agent-mongo-sharded-mongo-shard-1-1" = { host = "mongo-shard-1-1" }
    "nexus-agent-mongo-sharded-mongo-shard-1-2" = { host = "mongo-shard-1-2" }
    "nexus-agent-mongo-sharded-mongo-shard-1-3" = { host = "mongo-shard-1-3" }
    "nexus-agent-mongo-sharded-mongo-shard-2-1" = { host = "mongo-shard-2-1" }
    "nexus-agent-mongo-sharded-mongo-shard-2-2" = { host = "mongo-shard-2-2" }
    "nexus-agent-mongo-sharded-mongo-shard-2-3" = { host = "mongo-shard-2-3" }
    "nexus-agent-mongo-sharded-mongo-mongos-1"  = { host = "mongo-mongos-1" }
    "nexus-agent-mongo-sharded-mongo-mongos-2"  = { host = "mongo-mongos-2" }
  }
}

resource "null_resource" "vault_agent_mongo_sharded_policies" {
  count = var.enable_vault_cluster && var.enable_vault_init && var.enable_mongo_sharded_agent_setup && var.enable_mongo_sharded_agent_policies ? 1 : 0

  triggers = {
    post_init_id                     = null_resource.vault_post_init[0].id
    mongo_sharded_role_id            = length(null_resource.vault_pki_mongo_sharded_role) > 0 ? null_resource.vault_pki_mongo_sharded_role[0].id : "disabled"
    mongo_sharded_role_name          = var.vault_pki_mongo_sharded_role_name
    mongo_sharded_policies_overlay_v = "1" # v1 (0.N.1) = 11-node sharded MongoDB agent policies (PKI issue + keyfile KV read + token self-mgmt).
  }

  depends_on = [null_resource.vault_post_init, null_resource.vault_pki_mongo_sharded_role, null_resource.vault_mongo_keyfile_seed]

  provisioner "local-exec" {
    when        = create
    interpreter = ["pwsh", "-NoProfile", "-Command"]
    command     = <<-PWSH
      $ip          = '${local.vault_1_ip}'
      $user        = '${local.ssh_user}'
      $keysFileRaw = '${var.vault_init_keys_file}'
      $keysFile    = $ExecutionContext.InvokeCommand.ExpandString($keysFileRaw.Replace('$HOME', $env:USERPROFILE))

      if (-not (Test-Path $keysFile)) { throw "[mongo-sharded-policies] keys file $keysFile missing" }
      $rootToken = (Get-Content $keysFile | ConvertFrom-Json).root_token

      # One policy body for all 11 sharded-mongo nodes -- interchangeable from
      # Vault's perspective (same PKI role, same keyFile KV path).
      $mongoPolicy = @"
# Phase 0.N.1 -- agent policy for sharded-mongo nodes. PKI leaf issuance +
# KV read on the RS internal-auth keyFile (also the nexus-sharded-admin
# operator password) + token self-mgmt.
path "pki_int/issue/${var.vault_pki_mongo_sharded_role_name}" {
  capabilities = ["create", "update"]
}
path "nexus/data/oltp/mongo/keyfile" {
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
%{for name, spec in local.mongo_sharded_agent_policy_specs~}
        @{ Name = '${name}'; Host = '${spec.host}' },
%{endfor~}
        $null
      ) | Where-Object { $_ -ne $null }

      foreach ($s in $specs) {
        $name = $s.Name
        $hostName = $s.Host

        $bodyBytes = [System.Text.UTF8Encoding]::new($false).GetBytes($mongoPolicy)
        $bodyB64   = [Convert]::ToBase64String($bodyBytes)

        $remoteBash = @"
set -euo pipefail
export VAULT_TOKEN='$rootToken'
export VAULT_SKIP_VERIFY=true
export VAULT_ADDR=https://127.0.0.1:8200
echo '$bodyB64' | base64 -d | vault policy write $name - >/dev/null
echo "[mongo-sharded-policies] wrote policy $name"
"@
        $remoteBytes = [System.Text.UTF8Encoding]::new($false).GetBytes($remoteBash)
        $remoteB64   = [Convert]::ToBase64String($remoteBytes)

        Write-Host "[mongo-sharded-policies] writing $name (policy for $hostName)"
        $output = ssh -o ConnectTimeout=15 -o BatchMode=yes -o StrictHostKeyChecking=no $user@$ip "echo '$remoteB64' | base64 -d | bash" 2>&1 | Out-String
        if ($LASTEXITCODE -ne 0) {
          Write-Host $output.Trim()
          throw "[mongo-sharded-policies] failed writing $name (rc=$LASTEXITCODE)"
        }
        Write-Host $output.Trim()
      }

      Write-Host "[mongo-sharded-policies] all $($specs.Count) sharded-mongo-node policies written"
    PWSH
  }
}
