/*
 * role-overlay-vault-portainer-admin-seed.tf -- Phase 0.E.4d setup
 *
 * Sticky-seeds the Portainer CE admin password at
 * `nexus/portainer/admin-bcrypt`. Two fields:
 *
 *   - plaintext   : the admin password. **This is the field the swarm env's
 *                   role-overlay-portainer-admin-render.tf renders to
 *                   /etc/portainer/admin-password.txt**, because Portainer's
 *                   `--admin-password-file` reads the file as the PLAINTEXT
 *                   password and bcrypts it internally. It is also what you
 *                   type on the Portainer UI login form.
 *   - bcrypt_hash : bcrypt(plaintext), cost=10. Retained for reference / the
 *                   `--admin-password <hash>` CLI-flag alternative (which DOES
 *                   take a pre-computed bcrypt). NOTE: do NOT feed this to
 *                   `--admin-password-file` -- that flag wants plaintext, so
 *                   passing the bcrypt makes Portainer bcrypt the bcrypt-string
 *                   (the v2 render bug, fixed in admin-render v3 2026-06-19).
 *
 * The seed is sticky -- never overwrite a populated value (operator may
 * have rotated by hand; we don't churn). Generated server-side on
 * vault-1 via openssl + Python's bcrypt module (Debian 13 ships
 * python3-bcrypt by default). 24-char alphanumeric plaintext.
 *
 * Pre-reqs:
 *   - 0.D.1 Vault cluster init.
 *   - python3-bcrypt installed on vault-1 (apt-installed if missing).
 *
 * Idempotency:
 *   - Read existing field; only write if absent. Re-applies are no-op-fast
 *     after the first seed.
 *
 * Selective ops: var.enable_portainer_admin_seed (default true). Gated
 * under enable_vault_cluster + enable_vault_init.
 */

resource "null_resource" "vault_portainer_admin_seed" {
  count = var.enable_vault_cluster && var.enable_vault_init && var.enable_portainer_admin_seed ? 1 : 0

  triggers = {
    post_init_id     = null_resource.vault_post_init[0].id
    kv_mount_path    = var.vault_kv_mount_path
    portainer_seed_v = "1"
  }

  depends_on = [null_resource.vault_post_init]

  provisioner "local-exec" {
    when        = create
    interpreter = ["pwsh", "-NoProfile", "-Command"]
    command     = <<-PWSH
      $ip          = '${local.vault_1_ip}'
      $user        = '${local.ssh_user}'
      $kvPath      = '${var.vault_kv_mount_path}'
      $keysFileRaw = '${var.vault_init_keys_file}'
      $keysFile    = $ExecutionContext.InvokeCommand.ExpandString($keysFileRaw.Replace('$HOME', $env:USERPROFILE))

      if (-not (Test-Path $keysFile)) { throw "[portainer-admin-seed] keys file $keysFile missing" }
      $rootToken = (Get-Content $keysFile | ConvertFrom-Json).root_token

      $bash = @"
set -euo pipefail
export VAULT_TOKEN='$rootToken'
export VAULT_SKIP_VERIFY=true
export VAULT_ADDR=https://127.0.0.1:8200

# Sticky seed: nexus/portainer/admin-bcrypt
EXISTING=`$(vault kv get -field=bcrypt_hash -mount=$kvPath portainer/admin-bcrypt 2>/dev/null || true)
if [ -n "`$EXISTING" ]; then
  echo "[portainer-admin-seed] nexus/$kvPath/portainer/admin-bcrypt already populated -- preserving"
  exit 0
fi

# Ensure python3-bcrypt is available (used to bcrypt-hash the password).
if ! python3 -c 'import bcrypt' 2>/dev/null; then
  echo "[portainer-admin-seed] installing python3-bcrypt"
  sudo DEBIAN_FRONTEND=noninteractive apt-get update -qq
  sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq python3-bcrypt
fi

# Generate 24-char alphanumeric plaintext + bcrypt hash.
PLAINTEXT=`$(openssl rand -base64 24 | tr -dc 'a-zA-Z0-9' | head -c 24)
BCRYPT=`$(python3 -c "import bcrypt, sys; sys.stdout.write(bcrypt.hashpw(sys.argv[1].encode(), bcrypt.gensalt(rounds=10)).decode())" "`$PLAINTEXT")
TIMESTAMP=`$(date -u +%FT%TZ)

vault kv put -mount=$kvPath portainer/admin-bcrypt \
  bcrypt_hash="`$BCRYPT" \
  plaintext="`$PLAINTEXT" \
  status="seeded" \
  seeded_at="`$TIMESTAMP" >/dev/null

echo "[portainer-admin-seed] nexus/$kvPath/portainer/admin-bcrypt seeded (24-char alphanumeric plaintext, bcrypt cost=10)"
echo "[portainer-admin-seed] To retrieve plaintext: vault kv get -field=plaintext -mount=$kvPath portainer/admin-bcrypt"
"@

      $bytes = [System.Text.UTF8Encoding]::new($false).GetBytes($bash)
      $b64   = [Convert]::ToBase64String($bytes)

      Write-Host "[portainer-admin-seed] dispatching to $${ip} via base64"
      $output = ssh -o ConnectTimeout=30 -o BatchMode=yes -o StrictHostKeyChecking=no $user@$ip "echo '$b64' | base64 -d | bash" 2>&1 | Out-String
      $rc = $LASTEXITCODE
      Write-Host $output.Trim()
      if ($rc -ne 0) {
        throw "[portainer-admin-seed] script failed (rc=$rc)"
      }
    PWSH
  }
}
