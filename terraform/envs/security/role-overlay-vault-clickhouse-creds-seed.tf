/*
 * role-overlay-vault-clickhouse-creds-seed.tf -- Phase 0.G.5 setup
 *
 * Sticky-seeds the 2 ClickHouse SQL-driven-RBAC credentials in Vault KV
 * (field `password`, matching nexus-infra-analytics's schema-bootstrap read
 * `vault kv get -field=password ...`):
 *
 *   nexus/analytics/clickhouse/admin-password   (32-char hex)
 *     - The `admin` ClickHouse user (sha256_password, access_management=1).
 *       Created ON CLUSTER by the schema-bootstrap overlay. Operator/admin
 *       account for the cluster (full GRANT OPTION).
 *
 *   nexus/analytics/clickhouse/app-password     (32-char hex)
 *     - The least-priv `app` ClickHouse user (DEFAULT ROLE app_rw =
 *       SELECT,INSERT on nexus.*). The application connection identity.
 *
 * Both read on-node by the schema-bootstrap overlay via the per-host Vault
 * Agent token (policy grants nexus/data/analytics/clickhouse/* read). Values
 * are generated server-side on vault-1 + never transit the SSH wire.
 *
 * Sticky-seed: each path is probed; if already populated it is left alone
 * (operator rotation preserved). Mirrors role-overlay-vault-patroni-cluster-
 * creds-seed.tf, but uses field `password` (not `content`).
 *
 * Selective ops: var.enable_clickhouse_cluster_creds_seed (master). Pre-req:
 * vault cluster initialized + KV-v2 mount at nexus/.
 */

resource "null_resource" "vault_clickhouse_creds_seed" {
  count = var.enable_vault_cluster && var.enable_vault_init && var.enable_clickhouse_cluster_creds_seed ? 1 : 0

  triggers = {
    post_init_id            = null_resource.vault_post_init[0].id
    kv_paths                = "nexus/analytics/clickhouse/{admin,app}-password"
    clickhouse_creds_seed_v = "1" # v1 (0.G.5) = initial 2 sticky-seeded 32-char hex creds (admin, app), field=password.
  }

  depends_on = [null_resource.vault_post_init]

  provisioner "local-exec" {
    when        = create
    interpreter = ["pwsh", "-NoProfile", "-Command"]
    command     = <<-PWSH
      $ip          = '${local.vault_1_ip}'
      $user        = '${local.ssh_user}'
      $keysFileRaw = '${var.vault_init_keys_file}'
      $keysFile    = $ExecutionContext.InvokeCommand.ExpandString($keysFileRaw.Replace('$HOME', $env:USERPROFILE))

      if (-not (Test-Path $keysFile)) { throw "[clickhouse-creds-seed] keys file $keysFile missing" }
      $rootToken = (Get-Content $keysFile | ConvertFrom-Json).root_token

      $bash = @"
set -euo pipefail
export VAULT_TOKEN='$rootToken'
export VAULT_SKIP_VERIFY=true
export VAULT_ADDR=https://127.0.0.1:8200

seed_if_absent() {
  local path="`$1"
  local label="`$2"
  if vault kv get -field=password "`$path" >/dev/null 2>&1; then
    echo "[clickhouse-creds-seed] `$path already populated -- no-op (sticky `$label)"
    return 0
  fi
  local PW32
  PW32=`$(openssl rand -hex 16)
  local LEN
  LEN=`$(printf '%s' "`$PW32" | wc -c)
  if [ "`$LEN" -ne 32 ]; then
    echo "[clickhouse-creds-seed] ERROR: `$label generated length `$LEN (expected 32)" >&2
    return 1
  fi
  vault kv put "`$path" password="`$PW32" >/dev/null
  echo "[clickhouse-creds-seed] wrote `$path (`$LEN-char hex `$label)"
}

seed_if_absent 'nexus/analytics/clickhouse/admin-password' 'ClickHouse admin user password'
seed_if_absent 'nexus/analytics/clickhouse/app-password'   'ClickHouse app (least-priv) user password'

echo "[clickhouse-creds-seed] all 2 cluster creds present in nexus/analytics/clickhouse/"
"@

      $bytes = [System.Text.UTF8Encoding]::new($false).GetBytes($bash)
      $b64   = [Convert]::ToBase64String($bytes)

      Write-Host "[clickhouse-creds-seed] dispatching to $${ip} via base64"
      $output = ssh -o ConnectTimeout=30 -o BatchMode=yes -o StrictHostKeyChecking=no $user@$ip "echo '$b64' | base64 -d | bash" 2>&1 | Out-String
      $rc = $LASTEXITCODE
      Write-Host $output.Trim()
      if ($rc -ne 0) { throw "[clickhouse-creds-seed] script failed (rc=$rc)" }
    PWSH
  }
}
