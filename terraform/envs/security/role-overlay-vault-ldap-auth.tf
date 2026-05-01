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
    seed_id        = length(null_resource.vault_foundation_seed) > 0 ? null_resource.vault_foundation_seed[0].id : "disabled"
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
    auth_overlay_v = "5" # v5 = bindpass sourced from Vault KV (nexus/foundation/ad/svc-vault-ldap) with JSON-file fallback (0.D.4 -- KV becomes canonical, JSON vestigial). v4 = upndomain="" (search-then-bind via userfilter). Per Vault sdk/helper/ldaputil/client.go RenderUserSearchFilter, setting upndomain rewrites the {{.Username}} value to <user>@<upndomain> before executing the userfilter -- so our (sAMAccountName={{.Username}}) becomes (sAMAccountName=svc-...@nexus.lab) which AD never matches (sAMAccountName has no @-suffix). LDAPS doesn't need the UPN-bind workaround that motivated upndomain under plain-LDAP/389. Vault issue #27276; 1.19+ has enable_samaccountname_login. v3 = LDAPS + upndomain (broke smoke login, search returned 0). v2 = upndomain + plain-LDAP. v1 = plain-LDAP search-then-rebind.
  }

  depends_on = [null_resource.vault_ldap_policies, null_resource.vault_ldaps_cert, null_resource.vault_foundation_seed]

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
      if (-not (Test-Path $caBundlePath)) {
        throw "[ldap-auth] CA bundle missing at $caBundlePath -- run vault_pki_distribute_root first"
      }
      $rootToken  = (Get-Content $keysFile      | ConvertFrom-Json).root_token

      # ─── Resolve bindpass: prefer Vault KV (0.D.4), fall back to JSON ──
      # 0.D.4 makes nexus/foundation/ad/svc-vault-ldap the canonical store
      # for the bind cred. The seed overlay (foundation_seed_values) writes
      # this path on every fresh apply, sourced either from the legacy JSON
      # file or from the foundation env's bind overlay's direct-to-KV path
      # (Stage C). Either way, by the time ldap_auth runs, KV should have
      # the value -- depends_on enforces ordering.
      #
      # Fallback to JSON keeps the overlay resilient against operator
      # disabling enable_vault_kv_foundation_seed_values (e.g. iterating
      # on LDAP-auth alone with KV already in the desired state).
      Write-Host "[ldap-auth] resolving bind cred (preferring Vault KV nexus/foundation/ad/svc-vault-ldap)..."
      $kvProbeBash = @"
set -euo pipefail
export VAULT_TOKEN='$rootToken'
export VAULT_SKIP_VERIFY=true
export VAULT_ADDR=https://127.0.0.1:8200
vault kv get -format=json nexus/foundation/ad/svc-vault-ldap 2>/dev/null || echo '{}'
"@
      $kvProbeB64 = [Convert]::ToBase64String([System.Text.UTF8Encoding]::new($false).GetBytes($kvProbeBash))
      $kvProbeOut = ssh -o ConnectTimeout=15 -o BatchMode=yes -o StrictHostKeyChecking=no $user@$ip "echo '$kvProbeB64' | base64 -d | bash" 2>&1 | Out-String

      $bindDn   = $null
      $bindPass = $null
      try {
        $kvJson = $kvProbeOut | ConvertFrom-Json
        if ($kvJson.data.data.binddn -and $kvJson.data.data.password) {
          $bindDn   = $kvJson.data.data.binddn
          $bindPass = $kvJson.data.data.password
          Write-Host "[ldap-auth] bind cred resolved from Vault KV (canonical)"
        }
      } catch { }

      if (-not $bindDn -or -not $bindPass) {
        Write-Host "[ldap-auth] Vault KV path empty/unparseable; falling back to JSON file $bindCredsFile"
        if (-not (Test-Path $bindCredsFile)) {
          throw "[ldap-auth] neither Vault KV nor $bindCredsFile yields a bind cred -- run foundation env with -Vars enable_vault_ad_integration=true first, then security apply (which seeds KV)"
        }
        $bindCreds = (Get-Content $bindCredsFile | ConvertFrom-Json)
        $bindDn    = $bindCreds.binddn
        $bindPass  = $bindCreds.bindpass
        if (-not $bindDn -or -not $bindPass) {
          throw "[ldap-auth] $bindCredsFile missing binddn or bindpass"
        }
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
# trusts the LDAPS cert chain. NOTE: upndomain is intentionally NOT set,
# despite our earlier diagnosis on plain-LDAP/389 saying we needed it.
# Reason: per Vault's sdk/helper/ldaputil/client.go RenderUserSearchFilter
# (Vault issue #27276), when upndomain is set the {{.Username}} template
# value in userfilter gets silently rewritten to "<username>@<upndomain>"
# before the search executes -- so our literal filter
# (&(objectClass=user)(sAMAccountName={{.Username}})) becomes
# (&(objectClass=user)(sAMAccountName=svc-vault-smoke@nexus.lab)) which
# AD never matches (sAMAccountName is the bare login). Pre-1.19 there
# is no opt-out flag (1.19 adds enable_samaccountname_login=true). On
# LDAPS we don't need the UPN bind workaround that motivated upndomain
# under plain-LDAP/389 (the LDAPServerIntegrity story); the search-then-
# bind path works correctly when upndomain is empty + we have binddn +
# bindpass. Vault binds as svc-vault-ldap, searches with our literal
# userfilter, finds the user's DN, then rebinds as that DN with the
# user-supplied password.
TMPCA=`$(mktemp)
trap 'rm -f "`$TMPCA"' EXIT
echo '$caBundleB64' | base64 -d > "`$TMPCA"

echo '[ldap-auth] writing auth/ldap/config (LDAPS, search-then-bind, no upndomain)'
vault write auth/ldap/config \
  url='$ldapUrl' \
  binddn='$bindDn' \
  bindpass='$bindPass' \
  userdn='$userDn' \
  userattr='$userattr' \
  upndomain='' \
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
