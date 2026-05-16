/*
 * role-overlay-vault-mongo-keyfile-seed.tf -- Phase 0.G.2 setup
 *
 * Sticky-seeds a 1024-character base64 random keyFile at
 * nexus/oltp/mongo/keyfile in Vault KV. Each mongo-node Vault Agent
 * (role-overlay-mongo-vault-agents.tf in nexus-infra-oltp) renders the
 * value to /etc/nexus-mongo/keyfile (mode 0400 mongod:mongod). MongoDB's
 * replica set internal auth uses this shared secret to authenticate
 * between RS members (heartbeat / replication / election traffic).
 *
 * Sticky-seed pattern (mirrors role-overlay-vault-portainer-admin-seed.tf
 * + 0.E.4d): if the KV path is already populated, the overlay is a no-op.
 * Operator rotation is preserved -- `vault kv put nexus/oltp/mongo/keyfile
 * content=$(openssl rand -base64 756 | tr -d '\n')` followed by a rolling
 * restart of nexus-mongo.service across the 3 RS members updates the
 * secret without re-applying this overlay.
 *
 * Generation happens server-side on vault-1 (the transit-unseal anchor)
 * via openssl; the value never transits over the SSH wire to the build
 * host. The randomness source is /dev/urandom (openssl default).
 *
 * Why 1024 chars: MongoDB keyFile docs allow 6-1024 characters; longer is
 * better. Base64 is canonical because mongod's keyFile parser accepts any
 * printable chars but explicitly recommends base64. 756 raw bytes ->
 * 1024-char base64 (756 * 4/3 = 1008, padded to 1024).
 *
 * Selective ops: var.enable_mongo_keyfile_seed (master). Pre-req: vault
 * cluster initialized + KV-v2 mount at nexus/.
 */

resource "null_resource" "vault_mongo_keyfile_seed" {
  count = var.enable_vault_cluster && var.enable_vault_init && var.enable_mongo_keyfile_seed ? 1 : 0

  triggers = {
    post_init_id         = null_resource.vault_post_init[0].id
    kv_path              = "nexus/oltp/mongo/keyfile"
    mongo_keyfile_seed_v = "1" # v1 (0.G.2) = initial 1024-char base64 sticky-seed.
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

      if (-not (Test-Path $keysFile)) { throw "[mongo-keyfile-seed] keys file $keysFile missing" }
      $rootToken = (Get-Content $keysFile | ConvertFrom-Json).root_token

      # Generate-if-absent on vault-1. The keyFile content is the only
      # secret; metadata + presence are fine to log.
      $bash = @"
set -euo pipefail
export VAULT_TOKEN='$rootToken'
export VAULT_SKIP_VERIFY=true
export VAULT_ADDR=https://127.0.0.1:8200

# Sticky probe: if nexus/oltp/mongo/keyfile is already populated with a
# `content` field, do nothing -- operator rotation is preserved.
if vault kv get -field=content nexus/oltp/mongo/keyfile >/dev/null 2>&1; then
  echo "[mongo-keyfile-seed] nexus/oltp/mongo/keyfile already populated -- no-op (sticky)"
  exit 0
fi

echo "[mongo-keyfile-seed] generating 1024-char base64 keyFile via openssl rand -base64 756"
KEY=`$(openssl rand -base64 756 | tr -d '\n')
LEN=`$(printf '%s' "`$KEY" | wc -c)
if [ "`$LEN" -lt 6 ] || [ "`$LEN" -gt 1024 ]; then
  echo "[mongo-keyfile-seed] ERROR: generated keyFile is `$LEN chars (need 6-1024)" >&2
  exit 1
fi
vault kv put nexus/oltp/mongo/keyfile content="`$KEY" >/dev/null
echo "[mongo-keyfile-seed] wrote nexus/oltp/mongo/keyfile (`$LEN chars base64)"
"@

      $bytes = [System.Text.UTF8Encoding]::new($false).GetBytes($bash)
      $b64   = [Convert]::ToBase64String($bytes)

      Write-Host "[mongo-keyfile-seed] dispatching to $${ip} via base64"
      $output = ssh -o ConnectTimeout=30 -o BatchMode=yes -o StrictHostKeyChecking=no $user@$ip "echo '$b64' | base64 -d | bash" 2>&1 | Out-String
      $rc = $LASTEXITCODE
      Write-Host $output.Trim()
      if ($rc -ne 0) {
        throw "[mongo-keyfile-seed] script failed (rc=$rc)"
      }
    PWSH
  }
}
