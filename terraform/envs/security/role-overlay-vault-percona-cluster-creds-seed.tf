/*
 * role-overlay-vault-percona-cluster-creds-seed.tf -- Phase 0.G.3 setup
 *
 * Sticky-seeds the 4 Percona/ProxySQL cluster credentials in Vault KV:
 *
 *   nexus/oltp/percona/cluster-password         (32-char hex)
 *     - wsrep_sst_auth password for Galera SST/IST replication between
 *       the 3 PXC nodes. ProxySQL also needs it to connect to PXC.
 *     - Consumer: 3 PXC nodes (mysql user `wsrep_sst`) + 2 ProxySQL
 *
 *   nexus/oltp/percona/monitor-password         (32-char hex)
 *     - clustercheck monitor user, used by ProxySQL's mysql_galera_hostgroups
 *       to detect node health (wsrep_local_state_comment).
 *     - Consumer: 3 PXC nodes (mysql user `clustercheck`) + 2 ProxySQL
 *
 *   nexus/oltp/percona/root-password            (32-char hex)
 *     - MySQL root@localhost password, bootstrapped on the first Galera
 *       node and replicated via wsrep. ONLY used for in-band ops; remote
 *       root login is disabled.
 *     - Consumer: 3 PXC nodes (for the initial `mysql_secure_installation`
 *       equivalent + later operator ops)
 *
 *   nexus/oltp/percona/proxysql-admin-password  (32-char hex)
 *     - ProxySQL admin@127.0.0.1 password for the :6032 admin interface.
 *     - Consumer: 2 ProxySQL nodes only
 *
 * Sticky-seed pattern (mirrors role-overlay-vault-mongo-keyfile-seed.tf
 * + role-overlay-vault-mongo-smoke-user-seed.tf + 0.E.4d portainer-admin):
 * each KV path is probed; if already populated, that secret is left
 * alone (operator rotation preserved). Each `vault kv put nexus/oltp/
 * percona/<name>-password content=$(openssl rand -hex 16)` followed by
 * the appropriate restart (PXC: rolling restart of mysql.service across
 * the 3 nodes; ProxySQL: `proxysql restart` or `LOAD MYSQL USERS TO
 * RUNTIME` for backend creds) updates the secret without re-applying.
 *
 * Generation happens server-side on vault-1 (the transit-unseal anchor)
 * via openssl; values never transit over the SSH wire to the build host.
 *
 * Why 32-char hex (`openssl rand -hex 16` = 16 random bytes -> 32 hex
 * chars): MySQL passwords are unrestricted on the underlying SQL layer
 * but ProxySQL's mysql_users table stores them in mysql_native_password
 * hash form by default -- hex is a safe character set across mysql + the
 * shell layer that passes them via env vars / config files. 16 random
 * bytes = 128 bits of entropy, well above any sane threshold.
 *
 * Selective ops: var.enable_percona_cluster_creds_seed (master). Pre-req:
 * vault cluster initialized + KV-v2 mount at nexus/.
 */

resource "null_resource" "vault_percona_cluster_creds_seed" {
  count = var.enable_vault_cluster && var.enable_vault_init && var.enable_percona_cluster_creds_seed ? 1 : 0

  triggers = {
    post_init_id         = null_resource.vault_post_init[0].id
    kv_paths             = "nexus/oltp/percona/{cluster,monitor,root,proxysql-admin}-password"
    percona_creds_seed_v = "1" # v1 (0.G.3) = initial 4 sticky-seeded 32-char hex creds (cluster, monitor, root, proxysql-admin).
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

      if (-not (Test-Path $keysFile)) { throw "[percona-creds-seed] keys file $keysFile missing" }
      $rootToken = (Get-Content $keysFile | ConvertFrom-Json).root_token

      # Generate-if-absent on vault-1 per-secret. Each secret is independent;
      # if 3 of 4 are populated + 1 is missing (e.g. operator deleted to
      # rotate), only the missing one regenerates. Logging the LENGTH (not
      # the value) keeps the secret out of stdout.
      $bash = @"
set -euo pipefail
export VAULT_TOKEN='$rootToken'
export VAULT_SKIP_VERIFY=true
export VAULT_ADDR=https://127.0.0.1:8200

seed_if_absent() {
  local path="`$1"
  local label="`$2"
  if vault kv get -field=content "`$path" >/dev/null 2>&1; then
    echo "[percona-creds-seed] `$path already populated -- no-op (sticky `$label)"
    return 0
  fi
  local PWD32
  PWD32=`$(openssl rand -hex 16)
  local LEN
  LEN=`$(printf '%s' "`$PWD32" | wc -c)
  if [ "`$LEN" -ne 32 ]; then
    echo "[percona-creds-seed] ERROR: `$label generated length `$LEN (expected 32)" >&2
    return 1
  fi
  vault kv put "`$path" content="`$PWD32" >/dev/null
  echo "[percona-creds-seed] wrote `$path (`$LEN-char hex `$label)"
}

seed_if_absent 'nexus/oltp/percona/cluster-password'        'wsrep_sst password'
seed_if_absent 'nexus/oltp/percona/monitor-password'        'clustercheck monitor password'
seed_if_absent 'nexus/oltp/percona/root-password'           'mysql root password'
seed_if_absent 'nexus/oltp/percona/proxysql-admin-password' 'ProxySQL admin :6032 password'

echo "[percona-creds-seed] all 4 cluster creds present in nexus/oltp/percona/"
"@

      $bytes = [System.Text.UTF8Encoding]::new($false).GetBytes($bash)
      $b64   = [Convert]::ToBase64String($bytes)

      Write-Host "[percona-creds-seed] dispatching to $${ip} via base64"
      $output = ssh -o ConnectTimeout=30 -o BatchMode=yes -o StrictHostKeyChecking=no $user@$ip "echo '$b64' | base64 -d | bash" 2>&1 | Out-String
      $rc = $LASTEXITCODE
      Write-Host $output.Trim()
      if ($rc -ne 0) {
        throw "[percona-creds-seed] script failed (rc=$rc)"
      }
    PWSH
  }
}
