/*
 * role-overlay-vault-ldap-auth.tf -- Phase 0.D.3 step 2/4 (security side)
 *
 * Enable + configure Vault's auth/ldap method, point it at dc-nexus, and
 * wire AD group -> Vault policy mappings:
 *
 *   nexus-vault-admins    -> nexus-admin
 *   nexus-vault-operators -> nexus-operator
 *   nexus-vault-readers   -> nexus-reader
 *
 * Auth flow after this overlay:
 *   1. Operator: `vault login -method=ldap -username=nexusadmin`
 *   2. Vault binds to ldap://192.168.70.240:389 as svc-vault-ldap
 *   3. Vault searches userdn (DC=nexus,DC=lab) for samAccountName=nexusadmin
 *   4. Vault enumerates the user's group memberships
 *   5. Each AD group present in Vault's auth/ldap/groups/ contributes its
 *      policies to the issued token
 *   6. nexusadmin (member of nexus-vault-admins) gets nexus-admin policy
 *      = full sudo
 *
 * Idempotency:
 *   - `vault auth enable ldap` short-circuits if already enabled
 *   - `vault write auth/ldap/config ...` is upsert
 *   - `vault write auth/ldap/groups/<name> policies=...` is upsert
 *
 * Cross-env coupling: bindpass read from var.vault_ad_bind_creds_file at
 * apply time. Foundation env must have written that file by now.
 *
 * Selective ops: enable_vault_ldap (master) AND enable_vault_ldap_auth.
 */

resource "null_resource" "vault_ldap_auth" {
  count = var.enable_vault_cluster && var.enable_vault_init && var.enable_vault_ldap && var.enable_vault_ldap_auth ? 1 : 0

  triggers = {
    policies_id    = length(null_resource.vault_ldap_policies) > 0 ? null_resource.vault_ldap_policies[0].id : "disabled"
    ldaps_cert_id  = length(null_resource.vault_ldaps_cert) > 0 ? null_resource.vault_ldaps_cert[0].id : "disabled"
    ldap_url       = var.vault_ldap_url
    user_dn        = var.vault_ldap_user_dn
    group_dn       = var.vault_ldap_group_dn
    userattr       = var.vault_ldap_userattr
    groupattr      = var.vault_ldap_groupattr
    upn_domain     = var.vault_ldap_upn_domain
    userfilter     = var.vault_ldap_userfilter
    admin_group    = var.vault_ldap_admin_group
    operator_group = var.vault_ldap_operator_group
    reader_group   = var.vault_ldap_reader_group
    auth_overlay_v = "3" # v3 = LDAPS via certificate=@ca-bundle field; depends on vault_ldaps_cert so the DC is serving LDAPS before this writes the config. v2 = upndomain + AD-canonical userfilter (plain LDAP). v1 = initial implementation (plain LDAP, search-then-rebind, broken).
  }

  depends_on = [null_resource.vault_ldap_policies, null_resource.vault_ldaps_cert]

  provisioner "local-exec" {
    when        = create
    interpreter = ["pwsh", "-NoProfile", "-Command"]
    command     = <<-PWSH
      $ip                = '${local.vault_1_ip}'
      $user              = '${local.ssh_user}'
      $ldapUrl           = '${var.vault_ldap_url}'
      $userDn            = '${var.vault_ldap_user_dn}'
      $groupDn           = '${var.vault_ldap_group_dn}'
      $userattr          = '${var.vault_ldap_userattr}'
      $groupattr         = '${var.vault_ldap_groupattr}'
      $upnDomain         = '${var.vault_ldap_upn_domain}'
      $userFilter        = '${var.vault_ldap_userfilter}'
      $adminGroup        = '${var.vault_ldap_admin_group}'
      $operatorGroup     = '${var.vault_ldap_operator_group}'
      $readerGroup       = '${var.vault_ldap_reader_group}'
      $keysFileRaw       = '${var.vault_init_keys_file}'
      $keysFile          = $ExecutionContext.InvokeCommand.ExpandString($keysFileRaw.Replace('$HOME', $env:USERPROFILE))
      $bindCredsFileRaw  = '${var.vault_ad_bind_creds_file}'
      $bindCredsFile     = $ExecutionContext.InvokeCommand.ExpandString($bindCredsFileRaw.Replace('$HOME', $env:USERPROFILE))
      $caBundlePathRaw   = '${var.vault_pki_ca_bundle_path}'
      $caBundlePath      = $ExecutionContext.InvokeCommand.ExpandString($caBundlePathRaw.Replace('$HOME', $env:USERPROFILE))

      if (-not (Test-Path $keysFile)) {
        throw "[ldap-auth] vault-init.json missing at $keysFile"
      }
      if (-not (Test-Path $bindCredsFile)) {
        throw "[ldap-auth] vault-ad-bind.json missing at $bindCredsFile -- run foundation env with -Vars enable_vault_ad_integration=true first"
      }
      if (-not (Test-Path $caBundlePath)) {
        throw "[ldap-auth] CA bundle missing at $caBundlePath -- run vault_pki_distribute_root first"
      }
      $rootToken  = (Get-Content $keysFile      | ConvertFrom-Json).root_token
      $bindCreds  = (Get-Content $bindCredsFile | ConvertFrom-Json)
      $bindDn     = $bindCreds.binddn
      $bindPass   = $bindCreds.bindpass
      if (-not $bindDn -or -not $bindPass) {
        throw "[ldap-auth] vault-ad-bind.json missing binddn or bindpass"
      }

      # Read CA bundle as base64 so we can ship it cleanly via SSH heredoc
      $caBundleBytes = [System.IO.File]::ReadAllBytes($caBundlePath)
      $caBundleB64   = [Convert]::ToBase64String($caBundleBytes)

      Write-Host "[ldap-auth] dispatching to $${ip} -- ldap_url=$ldapUrl, binddn=$bindDn, certificate from $caBundlePath"

      $bash = @"
set -euo pipefail
export VAULT_TOKEN='$rootToken'
export VAULT_SKIP_VERIFY=true
export VAULT_ADDR=https://127.0.0.1:8200

# 1. Enable auth/ldap (idempotent)
if vault auth list -format=json | jq -e '."ldap/"' >/dev/null 2>&1; then
  echo '[ldap-auth] auth/ldap already enabled, skipping enable'
else
  echo '[ldap-auth] enabling auth/ldap'
  vault auth enable ldap
fi

# 2. Configure auth/ldap (upsert)
# Stage the CA bundle to a tmpfile + reference via @file syntax so Vault
# trusts the LDAPS cert chain. upndomain stays for AD-canonical UPN bind
# semantics. userfilter narrows to objectClass=user for the group
# enumeration searches Vault still does after the user bind succeeds.
TMPCA=`$(mktemp)
trap 'rm -f "`$TMPCA"' EXIT
echo '$caBundleB64' | base64 -d > "`$TMPCA"

echo '[ldap-auth] writing auth/ldap/config (LDAPS + upn_domain + AD-canonical userfilter)'
vault write auth/ldap/config \
  url='$ldapUrl' \
  binddn='$bindDn' \
  bindpass='$bindPass' \
  userdn='$userDn' \
  userattr='$userattr' \
  upndomain='$upnDomain' \
  userfilter='$userFilter' \
  groupdn='$groupDn' \
  groupattr='$groupattr' \
  groupfilter='(&(objectClass=group)(member:1.2.840.113556.1.4.1941:={{.UserDN}}))' \
  certificate=@"`$TMPCA" \
  insecure_tls=false \
  starttls=false \
  request_timeout=30 \
  username_as_alias=true >/dev/null

# 3. Group -> policy mappings (upsert each)
echo '[ldap-auth] mapping AD groups to Vault policies'
vault write auth/ldap/groups/$adminGroup     policies=nexus-admin    >/dev/null
vault write auth/ldap/groups/$operatorGroup  policies=nexus-operator >/dev/null
vault write auth/ldap/groups/$readerGroup    policies=nexus-reader   >/dev/null

echo "[ldap-auth] complete -- groups configured: $adminGroup -> nexus-admin, $operatorGroup -> nexus-operator, $readerGroup -> nexus-reader"
"@

      $bytes = [System.Text.UTF8Encoding]::new($false).GetBytes($bash)
      $b64   = [Convert]::ToBase64String($bytes)
      $output = ssh -o ConnectTimeout=30 -o BatchMode=yes -o StrictHostKeyChecking=no $user@$ip "echo '$b64' | base64 -d | bash" 2>&1 | Out-String
      if ($LASTEXITCODE -ne 0) {
        throw "[ldap-auth] script failed (rc=$LASTEXITCODE). Output:`n$output"
      }
      Write-Host $output.Trim()
    PWSH
  }
}
