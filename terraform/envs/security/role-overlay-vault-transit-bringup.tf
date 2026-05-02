/*
 * role-overlay-vault-transit-bringup.tf -- Phase 0.D.5.5 step 1/2 (security)
 *
 * Brings up vault-transit (single-node Vault, file storage) AFTER the
 * VM clone lands. Steps:
 *   1. Wait for SSH + vault.service active.
 *   2. Init shamir (5/3 keys, like cluster) -- vault-transit IS the unseal
 *      key custodian, so it can't auto-unseal itself; manual once per
 *      reboot.
 *   3. Unseal with 3 keys.
 *   4. Enable transit secrets engine.
 *   5. Create transit key `nexus-cluster-unseal`.
 *   6. Write Vault policy `nexus-cluster-unseal` (encrypt/decrypt on
 *      transit/keys/nexus-cluster-unseal only).
 *   7. Issue a non-expiring token bound to that policy.
 *   8. Persist:
 *      - vault-transit-init.json: root token + 5 unseal keys (mode 0600).
 *      - vault-transit-token.json: cluster-auth token + transit endpoint
 *        (consumed by role-overlay-vault-cluster-seal-config.tf).
 *
 * Independent of the 3-node cluster init -- transit must exist BEFORE
 * the cluster's seal-transit.hcl can reference it.
 *
 * Selective ops: enable_vault_transit_unseal (master) AND
 *                enable_vault_transit_vm AND
 *                enable_vault_transit_bringup.
 */

resource "null_resource" "vault_transit_bringup" {
  count = var.enable_vault_transit_unseal && var.enable_vault_transit_vm && var.enable_vault_transit_bringup ? 1 : 0

  triggers = {
    vm_id             = module.vault_transit[0].vm_name
    init_keys_file    = var.vault_transit_init_keys_file
    token_file        = var.vault_transit_token_file
    transit_key_name  = var.vault_transit_key_name
    bringup_overlay_v = "1"
  }

  depends_on = [module.vault_transit]

  provisioner "local-exec" {
    when        = create
    interpreter = ["pwsh", "-NoProfile", "-Command"]
    command     = <<-PWSH
      $ip                 = '192.168.70.124'
      $user               = '${local.ssh_user}'
      $keyName            = '${var.vault_transit_key_name}'
      $initKeysFileRaw    = '${var.vault_transit_init_keys_file}'
      $initKeysFile       = $ExecutionContext.InvokeCommand.ExpandString($initKeysFileRaw.Replace('$HOME', $env:USERPROFILE))
      $tokenFileRaw       = '${var.vault_transit_token_file}'
      $tokenFile          = $ExecutionContext.InvokeCommand.ExpandString($tokenFileRaw.Replace('$HOME', $env:USERPROFILE))

      # ─── Step 1: Wait for SSH + vault.service ─────────────────────────
      Write-Host "[vault-transit] waiting for SSH + vault.service on $ip"
      $deadline = (Get-Date).AddMinutes(${var.vault_cluster_timeout_minutes})
      while ((Get-Date) -lt $deadline) {
        $probe = (ssh -o ConnectTimeout=5 -o BatchMode=yes -o StrictHostKeyChecking=no $user@$ip "systemctl is-active vault.service" 2>&1 | Out-String).Trim()
        if ($probe -eq 'active') { break }
        Start-Sleep -Seconds 10
      }
      if ($probe -ne 'active') {
        throw "[vault-transit] vault.service never became active on $ip"
      }
      Write-Host "[vault-transit] vault.service active on $ip"

      # ─── Step 2: Init shamir (idempotent) + Step 3: Unseal ────────────
      $statusRaw = ssh -o ConnectTimeout=15 -o BatchMode=yes -o StrictHostKeyChecking=no $user@$ip "VAULT_SKIP_VERIFY=true vault status -format=json -address=https://127.0.0.1:8200" 2>&1 | Out-String
      $statusJson = $null
      try { $statusJson = $statusRaw | ConvertFrom-Json } catch { }

      if ($statusJson -and $statusJson.initialized -eq $true -and $statusJson.sealed -eq $false) {
        Write-Host "[vault-transit] already initialized + unsealed; skipping init"
      } elseif ($statusJson -and $statusJson.initialized -eq $true -and $statusJson.sealed -eq $true) {
        Write-Host "[vault-transit] initialized but sealed; unsealing from $initKeysFile"
        if (-not (Test-Path $initKeysFile)) {
          throw "[vault-transit] sealed but $initKeysFile missing -- cannot unseal"
        }
        $keys = (Get-Content $initKeysFile | ConvertFrom-Json).unseal_keys_b64
        for ($i = 0; $i -lt 3; $i++) {
          ssh -o ConnectTimeout=15 -o BatchMode=yes -o StrictHostKeyChecking=no $user@$ip "VAULT_SKIP_VERIFY=true vault operator unseal -address=https://127.0.0.1:8200 $($keys[$i])" 2>&1 | Out-Null
        }
      } else {
        Write-Host "[vault-transit] uninitialized -- vault operator init -key-shares=5 -key-threshold=3"
        $initOutput = ssh -o ConnectTimeout=30 -o BatchMode=yes -o StrictHostKeyChecking=no $user@$ip "VAULT_SKIP_VERIFY=true vault operator init -format=json -key-shares=5 -key-threshold=3 -address=https://127.0.0.1:8200" 2>&1 | Out-String
        if ($LASTEXITCODE -ne 0) {
          throw "[vault-transit] init failed (rc=$LASTEXITCODE). Output:`n$initOutput"
        }
        $initJson = $initOutput | ConvertFrom-Json
        # Persist init keys
        $keysDir = Split-Path -Parent $initKeysFile
        New-Item -ItemType Directory -Force -Path $keysDir | Out-Null
        $initOutput.Trim() | Set-Content -Path $initKeysFile -Encoding UTF8
        icacls $initKeysFile /inheritance:r /grant:r "$($env:USERNAME):F" 2>&1 | Out-Null
        Write-Host "[vault-transit] init keys persisted to $initKeysFile"
        # Unseal
        for ($i = 0; $i -lt 3; $i++) {
          ssh -o ConnectTimeout=15 -o BatchMode=yes -o StrictHostKeyChecking=no $user@$ip "VAULT_SKIP_VERIFY=true vault operator unseal -address=https://127.0.0.1:8200 $($initJson.unseal_keys_b64[$i])" 2>&1 | Out-Null
        }
        Write-Host "[vault-transit] unsealed"
      }

      # ─── Step 4-7: Enable transit + create key + policy + token ──────
      $rootToken = (Get-Content $initKeysFile | ConvertFrom-Json).root_token
      $bash = @"
set -euo pipefail
export VAULT_TOKEN='$rootToken'
export VAULT_SKIP_VERIFY=true
export VAULT_ADDR=https://127.0.0.1:8200

# 4. Enable transit (idempotent)
if vault secrets list -format=json | jq -e '."transit/"' >/dev/null 2>&1; then
  echo '[transit] secrets/transit already enabled'
else
  vault secrets enable transit
  echo '[transit] secrets/transit enabled'
fi

# 5. Create the transit key (idempotent: vault write -f is upsert)
if vault read transit/keys/$keyName >/dev/null 2>&1; then
  echo '[transit] key $keyName already exists'
else
  vault write -f transit/keys/$keyName
  echo '[transit] key $keyName created'
fi

# 6. Write policy (idempotent)
TMP_POL=`$(mktemp)
trap 'rm -f "`$TMP_POL"' EXIT
cat > "`$TMP_POL" <<'EOF'
path "transit/encrypt/$keyName" {
  capabilities = ["update"]
}
path "transit/decrypt/$keyName" {
  capabilities = ["update"]
}
EOF
vault policy write nexus-cluster-unseal "`$TMP_POL" >/dev/null
echo '[transit] policy nexus-cluster-unseal written'

# 7. Issue non-expiring token bound to the policy
TOKEN_OUT=`$(vault token create -policy=nexus-cluster-unseal -ttl=0 -period=720h -display-name=cluster-unseal -format=json)
echo "TRANSIT_TOKEN=`$(echo "`$TOKEN_OUT" | jq -r '.auth.client_token')"
echo "TRANSIT_ACCESSOR=`$(echo "`$TOKEN_OUT" | jq -r '.auth.accessor')"
"@
      $bashB64 = [Convert]::ToBase64String([System.Text.UTF8Encoding]::new($false).GetBytes($bash))
      $output = ssh -o ConnectTimeout=30 -o BatchMode=yes -o StrictHostKeyChecking=no $user@$ip "echo '$bashB64' | base64 -d | bash" 2>&1 | Out-String
      if ($LASTEXITCODE -ne 0) {
        throw "[vault-transit] transit setup failed (rc=$LASTEXITCODE). Output:`n$output"
      }
      Write-Host $output.Trim()

      $transitToken = $null
      if ($output -match '(?m)^TRANSIT_TOKEN=(.+)$') { $transitToken = $Matches[1].Trim() }
      if (-not $transitToken) {
        throw "[vault-transit] failed to parse TRANSIT_TOKEN from output"
      }

      # ─── Step 8: Persist cluster-auth token to JSON sidecar ──────────
      $tokenDir = Split-Path -Parent $tokenFile
      New-Item -ItemType Directory -Force -Path $tokenDir | Out-Null
      $h = @{
        transit_addr     = "https://192.168.70.124:8200"
        transit_key_name = $keyName
        transit_token    = $transitToken
        rotated_at       = (Get-Date).ToUniversalTime().ToString('o')
      }
      ($h | ConvertTo-Json -Depth 4) | Set-Content -Path $tokenFile -Encoding UTF8
      icacls $tokenFile /inheritance:r /grant:r "$($env:USERNAME):F" 2>&1 | Out-Null
      Write-Host "[vault-transit] cluster-auth token persisted to $tokenFile (token length=$($transitToken.Length))"
    PWSH
  }
}
