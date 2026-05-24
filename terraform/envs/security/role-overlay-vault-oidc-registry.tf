/*
 * role-overlay-vault-oidc-registry.tf -- Phase 0.L.4 setup (Harbor SSO)
 *
 * Stands up Vault as an OIDC provider for Harbor (ADR-0036), so Harbor delegates
 * login to Vault, which authenticates users against AD via its existing auth/ldap
 * (ADR-0013). Creates:
 *   1. an OIDC signing key (nexus-registry-key, RS256);
 *   2. OIDC scopes profile/email/groups (templates emitting preferred_username +
 *      groups so Harbor's oidc_user_claim/groups_claim resolve);
 *   3. an identity external group (nexus-registry-oidc) aliased -- via the ldap
 *      mount accessor -- to the AD admin group, so AD admins are authorized;
 *   4. an assignment binding the client to that group;
 *   5. the OIDC client `harbor` (redirect_uri the Harbor callback) -- reads back
 *      the generated client_id + client_secret and writes them to Vault KV
 *      (nexus/registry/oidc-client-{id,secret}); harbor-config reads them;
 *   6. the provider `nexus-registry` (issuer -> vault-1.nexus.lab:8200).
 *
 * The provider discovery URL Harbor uses (oidc_endpoint) is
 *   https://vault-1.nexus.lab:8200/v1/identity/oidc/provider/nexus-registry
 * Interactive login can't be auto-smoked (browser redirect); the smoke verifies
 * Harbor's auth_mode==oidc_auth + the discovery endpoint serves valid metadata.
 *
 * Selective ops: var.enable_registry_oidc.
 */

resource "null_resource" "vault_oidc_registry" {
  count = var.enable_vault_cluster && var.enable_vault_init && var.enable_registry_oidc ? 1 : 0

  triggers = {
    post_init_id    = null_resource.vault_post_init[0].id
    issuer          = var.registry_oidc_issuer_host
    admin_group     = var.vault_ldap_admin_group
    registry_oidc_v = "1"
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
      $issuerHost  = '${var.registry_oidc_issuer_host}'
      $adminGroup  = '${var.vault_ldap_admin_group}'
      $redirectUri = '${var.registry_oidc_redirect_uri}'

      if (-not (Test-Path $keysFile)) { throw "[registry-oidc] keys file $keysFile missing" }
      $rootToken = (Get-Content $keysFile | ConvertFrom-Json).root_token

      $bash = @"
# NOTE: deliberately NOT `set -e`. The very first OIDC bring-up on a fresh Vault
# identity store can transiently return non-zero on an idempotent write (a MemDB
# read-after-write race; chronicled in the registry handbook). Every write below
# is idempotent (overwrite), so we verify the OUTCOME (the discovery endpoint)
# rather than aborting on a benign intermediate non-zero.
set -uo pipefail
export VAULT_TOKEN='$rootToken'
export VAULT_SKIP_VERIFY=true
export VAULT_ADDR=https://127.0.0.1:8200

# 1. OIDC signing key
vault write identity/oidc/key/nexus-registry-key \
  allowed_client_ids='*' rotation_period=24h verification_ttl=24h algorithm=RS256 >/dev/null

# 2. scopes (base64 JSON templates). preferred_username from the ldap alias name;
#    groups from the entity's identity-group names.
LDAP_ACC=`$(vault auth list -format=json | jq -r '."ldap/".accessor // empty')
if [ -n "`$LDAP_ACC" ]; then
  PROFILE_TPL=`$(printf '{"preferred_username":{{identity.entity.aliases.%s.name}},"name":{{identity.entity.name}}}' "`$LDAP_ACC" | base64 -w0)
else
  PROFILE_TPL=`$(printf '{"preferred_username":{{identity.entity.name}},"name":{{identity.entity.name}}}' | base64 -w0)
fi
GROUPS_TPL=`$(printf '{"groups":{{identity.entity.groups.names}}}' | base64 -w0)
EMAIL_TPL=`$(printf '{"email":{{identity.entity.metadata.email}}}' | base64 -w0)
vault write identity/oidc/scope/profile template="`$PROFILE_TPL" description="username + name" >/dev/null
vault write identity/oidc/scope/groups  template="`$GROUPS_TPL"  description="identity groups" >/dev/null
vault write identity/oidc/scope/email   template="`$EMAIL_TPL"   description="email" >/dev/null

# 3. external identity group aliased to the AD admin group (via the ldap mount)
GID=`$(vault read -field=id identity/group/name/nexus-registry-oidc 2>/dev/null || true)
if [ -z "`$GID" ]; then
  GID=`$(vault write -field=id identity/group name=nexus-registry-oidc type=external policies=nexus-reader)
fi
if [ -n "`$LDAP_ACC" ]; then
  # idempotent: an external identity group has at most one alias -- create it only
  # if the group does not already have one.
  EXISTING_ALIAS=`$(vault read -format=json identity/group/name/nexus-registry-oidc 2>/dev/null | jq -r '.data.alias.id // empty')
  if [ -z "`$EXISTING_ALIAS" ]; then
    vault write identity/group-alias name="`$adminGroup" mount_accessor="`$LDAP_ACC" canonical_id="`$GID" >/dev/null
  fi
fi

# 4. assignment binding the client to that group
vault write identity/oidc/assignment/nexus-registry-assignment group_ids="`$GID" >/dev/null

# 5. client `harbor` + read back client_id/secret -> Vault KV
vault write identity/oidc/client/harbor \
  redirect_uris="$redirectUri" \
  assignments=nexus-registry-assignment \
  key=nexus-registry-key \
  id_token_ttl=30m access_token_ttl=1h >/dev/null
CID=`$(vault read -field=client_id identity/oidc/client/harbor)
CSEC=`$(vault read -field=client_secret identity/oidc/client/harbor)
[ -n "`$CID" ] && [ -n "`$CSEC" ] || { echo "ERROR: failed to read OIDC client_id/secret" >&2; exit 1; }
vault kv put nexus/registry/oidc-client-id     value="`$CID"  >/dev/null
vault kv put nexus/registry/oidc-client-secret value="`$CSEC" >/dev/null

# 6. provider (issuer points at the externally reachable vault-1 DNS)
vault write identity/oidc/provider/nexus-registry \
  issuer="https://$issuerHost" \
  allowed_client_ids="`$CID" \
  scopes_supported="profile,groups,email" >/dev/null

# Outcome gate: the discovery endpoint must serve the expected issuer (retry a few
# times in case the identity store is still settling on a fresh bring-up).
DISCO=""
for i in 1 2 3 4 5; do
  DISCO=`$(curl -sk https://127.0.0.1:8200/v1/identity/oidc/provider/nexus-registry/.well-known/openid-configuration 2>/dev/null)
  echo "`$DISCO" | grep -q '"issuer"' && break
  sleep 3
done
echo "`$DISCO" | grep -q 'identity/oidc/provider/nexus-registry' || { echo "ERROR: OIDC discovery endpoint did not serve the nexus-registry issuer" >&2; echo "`$DISCO" >&2; exit 1; }
echo "[registry-oidc] provider nexus-registry live; client_id=`$(echo "`$CID" | cut -c1-8)...; KV nexus/registry/oidc-client-{id,secret} written"
echo "[registry-oidc] discovery OK: https://$issuerHost/v1/identity/oidc/provider/nexus-registry/.well-known/openid-configuration"
"@

      $b64 = [Convert]::ToBase64String([System.Text.UTF8Encoding]::new($false).GetBytes($bash))
      Write-Host "[registry-oidc] dispatching to $${ip} via base64"
      $output = ssh -o ConnectTimeout=30 -o BatchMode=yes -o StrictHostKeyChecking=no $user@$ip "echo '$b64' | base64 -d | bash" 2>&1 | Out-String
      $rc = $LASTEXITCODE
      Write-Host $output.Trim()
      if ($rc -ne 0) { throw "[registry-oidc] script failed (rc=$rc)" }
    PWSH
  }
}
