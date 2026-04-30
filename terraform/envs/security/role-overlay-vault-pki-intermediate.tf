/*
 * role-overlay-vault-pki-intermediate.tf -- Phase 0.D.2 step 3/7
 *
 * Generate the intermediate CA: pki_int/ produces a CSR; pki/ signs it
 * (sign-intermediate); pki_int/ persists the signed cert. Intermediate
 * private key never leaves Vault.
 *
 * Idempotency: probe `vault read pki_int/cert/ca`; skip generation if a
 * signed intermediate is already in place. The full handshake (CSR ->
 * sign -> set-signed) is non-trivial to mid-step idempotently, so we
 * gate on the final state (pki_int has a CA cert).
 *
 * Why we always (re-)apply URL config: like with root, URLs is idempotent
 * overwrite and surfaces the leader's API addr to chain-walking clients.
 *
 * Selective ops: var.enable_vault_pki AND var.enable_vault_pki_intermediate.
 */

resource "null_resource" "vault_pki_intermediate_ca" {
  count = var.enable_vault_cluster && var.enable_vault_init && var.enable_vault_pki && var.enable_vault_pki_intermediate ? 1 : 0

  triggers = {
    root_id       = length(null_resource.vault_pki_root_ca) > 0 ? null_resource.vault_pki_root_ca[0].id : "disabled"
    common_name   = var.vault_pki_intermediate_common_name
    ttl           = var.vault_pki_intermediate_ttl
    int_overlay_v = "1"
  }

  depends_on = [null_resource.vault_pki_root_ca]

  provisioner "local-exec" {
    when        = create
    interpreter = ["pwsh", "-NoProfile", "-Command"]
    command     = <<-PWSH
      $ip             = '${local.vault_1_ip}'
      $user           = '${local.ssh_user}'
      $intCommonName  = '${var.vault_pki_intermediate_common_name}'
      $intTtl         = '${var.vault_pki_intermediate_ttl}'
      $apiAddr        = '${local.vault_leader_api_addr}'
      $keysFileRaw    = '${var.vault_init_keys_file}'
      $keysFile       = $ExecutionContext.InvokeCommand.ExpandString($keysFileRaw.Replace('$HOME', $env:USERPROFILE))

      if (-not (Test-Path $keysFile)) {
        throw "[pki-int] keys file $keysFile missing"
      }
      $rootToken = (Get-Content $keysFile | ConvertFrom-Json).root_token

      $bash = @"
set -euo pipefail
export VAULT_TOKEN='$rootToken'
export VAULT_SKIP_VERIFY=true
export VAULT_ADDR=https://127.0.0.1:8200

# Idempotency: skip if pki_int/ already has a signed intermediate
if vault read -format=json pki_int/cert/ca 2>/dev/null | jq -e '.data.certificate' >/dev/null 2>&1; then
  INT_SUBJECT=`$(vault read -format=json pki_int/cert/ca | jq -r '.data.certificate' | openssl x509 -noout -subject 2>/dev/null | sed 's/^subject= *//')
  echo "[pki-int] intermediate already present (subject=`$INT_SUBJECT), skipping generation"
  # URLs config is idempotent overwrite -- always (re-)apply.
  vault write pki_int/config/urls \
    issuing_certificates='$apiAddr/v1/pki_int/ca' \
    crl_distribution_points='$apiAddr/v1/pki_int/crl'
  echo '[pki-int] URLs config refreshed'
  exit 0
fi

# Generate CSR at pki_int/
echo "[pki-int] generating CSR at pki_int/ (CN='$intCommonName', RSA-4096)"
CSR=`$(vault write -format=json pki_int/intermediate/generate/internal \
  common_name='$intCommonName' \
  issuer_name='nexus-platform-intermediate-ca' \
  key_bits=4096 | jq -r '.data.csr')

if [ -z "`$CSR" ]; then
  echo '[pki-int] ERROR: empty CSR returned' >&2
  exit 1
fi

TMPCSR=`$(mktemp)
TMPCERT=`$(mktemp)
trap 'rm -f "`$TMPCSR" "`$TMPCERT"' EXIT
echo "`$CSR" > "`$TMPCSR"

# Sign via root
echo "[pki-int] signing CSR via pki/root/sign-intermediate (ttl=$intTtl)"
SIGNED=`$(vault write -format=json pki/root/sign-intermediate \
  csr=@"`$TMPCSR" \
  format=pem_bundle \
  ttl='$intTtl' | jq -r '.data.certificate')

if [ -z "`$SIGNED" ]; then
  echo '[pki-int] ERROR: empty signed certificate returned' >&2
  exit 1
fi
echo "`$SIGNED" > "`$TMPCERT"

# Persist signed intermediate at pki_int/
echo '[pki-int] setting signed intermediate at pki_int/intermediate/set-signed'
vault write pki_int/intermediate/set-signed certificate=@"`$TMPCERT" >/dev/null

# URLs config for the intermediate
vault write pki_int/config/urls \
  issuing_certificates='$apiAddr/v1/pki_int/ca' \
  crl_distribution_points='$apiAddr/v1/pki_int/crl'

echo '[pki-int] complete'
"@

      $bytes = [System.Text.UTF8Encoding]::new($false).GetBytes($bash)
      $b64   = [Convert]::ToBase64String($bytes)

      Write-Host "[pki-int] dispatching to $${ip} via base64"
      $output = ssh -o ConnectTimeout=60 -o BatchMode=yes -o StrictHostKeyChecking=no $user@$ip "echo '$b64' | base64 -d | bash" 2>&1 | Out-String
      $rc = $LASTEXITCODE
      Write-Host $output.Trim()
      if ($rc -ne 0) {
        throw "[pki-int] script failed (rc=$rc)"
      }
    PWSH
  }
}
