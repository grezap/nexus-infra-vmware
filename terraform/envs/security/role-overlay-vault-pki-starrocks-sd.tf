/*
 * role-overlay-vault-pki-starrocks-sd.tf -- Phase 0.L.5 setup (StarRocks shared-data mTLS)
 *
 * Defines the `starrocks-sd-server` PKI role at pki_int/. Leaf-cert role for the
 * 5 SR-shared-data nodes (3 FE + 2 CN). One role covers FE + CN; per-host CN/SAN
 * passed at issue time by nexus-infra-analytics's role-overlay-starrocks-sd-tls.tf.
 *
 * Certs cover: CN <hostname>.starrocks-sd.nexus.lab; SANs <hostname>,
 * <hostname>.nexus.lab, <hostname>.starrocks-sd.nexus.lab, starrocks-sd-fe.nexus.lab
 * (the round-robin endpoint -- ADR-0031/ADR-0037), localhost; IPs backplane +
 * service + 127.0.0.1. server+client EKU; 90-day TTL.
 *
 * SEPARATE PKI role from the sealed `starrocks-server` (0.G.6) -- the two
 * clusters share no certificate identity (full isolation per ADR-0037).
 *
 * Selective ops: var.enable_vault_pki AND var.enable_starrocks_sd_pki.
 */

resource "null_resource" "vault_pki_starrocks_sd_role" {
  count = var.enable_vault_cluster && var.enable_vault_init && var.enable_vault_pki && var.enable_starrocks_sd_pki ? 1 : 0

  triggers = {
    int_id                      = length(null_resource.vault_pki_intermediate_ca) > 0 ? null_resource.vault_pki_intermediate_ca[0].id : "disabled"
    role_name                   = var.vault_pki_starrocks_sd_role_name
    leaf_ttl                    = var.vault_pki_leaf_ttl
    starrocks_sd_role_overlay_v = "1" # v1 (0.L.5) = initial 5-node SR shared-data cluster (3 FE + 2 CN).
  }

  depends_on = [null_resource.vault_pki_intermediate_ca]

  provisioner "local-exec" {
    when        = create
    interpreter = ["pwsh", "-NoProfile", "-Command"]
    command     = <<-PWSH
      $ip          = '${local.vault_1_ip}'
      $user        = '${local.ssh_user}'
      $roleName    = '${var.vault_pki_starrocks_sd_role_name}'
      $leafTtl     = '${var.vault_pki_leaf_ttl}'
      $keysFileRaw = '${var.vault_init_keys_file}'
      $keysFile    = $ExecutionContext.InvokeCommand.ExpandString($keysFileRaw.Replace('$HOME', $env:USERPROFILE))

      if (-not (Test-Path $keysFile)) { throw "[pki-starrocks-sd] keys file $keysFile missing" }
      $rootToken = (Get-Content $keysFile | ConvertFrom-Json).root_token

      $bash = @"
set -euo pipefail
export VAULT_TOKEN='$rootToken'
export VAULT_SKIP_VERIFY=true
export VAULT_ADDR=https://127.0.0.1:8200

echo "[pki-starrocks-sd] writing pki_int/roles/$roleName (idempotent overwrite)"
vault write pki_int/roles/$roleName \
  allowed_domains='nexus.lab,starrocks-sd.nexus.lab,starrocks-sd-fe.nexus.lab,sr-sd-fe-1,sr-sd-fe-2,sr-sd-fe-3,sr-sd-cn-1,sr-sd-cn-2,sr-sd-fe-1.nexus.lab,sr-sd-fe-2.nexus.lab,sr-sd-fe-3.nexus.lab,sr-sd-cn-1.nexus.lab,sr-sd-cn-2.nexus.lab,sr-sd-fe-1.starrocks-sd.nexus.lab,sr-sd-fe-2.starrocks-sd.nexus.lab,sr-sd-fe-3.starrocks-sd.nexus.lab,sr-sd-cn-1.starrocks-sd.nexus.lab,sr-sd-cn-2.starrocks-sd.nexus.lab,localhost' \
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
echo "[pki-starrocks-sd] role pki_int/roles/$roleName configured (allowed_domains=`$ALLOWED entries, ttl=$leafTtl, server+client EKU)"
"@

      $b64 = [Convert]::ToBase64String([System.Text.UTF8Encoding]::new($false).GetBytes($bash))
      Write-Host "[pki-starrocks-sd] dispatching to $${ip} via base64"
      $output = ssh -o ConnectTimeout=30 -o BatchMode=yes -o StrictHostKeyChecking=no $user@$ip "echo '$b64' | base64 -d | bash" 2>&1 | Out-String
      $rc = $LASTEXITCODE
      Write-Host $output.Trim()
      if ($rc -ne 0) { throw "[pki-starrocks-sd] script failed (rc=$rc)" }
    PWSH
  }
}
