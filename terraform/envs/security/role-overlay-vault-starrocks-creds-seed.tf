/*
 * role-overlay-vault-starrocks-creds-seed.tf -- Phase 0.G.6 setup
 *
 * Sticky-seeds the 2 StarRocks SQL-RBAC credentials in Vault KV (field
 * `password`, matching the schema-bootstrap read):
 *   nexus/analytics/starrocks/root-password   (32-char hex) -- the StarRocks
 *     root user password (SET PASSWORD FOR root after FE bootstrap)
 *   nexus/analytics/starrocks/app-password    (32-char hex) -- the least-priv
 *     app user (DEFAULT ROLE app_rw)
 *
 * Read on-node by the schema-bootstrap overlay via the per-host Vault Agent
 * token. Mirrors the ClickHouse creds-seed (field `password`).
 *
 * Selective ops: var.enable_starrocks_cluster_creds_seed (master).
 */

resource "null_resource" "vault_starrocks_creds_seed" {
  count = var.enable_vault_cluster && var.enable_vault_init && var.enable_starrocks_cluster_creds_seed ? 1 : 0

  triggers = {
    post_init_id           = null_resource.vault_post_init[0].id
    kv_paths               = "nexus/analytics/starrocks/{root,app}-password"
    starrocks_creds_seed_v = "1"
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

      if (-not (Test-Path $keysFile)) { throw "[starrocks-creds-seed] keys file $keysFile missing" }
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
    echo "[starrocks-creds-seed] `$path already populated -- no-op (sticky `$label)"
    return 0
  fi
  local PW32
  PW32=`$(openssl rand -hex 16)
  local LEN
  LEN=`$(printf '%s' "`$PW32" | wc -c)
  if [ "`$LEN" -ne 32 ]; then echo "[starrocks-creds-seed] ERROR: `$label length `$LEN" >&2; return 1; fi
  vault kv put "`$path" password="`$PW32" >/dev/null
  echo "[starrocks-creds-seed] wrote `$path (`$LEN-char hex `$label)"
}

seed_if_absent 'nexus/analytics/starrocks/root-password' 'StarRocks root user password'
seed_if_absent 'nexus/analytics/starrocks/app-password'  'StarRocks app (least-priv) user password'

echo "[starrocks-creds-seed] all 2 cluster creds present in nexus/analytics/starrocks/"
"@

      $b64 = [Convert]::ToBase64String([System.Text.UTF8Encoding]::new($false).GetBytes($bash))
      Write-Host "[starrocks-creds-seed] dispatching to $${ip} via base64"
      $output = ssh -o ConnectTimeout=30 -o BatchMode=yes -o StrictHostKeyChecking=no $user@$ip "echo '$b64' | base64 -d | bash" 2>&1 | Out-String
      $rc = $LASTEXITCODE
      Write-Host $output.Trim()
      if ($rc -ne 0) { throw "[starrocks-creds-seed] script failed (rc=$rc)" }
    PWSH
  }
}
