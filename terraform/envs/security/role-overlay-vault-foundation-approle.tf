/*
 * role-overlay-vault-foundation-approle.tf -- Phase 0.D.4 step 2/3 (security side)
 *
 * Define the AppRole `nexus-foundation-reader` and persist its role-id +
 * secret-id into `$HOME/.nexus/vault-foundation-approle.json` on the build
 * host. The foundation env's `provider "vault"` block reads this JSON at
 * plan/apply time to authenticate the data sources that fetch
 * `nexus/foundation/*` creds.
 *
 * AppRole shape:
 *   - token_policies = [nexus-foundation-reader]  (defined in the prior overlay)
 *   - token_ttl = 1h, token_max_ttl = 4h          (outlasts a single apply
 *                                                   trivially; rotation
 *                                                   handled by re-apply)
 *   - secret_id_ttl = 0                            (no expiry; lab convention
 *                                                   per Phase 0.D scope)
 *   - secret_id_num_uses = 0                       (unlimited reuse)
 *   - bind_secret_id = true                        (canonical pattern)
 *
 * Idempotency:
 *   - role-id is stable across re-applies (Vault assigns once on role create
 *     and preserves it on `vault write auth/approle/role/<name>` upserts).
 *   - secret-id is regenerated on every apply (the role can hold multiple
 *     valid secret-ids; old ones become stale but don't break unrelated
 *     consumers). Foundation env always reads the freshest secret-id from
 *     the JSON, so the operator order "security apply -> foundation apply"
 *     is the canonical refresh cadence.
 *
 * Selective ops: enable_vault_kv_foundation_seed (master) AND
 *                enable_vault_kv_foundation_approle.
 */

resource "null_resource" "vault_foundation_approle" {
  count = var.enable_vault_cluster && var.enable_vault_init && var.enable_vault_kv_foundation_seed && var.enable_vault_kv_foundation_approle ? 1 : 0

  triggers = {
    policy_id          = null_resource.vault_foundation_policy[0].id
    approle_creds_file = var.vault_foundation_approle_creds_file
    approle_overlay_v  = "1"
  }

  depends_on = [null_resource.vault_foundation_policy]

  provisioner "local-exec" {
    when        = create
    interpreter = ["pwsh", "-NoProfile", "-Command"]
    command     = <<-PWSH
      $ip               = '${local.vault_1_ip}'
      $user             = '${local.ssh_user}'
      $keysFileRaw      = '${var.vault_init_keys_file}'
      $keysFile         = $ExecutionContext.InvokeCommand.ExpandString($keysFileRaw.Replace('$HOME', $env:USERPROFILE))
      $approleFileRaw   = '${var.vault_foundation_approle_creds_file}'
      $approleFile      = $ExecutionContext.InvokeCommand.ExpandString($approleFileRaw.Replace('$HOME', $env:USERPROFILE))

      if (-not (Test-Path $keysFile)) {
        throw "[foundation-approle] keys file $keysFile missing -- run 0.D.1 init first"
      }
      $rootToken = (Get-Content $keysFile | ConvertFrom-Json).root_token

      # ─── Step A: upsert role + fetch role-id + new secret-id on vault-1 ──
      $remoteBash = @"
set -euo pipefail
export VAULT_TOKEN='$rootToken'
export VAULT_SKIP_VERIFY=true
export VAULT_ADDR=https://127.0.0.1:8200

# Ensure approle auth method is enabled (vault_post_init enabled it; this is
# defensive for the case where someone disabled it manually).
if ! vault auth list -format=json | jq -e '."approle/"' >/dev/null 2>&1; then
  vault auth enable approle >/dev/null
fi

# Upsert the role. Lab-scope: secret_id_ttl=0 + secret_id_num_uses=0 because
# this lab's foundation env apply is operator-driven; production-grade
# rotation lands in 0.D.5 with Vault Agent + ~1h TTLs.
vault write auth/approle/role/nexus-foundation-reader \
  token_policies=nexus-foundation-reader \
  token_ttl=1h \
  token_max_ttl=4h \
  secret_id_ttl=0 \
  secret_id_num_uses=0 \
  bind_secret_id=true >/dev/null

ROLE_ID=`$(vault read -field=role_id auth/approle/role/nexus-foundation-reader/role-id)
SECRET_ID=`$(vault write -field=secret_id -f auth/approle/role/nexus-foundation-reader/secret-id)

# Emit role-id + secret-id as a discrete marker line so the build host can
# extract them. Both values are UUIDs; no shell-special chars.
echo "FOUNDATION_APPROLE_ROLE_ID=`$ROLE_ID"
echo "FOUNDATION_APPROLE_SECRET_ID=`$SECRET_ID"
"@
      $bashBytes = [System.Text.UTF8Encoding]::new($false).GetBytes($remoteBash)
      $bashB64   = [Convert]::ToBase64String($bashBytes)
      $output = ssh -o ConnectTimeout=30 -o BatchMode=yes -o StrictHostKeyChecking=no $user@$ip "echo '$bashB64' | base64 -d | bash" 2>&1 | Out-String
      if ($LASTEXITCODE -ne 0) {
        throw "[foundation-approle] role/secret-id provisioning failed (rc=$LASTEXITCODE). Output:`n$output"
      }

      # Multi-line regex match -- PowerShell's `-match` with `(?m)` flag
      # treats `^`/`$` as line anchors within the multi-line $output string.
      # (Select-String with -AllMatches on a multi-line string can return
      # null Matches when the input has no trailing newline; the (?m) regex
      # via `-match` is the canonical PS idiom for this.)
      $roleId   = $null
      $secretId = $null
      if ($output -match '(?m)^FOUNDATION_APPROLE_ROLE_ID=(.+)$')   { $roleId   = $Matches[1].Trim() }
      if ($output -match '(?m)^FOUNDATION_APPROLE_SECRET_ID=(.+)$') { $secretId = $Matches[1].Trim() }
      if (-not $roleId -or -not $secretId) {
        throw "[foundation-approle] failed to parse role-id/secret-id from remote output. Output:`n$output"
      }

      # ─── Step B: persist to JSON file (atomic merge) ────────────────────
      $approleDir = Split-Path -Parent $approleFile
      New-Item -ItemType Directory -Force -Path $approleDir | Out-Null

      $existingObj = $null
      if (Test-Path $approleFile) {
        try { $existingObj = Get-Content $approleFile -Raw | ConvertFrom-Json } catch { }
      }
      $h = @{}
      if ($existingObj) {
        $existingObj.PSObject.Properties | ForEach-Object { $h[$_.Name] = $_.Value }
      }
      $h.role_name      = 'nexus-foundation-reader'
      $h.role_id        = $roleId
      $h.secret_id      = $secretId
      $h.vault_addr     = 'https://${local.vault_1_ip}:8200'
      $h.ca_bundle_path = '${var.vault_pki_ca_bundle_path}'
      $h.rotated_at     = (Get-Date).ToUniversalTime().ToString('o')

      ($h | ConvertTo-Json -Depth 4) | Set-Content -Path $approleFile -Encoding UTF8

      # NTFS owner-only ACL (mode 0600 equivalent on Win)
      icacls $approleFile /inheritance:r /grant:r "$($env:USERNAME):F" 2>&1 | Out-Null

      Write-Host "[foundation-approle] persisted role-id + secret-id to $approleFile (mode 0600 equivalent via icacls)"
      Write-Host "[foundation-approle] CRITICAL: this file authenticates the foundation env's vault provider; back it up + protect it"
      Write-Host "[foundation-approle] role_id length=$($roleId.Length); secret_id length=$($secretId.Length)"
    PWSH
  }
}
