/*
 * role-overlay-vault-pki-platform-tools.tf -- Phase 0.Q.1 setup (ADR-0043)
 *
 * Defines the `platform-tools-server` PKI role at pki_int/. Leaf-cert role for
 * the 3 tier-09-platform nodes (1 Marquez app + 2 Marquez PG). Per-host CN/SAN
 * passed at issue time by nexus-infra-platform-tools' TLS overlay.
 *
 * Certs cover: CN <hostname>.nexus.lab; SANs the hostname bare + .nexus.lab +
 * the app front door marquez.nexus.lab + the datastore VRRP VIP front door
 * marquez-db.nexus.lab + localhost; IPs the service IPs (.127/.134/.135) +
 * backplane IPs (192.168.10.x) + the VIP .136 (both PG nodes) + 127.0.0.1.
 * server+client EKU; 90-day TTL (var.vault_pki_leaf_ttl = 2160h).
 * Used for the Marquez API/web HTTPS front and the PG server TLS.
 *
 * LANDMINES:
 *  - BRAND-NEW role on purpose. `vault write pki_int/roles/<name>` is a FULL
 *    REPLACE: omitted params silently reset to defaults. Never patch a role
 *    shared with another tier (feedback_vault_role_write_is_full_replace).
 *  - keepalived floats marquez-db.nexus.lab -> .136 between BOTH PG nodes, so
 *    BOTH leaves must carry marquez-db.nexus.lab in DNS SANs and 192.168.70.136
 *    in IP SANs -- otherwise a client that reconnects through the VIP after a
 *    failover hits a hostname/IP mismatch. Same posture as registry-db .119 and
 *    grafana-db .185. allow_ip_sans=true + enforce_hostnames=false is what makes
 *    that issue-time SAN set legal here.
 *
 * Selective ops: var.enable_vault_pki AND var.enable_platform_tools_pki.
 */

resource "null_resource" "vault_pki_platform_tools_role" {
  count = var.enable_vault_cluster && var.enable_vault_init && var.enable_vault_pki && var.enable_platform_tools_pki ? 1 : 0

  triggers = {
    int_id                        = length(null_resource.vault_pki_intermediate_ca) > 0 ? null_resource.vault_pki_intermediate_ca[0].id : "disabled"
    role_name                     = var.vault_pki_platform_tools_role_name
    leaf_ttl                      = var.vault_pki_leaf_ttl
    platform_tools_role_overlay_v = "1"
  }

  depends_on = [null_resource.vault_pki_intermediate_ca]

  provisioner "local-exec" {
    when        = create
    interpreter = ["pwsh", "-NoProfile", "-Command"]
    command     = <<-PWSH
      $ip          = '${local.vault_1_ip}'
      $user        = '${local.ssh_user}'
      $roleName    = '${var.vault_pki_platform_tools_role_name}'
      $leafTtl     = '${var.vault_pki_leaf_ttl}'
      $keysFileRaw = '${var.vault_init_keys_file}'
      $keysFile    = $ExecutionContext.InvokeCommand.ExpandString($keysFileRaw.Replace('$HOME', $env:USERPROFILE))

      if (-not (Test-Path $keysFile)) { throw "[pki-platform-tools] keys file $keysFile missing" }
      $rootToken = (Get-Content $keysFile | ConvertFrom-Json).root_token

      $allowed = @(
        'nexus.lab'
        # datastore VRRP VIP front door (floats .136 to the current PG primary).
        # NOTE: the app front door marquez.nexus.lab is NOT listed separately --
        # it is the same name as the marquez host's own FQDN, listed below.
        'marquez-db.nexus.lab'
        # 3 hostnames bare + .nexus.lab
        'marquez'; 'marquez-pg-1'; 'marquez-pg-2'
        'marquez.nexus.lab'; 'marquez-pg-1.nexus.lab'; 'marquez-pg-2.nexus.lab'
        'localhost'
      ) -join ','

      $bash = @"
set -euo pipefail
export VAULT_TOKEN='$rootToken'
export VAULT_SKIP_VERIFY=true
export VAULT_ADDR=https://127.0.0.1:8200

echo "[pki-platform-tools] writing pki_int/roles/$roleName (idempotent overwrite)"
vault write pki_int/roles/$roleName \
  allowed_domains='$allowed' \
  allow_subdomains=false \
  allow_bare_domains=true \
  allow_glob_domains=false \
  allow_ip_sans=true \
  enforce_hostnames=false \
  server_flag=true \
  client_flag=true \
  key_type=rsa \
  key_bits=4096 \
  ttl='$leafTtl' \
  max_ttl='$leafTtl' \
  no_store=false >/dev/null

ALLOWED=`$(vault read -format=json pki_int/roles/$roleName | jq -r '.data.allowed_domains | length')
echo "[pki-platform-tools] role pki_int/roles/$roleName configured (allowed_domains=`$ALLOWED entries, ttl=$leafTtl, server+client EKU)"
"@

      $b64 = [Convert]::ToBase64String([System.Text.UTF8Encoding]::new($false).GetBytes($bash))
      Write-Host "[pki-platform-tools] dispatching to $${ip} via base64"
      $output = ssh -o ConnectTimeout=30 -o BatchMode=yes -o StrictHostKeyChecking=no $user@$ip "echo '$b64' | base64 -d | bash" 2>&1 | Out-String
      $rc = $LASTEXITCODE
      Write-Host $output.Trim()
      if ($rc -ne 0) { throw "[pki-platform-tools] script failed (rc=$rc)" }
    PWSH
  }
}
