/*
 * role-overlay-vault-pki-root.tf -- Phase 0.D.2 step 2/7
 *
 * Generate the internal root CA at pki/. The root signs the intermediate
 * exactly once (next overlay) and is otherwise dormant. Root key never
 * leaves Vault.
 *
 * Idempotency: probe `vault read pki/cert/ca`; if a non-empty cert is
 * already there, skip generation. Re-issuance is a destructive change
 * that breaks every downstream cert; if you genuinely want to rotate
 * the root, taint this resource explicitly.
 *
 * Why issuer_name=nexus-platform-root-ca: Vault 1.11+ supports multiple
 * issuers per mount; naming the issuer makes ops/automation explicit.
 *
 * URLs config (issuing_certificates / crl_distribution_points): clients
 * that follow the AIA chain (rare in modern TLS but useful for ops
 * diagnostics with `openssl verify -CAfile`) need an HTTP fetch path.
 * Pointed at vault-1's API addr -- the leader handles PKI requests; raft
 * forwards from followers transparently.
 *
 * Selective ops: var.enable_vault_pki AND var.enable_vault_pki_root.
 */

resource "null_resource" "vault_pki_root_ca" {
  count = var.enable_vault_cluster && var.enable_vault_init && var.enable_vault_pki && var.enable_vault_pki_root ? 1 : 0

  triggers = {
    mount_id       = length(null_resource.vault_pki_mount) > 0 ? null_resource.vault_pki_mount[0].id : "disabled"
    common_name    = var.vault_pki_root_common_name
    ttl            = var.vault_pki_root_ttl
    root_overlay_v = "1"
  }

  depends_on = [null_resource.vault_pki_mount]

  provisioner "local-exec" {
    when        = create
    interpreter = ["pwsh", "-NoProfile", "-Command"]
    command     = <<-PWSH
      $ip          = '${local.vault_1_ip}'
      $user        = '${local.ssh_user}'
      $commonName  = '${var.vault_pki_root_common_name}'
      $ttl         = '${var.vault_pki_root_ttl}'
      $apiAddr     = '${local.vault_leader_api_addr}'
      $keysFileRaw = '${var.vault_init_keys_file}'
      $keysFile    = $ExecutionContext.InvokeCommand.ExpandString($keysFileRaw.Replace('$HOME', $env:USERPROFILE))

      if (-not (Test-Path $keysFile)) {
        throw "[pki-root] keys file $keysFile missing"
      }
      $rootToken = (Get-Content $keysFile | ConvertFrom-Json).root_token

      $bash = @"
set -euo pipefail
export VAULT_TOKEN='$rootToken'
export VAULT_SKIP_VERIFY=true
export VAULT_ADDR=https://127.0.0.1:8200

# Idempotency: skip if pki/ already has a CA cert
if vault read -format=json pki/cert/ca 2>/dev/null | jq -e '.data.certificate' >/dev/null 2>&1; then
  CA_SUBJECT=`$(vault read -format=json pki/cert/ca | jq -r '.data.certificate' | openssl x509 -noout -subject 2>/dev/null | sed 's/^subject= *//')
  echo "[pki-root] root CA already present (subject=`$CA_SUBJECT), skipping generation"
  # Always (re-)apply URL config -- it's idempotent overwrite at the API level.
  vault write pki/config/urls \
    issuing_certificates='$apiAddr/v1/pki/ca' \
    crl_distribution_points='$apiAddr/v1/pki/crl'
  echo '[pki-root] URLs config refreshed'
  exit 0
fi

echo "[pki-root] generating internal root CA (CN='$commonName', ttl=$ttl, RSA-4096)"
vault write -format=json pki/root/generate/internal \
  common_name='$commonName' \
  issuer_name='nexus-platform-root-ca' \
  ttl='$ttl' \
  key_bits=4096 >/dev/null

vault write pki/config/urls \
  issuing_certificates='$apiAddr/v1/pki/ca' \
  crl_distribution_points='$apiAddr/v1/pki/crl'

echo '[pki-root] complete'
"@

      $bytes = [System.Text.UTF8Encoding]::new($false).GetBytes($bash)
      $b64   = [Convert]::ToBase64String($bytes)

      Write-Host "[pki-root] dispatching to $${ip} via base64"
      $output = ssh -o ConnectTimeout=60 -o BatchMode=yes -o StrictHostKeyChecking=no $user@$ip "echo '$b64' | base64 -d | bash" 2>&1 | Out-String
      $rc = $LASTEXITCODE
      Write-Host $output.Trim()
      if ($rc -ne 0) {
        throw "[pki-root] script failed (rc=$rc)"
      }
    PWSH
  }
}
