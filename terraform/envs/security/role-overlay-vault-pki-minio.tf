/*
 * role-overlay-vault-pki-minio.tf -- Phase 0.L.1 setup (MinIO mTLS)
 *
 * Defines the `minio-server` PKI role at pki_int/. Leaf-cert role for all 4
 * MinIO nodes. Per-host CN/SAN passed at issue time by nexus-infra-lakehouse's
 * role-overlay-minio-tls.tf.
 *
 * Certs cover: CN <hostname>.nexus.lab; SANs <hostname>, <hostname>.nexus.lab,
 * minio.nexus.lab (the round-robin endpoint -- ADR-0033), localhost; IPs the
 * VMnet11 service IP + the VMnet10 backplane IP (distributed peers connect over
 * https://192.168.10.{141..144}) + 127.0.0.1. server+client EKU; 90-day TTL.
 *
 * Selective ops: var.enable_vault_pki AND var.enable_minio_pki.
 */

resource "null_resource" "vault_pki_minio_role" {
  count = var.enable_vault_cluster && var.enable_vault_init && var.enable_vault_pki && var.enable_minio_pki ? 1 : 0

  triggers = {
    int_id               = length(null_resource.vault_pki_intermediate_ca) > 0 ? null_resource.vault_pki_intermediate_ca[0].id : "disabled"
    role_name            = var.vault_pki_minio_role_name
    leaf_ttl             = var.vault_pki_leaf_ttl
    minio_role_overlay_v = "1" # v1 (0.L.1) = initial 4-node MinIO cluster.
  }

  depends_on = [null_resource.vault_pki_intermediate_ca]

  provisioner "local-exec" {
    when        = create
    interpreter = ["pwsh", "-NoProfile", "-Command"]
    command     = <<-PWSH
      $ip          = '${local.vault_1_ip}'
      $user        = '${local.ssh_user}'
      $roleName    = '${var.vault_pki_minio_role_name}'
      $leafTtl     = '${var.vault_pki_leaf_ttl}'
      $keysFileRaw = '${var.vault_init_keys_file}'
      $keysFile    = $ExecutionContext.InvokeCommand.ExpandString($keysFileRaw.Replace('$HOME', $env:USERPROFILE))

      if (-not (Test-Path $keysFile)) { throw "[pki-minio] keys file $keysFile missing" }
      $rootToken = (Get-Content $keysFile | ConvertFrom-Json).root_token

      $bash = @"
set -euo pipefail
export VAULT_TOKEN='$rootToken'
export VAULT_SKIP_VERIFY=true
export VAULT_ADDR=https://127.0.0.1:8200

echo "[pki-minio] writing pki_int/roles/$roleName (idempotent overwrite)"
vault write pki_int/roles/$roleName \
  allowed_domains='nexus.lab,minio.nexus.lab,minio-1,minio-2,minio-3,minio-4,minio-1.nexus.lab,minio-2.nexus.lab,minio-3.nexus.lab,minio-4.nexus.lab,localhost' \
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
echo "[pki-minio] role pki_int/roles/$roleName configured (allowed_domains=`$ALLOWED entries, ttl=$leafTtl, server+client EKU)"
"@

      $b64 = [Convert]::ToBase64String([System.Text.UTF8Encoding]::new($false).GetBytes($bash))
      Write-Host "[pki-minio] dispatching to $${ip} via base64"
      $output = ssh -o ConnectTimeout=30 -o BatchMode=yes -o StrictHostKeyChecking=no $user@$ip "echo '$b64' | base64 -d | bash" 2>&1 | Out-String
      $rc = $LASTEXITCODE
      Write-Host $output.Trim()
      if ($rc -ne 0) { throw "[pki-minio] script failed (rc=$rc)" }
    PWSH
  }
}
