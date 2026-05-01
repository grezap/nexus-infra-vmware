/*
 * role-overlay-vault-foundation-seed.tf -- Phase 0.D.4 step 3/3 (security side)
 *
 * One-time seed of the plaintext bootstrap creds + legacy JSON migration
 * into Vault KV at `nexus/foundation/...`. After this overlay applies, the
 * foundation env's `provider "vault"` data sources can resolve cleanly and
 * the role overlays can read creds without consulting plaintext defaults.
 *
 * Seven KV paths written (KV-v2; data lives at nexus/data/foundation/...):
 *
 *   nexus/foundation/dc-nexus/dsrm                {password}
 *   nexus/foundation/dc-nexus/local-administrator {password}
 *   nexus/foundation/identity/nexusadmin          {password}
 *   nexus/foundation/vault/userpass-nexusadmin    {password}
 *   nexus/foundation/ad/svc-vault-ldap            {binddn,password}    (from JSON)
 *   nexus/foundation/ad/svc-vault-smoke           {username,password}  (from JSON)
 *
 * (svc-demo-rotated is already Vault-managed via secrets/ldap; not seeded.)
 *
 * Idempotency: NEVER overwrites an existing path. If a path is already
 * populated (e.g. operator rotated it manually, or the foundation env's
 * dc_vault_ad_bind overlay already wrote the random pwd), the seed step
 * preserves the existing value. This is the canonical "sticky writes"
 * pattern -- seed is one-time-truth-population, not a forced-set.
 *
 * Source of seed values:
 *   - dsrm/local-admin/nexusadmin/userpass: from security env's mirror vars
 *     (defaults match foundation/security env defaults exactly). Marked
 *     sensitive=true.
 *   - ad/svc-vault-ldap + ad/svc-vault-smoke: read from
 *     $HOME/.nexus/vault-ad-bind.json on the build host. If the JSON file
 *     doesn't exist yet (greenfield without 0.D.3 having run with
 *     enable_vault_ad_integration=true), those two paths are skipped --
 *     foundation env's overlays will write them direct-to-KV on first
 *     create when 0.D.3+ runs.
 *
 * Selective ops: enable_vault_kv_foundation_seed (master) AND
 *                enable_vault_kv_foundation_seed_values.
 */

resource "null_resource" "vault_foundation_seed" {
  count = var.enable_vault_cluster && var.enable_vault_init && var.enable_vault_kv_foundation_seed && var.enable_vault_kv_foundation_seed_values ? 1 : 0

  triggers = {
    approle_id     = null_resource.vault_foundation_approle[0].id
    kv_mount_path  = var.vault_kv_mount_path
    seed_overlay_v = "1"
  }

  depends_on = [null_resource.vault_foundation_approle]

  provisioner "local-exec" {
    when        = create
    interpreter = ["pwsh", "-NoProfile", "-Command"]
    command     = <<-PWSH
      $ip               = '${local.vault_1_ip}'
      $user             = '${local.ssh_user}'
      $kvPath           = '${var.vault_kv_mount_path}'
      $keysFileRaw      = '${var.vault_init_keys_file}'
      $keysFile         = $ExecutionContext.InvokeCommand.ExpandString($keysFileRaw.Replace('$HOME', $env:USERPROFILE))
      $bindCredsFileRaw = '${var.vault_ad_bind_creds_file}'
      $bindCredsFile    = $ExecutionContext.InvokeCommand.ExpandString($bindCredsFileRaw.Replace('$HOME', $env:USERPROFILE))

      if (-not (Test-Path $keysFile)) {
        throw "[foundation-seed] keys file $keysFile missing -- run 0.D.1 init first"
      }
      $rootToken = (Get-Content $keysFile | ConvertFrom-Json).root_token

      # ─── Build the seed payload ─────────────────────────────────────────
      # Plaintext seeds (mirror foundation defaults)
      $dsrmPwd      = '${var.foundation_seed_dsrm_password}'
      $localAdmPwd  = '${var.foundation_seed_local_administrator_password}'
      $nexusAdmPwd  = '${var.foundation_seed_nexusadmin_password}'
      $userpassPwd  = '${var.vault_userpass_password}'
      $nexusAdmUser = 'nexusadmin'
      $userpassUser = '${var.vault_userpass_user}'

      # Optional legacy-JSON migration values
      $bindDn   = $null
      $bindPwd  = $null
      $smokeUsr = $null
      $smokePwd = $null
      if (Test-Path $bindCredsFile) {
        try {
          $j = Get-Content $bindCredsFile -Raw | ConvertFrom-Json
          if ($j.binddn -and $j.bindpass) {
            $bindDn  = $j.binddn
            $bindPwd = $j.bindpass
          }
          if ($j.smoke_username -and $j.smoke_password) {
            $smokeUsr = $j.smoke_username
            $smokePwd = $j.smoke_password
          }
        } catch {
          Write-Host "[foundation-seed] WARN: $bindCredsFile present but unparseable; skipping ad/* legacy migration"
        }
      } else {
        Write-Host "[foundation-seed] $bindCredsFile not present; foundation env will write ad/* paths direct-to-KV when its bind/smoke overlays run"
      }

      # Build the per-path seed list. Each item: {Path, JsonBody}. JsonBody
      # is shipped as base64 to avoid every shell-escape gotcha (passwords
      # contain $, !, ', etc).
      $items = @()
      $items += @{ Path = "foundation/dc-nexus/dsrm";                JsonBody = (@{ password = $dsrmPwd } | ConvertTo-Json -Compress) }
      $items += @{ Path = "foundation/dc-nexus/local-administrator"; JsonBody = (@{ password = $localAdmPwd } | ConvertTo-Json -Compress) }
      $items += @{ Path = "foundation/identity/nexusadmin";          JsonBody = (@{ username = $nexusAdmUser; password = $nexusAdmPwd } | ConvertTo-Json -Compress) }
      $items += @{ Path = "foundation/vault/userpass-nexusadmin";    JsonBody = (@{ username = $userpassUser; password = $userpassPwd } | ConvertTo-Json -Compress) }
      if ($bindDn -and $bindPwd) {
        $items += @{ Path = "foundation/ad/svc-vault-ldap"; JsonBody = (@{ binddn = $bindDn; username = 'svc-vault-ldap'; password = $bindPwd } | ConvertTo-Json -Compress) }
      }
      if ($smokeUsr -and $smokePwd) {
        $items += @{ Path = "foundation/ad/svc-vault-smoke"; JsonBody = (@{ username = $smokeUsr; password = $smokePwd } | ConvertTo-Json -Compress) }
      }

      Write-Host "[foundation-seed] $($items.Count) path(s) to consider; existing populated paths will be preserved (sticky writes)"

      # ─── Per-path seed loop on vault-1 ──────────────────────────────────
      foreach ($item in $items) {
        $pathFull = "$kvPath/$($item.Path)"
        $bodyB64  = [Convert]::ToBase64String([System.Text.UTF8Encoding]::new($false).GetBytes($item.JsonBody))

        $remoteBash = @"
set -euo pipefail
export VAULT_TOKEN='$rootToken'
export VAULT_SKIP_VERIFY=true
export VAULT_ADDR=https://127.0.0.1:8200

# Probe: does the path already hold a value?
EXISTING=`$(vault kv get -format=json '$pathFull' 2>/dev/null | jq -r '.data.data | length' 2>/dev/null || echo 0)

if [[ "`$EXISTING" -gt 0 ]]; then
  echo "[foundation-seed] $pathFull -- already populated (sticky); preserved"
  exit 0
fi

# Stage the JSON body to a tmpfile + use vault kv put @file syntax. Avoids
# shell-quoting woes with passwords containing !, \$, ', etc.
TMP=`$(mktemp)
trap 'rm -f "`$TMP"' EXIT
echo '$bodyB64' | base64 -d > "`$TMP"

vault kv put '$pathFull' @"`$TMP" >/dev/null
echo "[foundation-seed] $pathFull -- SEEDED"
"@
        $bashBytes = [System.Text.UTF8Encoding]::new($false).GetBytes($remoteBash)
        $bashB64   = [Convert]::ToBase64String($bashBytes)
        $output = ssh -o ConnectTimeout=30 -o BatchMode=yes -o StrictHostKeyChecking=no $user@$ip "echo '$bashB64' | base64 -d | bash" 2>&1 | Out-String
        if ($LASTEXITCODE -ne 0) {
          throw "[foundation-seed] write to $pathFull failed (rc=$LASTEXITCODE). Output:`n$output"
        }
        Write-Host $output.Trim()
      }

      Write-Host "[foundation-seed] complete -- foundation env's vault provider can now resolve nexus/foundation/* data sources"
    PWSH
  }
}
