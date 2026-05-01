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
    rotate_overlay_v = "3" # v3 = upsert static-role (don't short-circuit if role exists) + ALWAYS run force-rotate (idempotent; Vault re-rotates each call) + verify via static-cred read. Required because v2's "skip if role exists" branch left the role in Vault from the previous failed apply (AD ACL missing) without ever rotating, so subsequent applies skipped the rotation forever. v2 = skip_import_rotation=true + explicit force-rotate. v1 = create-only (failed; "failed to bind with current password").
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

# 1. Upsert the static-role with skip_import_rotation=true. `vault write`
#    is idempotent for static-role (creates or updates). We don't short-
#    circuit on "role already exists" because the previous apply may have
#    created the role but failed during force-rotate (e.g. missing AD ACL),
#    leaving the role in Vault but with no actual managed credential. We
#    must reach the force-rotate step on every apply until static-cred
#    has a real value.
#
#    skip_import_rotation=true tells Vault NOT to bind AS the target user
#    with an unknown pre-existing password. The engine-level
#    skip_static_role_import_rotation=true (set by the secret-engine
#    overlay) is the primary default; this role-level flag is explicit +
#    override-safe in case the engine config drifts.
echo "[ldap-rotate-role] upsert ldap/static-role/$accountName (skip_import_rotation=true)"
vault write ldap/static-role/$accountName \
  username='$accountName' \
  dn='$accountDn' \
  rotation_period='$rotationPeriod' \
  skip_import_rotation=true >/dev/null

# 2. Take ownership of the AD password via an explicit rotation. This
#    binds as svc-vault-ldap (the engine bindcred) and writes unicodePwd
#    over LDAPS. The bind account needs Reset Password extended right on
#    the target -- delegated by foundation env's
#    role-overlay-dc-vault-ad-bind-acl.tf. Without that ACL, this step
#    fails with LDAP code 50 INSUFF_ACCESS_RIGHTS.
#
#    `vault write -force ldap/rotate-role` is idempotent: every call
#    rotates anew. Safe to run on every apply -- subsequent applies
#    just produce a fresh password each time, which is fine for a demo
#    rotate-role (production rotate-roles use rotation_period to
#    schedule rotation, not apply cadence).
echo "[ldap-rotate-role] forcing managed rotation of $accountName"
vault write -force ldap/rotate-role/$accountName >/dev/null

# 3. Verify static-cred lookup works (reads back the just-rotated cred).
#    last_vault_rotation should be a fresh ISO timestamp; ttl is positive.
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
