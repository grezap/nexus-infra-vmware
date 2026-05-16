/*
 * role-overlay-vault-mongo-smoke-user-seed.tf -- Phase 0.G.2 ratification fix
 *
 * Sticky-seeds a 32-character base64 random password at
 * nexus/oltp/mongo/smoke-user-password in Vault KV. Each mongo-node
 * Vault Agent (role-overlay-mongo-tls.tf in nexus-infra-oltp) renders
 * the value to /etc/nexus-mongo/smoke-user-password (mode 0400
 * mongodb:mongodb).
 *
 * Why this exists:
 *   MongoDB 8.0 changed the localhost-exception default for replica
 *   sets: with `security.keyFile` + `authorization=enabled`, the
 *   localhost exception is DISABLED by default. rs.initiate() still
 *   works (special bootstrap command), but ALL other operations
 *   require an authenticated user. The 0.G.2 first ratification
 *   surfaced this when the rs-initiate exit-gate's write/read round-
 *   trip failed with "not authorized on nexus_smoke to execute
 *   command insert".
 *
 *   Fix: bootstrap a `smoke-rw` user during rs.initiate via the
 *   `enableLocalhostAuthBypass=true` setParameter (set in mongod.conf
 *   role-overlay), using the password seeded here. After the first
 *   user is created, the localhost bypass auto-deactivates per
 *   MongoDB's normal rule (system.users non-empty -> bypass off).
 *   Subsequent operations (including smoke) authenticate as smoke-rw
 *   with this password.
 *
 *   The smoke-rw user has narrow scope: role `readWrite` on database
 *   `nexus_smoke` only (no cross-DB access, no admin privileges).
 *   It's a SMOKE-TEST user; real application access in later phases
 *   would use x509 user auth (cert subject -> user mapping).
 *
 * Sticky-seed pattern (mirrors role-overlay-vault-mongo-keyfile-seed.tf):
 *   if the KV path is already populated, the overlay is a no-op.
 *   Operator rotation requires two steps -- the user IS sticky-bound
 *   to whatever pwd is in MongoDB's admin.system.users:
 *     1. `vault kv put nexus/oltp/mongo/smoke-user-password content=<new>`
 *     2. SSH to any mongo node and:
 *        mongosh --tls ... --username smoke-rw --password <OLD>
 *        --authenticationDatabase admin --eval
 *        'db.getSiblingDB("admin").updateUser("smoke-rw",{pwd:"<NEW>"})'
 *   Documented in nexus-infra-oltp/docs/handbook.md.
 *
 * Generation: 32-char base64 (~192 bits of entropy) via openssl rand.
 * Stripped of slash/equals/plus to keep it shell-safe in CLI flags.
 *
 * Selective ops: var.enable_mongo_smoke_user_seed (master). Pre-req:
 * vault cluster initialized + KV-v2 mount at nexus/.
 */

resource "null_resource" "vault_mongo_smoke_user_seed" {
  count = var.enable_vault_cluster && var.enable_vault_init && var.enable_mongo_smoke_user_seed ? 1 : 0

  triggers = {
    post_init_id            = null_resource.vault_post_init[0].id
    kv_path                 = "nexus/oltp/mongo/smoke-user-password"
    mongo_smoke_user_seed_v = "1" # v1 (0.G.2 ratification fix 2026-05-17) = initial 32-char base64 sticky-seed for the smoke-rw RBAC user.
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

      if (-not (Test-Path $keysFile)) { throw "[mongo-smoke-user-seed] keys file $keysFile missing" }
      $rootToken = (Get-Content $keysFile | ConvertFrom-Json).root_token

      $bash = @"
set -euo pipefail
export VAULT_TOKEN='$rootToken'
export VAULT_SKIP_VERIFY=true
export VAULT_ADDR=https://127.0.0.1:8200

# Sticky probe: if the path is already populated, do nothing.
if vault kv get -field=content nexus/oltp/mongo/smoke-user-password >/dev/null 2>&1; then
  echo "[mongo-smoke-user-seed] nexus/oltp/mongo/smoke-user-password already populated -- no-op (sticky)"
  exit 0
fi

echo "[mongo-smoke-user-seed] generating 32-char base64 password via openssl rand -base64 24"
# 24 raw bytes -> 32 base64 chars; strip /=+ to keep CLI-shell-safe; pad
# to 32 with hex if length drops below 24 (rare but possible).
PWD=`$(openssl rand -base64 24 | tr -d '/=+\n')
LEN=`$(printf '%s' "`$PWD" | wc -c)
if [ "`$LEN" -lt 24 ]; then
  EXTRA=`$(openssl rand -hex 4)
  PWD="$${PWD}$${EXTRA}"
  LEN=`$(printf '%s' "`$PWD" | wc -c)
fi
vault kv put nexus/oltp/mongo/smoke-user-password content="`$PWD" >/dev/null
echo "[mongo-smoke-user-seed] wrote nexus/oltp/mongo/smoke-user-password (`$LEN chars)"
"@

      $bytes = [System.Text.UTF8Encoding]::new($false).GetBytes($bash)
      $b64   = [Convert]::ToBase64String($bytes)

      Write-Host "[mongo-smoke-user-seed] dispatching to $${ip} via base64"
      $output = ssh -o ConnectTimeout=30 -o BatchMode=yes -o StrictHostKeyChecking=no $user@$ip "echo '$b64' | base64 -d | bash" 2>&1 | Out-String
      $rc = $LASTEXITCODE
      Write-Host $output.Trim()
      if ($rc -ne 0) {
        throw "[mongo-smoke-user-seed] script failed (rc=$rc)"
      }
    PWSH
  }
}
