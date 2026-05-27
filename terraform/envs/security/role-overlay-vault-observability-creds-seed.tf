/*
 * role-overlay-vault-observability-creds-seed.tf -- Phase 0.I setup
 *
 * Sticky-seeds the obs-tier web-auth + S3 tenant + Grafana (admin / session /
 * state-DB) credentials in Vault KV. For each web-auth password, seeds BOTH:
 *   nexus/observability/<service>/web-auth-password         (field `password`: 32-char hex)
 *   nexus/observability/<service>/web-auth-password         (field `password_bcrypt`: bcrypt of `password`)
 *
 * Prom + AM consume password_bcrypt in their web.yml; Grafana consumes
 * `password` (datasource basic-auth). Sticky: never overwrites the password;
 * the bcrypt is re-derived idempotently.
 *
 * KV paths seeded by this overlay (cumulative through 0.I.4):
 *   0.I.1: nexus/observability/prometheus/web-auth-password   (basic-auth on Prom :9090)
 *          nexus/observability/alertmanager/web-auth-password (basic-auth on AM :9093)
 *   0.I.2: nexus/observability/loki/s3-{access,secret}-key    (MinIO `loki` tenant)
 *   0.I.3: nexus/observability/tempo/s3-{access,secret}-key   (MinIO `tempo` tenant)
 *   0.I.4: nexus/observability/grafana-pg/superuser-password    (PG postgres pw)
 *          nexus/observability/grafana-pg/replication-password  (repluser pw; streaming repl)
 *          nexus/observability/grafana-pg/grafana-db-password   (grafana app PG user pw)
 *          nexus/observability/grafana/admin-password           (Grafana admin login pw)
 *          nexus/observability/grafana/session-key              (Grafana [security] secret_key)
 *
 * Selective ops: var.enable_observability_creds_seed (master).
 */

resource "null_resource" "vault_observability_creds_seed" {
  count = var.enable_vault_cluster && var.enable_vault_init && var.enable_observability_creds_seed ? 1 : 0

  triggers = {
    post_init_id     = null_resource.vault_post_init[0].id
    kv_paths         = "nexus/observability/{prometheus,alertmanager}/web-auth-password + nexus/observability/{loki,tempo}/s3-{access,secret}-key + nexus/observability/grafana-pg/{superuser,replication,grafana-db}-password + nexus/observability/grafana/{admin-password,session-key}"
    obs_creds_seed_v = "3" # v3: add 0.I.4 Grafana + grafana-pg sticky-hex passwords
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

      if (-not (Test-Path $keysFile)) { throw "[obs-creds-seed] keys file $keysFile missing" }
      $rootToken = (Get-Content $keysFile | ConvertFrom-Json).root_token

      $bash = @"
set -euo pipefail
export VAULT_TOKEN='$rootToken'
export VAULT_SKIP_VERIFY=true
export VAULT_ADDR=https://127.0.0.1:8200

# Two-transient story (handbook §3.A T2+T3):
# T2: `apt-get install apache2-utils` (for htpasswd bcrypt) fails on vault-1
#     because /etc/resolv.conf is empty (feedback_deb13_baseline_dns_resolver.md).
# T3: `openssl passwd -bcrypt` does NOT work on OpenSSL 3.x (Debian 13 ships
#     OpenSSL 3.5.5) -- bcrypt was removed from `openssl passwd` in 3.0.
# Resolution: defensive resolv.conf write (the iceberg-vault-agents canon)
# THEN apt-install apache2-utils THEN htpasswd. Idempotent.

# Defensive resolv.conf write per feedback_deb13_baseline_dns_resolver.md
if ! getent hosts deb.debian.org >/dev/null 2>&1; then
  echo "nameserver 192.168.70.1" | sudo tee /etc/resolv.conf > /dev/null
fi

# Ensure htpasswd available for bcrypt (apache2-utils on Debian)
if ! command -v htpasswd >/dev/null 2>&1; then
  sudo apt-get update -qq && sudo apt-get install -y -qq apache2-utils >/dev/null
fi

seed_webauth() {
  local path="`$1"; local label="`$2"
  if vault kv get -field=password "`$path" >/dev/null 2>&1; then
    PW=`$(vault kv get -field=password "`$path")
    echo "[obs-creds-seed] `$path already populated (sticky `$label); re-deriving bcrypt"
  else
    PW=`$(openssl rand -hex 16)
  fi
  # bcrypt of `$PW via htpasswd. Prom + AM web.yml accept any \$2[ayb]\$ prefix.
  BCRYPT=`$(htpasswd -nbBC 10 admin "`$PW" | cut -d: -f2)
  vault kv put "`$path" password="`$PW" password_bcrypt="`$BCRYPT" >/dev/null
  echo "[obs-creds-seed] wrote `$path (32-char hex `$label + bcrypt cost=10)"
}

seed_webauth 'nexus/observability/prometheus/web-auth-password'   'Prometheus web-auth password'
seed_webauth 'nexus/observability/alertmanager/web-auth-password' 'Alertmanager web-auth password'

# S3 tenant credentials for Loki + Tempo (consumed by the MinIO obs-tenants
# overlay in nexus-infra-lakehouse + the obs-loki + obs-tempo overlays in
# nexus-infra-observability via Vault Agent KV read).
seed_s3() {
  local ak_path="`$1"; local sk_path="`$2"; local label="`$3"
  if vault kv get -field=value "`$ak_path" >/dev/null 2>&1 && vault kv get -field=value "`$sk_path" >/dev/null 2>&1; then
    echo "[obs-creds-seed] `$ak_path + `$sk_path already populated -- no-op (sticky `$label)"
    return 0
  fi
  AK=`$(openssl rand -hex 12)
  SK=`$(openssl rand -hex 24)
  vault kv put "`$ak_path" value="`$AK" >/dev/null
  vault kv put "`$sk_path" value="`$SK" >/dev/null
  echo "[obs-creds-seed] wrote `$ak_path + `$sk_path (`$label)"
}

seed_s3 'nexus/observability/loki/s3-access-key'  'nexus/observability/loki/s3-secret-key'  'Loki MinIO tenant key'
seed_s3 'nexus/observability/tempo/s3-access-key' 'nexus/observability/tempo/s3-secret-key' 'Tempo MinIO tenant key'

# 0.I.4 Grafana + grafana-pg sticky-hex passwords (field name `value`, matching
# the iceberg-pg / registry-pg / S3-tenant idiom). Idempotent: never overwrites
# an existing value.
seed_pw() {
  local path="`$1"; local label="`$2"; local len="`$${3:-32}"
  if vault kv get -field=value "`$path" >/dev/null 2>&1; then
    echo "[obs-creds-seed] `$path already populated -- no-op (sticky `$label)"
    return 0
  fi
  PW=`$(openssl rand -hex `$len)
  vault kv put "`$path" value="`$PW" >/dev/null
  echo "[obs-creds-seed] wrote `$path (`$${len}-byte hex `$label)"
}

seed_pw 'nexus/observability/grafana-pg/superuser-password'   'Grafana state-DB postgres superuser password'   16
seed_pw 'nexus/observability/grafana-pg/replication-password' 'Grafana state-DB repluser password'             16
seed_pw 'nexus/observability/grafana-pg/grafana-db-password'  'Grafana PG user (grafana app) password'         16
seed_pw 'nexus/observability/grafana/admin-password'          'Grafana admin user password'                    16
seed_pw 'nexus/observability/grafana/session-key'             'Grafana [security] secret_key (cookie signing)' 32

echo "[obs-creds-seed] all obs creds present in nexus/observability/{prometheus,alertmanager,loki,tempo,grafana,grafana-pg}/"
"@

      $b64 = [Convert]::ToBase64String([System.Text.UTF8Encoding]::new($false).GetBytes($bash))
      Write-Host "[obs-creds-seed] dispatching to $${ip} via base64"
      $output = ssh -o ConnectTimeout=30 -o BatchMode=yes -o StrictHostKeyChecking=no $user@$ip "echo '$b64' | base64 -d | bash" 2>&1 | Out-String
      $rc = $LASTEXITCODE
      Write-Host $output.Trim()
      if ($rc -ne 0) { throw "[obs-creds-seed] script failed (rc=$rc)" }
    PWSH
  }
}
