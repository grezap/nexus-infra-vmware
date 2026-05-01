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
    rotate_overlay_v = "4" # v4 = three-state probe: (a) role exists + managed cred (last_vault_rotation set, password non-empty) -> short-circuit, (b) role missing -> create with skip_import_rotation=true + force-rotate, (c) role exists but not yet rotated -> force-rotate without rewriting role. Required because skip_import_rotation is CREATE-ONLY; Vault rejects PUT-with-flag on existing role with 400 "skip_import_rotation has no effect on updates". v3 always-upserted (broke on update). v2 short-circuited on existence (broke when previous run left role un-rotated). v1 create-only.
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

# Three-state idempotency probe.
#
# State A: role exists AND has a managed credential (last_vault_rotation
#   set and a non-empty password). Everything is already done; exit 0.
#
# State B: role MISSING. Create with skip_import_rotation=true (the flag
#   is CREATE-ONLY -- Vault rejects updates with "skip_import_rotation
#   has no effect on updates" / 400), then force-rotate to take ownership.
#
# State C: role EXISTS but not yet rotated (e.g. prior apply created the
#   role but the force-rotate hit a transient AD error -- "retries will
#   continue in the background but it is also safe to retry manually").
#   Skip the create/update entirely, just run force-rotate.
ROLE_JSON=`$(vault read -format=json ldap/static-role/$accountName 2>/dev/null || true)
ROLE_PRESENT=`$(echo "`$ROLE_JSON" | jq -e '.data.username' >/dev/null 2>&1 && echo yes || echo no)
ROLE_ROTATED=`$(echo "`$ROLE_JSON" | jq -er '.data.last_vault_rotation' 2>/dev/null | grep -E '^[0-9]{4}-' >/dev/null && echo yes || echo no)

if [ "`$ROLE_PRESENT" = "yes" ] && [ "`$ROLE_ROTATED" = "yes" ]; then
  HAS_PWD=`$(vault read -format=json ldap/static-cred/$accountName 2>/dev/null | jq -er '.data.password | length > 0' 2>/dev/null || echo false)
  if [ "`$HAS_PWD" = "true" ]; then
    LAST=`$(echo "`$ROLE_JSON" | jq -r '.data.last_vault_rotation')
    echo "[ldap-rotate-role] State A: role exists + managed cred present (last_vault_rotation=`$LAST). No-op."
    exit 0
  fi
fi

if [ "`$ROLE_PRESENT" = "no" ]; then
  echo "[ldap-rotate-role] State B: creating ldap/static-role/$accountName with skip_import_rotation=true"
  # skip_import_rotation=true tells Vault NOT to bind AS the target user
  # with an unknown pre-existing password. CREATE-ONLY flag (Vault errors
  # 400 if sent on an UPDATE). Engine-level skip_static_role_import_rotation
  # is the primary default; this role-level flag is explicit + override-safe.
  vault write ldap/static-role/$accountName \
    username='$accountName' \
    dn='$accountDn' \
    rotation_period='$rotationPeriod' \
    skip_import_rotation=true >/dev/null
else
  echo "[ldap-rotate-role] State C: role exists but un-rotated; skipping create -- proceeding to force-rotate"
fi

# Take ownership of the AD password via an explicit rotation. This binds
# as svc-vault-ldap (the engine bindcred) and writes unicodePwd over
# LDAPS. The bind account needs Reset Password extended right on the
# target -- delegated by foundation env's role-overlay-dc-vault-ad-bind-acl.tf.
# Without that ACL, this step fails with LDAP code 50 INSUFF_ACCESS_RIGHTS.
echo "[ldap-rotate-role] forcing managed rotation of $accountName"
vault write -force ldap/rotate-role/$accountName >/dev/null

# Verify static-cred lookup works (reads back the just-rotated cred).
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
