/*
 * role-overlay-vault-pki-mount.tf -- Phase 0.D.2 step 1/7
 *
 * Mount the Vault PKI secrets engine at pki/ (root CA, max_lease_ttl 10y)
 * and the intermediate engine at pki_int/ (max_lease_ttl 5y).
 *
 * Why two mounts: standard Vault PKI design separates the offline-only
 * root from the online intermediate. Root signs the intermediate once,
 * then is read-only forever. All leaf certs (vault listeners, future
 * templates) issue from pki_int/.
 *
 * Idempotency: probe `vault secrets list` for both paths; only enable
 * when missing. Always re-tune max-lease-ttl in case the user changed
 * the TTL var (tune is itself idempotent at the API level).
 *
 * Depends on: null_resource.vault_post_init (cluster + KV + auth methods
 * must be live).
 *
 * Selective ops: var.enable_vault_pki (master) AND var.enable_vault_pki_mount.
 */

resource "null_resource" "vault_pki_mount" {
  count = var.enable_vault_cluster && var.enable_vault_init && var.enable_vault_pki && var.enable_vault_pki_mount ? 1 : 0

  triggers = {
    post_init_id    = null_resource.vault_post_init[0].id
    pki_root_ttl    = var.vault_pki_root_ttl
    pki_int_ttl     = var.vault_pki_intermediate_ttl
    mount_overlay_v = "1"
  }

  depends_on = [null_resource.vault_post_init]

  provisioner "local-exec" {
    when        = create
    interpreter = ["pwsh", "-NoProfile", "-Command"]
    command     = <<-PWSH
      $ip          = '${local.vault_1_ip}'
      $user        = '${local.ssh_user}'
      $rootTtl     = '${var.vault_pki_root_ttl}'
      $intTtl      = '${var.vault_pki_intermediate_ttl}'
      $keysFileRaw = '${var.vault_init_keys_file}'
      $keysFile    = $ExecutionContext.InvokeCommand.ExpandString($keysFileRaw.Replace('$HOME', $env:USERPROFILE))

      if (-not (Test-Path $keysFile)) {
        throw "[pki-mount] keys file $keysFile missing -- run 0.D.1 init first"
      }
      $rootToken = (Get-Content $keysFile | ConvertFrom-Json).root_token

      $bash = @"
set -euo pipefail
export VAULT_TOKEN='$rootToken'
export VAULT_SKIP_VERIFY=true
export VAULT_ADDR=https://127.0.0.1:8200

# pki/ -- root CA mount
if vault secrets list -format=json | jq -e '."pki/"' >/dev/null 2>&1; then
  echo '[pki-mount] pki/ already mounted, re-tuning max-lease-ttl'
else
  echo '[pki-mount] mounting pki/ (root CA, max-lease-ttl=$rootTtl)'
  vault secrets enable -path=pki -max-lease-ttl=$rootTtl pki
fi
vault secrets tune -max-lease-ttl=$rootTtl pki

# pki_int/ -- intermediate CA mount
if vault secrets list -format=json | jq -e '."pki_int/"' >/dev/null 2>&1; then
  echo '[pki-mount] pki_int/ already mounted, re-tuning max-lease-ttl'
else
  echo '[pki-mount] mounting pki_int/ (intermediate CA, max-lease-ttl=$intTtl)'
  vault secrets enable -path=pki_int -max-lease-ttl=$intTtl pki
fi
vault secrets tune -max-lease-ttl=$intTtl pki_int

echo '[pki-mount] complete'
"@

      $bytes = [System.Text.UTF8Encoding]::new($false).GetBytes($bash)
      $b64   = [Convert]::ToBase64String($bytes)

      Write-Host "[pki-mount] dispatching to $${ip} via base64"
      $output = ssh -o ConnectTimeout=30 -o BatchMode=yes -o StrictHostKeyChecking=no $user@$ip "echo '$b64' | base64 -d | bash" 2>&1 | Out-String
      $rc = $LASTEXITCODE
      Write-Host $output.Trim()
      if ($rc -ne 0) {
        throw "[pki-mount] script failed (rc=$rc)"
      }
    PWSH
  }
}
