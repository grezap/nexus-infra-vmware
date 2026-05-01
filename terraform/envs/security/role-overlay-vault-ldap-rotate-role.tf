/*
 * role-overlay-vault-ldap-rotate-role.tf -- Phase 0.D.3 step 4/4 (security)
 *
 * STATUS: gated ON by default in 0.D.3 (var.enable_vault_ldap_rotate_role
 * defaults to true). LDAPS was pulled forward from 0.D.5 to 0.D.3 via the
 * vault_ldaps_cert overlay because plain-LDAP simple bind fails wholesale
 * in this AD environment regardless of LDAPServerIntegrity (tested 2/1/0;
 * all fail with "Strong Auth Required"). With LDAPS now in place, AD
 * password-change operations (writing the unicodePwd attribute) succeed
 * because the TLS channel structurally satisfies AD's integrity
 * requirement. Canonized in memory/feedback_ad_ldaps_password_writes.md.
 *
 * Dependency chain:
 *   vault_ldaps_cert -> vault_ldap_auth -> vault_ldap_secret_engine -> THIS
 * The secret_engine trigger captures ldaps_cert_id transitively, so cert
 * re-issue invalidates the engine config which invalidates this role's
 * trigger and forces re-create on next apply.
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
    rotate_overlay_v = "2" # v2 = skip_import_rotation=true + explicit `vault write -force ldap/rotate-role/<name>` after create. Default Vault behavior on static-role create is to bind AS the target with the unknown pre-existing password, which AD rejects with data 52e (ERROR_LOGON_FAILURE / "Invalid Credentials"). With the skip flag set, Vault creates the role without that bind attempt; the force-rotate then takes ownership using the bind credential which has unicodePwd write rights. v1 = create-only (failed; "failed to bind with current password").
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

# Create the static-role WITHOUT the import-rotate bind attempt. The
# engine-level skip_static_role_import_rotation=true (set by the
# secret-engine overlay) is the primary defense; the role-level
# skip_import_rotation=true here is explicit + override-safe in case the
# engine config drifts. Without these, Vault tries to bind to AD as
# `$accountName` with a freshly-generated password it has never given
# AD, AD rejects ("data 52e" / "Invalid Credentials"), and the create
# returns 500 "failed to bind with current password".
echo "[ldap-rotate-role] writing ldap/static-role/$accountName (skip_import_rotation=true)"
vault write ldap/static-role/$accountName \
  username='$accountName' \
  dn='$accountDn' \
  rotation_period='$rotationPeriod' \
  skip_import_rotation=true >/dev/null

# Now take ownership of the AD password via an explicit rotation. This
# binds as svc-vault-ldap (the engine bindcred) and writes unicodePwd
# over LDAPS -- the proven write path. After this, Vault owns + serves
# the credential via ldap/static-cred/<name>.
echo "[ldap-rotate-role] forcing first managed rotation of $accountName"
vault write -force ldap/rotate-role/$accountName >/dev/null

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
