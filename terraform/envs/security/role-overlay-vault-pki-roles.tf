/*
 * role-overlay-vault-pki-roles.tf -- Phase 0.D.2 step 4/7
 *
 * Define the `vault-server` PKI role at pki_int/. This is the role used
 * by the rotate overlay to issue listener certs for vault-1/2/3, and is
 * available for future templates to issue server certs (until 0.D.3+
 * adds dedicated roles for AD/LDAP, app servers, etc.).
 *
 * Allowed identities baked into the role:
 *   - DNS: nexus.lab (parent domain), vault-1/2/3 (short names),
 *          vault-1/2/3.nexus.lab (FQDNs)
 *   - IP : any (allow_ip_sans=true) -- the rotate overlay supplies the
 *          canonical .121/.122/.123 + .10.121/.122/.123 + 127.0.0.1
 *
 * `vault write` semantics on roles is upsert -- always-overwrite is
 * naturally idempotent. Triggers track config so a knob change re-applies.
 *
 * Selective ops: var.enable_vault_pki AND var.enable_vault_pki_roles.
 */

resource "null_resource" "vault_pki_roles" {
  count = var.enable_vault_cluster && var.enable_vault_init && var.enable_vault_pki && var.enable_vault_pki_roles ? 1 : 0

  triggers = {
    int_id          = length(null_resource.vault_pki_intermediate_ca) > 0 ? null_resource.vault_pki_intermediate_ca[0].id : "disabled"
    role_name       = var.vault_pki_role_name
    leaf_ttl        = var.vault_pki_leaf_ttl
    roles_overlay_v = "2" # v2 = added dc-nexus + dc-nexus.nexus.lab to allowed_domains for LDAPS cert issuance (0.D.3 scope expansion). v1 = vault-N hostnames only.
  }

  depends_on = [null_resource.vault_pki_intermediate_ca]

  provisioner "local-exec" {
    when        = create
    interpreter = ["pwsh", "-NoProfile", "-Command"]
    command     = <<-PWSH
      $ip          = '${local.vault_1_ip}'
      $user        = '${local.ssh_user}'
      $roleName    = '${var.vault_pki_role_name}'
      $leafTtl     = '${var.vault_pki_leaf_ttl}'
      $keysFileRaw = '${var.vault_init_keys_file}'
      $keysFile    = $ExecutionContext.InvokeCommand.ExpandString($keysFileRaw.Replace('$HOME', $env:USERPROFILE))

      if (-not (Test-Path $keysFile)) {
        throw "[pki-roles] keys file $keysFile missing"
      }
      $rootToken = (Get-Content $keysFile | ConvertFrom-Json).root_token

      $bash = @"
set -euo pipefail
export VAULT_TOKEN='$rootToken'
export VAULT_SKIP_VERIFY=true
export VAULT_ADDR=https://127.0.0.1:8200

echo "[pki-roles] writing pki_int/roles/$roleName (idempotent overwrite)"
vault write pki_int/roles/$roleName \
  allowed_domains='nexus.lab,vault-1,vault-2,vault-3,vault-1.nexus.lab,vault-2.nexus.lab,vault-3.nexus.lab,dc-nexus,dc-nexus.nexus.lab,DC-NEXUS,DC-NEXUS.nexus.lab,localhost' \
  allow_subdomains=false \
  allow_bare_domains=true \
  allow_glob_domains=false \
  allow_ip_sans=true \
  enforce_hostnames=false \
  server_flag=true \
  client_flag=false \
  key_type=rsa \
  key_bits=4096 \
  ttl='$leafTtl' \
  max_ttl='$leafTtl' \
  no_store=false >/dev/null

# Verify by reading back
ALLOWED=`$(vault read -format=json pki_int/roles/$roleName | jq -r '.data.allowed_domains | join(",")')
echo "[pki-roles] role pki_int/roles/$roleName configured (allowed_domains=`$ALLOWED, ttl=$leafTtl)"
"@

      $bytes = [System.Text.UTF8Encoding]::new($false).GetBytes($bash)
      $b64   = [Convert]::ToBase64String($bytes)

      Write-Host "[pki-roles] dispatching to $${ip} via base64"
      $output = ssh -o ConnectTimeout=30 -o BatchMode=yes -o StrictHostKeyChecking=no $user@$ip "echo '$b64' | base64 -d | bash" 2>&1 | Out-String
      $rc = $LASTEXITCODE
      Write-Host $output.Trim()
      if ($rc -ne 0) {
        throw "[pki-roles] script failed (rc=$rc)"
      }
    PWSH
  }
}
