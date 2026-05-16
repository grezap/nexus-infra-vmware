/*
 * role-overlay-vault-agent-redis-policies.tf -- Phase 0.G.1 setup
 *
 * One narrow Vault policy per redis-node Vault Agent. Mirrors the 0.H.2
 * `nexus-agent-kafka-*` shape, scaled to the 6-node Redis Cluster:
 *
 *   nexus-agent-redis-1  -- master shard 1
 *   nexus-agent-redis-2  -- master shard 2
 *   nexus-agent-redis-3  -- master shard 3
 *   nexus-agent-redis-4  -- replica of shard 1
 *   nexus-agent-redis-5  -- replica of shard 2
 *   nexus-agent-redis-6  -- replica of shard 3
 *
 * Shard pairing happens at `redis-cli --cluster create` time (one-shot
 * overlay in nexus-infra-oltp); the Vault Agent doesn't care which node is
 * master vs replica -- both roles need the same cert + same KV access (none).
 *
 * Permissions (minimal -- Redis mTLS needs only a PKI leaf, no KV secret):
 *   - PKI issue on pki_int/issue/<redis_role>   (all 6 -- TLS cert)
 *   - token self-lookup + self-renew            (all 6)
 *
 * Unlike the swarm policies there is NO KV grant: the redis-node Vault Agent
 * renders the leaf cert + key + CA bundle straight from the PKI leaf to
 * /etc/nexus-redis/tls/{server.crt,server.key,ca.crt}. Redis 7.x's
 * `tls-cert-file` / `tls-key-file` / `tls-ca-cert-file` directives read PEM
 * directly -- no keystore password to read from KV. If a later sub-phase
 * adds Redis ACLs with a Vault-managed default password, add a KV path here.
 *
 * Idempotency: vault policy write is upsert.
 *
 * Selective ops: var.enable_redis_agent_setup (master) AND
 *                var.enable_redis_agent_policies.
 */

locals {
  # One spec per redis-node Vault Agent. The 6 nodes landed in 0.G.1; the
  # cluster is a single shard set (3 masters + 3 replicas), no east/west
  # split like Kafka -- redis-1..6 is the full membership.
  redis_agent_policy_specs = {
    "nexus-agent-redis-1" = { host = "redis-1" }
    "nexus-agent-redis-2" = { host = "redis-2" }
    "nexus-agent-redis-3" = { host = "redis-3" }
    "nexus-agent-redis-4" = { host = "redis-4" }
    "nexus-agent-redis-5" = { host = "redis-5" }
    "nexus-agent-redis-6" = { host = "redis-6" }
  }
}

resource "null_resource" "vault_agent_redis_policies" {
  count = var.enable_vault_cluster && var.enable_vault_init && var.enable_redis_agent_setup && var.enable_redis_agent_policies ? 1 : 0

  triggers = {
    post_init_id             = null_resource.vault_post_init[0].id
    redis_role_id            = length(null_resource.vault_pki_redis_role) > 0 ? null_resource.vault_pki_redis_role[0].id : "disabled"
    redis_role_name          = var.vault_pki_redis_role_name
    redis_policies_overlay_v = "1" # v1 (0.G.1) = initial 6-node Redis Cluster. Same minimal policy body for all 6 nodes (interchangeable from Vault's perspective -- no per-shard policy variance).
  }

  depends_on = [null_resource.vault_post_init, null_resource.vault_pki_redis_role]

  provisioner "local-exec" {
    when        = create
    interpreter = ["pwsh", "-NoProfile", "-Command"]
    command     = <<-PWSH
      $ip          = '${local.vault_1_ip}'
      $user        = '${local.ssh_user}'
      $keysFileRaw = '${var.vault_init_keys_file}'
      $keysFile    = $ExecutionContext.InvokeCommand.ExpandString($keysFileRaw.Replace('$HOME', $env:USERPROFILE))

      if (-not (Test-Path $keysFile)) { throw "[redis-policies] keys file $keysFile missing" }
      $rootToken = (Get-Content $keysFile | ConvertFrom-Json).root_token

      # One policy body for all 6 redis nodes -- they are interchangeable from
      # Vault's perspective (same PKI role, no per-host KV path). The
      # HOSTNAME placeholder is kept for symmetry with the kafka/swarm patterns
      # + so a future per-host KV grant is a one-line change.
      $redisPolicy = @"
# Phase 0.G.1 setup -- agent policy for redis cluster nodes (HOSTNAME placeholder
# substituted per-policy below). Minimal: PKI leaf issuance + token self-mgmt.
path "pki_int/issue/${var.vault_pki_redis_role_name}" {
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
%{for name, spec in local.redis_agent_policy_specs~}
        @{ Name = '${name}'; Host = '${spec.host}' },
%{endfor~}
        $null
      ) | Where-Object { $_ -ne $null }

      foreach ($s in $specs) {
        $name = $s.Name
        $hostName = $s.Host
        $bodyRendered = $redisPolicy -replace 'HOSTNAME', $hostName

        $bodyBytes = [System.Text.UTF8Encoding]::new($false).GetBytes($bodyRendered)
        $bodyB64   = [Convert]::ToBase64String($bodyBytes)

        $remoteBash = @"
set -euo pipefail
export VAULT_TOKEN='$rootToken'
export VAULT_SKIP_VERIFY=true
export VAULT_ADDR=https://127.0.0.1:8200
echo '$bodyB64' | base64 -d | vault policy write $name - >/dev/null
echo "[redis-policies] wrote policy $name"
"@
        $remoteBytes = [System.Text.UTF8Encoding]::new($false).GetBytes($remoteBash)
        $remoteB64   = [Convert]::ToBase64String($remoteBytes)

        Write-Host "[redis-policies] writing $name (redis policy for $hostName)"
        $output = ssh -o ConnectTimeout=15 -o BatchMode=yes -o StrictHostKeyChecking=no $user@$ip "echo '$remoteB64' | base64 -d | bash" 2>&1 | Out-String
        if ($LASTEXITCODE -ne 0) {
          Write-Host $output.Trim()
          throw "[redis-policies] failed writing $name (rc=$LASTEXITCODE)"
        }
        Write-Host $output.Trim()
      }

      Write-Host "[redis-policies] all $($specs.Count) redis-node policies written"
    PWSH
  }
}
