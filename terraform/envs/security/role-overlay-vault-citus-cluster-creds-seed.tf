/*
 * role-overlay-vault-citus-cluster-creds-seed.tf -- Phase 0.P setup
 *
 * Sticky-seeds the 4 Citus-tier PostgreSQL credentials in Vault KV. Patroni
 * bootstraps each PG cluster with these users; the terraform patroni-bootstrap
 * overlay reads them via each node's Vault Agent and renders patroni.yml +
 * pg_hba so every node in the cluster shares consistent secrets:
 *
 *   nexus/citus/superuser-password       (32-char hex)
 *     - the PostgreSQL superuser (`postgres`) password Patroni sets at bootstrap.
 *       Consumer: all 6 PG nodes. Also the user Citus's coordinator uses to dial
 *       workers (citus.node_conninfo).
 *   nexus/citus/replication-password     (32-char hex)
 *     - the `replicator` streaming-replication user Patroni creates. Consumer:
 *       all 6 PG nodes (the standby of each group dials the leader).
 *   nexus/citus/patroni-restapi-password  (32-char hex)
 *     - HTTP basic-auth password protecting the Patroni REST API's unsafe
 *       endpoints (restart/reinitialize/switchover). Consumer: all 6 PG nodes.
 *   nexus/citus/citus-app-password        (32-char hex)
 *     - the `citus_app` login role that owns the distributed/reference demo
 *       tables. Consumer: the coordinator pair (created post-bootstrap by the
 *       citus-extension overlay); used by clients + the smoke gate.
 *
 * Sticky-seed pattern (mirrors role-overlay-vault-vitess-cluster-creds-seed):
 * each KV path is probed; if already populated it's left alone (operator
 * rotation preserved). Generation is server-side on vault-1 via openssl;
 * values never transit the SSH wire to the build host. 32-char hex = 128 bits.
 *
 * Selective ops: var.enable_citus_cluster_creds_seed. Pre-req: vault cluster
 * initialized + KV-v2 mount at nexus/.
 */

resource "null_resource" "vault_citus_cluster_creds_seed" {
  count = var.enable_vault_cluster && var.enable_vault_init && var.enable_citus_cluster_creds_seed ? 1 : 0

  triggers = {
    post_init_id       = null_resource.vault_post_init[0].id
    kv_paths           = "nexus/citus/{superuser,replication,patroni-restapi,citus-app,operator}-password"
    citus_creds_seed_v = "2" # v2 (0.7.3) = + operator-password (nexus-cluster-admin, ADR-0011); v1 = 4 sticky creds (superuser, replication, patroni-restapi, citus-app).
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

      if (-not (Test-Path $keysFile)) { throw "[citus-creds-seed] keys file $keysFile missing" }
      $rootToken = (Get-Content $keysFile | ConvertFrom-Json).root_token

      $bash = @"
set -euo pipefail
export VAULT_TOKEN='$rootToken'
export VAULT_SKIP_VERIFY=true
export VAULT_ADDR=https://127.0.0.1:8200

seed_if_absent() {
  local path="`$1"
  local label="`$2"
  if vault kv get -field=content "`$path" >/dev/null 2>&1; then
    echo "[citus-creds-seed] `$path already populated -- no-op (sticky `$label)"
    return 0
  fi
  local PWD32
  PWD32=`$(openssl rand -hex 16)
  local LEN
  LEN=`$(printf '%s' "`$PWD32" | wc -c)
  if [ "`$LEN" -ne 32 ]; then
    echo "[citus-creds-seed] ERROR: `$label generated length `$LEN (expected 32)" >&2
    return 1
  fi
  vault kv put "`$path" content="`$PWD32" >/dev/null
  echo "[citus-creds-seed] wrote `$path (`$LEN-char hex `$label)"
}

seed_if_absent 'nexus/citus/superuser-password'       'PostgreSQL superuser password'
seed_if_absent 'nexus/citus/replication-password'     'streaming-replication user password'
seed_if_absent 'nexus/citus/patroni-restapi-password' 'Patroni REST API basic-auth password'
seed_if_absent 'nexus/citus/citus-app-password'       'citus_app distributed-table owner password'
seed_if_absent 'nexus/citus/operator-password'        'nexus-cluster-admin operator role password (ADR-0011; v0.7.3 CitusAdapter)'

echo "[citus-creds-seed] all 5 cluster creds present in nexus/citus/"
"@

      $bytes = [System.Text.UTF8Encoding]::new($false).GetBytes($bash)
      $b64   = [Convert]::ToBase64String($bytes)

      Write-Host "[citus-creds-seed] dispatching to $${ip} via base64"
      $output = ssh -o ConnectTimeout=30 -o BatchMode=yes -o StrictHostKeyChecking=no $user@$ip "echo '$b64' | base64 -d | bash" 2>&1 | Out-String
      $rc = $LASTEXITCODE
      Write-Host $output.Trim()
      if ($rc -ne 0) {
        throw "[citus-creds-seed] script failed (rc=$rc)"
      }
    PWSH
  }
}
