/*
 * role-overlay-vault-ldap-secret-engine.tf -- Phase 0.D.3 step 3/4 (security)
 *
 * Enable + configure Vault's `secrets/ldap` engine. This is the unified
 * AD/OpenLDAP engine introduced in Vault 1.12; it replaces the deprecated
 * `ad` secret engine. Same binddn/bindpass as auth/ldap (we share the bind
 * account so AD permissions are managed in one place).
 *
 * After this overlay, the rotate-role overlay (step 4/4) defines static
 * roles whose passwords Vault rotates. Consumers read current passwords
 * via `vault read ldap/static-cred/<role>`.
 *
 * Password policy:
 *   We define a Vault password-policy named `nexus-ad-rotated` that
 *   generates 24-char strings with mixed case + digits + symbols. The
 *   ldap engine references this policy via the `password_policy` config
 *   key. AD's complexity rules require at least 3 of 4 char categories;
 *   our policy uses all 4, so generated passwords always satisfy AD.
 *
 * Selective ops: enable_vault_ldap (master) AND enable_vault_ldap_secret_engine.
 */

resource "null_resource" "vault_ldap_secret_engine" {
  count = var.enable_vault_cluster && var.enable_vault_init && var.enable_vault_ldap && var.enable_vault_ldap_secret_engine ? 1 : 0

  triggers = {
    auth_id          = length(null_resource.vault_ldap_auth) > 0 ? null_resource.vault_ldap_auth[0].id : "disabled"
    ldap_url         = var.vault_ldap_url
    secret_overlay_v = "1"
  }

  depends_on = [null_resource.vault_ldap_auth]

  provisioner "local-exec" {
    when        = create
    interpreter = ["pwsh", "-NoProfile", "-Command"]
    command     = <<-PWSH
      $ip                = '${local.vault_1_ip}'
      $user              = '${local.ssh_user}'
      $ldapUrl           = '${var.vault_ldap_url}'
      $keysFileRaw       = '${var.vault_init_keys_file}'
      $keysFile          = $ExecutionContext.InvokeCommand.ExpandString($keysFileRaw.Replace('$HOME', $env:USERPROFILE))
      $bindCredsFileRaw  = '${var.vault_ad_bind_creds_file}'
      $bindCredsFile     = $ExecutionContext.InvokeCommand.ExpandString($bindCredsFileRaw.Replace('$HOME', $env:USERPROFILE))

      if (-not (Test-Path $keysFile))      { throw "[ldap-secret-engine] vault-init.json missing"     }
      if (-not (Test-Path $bindCredsFile)) { throw "[ldap-secret-engine] vault-ad-bind.json missing"  }
      $rootToken  = (Get-Content $keysFile      | ConvertFrom-Json).root_token
      $bindCreds  = (Get-Content $bindCredsFile | ConvertFrom-Json)
      $bindDn     = $bindCreds.binddn
      $bindPass   = $bindCreds.bindpass

      $bash = @"
set -euo pipefail
export VAULT_TOKEN='$rootToken'
export VAULT_SKIP_VERIFY=true
export VAULT_ADDR=https://127.0.0.1:8200

# 1. Define the password policy `nexus-ad-rotated` (idempotent overwrite)
echo '[ldap-secret-engine] writing password policy nexus-ad-rotated'
TMPPOL=`$(mktemp)
trap 'rm -f "`$TMPPOL"' EXIT
cat > "`$TMPPOL" <<'POLICY'
length = 24
rule "charset" {
  charset = "abcdefghijklmnopqrstuvwxyz"
  min-chars = 2
}
rule "charset" {
  charset = "ABCDEFGHIJKLMNOPQRSTUVWXYZ"
  min-chars = 2
}
rule "charset" {
  charset = "0123456789"
  min-chars = 2
}
rule "charset" {
  charset = "!#$%&*+-.=?@_"
  min-chars = 2
}
POLICY
vault write sys/policies/password/nexus-ad-rotated policy=@"`$TMPPOL" >/dev/null

# 2. Enable secrets/ldap (idempotent)
if vault secrets list -format=json | jq -e '."ldap/"' >/dev/null 2>&1; then
  echo '[ldap-secret-engine] secrets/ldap already mounted, skipping enable'
else
  echo '[ldap-secret-engine] mounting secrets/ldap'
  vault secrets enable ldap
fi

# 3. Configure secrets/ldap (upsert; AD schema)
echo '[ldap-secret-engine] writing ldap/config (schema=ad, password_policy=nexus-ad-rotated)'
vault write ldap/config \
  binddn='$bindDn' \
  bindpass='$bindPass' \
  url='$ldapUrl' \
  schema=ad \
  password_policy=nexus-ad-rotated \
  request_timeout=30 \
  insecure_tls=false \
  starttls=false >/dev/null

echo '[ldap-secret-engine] complete'
"@

      $bytes = [System.Text.UTF8Encoding]::new($false).GetBytes($bash)
      $b64   = [Convert]::ToBase64String($bytes)
      $output = ssh -o ConnectTimeout=30 -o BatchMode=yes -o StrictHostKeyChecking=no $user@$ip "echo '$b64' | base64 -d | bash" 2>&1 | Out-String
      if ($LASTEXITCODE -ne 0) {
        throw "[ldap-secret-engine] script failed (rc=$LASTEXITCODE). Output:`n$output"
      }
      Write-Host $output.Trim()
    PWSH
  }
}
