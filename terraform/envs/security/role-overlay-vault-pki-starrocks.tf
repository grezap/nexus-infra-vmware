/*
 * role-overlay-vault-pki-starrocks.tf -- Phase 0.G.6 setup (StarRocks mTLS)
 *
 * Defines the `starrocks-server` PKI role at pki_int/. Leaf-cert role for all 6
 * StarRocks nodes (3 FE + 3 BE). One role covers FE + BE; per-host CN/SAN passed
 * at issue time by nexus-infra-analytics's role-overlay-starrocks-tls.tf.
 *
 * Certs cover: CN <hostname>.starrocks.nexus.lab; SANs <hostname>,
 * <hostname>.nexus.lab, <hostname>.starrocks.nexus.lab, starrocks-fe.nexus.lab
 * (the round-robin endpoint -- ADR-0031), localhost; IPs backplane + service +
 * 127.0.0.1. server+client EKU; 90-day TTL.
 *
 * Selective ops: var.enable_vault_pki AND var.enable_starrocks_pki.
 */

resource "null_resource" "vault_pki_starrocks_role" {
  count = var.enable_vault_cluster && var.enable_vault_init && var.enable_vault_pki && var.enable_starrocks_pki ? 1 : 0

  triggers = {
    int_id                   = length(null_resource.vault_pki_intermediate_ca) > 0 ? null_resource.vault_pki_intermediate_ca[0].id : "disabled"
    role_name                = var.vault_pki_starrocks_role_name
    leaf_ttl                 = var.vault_pki_leaf_ttl
    starrocks_role_overlay_v = "1" # v1 (0.G.6) = initial 6-node StarRocks cluster (3 FE + 3 BE).
  }

  depends_on = [null_resource.vault_pki_intermediate_ca]

  provisioner "local-exec" {
    when        = create
    interpreter = ["pwsh", "-NoProfile", "-Command"]
    command     = <<-PWSH
      $ip          = '${local.vault_1_ip}'
      $user        = '${local.ssh_user}'
      $roleName    = '${var.vault_pki_starrocks_role_name}'
      $leafTtl     = '${var.vault_pki_leaf_ttl}'
      $keysFileRaw = '${var.vault_init_keys_file}'
      $keysFile    = $ExecutionContext.InvokeCommand.ExpandString($keysFileRaw.Replace('$HOME', $env:USERPROFILE))

      if (-not (Test-Path $keysFile)) { throw "[pki-starrocks] keys file $keysFile missing" }
      $rootToken = (Get-Content $keysFile | ConvertFrom-Json).root_token

      $bash = @"
set -euo pipefail
export VAULT_TOKEN='$rootToken'
export VAULT_SKIP_VERIFY=true
export VAULT_ADDR=https://127.0.0.1:8200

echo "[pki-starrocks] writing pki_int/roles/$roleName (idempotent overwrite)"
vault write pki_int/roles/$roleName \
  allowed_domains='nexus.lab,starrocks.nexus.lab,starrocks-fe.nexus.lab,sr-fe-leader,sr-fe-follower-1,sr-fe-follower-2,sr-be-1,sr-be-2,sr-be-3,sr-fe-leader.nexus.lab,sr-fe-follower-1.nexus.lab,sr-fe-follower-2.nexus.lab,sr-be-1.nexus.lab,sr-be-2.nexus.lab,sr-be-3.nexus.lab,sr-fe-leader.starrocks.nexus.lab,sr-fe-follower-1.starrocks.nexus.lab,sr-fe-follower-2.starrocks.nexus.lab,sr-be-1.starrocks.nexus.lab,sr-be-2.starrocks.nexus.lab,sr-be-3.starrocks.nexus.lab,localhost' \
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
echo "[pki-starrocks] role pki_int/roles/$roleName configured (allowed_domains=`$ALLOWED entries, ttl=$leafTtl, server+client EKU)"
"@

      $b64 = [Convert]::ToBase64String([System.Text.UTF8Encoding]::new($false).GetBytes($bash))
      Write-Host "[pki-starrocks] dispatching to $${ip} via base64"
      $output = ssh -o ConnectTimeout=30 -o BatchMode=yes -o StrictHostKeyChecking=no $user@$ip "echo '$b64' | base64 -d | bash" 2>&1 | Out-String
      $rc = $LASTEXITCODE
      Write-Host $output.Trim()
      if ($rc -ne 0) { throw "[pki-starrocks] script failed (rc=$rc)" }
    PWSH
  }
}
