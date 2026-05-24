/*
 * role-overlay-vault-registry-creds-seed.tf -- Phase 0.L.4 setup
 *
 * Sticky-seeds the Harbor registry creds in Vault KV (field `value`):
 *   nexus/registry/harbor-admin           (Harbor local admin -- break-glass;
 *                                           complexity: 1 upper+1 lower+1 digit)
 *   nexus/registry/harbor-secret-key      (Harbor encryption secretkey -- EXACTLY
 *                                           16 chars; identical across HA app nodes)
 *   nexus/registry/pg-superuser-password  (PG `postgres` role)
 *   nexus/registry/pg-replication-password(PG `repluser` streaming-repl role)
 *   nexus/registry/harbor-db-password     (PG `harbor` role -- Harbor's DB user)
 *   nexus/registry/redis-password         (Redis requirepass/masterauth)
 *
 * The OIDC client_id + client_secret are written by role-overlay-vault-oidc-
 * registry.tf (read back from the generated Vault OIDC client). All read on-node
 * via the per-host Vault Agent token; never transit the host. Sticky -- never
 * overwrites a populated path (operator rotation preserved).
 *
 * Selective ops: var.enable_registry_cluster_creds_seed (master).
 */

resource "null_resource" "vault_registry_creds_seed" {
  count = var.enable_vault_cluster && var.enable_vault_init && var.enable_registry_cluster_creds_seed ? 1 : 0

  triggers = {
    post_init_id          = null_resource.vault_post_init[0].id
    kv_paths              = "nexus/registry/{harbor-admin,harbor-secret-key,pg-superuser-password,pg-replication-password,harbor-db-password,redis-password}"
    registry_creds_seed_v = "1"
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

      if (-not (Test-Path $keysFile)) { throw "[registry-creds-seed] keys file $keysFile missing" }
      $rootToken = (Get-Content $keysFile | ConvertFrom-Json).root_token

      $bash = @"
set -euo pipefail
export VAULT_TOKEN='$rootToken'
export VAULT_SKIP_VERIFY=true
export VAULT_ADDR=https://127.0.0.1:8200

seed() {
  local path="`$1"; local val="`$2"; local label="`$3"
  if vault kv get -field=value "`$path" >/dev/null 2>&1; then
    echo "[registry-creds-seed] `$path already populated -- no-op (sticky `$label)"
    return 0
  fi
  vault kv put "`$path" value="`$val" >/dev/null
  echo "[registry-creds-seed] wrote `$path (`$label)"
}

# Harbor admin pw: Harbor enforces 1 upper + 1 lower + 1 digit, 8-128 chars.
# 'Aa1' prefix guarantees the classes; 32 random hex chars supply the entropy.
ADMINPW="Aa1`$(openssl rand -hex 16)"
seed 'nexus/registry/harbor-admin'            "`$ADMINPW"               'Harbor admin (break-glass)'
# Harbor secretkey MUST be exactly 16 bytes (encrypts DB-stored data; same on HA nodes).
seed 'nexus/registry/harbor-secret-key'       "`$(openssl rand -hex 8)" 'Harbor 16-char secretkey'
seed 'nexus/registry/pg-superuser-password'   "`$(openssl rand -hex 20)" 'PG postgres superuser'
seed 'nexus/registry/pg-replication-password' "`$(openssl rand -hex 20)" 'PG replication'
seed 'nexus/registry/harbor-db-password'      "`$(openssl rand -hex 20)" 'PG harbor DB role'
seed 'nexus/registry/redis-password'          "`$(openssl rand -hex 20)" 'Redis requirepass'

echo "[registry-creds-seed] all registry datastore + Harbor creds present in nexus/registry/"
"@

      $b64 = [Convert]::ToBase64String([System.Text.UTF8Encoding]::new($false).GetBytes($bash))
      Write-Host "[registry-creds-seed] dispatching to $${ip} via base64"
      $output = ssh -o ConnectTimeout=30 -o BatchMode=yes -o StrictHostKeyChecking=no $user@$ip "echo '$b64' | base64 -d | bash" 2>&1 | Out-String
      $rc = $LASTEXITCODE
      Write-Host $output.Trim()
      if ($rc -ne 0) { throw "[registry-creds-seed] script failed (rc=$rc)" }
    PWSH
  }
}
