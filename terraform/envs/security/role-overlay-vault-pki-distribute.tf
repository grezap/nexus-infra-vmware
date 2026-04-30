/*
 * role-overlay-vault-pki-distribute.tf -- Phase 0.D.2 step 6/7
 *
 * Distribute the root CA cert to:
 *   1. Build host -- write to var.vault_pki_ca_bundle_path (default
 *      $HOME\.nexus\vault-ca-bundle.crt). Operator uses this with
 *      VAULT_CACERT to drop VAULT_SKIP_VERIFY.
 *   2. Each Vault node's system trust store at
 *      /usr/local/share/ca-certificates/nexus-vault-pki-root.crt + run
 *      `sudo update-ca-certificates`. This makes every node trust certs
 *      signed by our PKI without per-clone trust shuffles. Replaces the
 *      0.D.1 cold-start hack (vault-leader.crt installed on followers
 *      during raft join) -- the cleanup overlay (step 7) removes that
 *      residue.
 *
 * Idempotency: hash-compare on the build host (Get-FileHash) and on each
 * node (cmp -s). Skip writes when content already matches.
 *
 * Selective ops: var.enable_vault_pki AND var.enable_vault_pki_distribute.
 */

resource "null_resource" "vault_pki_distribute_root" {
  count = var.enable_vault_cluster && var.enable_vault_init && var.enable_vault_pki && var.enable_vault_pki_distribute ? 1 : 0

  triggers = {
    rotate_id            = length(null_resource.vault_pki_rotate_listener) > 0 ? null_resource.vault_pki_rotate_listener[0].id : "disabled"
    ca_bundle_path       = var.vault_pki_ca_bundle_path
    distribute_overlay_v = "1"
  }

  depends_on = [null_resource.vault_pki_rotate_listener]

  provisioner "local-exec" {
    when        = create
    interpreter = ["pwsh", "-NoProfile", "-Command"]
    command     = <<-PWSH
      $user            = '${local.ssh_user}'
      $leaderIp        = '${local.vault_1_ip}'
      $bundlePathRaw   = '${var.vault_pki_ca_bundle_path}'
      $bundlePath      = $ExecutionContext.InvokeCommand.ExpandString($bundlePathRaw.Replace('$HOME', $env:USERPROFILE))
      $keysFileRaw     = '${var.vault_init_keys_file}'
      $keysFile        = $ExecutionContext.InvokeCommand.ExpandString($keysFileRaw.Replace('$HOME', $env:USERPROFILE))

      if (-not (Test-Path $keysFile)) {
        throw "[pki-distribute] keys file $keysFile missing"
      }
      $rootToken = (Get-Content $keysFile | ConvertFrom-Json).root_token

      # ─── Step A: pull root CA cert via SSH on vault-1 ─────────────────────
      Write-Host "[pki-distribute] fetching root CA cert from vault-1 (pki/cert/ca)"
      $caRaw = ssh -o ConnectTimeout=15 -o BatchMode=yes -o StrictHostKeyChecking=no $user@$leaderIp `
        "VAULT_TOKEN='$rootToken' VAULT_SKIP_VERIFY=true VAULT_ADDR=https://127.0.0.1:8200 vault read -format=json pki/cert/ca | jq -r '.data.certificate'" 2>&1 | Out-String

      $caClean = $caRaw.Trim()
      if (-not $caClean -or $caClean -notmatch 'BEGIN CERTIFICATE') {
        throw "[pki-distribute] failed to fetch root CA cert. Output:`n$caRaw"
      }

      # Normalize line endings to LF + ensure single trailing newline
      $caLF = ($caClean -replace "`r`n", "`n").TrimEnd("`n") + "`n"

      # ─── Step B: write to build host ──────────────────────────────────────
      $bundleDir = Split-Path -Parent $bundlePath
      if (-not (Test-Path $bundleDir)) {
        New-Item -ItemType Directory -Force -Path $bundleDir | Out-Null
      }

      $needWrite = $true
      if (Test-Path $bundlePath) {
        $existing = (Get-Content $bundlePath -Raw -ErrorAction SilentlyContinue)
        if ($existing -and ($existing.TrimEnd("`r","`n") -eq $caLF.TrimEnd("`r","`n"))) {
          Write-Host "[pki-distribute] build-host bundle already matches at $${bundlePath}; no rewrite"
          $needWrite = $false
        }
      }
      if ($needWrite) {
        # Write bytes to keep LF line endings (Set-Content default is CRLF on Win)
        $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
        [System.IO.File]::WriteAllText($bundlePath, $caLF, $utf8NoBom)
        Write-Host "[pki-distribute] wrote root CA bundle to $${bundlePath}"
      }

      # ─── Step C: install on each Vault node's system trust store ─────────
      # Stage to a temp file with LF endings, scp to /tmp, then sudo install.
      $tmpFile = [System.IO.Path]::GetTempFileName()
      try {
        $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
        [System.IO.File]::WriteAllText($tmpFile, $caLF, $utf8NoBom)

        $nodes = @('${local.vault_1_ip}', '${local.vault_2_ip}', '${local.vault_3_ip}')
        foreach ($ip in $nodes) {
          Write-Host "[pki-distribute] $${ip}: staging + installing root CA in system trust store"

          scp -o ConnectTimeout=15 -o BatchMode=yes -o StrictHostKeyChecking=no $tmpFile "$${user}@$${ip}:/tmp/nexus-vault-pki-root.crt" 2>&1 | Out-Null
          if ($LASTEXITCODE -ne 0) {
            throw "[pki-distribute] $${ip}: scp of root CA failed (rc=$LASTEXITCODE)"
          }

          $bash = @'
set -euo pipefail
SRC=/tmp/nexus-vault-pki-root.crt
DEST=/usr/local/share/ca-certificates/nexus-vault-pki-root.crt

if [ -f "$DEST" ] && sudo cmp -s "$SRC" "$DEST"; then
  echo "[pki-distribute] node trust anchor already matches $DEST; no rewrite"
  rm -f "$SRC"
  exit 0
fi

sudo install -o root -g root -m 0644 "$SRC" "$DEST"
sudo update-ca-certificates 2>&1 | tail -3
rm -f "$SRC"
echo "[pki-distribute] node trust anchor installed at $DEST"
'@
          $bytes = [System.Text.UTF8Encoding]::new($false).GetBytes($bash)
          $b64   = [Convert]::ToBase64String($bytes)
          $output = ssh -o ConnectTimeout=30 -o BatchMode=yes -o StrictHostKeyChecking=no $user@$ip "echo '$b64' | base64 -d | bash" 2>&1 | Out-String
          $rc = $LASTEXITCODE
          Write-Host $output.Trim()
          if ($rc -ne 0) {
            throw "[pki-distribute] $${ip}: trust-store install failed (rc=$rc)"
          }
        }
      } finally {
        Remove-Item -Force $tmpFile -ErrorAction SilentlyContinue
      }

      Write-Host "[pki-distribute] root CA distributed to build host + all 3 Vault nodes"
    PWSH
  }
}
