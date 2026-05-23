/*
 * role-overlay-vault-pki-iceberg.tf -- Phase 0.L.2 setup (Iceberg catalog mTLS)
 *
 * Defines the `iceberg-server` PKI role at pki_int/. Leaf-cert role for all 4
 * iceberg nodes (2 PG + 2 Nessie REST). Per-host CN/SAN passed at issue time by
 * nexus-infra-lakehouse's role-overlay-iceberg-tls.tf.
 *
 * Certs cover: CN <hostname>.nexus.lab; SANs <hostname>, <hostname>.nexus.lab,
 * the PG front door iceberg-db.nexus.lab + the REST front door iceberg.nexus.lab,
 * localhost; IPs the service IPs + the VRRP VIP (.151) + the backplane IPs +
 * 127.0.0.1. server+client EKU; 90-day TTL.
 *
 * Selective ops: var.enable_vault_pki AND var.enable_iceberg_pki.
 */

resource "null_resource" "vault_pki_iceberg_role" {
  count = var.enable_vault_cluster && var.enable_vault_init && var.enable_vault_pki && var.enable_iceberg_pki ? 1 : 0

  triggers = {
    int_id                 = length(null_resource.vault_pki_intermediate_ca) > 0 ? null_resource.vault_pki_intermediate_ca[0].id : "disabled"
    role_name              = var.vault_pki_iceberg_role_name
    leaf_ttl               = var.vault_pki_leaf_ttl
    iceberg_role_overlay_v = "1"
  }

  depends_on = [null_resource.vault_pki_intermediate_ca]

  provisioner "local-exec" {
    when        = create
    interpreter = ["pwsh", "-NoProfile", "-Command"]
    command     = <<-PWSH
      $ip          = '${local.vault_1_ip}'
      $user        = '${local.ssh_user}'
      $roleName    = '${var.vault_pki_iceberg_role_name}'
      $leafTtl     = '${var.vault_pki_leaf_ttl}'
      $keysFileRaw = '${var.vault_init_keys_file}'
      $keysFile    = $ExecutionContext.InvokeCommand.ExpandString($keysFileRaw.Replace('$HOME', $env:USERPROFILE))

      if (-not (Test-Path $keysFile)) { throw "[pki-iceberg] keys file $keysFile missing" }
      $rootToken = (Get-Content $keysFile | ConvertFrom-Json).root_token

      $bash = @"
set -euo pipefail
export VAULT_TOKEN='$rootToken'
export VAULT_SKIP_VERIFY=true
export VAULT_ADDR=https://127.0.0.1:8200

echo "[pki-iceberg] writing pki_int/roles/$roleName (idempotent overwrite)"
vault write pki_int/roles/$roleName \
  allowed_domains='nexus.lab,iceberg.nexus.lab,iceberg-db.nexus.lab,iceberg-rest-1,iceberg-rest-2,iceberg-pg-1,iceberg-pg-2,iceberg-rest-1.nexus.lab,iceberg-rest-2.nexus.lab,iceberg-pg-1.nexus.lab,iceberg-pg-2.nexus.lab,localhost' \
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
echo "[pki-iceberg] role pki_int/roles/$roleName configured (allowed_domains=`$ALLOWED entries, ttl=$leafTtl, server+client EKU)"
"@

      $b64 = [Convert]::ToBase64String([System.Text.UTF8Encoding]::new($false).GetBytes($bash))
      Write-Host "[pki-iceberg] dispatching to $${ip} via base64"
      $output = ssh -o ConnectTimeout=30 -o BatchMode=yes -o StrictHostKeyChecking=no $user@$ip "echo '$b64' | base64 -d | bash" 2>&1 | Out-String
      $rc = $LASTEXITCODE
      Write-Host $output.Trim()
      if ($rc -ne 0) { throw "[pki-iceberg] script failed (rc=$rc)" }
    PWSH
  }
}
