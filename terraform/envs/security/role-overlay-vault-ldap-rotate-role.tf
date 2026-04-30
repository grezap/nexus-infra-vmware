/*
 * role-overlay-vault-ldap-rotate-role.tf -- Phase 0.D.3 step 4/4 (security)
 *
 * STATUS: gated OFF by default in 0.D.3 (var.enable_vault_ldap_rotate_role
 * defaults to false). Reason: AD requires LDAPS or LDAP+StartTLS for
 * password-change operations (writing the unicodePwd attribute). Plain
 * LDAP/389 binds work for reads + auth, so auth/ldap is fully functional,
 * but Vault's first-apply rotate of svc-demo-rotated fails with
 * "LDAP Result Code 8 Strong Auth Required" -- AD enforces TLS for this
 * specific operation regardless of the LDAPServerIntegrity signing setting.
 * Canonized in memory/feedback_ad_ldaps_password_writes.md.
 *
 * Re-enable after 0.D.5 lands the LDAPS overlay:
 *   1. Issue a cert via pki_int/issue/vault-server for dc-nexus.nexus.lab
 *      (foundation-side overlay, TBD)
 *   2. Import cert into dc-nexus's Local Computer Personal cert store; AD
 *      DS auto-detects + serves LDAPS on TCP/636
 *   3. Flip var.vault_ldap_url to ldaps://192.168.70.240:636
 *   4. terraform apply -var enable_vault_ldap_rotate_role=true
 *
 * Define the static rotate-role for `svc-demo-rotated`. From this overlay
 * forward, Vault owns that AD account's password and rotates it every
 * `var.vault_ldap_demo_rotation_period` (default 24h).
 *
 * Static-role flow:
 *   - First apply: Vault binds to AD as svc-vault-ldap, calls
 *     SetADAccountPassword on svc-demo-rotated with a freshly-generated
 *     pwd (using the nexus-ad-rotated password policy from step 3/4),
 *     stores the pwd in its own state. AD's pwdLastSet is bumped.
 *   - Subsequent reads: `vault read ldap/static-cred/svc-demo-rotated`
 *     returns { username, password, last_vault_rotation, ttl, ... }.
 *   - Auto-rotation: every `rotation_period`, Vault repeats the dance.
 *
 * Consumers downstream (apps in 0.G+, jobs in 0.E+) use Vault Agent or
 * the API directly to fetch the current password. The legacy pattern of
 * "embed the AD pwd in app config" is replaced by "agent renews from
 * Vault". This is the demo / proof-of-concept that proves the engine
 * works against our AD; production rotate-roles will be added per app.
 *
 * Idempotency: `vault write ldap/static-role/<name> ...` is upsert.
 *   First write: Vault rotates immediately to seize ownership.
 *   Subsequent writes with same params: no-op (Vault doesn't rotate
 *   on every read; only on rotation_period elapse OR explicit
 *   `vault write -force ldap/rotate-role/<name>`).
 *
 * Selective ops: enable_vault_ldap (master) AND enable_vault_ldap_rotate_role.
 */

resource "null_resource" "vault_ldap_rotate_role" {
  count = var.enable_vault_cluster && var.enable_vault_init && var.enable_vault_ldap && var.enable_vault_ldap_rotate_role ? 1 : 0

  triggers = {
    secret_engine_id = length(null_resource.vault_ldap_secret_engine) > 0 ? null_resource.vault_ldap_secret_engine[0].id : "disabled"
    account_name     = var.vault_ldap_demo_rotate_account
    rotation_period  = var.vault_ldap_demo_rotation_period
    rotate_overlay_v = "1"
  }

  depends_on = [null_resource.vault_ldap_secret_engine]

  provisioner "local-exec" {
    when        = create
    interpreter = ["pwsh", "-NoProfile", "-Command"]
    command     = <<-PWSH
      $ip                = '${local.vault_1_ip}'
      $user              = '${local.ssh_user}'
      $accountName       = '${var.vault_ldap_demo_rotate_account}'
      $rotationPeriod    = '${var.vault_ldap_demo_rotation_period}'
      $userDn            = '${var.vault_ldap_user_dn}'
      $keysFileRaw       = '${var.vault_init_keys_file}'
      $keysFile          = $ExecutionContext.InvokeCommand.ExpandString($keysFileRaw.Replace('$HOME', $env:USERPROFILE))

      if (-not (Test-Path $keysFile)) {
        throw "[ldap-rotate-role] vault-init.json missing"
      }
      $rootToken = (Get-Content $keysFile | ConvertFrom-Json).root_token

      # The DN of the rotate target: CN=<account>,OU=ServiceAccounts,<userDn>.
      # Foundation creates the account in OU=ServiceAccounts so the DN is fixed.
      $accountDn = "CN=$accountName,OU=ServiceAccounts,$userDn"
      Write-Host "[ldap-rotate-role] target DN: $accountDn (rotation_period=$rotationPeriod)"

      $bash = @"
set -euo pipefail
export VAULT_TOKEN='$rootToken'
export VAULT_SKIP_VERIFY=true
export VAULT_ADDR=https://127.0.0.1:8200

# Idempotency: probe for existing static-role
if vault read -format=json ldap/static-role/$accountName 2>/dev/null | jq -e '.data.username' >/dev/null 2>&1; then
  echo '[ldap-rotate-role] static-role $accountName already defined; skipping create (use vault write -force ldap/rotate-role/$accountName to force-rotate)'
  exit 0
fi

echo "[ldap-rotate-role] writing ldap/static-role/$accountName"
vault write ldap/static-role/$accountName \
  username='$accountName' \
  dn='$accountDn' \
  rotation_period='$rotationPeriod' >/dev/null

# Verify the role is queryable + a credential lookup works
echo '[ldap-rotate-role] verifying ldap/static-cred/$accountName...'
LOOKUP=`$(vault read -format=json ldap/static-cred/$accountName | jq -r '.data | {username, last_vault_rotation, ttl}')
echo "[ldap-rotate-role] static-cred ready: `$LOOKUP"
"@

      $bytes = [System.Text.UTF8Encoding]::new($false).GetBytes($bash)
      $b64   = [Convert]::ToBase64String($bytes)
      $output = ssh -o ConnectTimeout=60 -o BatchMode=yes -o StrictHostKeyChecking=no $user@$ip "echo '$b64' | base64 -d | bash" 2>&1 | Out-String
      if ($LASTEXITCODE -ne 0) {
        throw "[ldap-rotate-role] script failed (rc=$LASTEXITCODE). Output:`n$output"
      }
      Write-Host $output.Trim()
    PWSH
  }
}
