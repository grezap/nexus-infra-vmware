/*
 * role-overlay-vault-nexusadmin-creds-seed.tf -- Phase 0.G.7 close-out
 *
 * Writes a host-side sidecar at $HOME/.nexus/nexusadmin-credentials.json
 * containing the nexusadmin AD-user credentials. Read from Vault KV at
 * nexus/foundation/identity/nexusadmin (seeded by role-overlay-vault-
 * foundation-seed.tf; field names: username + password).
 *
 * Why a sidecar (and not a per-env vault provider data lookup):
 *   The oltp-sqlserver env (nexus-infra-oltp/terraform/envs/oltp-sqlserver/)
 *   does not have the vault provider configured -- it uses null_resource +
 *   local-exec for every operation. Foundation env's role-overlay-jumpbox-
 *   domainjoin.tf reads the nexusadmin password via the vault provider
 *   (data.vault_kv_secret_v2.identity_nexusadmin -> local.foundation_creds.
 *   nexusadmin) but the oltp env can't replicate that pattern without taking
 *   on the vault provider + AppRole auth.
 *
 *   The sidecar pattern is the canonical workaround per the existing
 *   vault-ad-bind.json (LDAP bind creds for the jumpbox -> svc-vault-ldap)
 *   + vault-init.json (root token + unseal keys -> consumed by every cross-
 *   env post-init operation) + iscsi-sqlfci-chap.json (CHAP secret ->
 *   consumed by foundation's iSCSI target overlay).
 *
 *   Transient #22 at 0.G.7 ratify 2026-05-21: the oltp env's role-overlay-
 *   sqlserver-domain-join.tf originally read vault-ad-bind.json's
 *   nexusadmin_password field. That field does not exist -- vault-ad-bind.
 *   json holds the LDAP bind creds (binddn + bindpass for svc-vault-ldap),
 *   NOT the nexusadmin domain user. The domain-join overlay was patched to
 *   read THIS sidecar; this overlay populates it.
 *
 * Sidecar shape:
 *   {
 *     "username": "nexusadmin",
 *     "password": "<32-char password from Vault KV>",
 *     "domain": "nexus.lab",
 *     "domain_user_upn": "nexusadmin@nexus.lab",
 *     "generated_at": "<ISO-8601>",
 *     "source": "nexus/foundation/identity/nexusadmin"
 *   }
 *
 * ACL: build-host operator user only (icacls /inheritance:r /grant:r
 * "$USERNAME:(R,W)"). Same pattern as the other 3 sidecars.
 *
 * Idempotent: each apply overwrites the sidecar from the current Vault KV
 * value. If the operator rotates nexusadmin's password via Vault KV, the
 * next security apply re-renders the sidecar with the new value.
 *
 * Selective ops: var.enable_nexusadmin_creds_sidecar (default true). Pre-
 * req: vault cluster initialized + foundation-seed applied (so the KV path
 * is populated).
 */

resource "null_resource" "vault_nexusadmin_creds_sidecar" {
  count = var.enable_vault_cluster && var.enable_vault_init && var.enable_nexusadmin_creds_sidecar ? 1 : 0

  triggers = {
    post_init_id              = null_resource.vault_post_init[0].id
    foundation_seed_id        = length(null_resource.vault_foundation_seed) > 0 ? null_resource.vault_foundation_seed[0].id : "disabled"
    sidecar_path              = var.nexusadmin_creds_sidecar_path
    kv_path                   = "nexus/foundation/identity/nexusadmin"
    nexusadmin_sidecar_v      = "1" # v1 (0.G.7 ratify 2026-05-21) = transient #22 fix.
  }

  depends_on = [
    null_resource.vault_post_init,
    null_resource.vault_foundation_seed,
  ]

  provisioner "local-exec" {
    when        = create
    interpreter = ["pwsh", "-NoProfile", "-Command"]
    command     = <<-PWSH
      $ip          = '${local.vault_1_ip}'
      $user        = '${local.ssh_user}'
      $keysFileRaw = '${var.vault_init_keys_file}'
      $keysFile    = $ExecutionContext.InvokeCommand.ExpandString($keysFileRaw.Replace('$HOME', $env:USERPROFILE))
      $homeDir     = $env:USERPROFILE
      $sidecarRaw  = '${var.nexusadmin_creds_sidecar_path}'
      $sidecar     = $ExecutionContext.InvokeCommand.ExpandString($sidecarRaw.Replace('$HOME', $homeDir))

      if (-not (Test-Path $keysFile)) { throw "[nexusadmin-creds-sidecar] keys file $keysFile missing" }
      $rootToken = (Get-Content $keysFile | ConvertFrom-Json).root_token

      # Stage 1: vault-1 RPC to fetch nexus/foundation/identity/nexusadmin
      # data. Emit two marker lines (one per field) to stdout for the
      # build-host parser to consume. Pattern mirrors the CHAP secret marker
      # in role-overlay-vault-sqlserver-cluster-creds-seed.tf.
      $bash = @"
set -euo pipefail
export VAULT_TOKEN='$rootToken'
export VAULT_SKIP_VERIFY=true
export VAULT_ADDR=https://127.0.0.1:8200

NEXUSADMIN_USERNAME=`$(vault kv get -field=username nexus/foundation/identity/nexusadmin)
NEXUSADMIN_PASSWORD=`$(vault kv get -field=password nexus/foundation/identity/nexusadmin)

if [ -z "`$NEXUSADMIN_USERNAME" ] || [ -z "`$NEXUSADMIN_PASSWORD" ]; then
  echo "[nexusadmin-creds-sidecar] ERROR: empty username/password from KV nexus/foundation/identity/nexusadmin" >&2
  exit 1
fi

echo "NEXUSADMIN_USERNAME_MARKER=`$NEXUSADMIN_USERNAME"
echo "NEXUSADMIN_PASSWORD_MARKER=`$NEXUSADMIN_PASSWORD"
echo "[nexusadmin-creds-sidecar] fetched username + password (lengths: u=`$(printf '%s' `$NEXUSADMIN_USERNAME | wc -c) p=`$(printf '%s' `$NEXUSADMIN_PASSWORD | wc -c))"
"@

      $bytes = [System.Text.UTF8Encoding]::new($false).GetBytes($bash)
      $b64   = [Convert]::ToBase64String($bytes)

      Write-Host "[nexusadmin-creds-sidecar] dispatching to $${ip} via base64"
      $output = ssh -o ConnectTimeout=30 -o BatchMode=yes -o StrictHostKeyChecking=no $user@$ip "echo '$b64' | base64 -d | bash" 2>&1 | Out-String
      $rc = $LASTEXITCODE
      if ($rc -ne 0) {
        Write-Host $output.Trim()
        throw "[nexusadmin-creds-sidecar] vault-1 RPC failed (rc=$rc)"
      }

      # Stage 2: parse the 2 marker lines. Tolerate trailing CR/whitespace
      # per feedback_pwsh_ssh_stdin_cr_injection.md.
      $userMatch = $output -match '(?m)^NEXUSADMIN_USERNAME_MARKER=(.+?)\s*$'
      if (-not $userMatch) {
        Write-Host "[nexusadmin-creds-sidecar] script output for diag:"
        Write-Host $output
        throw "[nexusadmin-creds-sidecar] failed to parse username marker"
      }
      $nexusUser = $matches[1]

      $pwdMatch = $output -match '(?m)^NEXUSADMIN_PASSWORD_MARKER=(.+?)\s*$'
      if (-not $pwdMatch) {
        Write-Host "[nexusadmin-creds-sidecar] script output for diag (password marker missing)"
        throw "[nexusadmin-creds-sidecar] failed to parse password marker"
      }
      $nexusPwd = $matches[1]

      # Filter both marker lines out of operator-visible output (keep secret
      # out of operator's scrollback). Same pattern as the CHAP sidecar.
      $sanitized = ($output -split "`n" | Where-Object { $_ -notmatch '^NEXUSADMIN_(USERNAME|PASSWORD)_MARKER=' }) -join "`n"
      Write-Host $sanitized.Trim()

      # Stage 3: write sidecar JSON with structured fields. Same shape that
      # the oltp env's role-overlay-sqlserver-domain-join.tf expects.
      $sidecarDir = Split-Path -Parent $sidecar
      if (-not (Test-Path $sidecarDir)) {
        New-Item -ItemType Directory -Force -Path $sidecarDir | Out-Null
      }
      $payload = [PSCustomObject]@{
        username        = $nexusUser
        password        = $nexusPwd
        domain          = '${var.ad_domain_name}'
        netbios         = '${var.ad_netbios_name}'
        domain_user_upn = "$nexusUser@${var.ad_domain_name}"
        generated_at    = (Get-Date -Format 'o')
        source          = 'nexus/foundation/identity/nexusadmin'
      }
      $payload | ConvertTo-Json -Depth 5 | Out-File -FilePath $sidecar -Encoding UTF8 -Force
      icacls $sidecar /inheritance:r /grant:r "$($env:USERNAME):(R,W)" | Out-Null
      Write-Host "[nexusadmin-creds-sidecar] sidecar written to $sidecar (consumed by oltp-sqlserver env's role-overlay-sqlserver-domain-join.tf + future oltp Windows-domain overlays)"
    PWSH
  }
}
