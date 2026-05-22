/*
 * role-overlay-vault-agent-clickhouse-policies.tf -- Phase 0.G.5 setup
 *
 * One narrow Vault policy per ClickHouse-node Vault Agent (9 nodes: 3 Keeper +
 * 3 shards x 2 replicas). Mirrors the redis/kafka agent-policy shape.
 *
 *   nexus-agent-clickhouse-ch-keeper-1/2/3      -- Keeper RAFT quorum
 *   nexus-agent-clickhouse-ch-shard{1,2,3}-rep{1,2}  -- data nodes
 *
 * Permissions:
 *   - PKI issue on pki_int/issue/<clickhouse_role>   (all 9 -- mTLS leaf cert)
 *   - KV read on nexus/data/analytics/clickhouse/*    (all 9 -- the schema-
 *       bootstrap overlay reads admin/app passwords via the on-node agent token;
 *       granted uniformly so any node can run the SQL-driven RBAC bootstrap)
 *   - token self-lookup + self-renew                  (all 9)
 *
 * Idempotency: vault policy write is upsert. Selective ops:
 * var.enable_clickhouse_agent_setup AND var.enable_clickhouse_agent_policies.
 */

locals {
  clickhouse_agent_policy_specs = {
    "nexus-agent-clickhouse-ch-keeper-1"    = { host = "ch-keeper-1" }
    "nexus-agent-clickhouse-ch-keeper-2"    = { host = "ch-keeper-2" }
    "nexus-agent-clickhouse-ch-keeper-3"    = { host = "ch-keeper-3" }
    "nexus-agent-clickhouse-ch-shard1-rep1" = { host = "ch-shard1-rep1" }
    "nexus-agent-clickhouse-ch-shard1-rep2" = { host = "ch-shard1-rep2" }
    "nexus-agent-clickhouse-ch-shard2-rep1" = { host = "ch-shard2-rep1" }
    "nexus-agent-clickhouse-ch-shard2-rep2" = { host = "ch-shard2-rep2" }
    "nexus-agent-clickhouse-ch-shard3-rep1" = { host = "ch-shard3-rep1" }
    "nexus-agent-clickhouse-ch-shard3-rep2" = { host = "ch-shard3-rep2" }
  }
}

resource "null_resource" "vault_agent_clickhouse_policies" {
  count = var.enable_vault_cluster && var.enable_vault_init && var.enable_clickhouse_agent_setup && var.enable_clickhouse_agent_policies ? 1 : 0

  triggers = {
    post_init_id                  = null_resource.vault_post_init[0].id
    clickhouse_role_id            = length(null_resource.vault_pki_clickhouse_role) > 0 ? null_resource.vault_pki_clickhouse_role[0].id : "disabled"
    clickhouse_role_name          = var.vault_pki_clickhouse_role_name
    clickhouse_policies_overlay_v = "1" # v1 (0.G.5) = initial 9-node ClickHouse cluster; PKI issue + KV read on nexus/data/analytics/clickhouse/* + token self.
  }

  depends_on = [null_resource.vault_post_init, null_resource.vault_pki_clickhouse_role]

  provisioner "local-exec" {
    when        = create
    interpreter = ["pwsh", "-NoProfile", "-Command"]
    command     = <<-PWSH
      $ip          = '${local.vault_1_ip}'
      $user        = '${local.ssh_user}'
      $keysFileRaw = '${var.vault_init_keys_file}'
      $keysFile    = $ExecutionContext.InvokeCommand.ExpandString($keysFileRaw.Replace('$HOME', $env:USERPROFILE))

      if (-not (Test-Path $keysFile)) { throw "[clickhouse-policies] keys file $keysFile missing" }
      $rootToken = (Get-Content $keysFile | ConvertFrom-Json).root_token

      # One policy body for all 9 nodes (interchangeable from Vault's view:
      # same PKI role + same KV path). The HOSTNAME placeholder is kept for
      # symmetry with the redis/kafka patterns + future per-host KV grants.
      $clickhousePolicy = @"
# Phase 0.G.5 setup -- agent policy for ClickHouse nodes (HOSTNAME).
# PKI leaf issuance + KV read of the RBAC passwords + token self-mgmt.
path "pki_int/issue/${var.vault_pki_clickhouse_role_name}" {
  capabilities = ["create", "update"]
}
path "nexus/data/analytics/clickhouse/*" {
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
%{for name, spec in local.clickhouse_agent_policy_specs~}
        @{ Name = '${name}'; Host = '${spec.host}' },
%{endfor~}
        $null
      ) | Where-Object { $_ -ne $null }

      foreach ($s in $specs) {
        $name = $s.Name
        $hostName = $s.Host
        $bodyRendered = $clickhousePolicy -replace 'HOSTNAME', $hostName

        $bodyBytes = [System.Text.UTF8Encoding]::new($false).GetBytes($bodyRendered)
        $bodyB64   = [Convert]::ToBase64String($bodyBytes)

        $remoteBash = @"
set -euo pipefail
export VAULT_TOKEN='$rootToken'
export VAULT_SKIP_VERIFY=true
export VAULT_ADDR=https://127.0.0.1:8200
echo '$bodyB64' | base64 -d | vault policy write $name - >/dev/null
echo "[clickhouse-policies] wrote policy $name"
"@
        $remoteBytes = [System.Text.UTF8Encoding]::new($false).GetBytes($remoteBash)
        $remoteB64   = [Convert]::ToBase64String($remoteBytes)

        Write-Host "[clickhouse-policies] writing $name (policy for $hostName)"
        $output = ssh -o ConnectTimeout=15 -o BatchMode=yes -o StrictHostKeyChecking=no $user@$ip "echo '$remoteB64' | base64 -d | bash" 2>&1 | Out-String
        if ($LASTEXITCODE -ne 0) {
          Write-Host $output.Trim()
          throw "[clickhouse-policies] failed writing $name (rc=$LASTEXITCODE)"
        }
        Write-Host $output.Trim()
      }

      Write-Host "[clickhouse-policies] all $($specs.Count) ClickHouse-node policies written"
    PWSH
  }
}
