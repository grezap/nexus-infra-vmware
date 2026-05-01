/*
 * role-overlay-vault-foundation-policy.tf -- Phase 0.D.4 step 1/3 (security side)
 *
 * Define the `nexus-foundation-reader` policy that the foundation env's
 * AppRole token will hold. Read+list on `nexus/data/foundation/*` and
 * `nexus/metadata/foundation/*` (KV-v2 path semantics) plus token-self
 * lookup/renew for healthy provider behavior. NO sudo. NO writes outside
 * `nexus/foundation/ad/*` (writes scoped narrowly because the foundation
 * env's dc_vault_ad_bind / dc_vault_ad_smoke overlays generate-and-write
 * the bind+smoke creds at create time -- per 0.D.4 design decision (3)).
 *
 * Policy lives in security env because Vault is the home of policies; the
 * foundation env's AppRole is "tenant-side credentials" but the policy
 * shape is owned by whoever owns Vault (security env).
 *
 * Idempotency: `vault policy write` is upsert; trigger refires on policy
 * text change.
 *
 * Selective ops: enable_vault_kv_foundation_seed master toggle gates the
 * entire 0.D.4 layer; per-step toggle enable_vault_kv_foundation_policy.
 */

resource "null_resource" "vault_foundation_policy" {
  count = var.enable_vault_cluster && var.enable_vault_init && var.enable_vault_kv_foundation_seed && var.enable_vault_kv_foundation_policy ? 1 : 0

  triggers = {
    post_init_id     = null_resource.vault_post_init[0].id
    kv_mount_path    = var.vault_kv_mount_path
    policy_overlay_v = "1"
  }

  depends_on = [null_resource.vault_post_init]

  provisioner "local-exec" {
    when        = create
    interpreter = ["pwsh", "-NoProfile", "-Command"]
    command     = <<-PWSH
      $ip          = '${local.vault_1_ip}'
      $user        = '${local.ssh_user}'
      $kvPath      = '${var.vault_kv_mount_path}'
      $keysFileRaw = '${var.vault_init_keys_file}'
      $keysFile    = $ExecutionContext.InvokeCommand.ExpandString($keysFileRaw.Replace('$HOME', $env:USERPROFILE))

      if (-not (Test-Path $keysFile)) {
        throw "[foundation-policy] keys file $keysFile missing -- run 0.D.1 init first"
      }
      $rootToken = (Get-Content $keysFile | ConvertFrom-Json).root_token

      # Policy body. Read: data + metadata. Write: ad/* only (where the bind
      # and smoke account overlays push generated creds at create time).
      # Token-self lookup/renew lets the provider keep its token alive across
      # the apply window without needing 'default' policy stacked on top.
      $policyBody = @"
# nexus-foundation-reader -- Phase 0.D.4 AppRole policy.
# Read all of nexus/foundation/*, write only nexus/foundation/ad/* (where
# the foundation env's bind/smoke overlays push generated creds).
path "$kvPath/data/foundation/*" {
  capabilities = ["read"]
}
path "$kvPath/metadata/foundation/*" {
  capabilities = ["read", "list"]
}
path "$kvPath/data/foundation/ad/*" {
  capabilities = ["create", "update"]
}
path "$kvPath/metadata/foundation/ad/*" {
  capabilities = ["read", "list"]
}
path "auth/token/lookup-self" {
  capabilities = ["read"]
}
path "auth/token/renew-self" {
  capabilities = ["update"]
}
"@

      $bytes = [System.Text.UTF8Encoding]::new($false).GetBytes($policyBody)
      $b64   = [Convert]::ToBase64String($bytes)

      $remoteBash = @"
set -euo pipefail
export VAULT_TOKEN='$rootToken'
export VAULT_SKIP_VERIFY=true
export VAULT_ADDR=https://127.0.0.1:8200

TMP=`$(mktemp)
trap 'rm -f "`$TMP"' EXIT
echo '$b64' | base64 -d > "`$TMP"

vault policy write 'nexus-foundation-reader' "`$TMP" >/dev/null
echo "[foundation-policy] wrote policy 'nexus-foundation-reader' (`$(wc -c < "`$TMP") bytes)"
"@
      $bashBytes = [System.Text.UTF8Encoding]::new($false).GetBytes($remoteBash)
      $bashB64   = [Convert]::ToBase64String($bashBytes)
      $output = ssh -o ConnectTimeout=30 -o BatchMode=yes -o StrictHostKeyChecking=no $user@$ip "echo '$bashB64' | base64 -d | bash" 2>&1 | Out-String
      if ($LASTEXITCODE -ne 0) {
        throw "[foundation-policy] vault policy write failed (rc=$LASTEXITCODE). Output:`n$output"
      }
      Write-Host $output.Trim()
    PWSH
  }
}
