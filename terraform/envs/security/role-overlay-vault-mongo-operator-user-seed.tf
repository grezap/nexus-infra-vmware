/*
 * role-overlay-vault-mongo-operator-user-seed.tf -- Phase 0.G.2 / nexus-cli
 * v0.6.1 MongoAdapter operator-credential model.
 *
 * Sticky-seeds a 32-character base64 random password at
 * nexus/oltp/mongo/operator-password in Vault KV. This is the password for
 * the dedicated `nexus-cluster-admin` operator user (roles clusterMonitor +
 * clusterManager on `admin`) that the nexus-cli MongoAdapter authenticates
 * as for read/admin verbs (status / health / topology / failover / acl /
 * scale-out / backup).
 *
 * Credential model (decision locked with Greg 2026-06-05 -- the standard for
 * ALL password-auth adapters Mongo/Percona/Patroni/SQL):
 *   - The password lives ONLY in Vault KV. It is NEVER written to a node
 *     file (unlike smoke-user-password, which the mongo-tls overlay renders
 *     to /etc/nexus-mongo/smoke-user-password). The nexus-cli MongoAdapter
 *     fetches it at runtime via the existing VaultClient + VAULT_TOKEN
 *     (VaultTokenResolver reads VAULT_ADDR / VAULT_TOKEN / VAULT_CACERT) and
 *     passes it to mongosh over SSH -- creds transit, never persist on nodes.
 *   - The one-time createUser bootstrap (role-overlay-mongo-operator-user.tf
 *     in nexus-infra-oltp/terraform/envs/oltp-mongo) reads this same value
 *     via the mongo node's OWN Vault Agent token (`vault kv get` on-node),
 *     so the password is never written to disk there either.
 *
 * Why a dedicated operator user (vs reusing __system or smoke-rw):
 *   - __system (keyFile-derived cluster identity) is "discouraged for
 *     operator use" per MongoDB docs and is off-limits for the adapter's
 *     auto-mode classifier (it correctly blocked using it for queries).
 *   - smoke-rw has only `readWrite on nexus_smoke` -- it can't run
 *     rs.status() (needs replSetGetStatus / clusterMonitor) nor rs.stepDown
 *     / rs.add / rs.remove (needs clusterManager). The operator user gets
 *     exactly clusterMonitor + clusterManager -- the least privilege that
 *     covers the full MongoAdapter verb surface without granting root.
 *
 * Sticky-seed pattern (mirrors role-overlay-vault-mongo-smoke-user-seed.tf):
 *   if the KV path is already populated, the overlay is a no-op. Operator
 *   rotation requires two steps -- the user IS sticky-bound to whatever pwd
 *   is in MongoDB's admin.system.users:
 *     1. `vault kv put nexus/oltp/mongo/operator-password content=<new>`
 *     2. SSH to any mongo node and:
 *        mongosh --tls ... --username nexus-cluster-admin --password <OLD>
 *        --authenticationDatabase admin --eval
 *        'db.getSiblingDB("admin").updateUser("nexus-cluster-admin",{pwd:"<NEW>"})'
 *   Documented in nexus-infra-oltp/docs/handbook.md.
 *
 * Generation: 32-char base64 (~192 bits of entropy) via openssl rand.
 * Stripped of slash/equals/plus to keep it shell-safe in CLI flags.
 *
 * Selective ops: var.enable_mongo_operator_user_seed (master). Pre-req:
 * vault cluster initialized + KV-v2 mount at nexus/.
 */

resource "null_resource" "vault_mongo_operator_user_seed" {
  count = var.enable_vault_cluster && var.enable_vault_init && var.enable_mongo_operator_user_seed ? 1 : 0

  triggers = {
    post_init_id               = null_resource.vault_post_init[0].id
    kv_path                    = "nexus/oltp/mongo/operator-password"
    mongo_operator_user_seed_v = "1" # v1 (nexus-cli v0.6.1 MongoAdapter, 2026-06-05) = initial 32-char base64 sticky-seed for the nexus-cluster-admin operator user (clusterMonitor + clusterManager).
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

      if (-not (Test-Path $keysFile)) { throw "[mongo-operator-user-seed] keys file $keysFile missing" }
      $rootToken = (Get-Content $keysFile | ConvertFrom-Json).root_token

      $bash = @"
set -euo pipefail
export VAULT_TOKEN='$rootToken'
export VAULT_SKIP_VERIFY=true
export VAULT_ADDR=https://127.0.0.1:8200

# Sticky probe: if the path is already populated, do nothing.
if vault kv get -field=content nexus/oltp/mongo/operator-password >/dev/null 2>&1; then
  echo "[mongo-operator-user-seed] nexus/oltp/mongo/operator-password already populated -- no-op (sticky)"
  exit 0
fi

echo "[mongo-operator-user-seed] generating 32-char base64 password via openssl rand -base64 24"
# 24 raw bytes -> 32 base64 chars; strip /=+ to keep CLI-shell-safe; pad
# to 32 with hex if length drops below 24 (rare but possible).
PWD=`$(openssl rand -base64 24 | tr -d '/=+\n')
LEN=`$(printf '%s' "`$PWD" | wc -c)
if [ "`$LEN" -lt 24 ]; then
  EXTRA=`$(openssl rand -hex 4)
  PWD="$${PWD}$${EXTRA}"
  LEN=`$(printf '%s' "`$PWD" | wc -c)
fi
vault kv put nexus/oltp/mongo/operator-password content="`$PWD" >/dev/null
echo "[mongo-operator-user-seed] wrote nexus/oltp/mongo/operator-password (`$LEN chars)"
"@

      $bytes = [System.Text.UTF8Encoding]::new($false).GetBytes($bash)
      $b64   = [Convert]::ToBase64String($bytes)

      Write-Host "[mongo-operator-user-seed] dispatching to $${ip} via base64"
      $output = ssh -o ConnectTimeout=30 -o BatchMode=yes -o StrictHostKeyChecking=no $user@$ip "echo '$b64' | base64 -d | bash" 2>&1 | Out-String
      $rc = $LASTEXITCODE
      Write-Host $output.Trim()
      if ($rc -ne 0) {
        throw "[mongo-operator-user-seed] script failed (rc=$rc)"
      }
    PWSH
  }
}
