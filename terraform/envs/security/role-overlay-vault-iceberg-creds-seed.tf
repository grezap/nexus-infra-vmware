/*
 * role-overlay-vault-iceberg-creds-seed.tf -- Phase 0.L.2 setup
 *
 * Sticky-seeds the 3 Iceberg catalog DB credentials in Vault KV (field `value`,
 * 40-char hex):
 *   nexus/lakehouse/iceberg/pg-superuser-password   (PG postgres superuser)
 *   nexus/lakehouse/iceberg/pg-replication-password (repluser, streaming repl)
 *   nexus/lakehouse/iceberg/nessie-db-password      (the nessie DB role)
 *
 * Read on-node by the pg-replication + nessie-config overlays via the per-host
 * Vault Agent token. Sticky -- never overwrites. (Nessie's S3 warehouse creds
 * are the nexus-lakehouse-app key seeded at 0.L.1 under nexus/lakehouse/minio/.)
 *
 * Selective ops: var.enable_iceberg_cluster_creds_seed (master).
 */

resource "null_resource" "vault_iceberg_creds_seed" {
  count = var.enable_vault_cluster && var.enable_vault_init && var.enable_iceberg_cluster_creds_seed ? 1 : 0

  triggers = {
    post_init_id         = null_resource.vault_post_init[0].id
    kv_paths             = "nexus/lakehouse/iceberg/{pg-superuser,pg-replication,nessie-db}-password"
    iceberg_creds_seed_v = "1"
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

      if (-not (Test-Path $keysFile)) { throw "[iceberg-creds-seed] keys file $keysFile missing" }
      $rootToken = (Get-Content $keysFile | ConvertFrom-Json).root_token

      $bash = @"
set -euo pipefail
export VAULT_TOKEN='$rootToken'
export VAULT_SKIP_VERIFY=true
export VAULT_ADDR=https://127.0.0.1:8200

seed_random() {
  local path="`$1"; local label="`$2"
  if vault kv get -field=value "`$path" >/dev/null 2>&1; then
    echo "[iceberg-creds-seed] `$path already populated -- no-op (sticky `$label)"
    return 0
  fi
  local PW
  PW=`$(openssl rand -hex 20)
  vault kv put "`$path" value="`$PW" >/dev/null
  echo "[iceberg-creds-seed] wrote `$path (40-char hex `$label)"
}

seed_random 'nexus/lakehouse/iceberg/pg-superuser-password'   'PG superuser password'
seed_random 'nexus/lakehouse/iceberg/pg-replication-password' 'PG replication password'
seed_random 'nexus/lakehouse/iceberg/nessie-db-password'      'Nessie DB password'

echo "[iceberg-creds-seed] all 3 iceberg catalog DB creds present in nexus/lakehouse/iceberg/"
"@

      $b64 = [Convert]::ToBase64String([System.Text.UTF8Encoding]::new($false).GetBytes($bash))
      Write-Host "[iceberg-creds-seed] dispatching to $${ip} via base64"
      $output = ssh -o ConnectTimeout=30 -o BatchMode=yes -o StrictHostKeyChecking=no $user@$ip "echo '$b64' | base64 -d | bash" 2>&1 | Out-String
      $rc = $LASTEXITCODE
      Write-Host $output.Trim()
      if ($rc -ne 0) { throw "[iceberg-creds-seed] script failed (rc=$rc)" }
    PWSH
  }
}
