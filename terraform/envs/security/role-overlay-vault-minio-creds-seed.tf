/*
 * role-overlay-vault-minio-creds-seed.tf -- Phase 0.L.1 setup
 *
 * Sticky-seeds the 4 MinIO credentials in Vault KV (field `value`, matching the
 * minio-config + bucket-bootstrap reads):
 *   nexus/lakehouse/minio/root-user      -- MINIO_ROOT_USER  (fixed access key)
 *   nexus/lakehouse/minio/root-password  -- MINIO_ROOT_PASSWORD (40-char hex)
 *   nexus/lakehouse/minio/app-access-key -- lakehouse-app access key (fixed)
 *   nexus/lakehouse/minio/app-secret-key -- lakehouse-app secret key (40-char hex)
 *
 * The app-* pair is the least-priv service account consumed by 0.L.2 Iceberg +
 * 0.L.3 Spark for S3 access to the warehouse bucket. Sticky -- never overwrites.
 *
 * Selective ops: var.enable_minio_cluster_creds_seed (master).
 */

resource "null_resource" "vault_minio_creds_seed" {
  count = var.enable_vault_cluster && var.enable_vault_init && var.enable_minio_cluster_creds_seed ? 1 : 0

  triggers = {
    post_init_id       = null_resource.vault_post_init[0].id
    kv_paths           = "nexus/lakehouse/minio/{root-user,root-password,app-access-key,app-secret-key}"
    minio_creds_seed_v = "1"
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

      if (-not (Test-Path $keysFile)) { throw "[minio-creds-seed] keys file $keysFile missing" }
      $rootToken = (Get-Content $keysFile | ConvertFrom-Json).root_token

      $bash = @"
set -euo pipefail
export VAULT_TOKEN='$rootToken'
export VAULT_SKIP_VERIFY=true
export VAULT_ADDR=https://127.0.0.1:8200

seed_value() {
  local path="`$1"; local val="`$2"; local label="`$3"
  if vault kv get -field=value "`$path" >/dev/null 2>&1; then
    echo "[minio-creds-seed] `$path already populated -- no-op (sticky `$label)"
    return 0
  fi
  vault kv put "`$path" value="`$val" >/dev/null
  echo "[minio-creds-seed] wrote `$path (`$label)"
}

seed_random() {
  local path="`$1"; local label="`$2"
  if vault kv get -field=value "`$path" >/dev/null 2>&1; then
    echo "[minio-creds-seed] `$path already populated -- no-op (sticky `$label)"
    return 0
  fi
  local SK
  SK=`$(openssl rand -hex 20)
  local LEN
  LEN=`$(printf '%s' "`$SK" | wc -c)
  if [ "`$LEN" -ne 40 ]; then echo "[minio-creds-seed] ERROR: `$label length `$LEN" >&2; return 1; fi
  vault kv put "`$path" value="`$SK" >/dev/null
  echo "[minio-creds-seed] wrote `$path (`$LEN-char hex `$label)"
}

seed_value  'nexus/lakehouse/minio/root-user'      'nexus-minio-root'    'MinIO root access key'
seed_random 'nexus/lakehouse/minio/root-password'                        'MinIO root secret key'
seed_value  'nexus/lakehouse/minio/app-access-key' 'nexus-lakehouse-app' 'MinIO app access key'
seed_random 'nexus/lakehouse/minio/app-secret-key'                       'MinIO app secret key'

echo "[minio-creds-seed] all 4 MinIO creds present in nexus/lakehouse/minio/"
"@

      $b64 = [Convert]::ToBase64String([System.Text.UTF8Encoding]::new($false).GetBytes($bash))
      Write-Host "[minio-creds-seed] dispatching to $${ip} via base64"
      $output = ssh -o ConnectTimeout=30 -o BatchMode=yes -o StrictHostKeyChecking=no $user@$ip "echo '$b64' | base64 -d | bash" 2>&1 | Out-String
      $rc = $LASTEXITCODE
      Write-Host $output.Trim()
      if ($rc -ne 0) { throw "[minio-creds-seed] script failed (rc=$rc)" }
    PWSH
  }
}
