/*
 * role-overlay-vault-vitess-cluster-creds-seed.tf -- Phase 0.O setup
 *
 * Sticky-seeds the 5 Vitess-tier MySQL/VTOrc credentials in Vault KV. These are
 * the standard Vitess mysqld user set (Vitess creates vt_app / vt_dba /
 * vt_allprivs / vt_repl / vt_filtered via its init_db.sql; we KV-seed the
 * passwords + the VTOrc topology user so the terraform tablet overlay renders
 * a per-host init_db.sql + db creds with consistent secrets cluster-wide):
 *
 *   nexus/vitess/mysql-root-password        (32-char hex)
 *     - Percona Server `root@localhost` password (mysqlctld init). Consumer:
 *       6 tablets.
 *   nexus/vitess/mysql-app-password         (32-char hex)
 *     - `vt_app` user -- vttablet/vtgate query traffic (the application path).
 *       Consumer: 6 tablets.
 *   nexus/vitess/mysql-allprivs-password    (32-char hex)
 *     - `vt_allprivs`/`vt_dba` admin user -- mysqlctld + reparenting + schema
 *       changes. Consumer: 6 tablets.
 *   nexus/vitess/mysql-repl-password        (32-char hex)
 *     - `vt_repl` replication user -- intra-shard MySQL replication
 *       (primary -> replicas). Consumer: 6 tablets.
 *   nexus/vitess/vtorc-topo-password        (32-char hex)
 *     - the mysqld user VTOrc uses to probe replication health + run the
 *       reparent SQL. Consumer: control node (VTOrc) + 6 tablets (grant).
 *
 * Sticky-seed pattern (mirrors role-overlay-vault-patroni-cluster-creds-seed):
 * each KV path is probed; if already populated it's left alone (operator
 * rotation preserved). Generation is server-side on vault-1 via openssl;
 * values never transit the SSH wire to the build host. 32-char hex = 128 bits.
 *
 * Selective ops: var.enable_vitess_cluster_creds_seed. Pre-req: vault cluster
 * initialized + KV-v2 mount at nexus/.
 */

resource "null_resource" "vault_vitess_cluster_creds_seed" {
  count = var.enable_vault_cluster && var.enable_vault_init && var.enable_vitess_cluster_creds_seed ? 1 : 0

  triggers = {
    post_init_id        = null_resource.vault_post_init[0].id
    kv_paths            = "nexus/vitess/{mysql-root,mysql-app,mysql-allprivs,mysql-repl,vtorc-topo}-password"
    vitess_creds_seed_v = "1" # v1 (0.O) = 5 sticky-seeded 32-char hex creds (mysql-root, mysql-app, mysql-allprivs, mysql-repl, vtorc-topo).
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

      if (-not (Test-Path $keysFile)) { throw "[vitess-creds-seed] keys file $keysFile missing" }
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
    echo "[vitess-creds-seed] `$path already populated -- no-op (sticky `$label)"
    return 0
  fi
  local PWD32
  PWD32=`$(openssl rand -hex 16)
  local LEN
  LEN=`$(printf '%s' "`$PWD32" | wc -c)
  if [ "`$LEN" -ne 32 ]; then
    echo "[vitess-creds-seed] ERROR: `$label generated length `$LEN (expected 32)" >&2
    return 1
  fi
  vault kv put "`$path" content="`$PWD32" >/dev/null
  echo "[vitess-creds-seed] wrote `$path (`$LEN-char hex `$label)"
}

seed_if_absent 'nexus/vitess/mysql-root-password'      'Percona Server root password'
seed_if_absent 'nexus/vitess/mysql-app-password'       'vt_app user password'
seed_if_absent 'nexus/vitess/mysql-allprivs-password'  'vt_allprivs/vt_dba admin user password'
seed_if_absent 'nexus/vitess/mysql-repl-password'      'vt_repl replication user password'
seed_if_absent 'nexus/vitess/vtorc-topo-password'      'VTOrc mysqld topology user password'

echo "[vitess-creds-seed] all 5 cluster creds present in nexus/vitess/"
"@

      $bytes = [System.Text.UTF8Encoding]::new($false).GetBytes($bash)
      $b64   = [Convert]::ToBase64String($bytes)

      Write-Host "[vitess-creds-seed] dispatching to $${ip} via base64"
      $output = ssh -o ConnectTimeout=30 -o BatchMode=yes -o StrictHostKeyChecking=no $user@$ip "echo '$b64' | base64 -d | bash" 2>&1 | Out-String
      $rc = $LASTEXITCODE
      Write-Host $output.Trim()
      if ($rc -ne 0) {
        throw "[vitess-creds-seed] script failed (rc=$rc)"
      }
    PWSH
  }
}
