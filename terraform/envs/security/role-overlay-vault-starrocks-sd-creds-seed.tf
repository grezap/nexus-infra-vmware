/*
 * role-overlay-vault-starrocks-sd-creds-seed.tf -- Phase 0.L.5 setup
 *
 * Sticky-seeds the 4 StarRocks shared-data credentials in Vault KV:
 *   nexus/analytics/starrocks-sd/root-password   (field `password`, 32-char hex)
 *     -- the StarRocks root SQL user (SET PASSWORD FOR root after FE bootstrap)
 *   nexus/analytics/starrocks-sd/app-password    (field `password`, 32-char hex)
 *     -- the least-priv app SQL user (DEFAULT ROLE app_rw)
 *   nexus/analytics/starrocks-sd/s3-access-key   (field `value`, fixed)
 *     -- the MinIO service-account access key (`nexus-starrocks-app`)
 *   nexus/analytics/starrocks-sd/s3-secret-key   (field `value`, 40-char hex)
 *     -- the MinIO service-account secret key (consumed by CREATE STORAGE VOLUME
 *        on the FE leader + by the lakehouse-minio tenant-bootstrap that
 *        provisions the MinIO user with this access/secret pair).
 *
 * The {root,app}-password reads use field `password` (mirrors the sealed sn
 * cluster). The s3-* reads use field `value` (mirrors the MinIO creds-seed
 * pattern so the lakehouse-side tenant bootstrap can use the same reader code).
 *
 * Selective ops: var.enable_starrocks_sd_cluster_creds_seed (master).
 */

resource "null_resource" "vault_starrocks_sd_creds_seed" {
  count = var.enable_vault_cluster && var.enable_vault_init && var.enable_starrocks_sd_cluster_creds_seed ? 1 : 0

  triggers = {
    post_init_id              = null_resource.vault_post_init[0].id
    kv_paths                  = "nexus/analytics/starrocks-sd/{root-password,app-password,s3-access-key,s3-secret-key}"
    starrocks_sd_creds_seed_v = "1"
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

      if (-not (Test-Path $keysFile)) { throw "[starrocks-sd-creds-seed] keys file $keysFile missing" }
      $rootToken = (Get-Content $keysFile | ConvertFrom-Json).root_token

      $bash = @"
set -euo pipefail
export VAULT_TOKEN='$rootToken'
export VAULT_SKIP_VERIFY=true
export VAULT_ADDR=https://127.0.0.1:8200

seed_password_random() {
  local path="`$1"
  local label="`$2"
  if vault kv get -field=password "`$path" >/dev/null 2>&1; then
    echo "[starrocks-sd-creds-seed] `$path already populated -- no-op (sticky `$label)"
    return 0
  fi
  local PW32
  PW32=`$(openssl rand -hex 16)
  local LEN
  LEN=`$(printf '%s' "`$PW32" | wc -c)
  if [ "`$LEN" -ne 32 ]; then echo "[starrocks-sd-creds-seed] ERROR: `$label length `$LEN" >&2; return 1; fi
  vault kv put "`$path" password="`$PW32" >/dev/null
  echo "[starrocks-sd-creds-seed] wrote `$path (`$LEN-char hex `$label)"
}

seed_value_fixed() {
  local path="`$1"; local val="`$2"; local label="`$3"
  if vault kv get -field=value "`$path" >/dev/null 2>&1; then
    echo "[starrocks-sd-creds-seed] `$path already populated -- no-op (sticky `$label)"
    return 0
  fi
  vault kv put "`$path" value="`$val" >/dev/null
  echo "[starrocks-sd-creds-seed] wrote `$path (`$label)"
}

seed_value_random() {
  local path="`$1"; local label="`$2"
  if vault kv get -field=value "`$path" >/dev/null 2>&1; then
    echo "[starrocks-sd-creds-seed] `$path already populated -- no-op (sticky `$label)"
    return 0
  fi
  local SK
  SK=`$(openssl rand -hex 20)
  local LEN
  LEN=`$(printf '%s' "`$SK" | wc -c)
  if [ "`$LEN" -ne 40 ]; then echo "[starrocks-sd-creds-seed] ERROR: `$label length `$LEN" >&2; return 1; fi
  vault kv put "`$path" value="`$SK" >/dev/null
  echo "[starrocks-sd-creds-seed] wrote `$path (`$LEN-char hex `$label)"
}

seed_password_random 'nexus/analytics/starrocks-sd/root-password' 'SR shared-data root SQL password'
seed_password_random 'nexus/analytics/starrocks-sd/app-password'  'SR shared-data app SQL password'
seed_value_fixed     'nexus/analytics/starrocks-sd/s3-access-key' 'nexus-starrocks-app' 'MinIO storage-volume access key'
seed_value_random    'nexus/analytics/starrocks-sd/s3-secret-key'                       'MinIO storage-volume secret key'

echo "[starrocks-sd-creds-seed] all 4 cluster creds present in nexus/analytics/starrocks-sd/"
"@

      $b64 = [Convert]::ToBase64String([System.Text.UTF8Encoding]::new($false).GetBytes($bash))
      Write-Host "[starrocks-sd-creds-seed] dispatching to $${ip} via base64"
      $output = ssh -o ConnectTimeout=30 -o BatchMode=yes -o StrictHostKeyChecking=no $user@$ip "echo '$b64' | base64 -d | bash" 2>&1 | Out-String
      $rc = $LASTEXITCODE
      Write-Host $output.Trim()
      if ($rc -ne 0) { throw "[starrocks-sd-creds-seed] script failed (rc=$rc)" }
    PWSH
  }
}
