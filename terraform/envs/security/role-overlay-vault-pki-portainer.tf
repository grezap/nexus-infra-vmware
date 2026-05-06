/*
 * role-overlay-vault-pki-portainer.tf -- Phase 0.E.4b setup
 *
 * Defines the `portainer-server` PKI role at pki_int/. Used by the 3
 * swarm-MANAGER Vault Agents to issue Portainer CE TLS leaf certs that
 * cover:
 *
 *   - Subject CN: portainer.nexus.lab (the round-robin DNS name)
 *   - SANs: portainer.nexus.lab + per-host VMnet11 manager IPs (.111-.113)
 *           + 127.0.0.1 + localhost
 *
 * Why a single shared CN (`portainer.nexus.lab`) instead of per-host CNs:
 *   - Portainer CE has only ONE Server replica running at a time (Swarm
 *     reschedules across managers on failure). The cert needs to be valid
 *     for whichever manager is currently active. The cleanest way is a
 *     single shared cert with `portainer.nexus.lab` as CN + all 3 manager
 *     IPs in `ip_sans`. dnsmasq round-robins the A-record across managers,
 *     so any of `https://portainer.nexus.lab:9443` or `https://192.168.70
 *     .111:9443` etc. validates.
 *   - Same cert deployed on all 3 managers (simpler than 3 per-host certs;
 *     no "wrong cert during reschedule" race).
 *
 * Mirrors role-overlay-vault-pki-consul.tf shape.
 *
 * Selective ops: var.enable_vault_pki AND var.enable_vault_pki_portainer.
 */

resource "null_resource" "vault_pki_portainer_role" {
  count = var.enable_vault_cluster && var.enable_vault_init && var.enable_vault_pki && var.enable_vault_pki_portainer ? 1 : 0

  triggers = {
    int_id                   = length(null_resource.vault_pki_intermediate_ca) > 0 ? null_resource.vault_pki_intermediate_ca[0].id : "disabled"
    role_name                = var.vault_pki_portainer_role_name
    leaf_ttl                 = var.vault_pki_leaf_ttl
    portainer_role_overlay_v = "1"
  }

  depends_on = [null_resource.vault_pki_intermediate_ca]

  provisioner "local-exec" {
    when        = create
    interpreter = ["pwsh", "-NoProfile", "-Command"]
    command     = <<-PWSH
      $ip          = '${local.vault_1_ip}'
      $user        = '${local.ssh_user}'
      $roleName    = '${var.vault_pki_portainer_role_name}'
      $leafTtl     = '${var.vault_pki_leaf_ttl}'
      $keysFileRaw = '${var.vault_init_keys_file}'
      $keysFile    = $ExecutionContext.InvokeCommand.ExpandString($keysFileRaw.Replace('$HOME', $env:USERPROFILE))

      if (-not (Test-Path $keysFile)) { throw "[pki-portainer] keys file $keysFile missing" }
      $rootToken = (Get-Content $keysFile | ConvertFrom-Json).root_token

      $bash = @"
set -euo pipefail
export VAULT_TOKEN='$rootToken'
export VAULT_SKIP_VERIFY=true
export VAULT_ADDR=https://127.0.0.1:8200

echo "[pki-portainer] writing pki_int/roles/$roleName (idempotent overwrite)"
vault write pki_int/roles/$roleName \
  allowed_domains='portainer.nexus.lab,nexus.lab,localhost' \
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

ALLOWED=`$(vault read -format=json pki_int/roles/$roleName | jq -r '.data.allowed_domains | length')
echo "[pki-portainer] role pki_int/roles/$roleName configured (allowed_domains=`$ALLOWED entries, ttl=$leafTtl, server-only EKU)"
"@

      $bytes = [System.Text.UTF8Encoding]::new($false).GetBytes($bash)
      $b64   = [Convert]::ToBase64String($bytes)

      Write-Host "[pki-portainer] dispatching to $${ip} via base64"
      $output = ssh -o ConnectTimeout=30 -o BatchMode=yes -o StrictHostKeyChecking=no $user@$ip "echo '$b64' | base64 -d | bash" 2>&1 | Out-String
      $rc = $LASTEXITCODE
      Write-Host $output.Trim()
      if ($rc -ne 0) {
        throw "[pki-portainer] script failed (rc=$rc)"
      }
    PWSH
  }
}
