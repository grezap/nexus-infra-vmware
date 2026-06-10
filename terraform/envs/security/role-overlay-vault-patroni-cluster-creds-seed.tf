/*
 * role-overlay-vault-patroni-cluster-creds-seed.tf -- Phase 0.G.4 setup
 *
 * Sticky-seeds the 5 Patroni-tier cluster credentials in Vault KV:
 *
 *   nexus/oltp/patroni/etcd-root-password                  (32-char hex)
 *     - etcd `root` user password. Used for etcdctl operator ops + cluster
 *       RBAC (after `etcdctl auth enable` flips the cluster from no-auth
 *       to authenticated).
 *     - Consumer: 3 etcd nodes (root@etcd) + 3 Patroni nodes (operator ops
 *       on rare cases when manually inspecting DCS state via etcdctl)
 *
 *   nexus/oltp/patroni/patroni-rest-password               (32-char hex)
 *     - Patroni REST API :8008 HTTP basic-auth password (single shared user
 *       `nexusops` baked into patroni.yml's restapi.authentication block).
 *       Required by Patroni REST for any state-changing call (/switchover,
 *       /restart, /reinitialize). Read-only endpoints (/leader, /readiness,
 *       /health) are unauthenticated by design (HAProxy uses these for
 *       backend health probes).
 *     - Consumer: 3 Patroni nodes (REST listener config) + 3 etcd nodes
 *       (parity with operator workflow that may etcdctl-then-patronictl)
 *       + 1 HAProxy node (for operator tunneled access via :8404 stats UI
 *       backlinks; HAProxy itself uses the unauth /leader for health probes)
 *
 *   nexus/oltp/patroni/postgres-superuser-password         (32-char hex)
 *     - PostgreSQL `postgres` superuser password. Bootstrapped on initial
 *       Patroni `initdb` then propagated via streaming replication. Used by
 *       Patroni internally for cluster ops + by the smoke gate for write/
 *       read round-trips via `psql -h haproxy-pg`.
 *     - Consumer: 3 Patroni nodes only (etcd + haproxy don't dial PG directly)
 *
 *   nexus/oltp/patroni/postgres-replication-password       (32-char hex)
 *     - PostgreSQL `replicator` user password. Used for streaming replication
 *       between leader + 2 replicas (pg_hba.conf grants `replication`
 *       capability to this user from VMnet10 backplane IPs only).
 *     - Consumer: 3 Patroni nodes only
 *
 *   nexus/oltp/patroni/haproxy-stats-password              (32-char hex)
 *     - HAProxy :8404 stats UI HTTP basic-auth password (single shared user
 *       `nexusops`). Used by operator to view backend health + connection
 *       rates.
 *     - Consumer: 1 HAProxy node only
 *
 *   nexus/oltp/patroni/operator-password                   (32-char hex)
 *     - PostgreSQL `nexus-cluster-admin` operator role password (nexus-cli
 *       v0.6.3 PatroniAdapter). The dedicated least-priv operator identity the
 *       adapter authenticates as for its read/admin verbs (status / health /
 *       topology / failover / scale-out / backup / cert-rotate / acl / chaos).
 *       Mirrors the mongo + percona operator-password model locked with Greg
 *       2026-06-05: the password lives ONLY in Vault KV (never rendered to a
 *       node file); the oltp-patroni operator-user overlay reads it on the
 *       Patroni LEADER via the node's own Vault Agent token + CREATE ROLEs it;
 *       at RUNTIME the PatroniAdapter fetches the same KV value via the
 *       existing INexusVaultClient + VAULT_TOKEN and passes it to psql.
 *     - Consumer: 3 Patroni nodes (operator-user overlay reads it on the
 *       leader; the role replicates to the 2 streaming replicas via WAL)
 *
 * Sticky-seed pattern (mirrors role-overlay-vault-percona-cluster-creds-seed):
 * each KV path is probed; if already populated, that secret is left alone
 * (operator rotation preserved). Each `vault kv put nexus/oltp/patroni/
 * <name>-password content=$(openssl rand -hex 16)` followed by the
 * appropriate cluster restart updates the secret without re-applying.
 *
 * Generation happens server-side on vault-1 (the transit-unseal anchor) via
 * openssl; values never transit over the SSH wire to the build host.
 *
 * Why 32-char hex (`openssl rand -hex 16` = 16 random bytes -> 32 hex
 * chars): PostgreSQL passwords are unrestricted but hex is the safest
 * portable character set across PG + etcd + Patroni YAML + shell layers.
 * 16 random bytes = 128 bits of entropy.
 *
 * Selective ops: var.enable_patroni_cluster_creds_seed (master). Pre-req:
 * vault cluster initialized + KV-v2 mount at nexus/.
 */

resource "null_resource" "vault_patroni_cluster_creds_seed" {
  count = var.enable_vault_cluster && var.enable_vault_init && var.enable_patroni_cluster_creds_seed ? 1 : 0

  triggers = {
    post_init_id         = null_resource.vault_post_init[0].id
    kv_paths             = "nexus/oltp/patroni/{etcd-root,patroni-rest,postgres-superuser,postgres-replication,haproxy-stats,operator}-password"
    patroni_creds_seed_v = "2" # v2 (nexus-cli v0.6.3 PatroniAdapter, 2026-06-11) = +operator-password (the dedicated nexus-cluster-admin PostgreSQL operator role; lives ONLY in Vault KV, fetched by the adapter at runtime via INexusVaultClient, like mongo + percona operator-password). v1 (0.G.4) = initial 5 sticky-seeded 32-char hex creds (etcd-root, patroni-rest, postgres-superuser, postgres-replication, haproxy-stats).
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

      if (-not (Test-Path $keysFile)) { throw "[patroni-creds-seed] keys file $keysFile missing" }
      $rootToken = (Get-Content $keysFile | ConvertFrom-Json).root_token

      # Generate-if-absent on vault-1 per-secret. Each secret is independent;
      # if 4 of 5 are populated + 1 is missing (e.g. operator deleted to
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
    echo "[patroni-creds-seed] `$path already populated -- no-op (sticky `$label)"
    return 0
  fi
  local PWD32
  PWD32=`$(openssl rand -hex 16)
  local LEN
  LEN=`$(printf '%s' "`$PWD32" | wc -c)
  if [ "`$LEN" -ne 32 ]; then
    echo "[patroni-creds-seed] ERROR: `$label generated length `$LEN (expected 32)" >&2
    return 1
  fi
  vault kv put "`$path" content="`$PWD32" >/dev/null
  echo "[patroni-creds-seed] wrote `$path (`$LEN-char hex `$label)"
}

seed_if_absent 'nexus/oltp/patroni/etcd-root-password'              'etcd root password'
seed_if_absent 'nexus/oltp/patroni/patroni-rest-password'           'Patroni REST :8008 HTTP basic password'
seed_if_absent 'nexus/oltp/patroni/postgres-superuser-password'     'PostgreSQL postgres superuser password'
seed_if_absent 'nexus/oltp/patroni/postgres-replication-password'   'PostgreSQL replicator user password'
seed_if_absent 'nexus/oltp/patroni/haproxy-stats-password'          'HAProxy :8404 stats UI HTTP basic password'
seed_if_absent 'nexus/oltp/patroni/operator-password'               'nexus-cluster-admin PostgreSQL operator password (nexus-cli PatroniAdapter; Vault-KV-only)'

echo "[patroni-creds-seed] all 6 cluster creds present in nexus/oltp/patroni/"
"@

      $bytes = [System.Text.UTF8Encoding]::new($false).GetBytes($bash)
      $b64   = [Convert]::ToBase64String($bytes)

      Write-Host "[patroni-creds-seed] dispatching to $${ip} via base64"
      $output = ssh -o ConnectTimeout=30 -o BatchMode=yes -o StrictHostKeyChecking=no $user@$ip "echo '$b64' | base64 -d | bash" 2>&1 | Out-String
      $rc = $LASTEXITCODE
      Write-Host $output.Trim()
      if ($rc -ne 0) {
        throw "[patroni-creds-seed] script failed (rc=$rc)"
      }
    PWSH
  }
}
