/*
 * role-overlay-vault-cluster-seal-config.tf -- Phase 0.D.5.5 step 2/2 (security)
 *
 * Delivers /etc/vault.d/seal-transit.hcl to vault-1/2/3 BEFORE the
 * cluster is initialized. The Packer template's vault.service is now
 * launched with `-config=/etc/vault.d/` (directory mode), which merges
 * vault.hcl + any seal-transit.hcl drop-in. With seal-transit.hcl
 * present, vault server runs in transit-seal mode and auto-unseals at
 * boot via vault-transit.
 *
 * Order:
 *   vault_ready_probe -> vault_transit_bringup (parallel) ->
 *   vault_cluster_seal_config -> vault_init_leader (recovery-keys mode) ->
 *   vault_join_followers (no manual unseal needed)
 *
 * Idempotency: hash-compare existing seal-transit.hcl content. Overwrite
 * + restart vault.service only when content differs (token rotation,
 * transit endpoint change).
 *
 * The seal-transit.hcl token grants transit/encrypt + transit/decrypt on
 * `transit/keys/nexus-cluster-unseal` only -- nothing else. Compromising
 * a cluster node yields no other Vault access.
 *
 * Selective ops: enable_vault_transit_unseal (master) AND
 *                enable_vault_cluster_seal_config.
 */

resource "null_resource" "vault_cluster_seal_config" {
  count = var.enable_vault_cluster && var.enable_vault_init && var.enable_vault_transit_unseal && var.enable_vault_cluster_seal_config ? 1 : 0

  triggers = {
    ready_id           = null_resource.vault_ready_probe[0].id
    transit_bringup_id = length(null_resource.vault_transit_bringup) > 0 ? null_resource.vault_transit_bringup[0].id : "disabled"
    transit_token_file = var.vault_transit_token_file
    transit_key_name   = var.vault_transit_key_name
    seal_overlay_v     = "1"
  }

  depends_on = [null_resource.vault_ready_probe, null_resource.vault_transit_bringup]

  provisioner "local-exec" {
    when        = create
    interpreter = ["pwsh", "-NoProfile", "-Command"]
    command     = <<-PWSH
      $user                = '${local.ssh_user}'
      $tokenFileRaw        = '${var.vault_transit_token_file}'
      $tokenFile           = $ExecutionContext.InvokeCommand.ExpandString($tokenFileRaw.Replace('$HOME', $env:USERPROFILE))
      $cluster_ips = @('${local.vault_1_ip}', '${local.vault_2_ip}', '${local.vault_3_ip}')

      if (-not (Test-Path $tokenFile)) {
        throw "[seal-config] $tokenFile missing -- vault_transit_bringup didn't run? Apply security env from scratch (greenfield)."
      }
      $transit = Get-Content $tokenFile -Raw | ConvertFrom-Json

      # The seal-transit.hcl drop-in. vault server merges this with
      # vault.hcl from the same directory. tls_skip_verify=true is
      # acceptable here because vault-transit's listener cert is the
      # 0.D.1 self-signed bootstrap (Phase 0.D.2 PKI rotates LATER, after
      # transit is up and providing seal). The risk: a compromised
      # network attacker sitting between cluster nodes and vault-transit
      # could MITM the unseal call. Acceptable for a lab where the lab
      # network is trusted; production would issue vault-transit's cert
      # from PKI before the cluster's first init.
      $sealHcl = @"
seal "transit" {
  address         = "$($transit.transit_addr)"
  token           = "$($transit.transit_token)"
  disable_renewal = "false"
  key_name        = "$($transit.transit_key_name)"
  mount_path      = "transit/"
  tls_skip_verify = "true"
}
"@

      $sealB64 = [Convert]::ToBase64String([System.Text.UTF8Encoding]::new($false).GetBytes($sealHcl))

      foreach ($ip in $cluster_ips) {
        Write-Host "[seal-config] $ip : delivering seal-transit.hcl + restarting vault.service"

        # Bash on the remote: write the file (root:vault 640), restart
        # vault.service. The service's config-directory ExecStart picks
        # up the new file on next start.
        $bash = @"
set -euo pipefail
TMP=`$(mktemp)
trap 'rm -f "`$TMP"' EXIT
echo '$sealB64' | base64 -d > "`$TMP"

# Hash-compare against existing -- skip restart if unchanged
EXISTING_HASH=`$(sudo sha256sum /etc/vault.d/seal-transit.hcl 2>/dev/null | awk '{print `$1}' || echo none)
NEW_HASH=`$(sha256sum "`$TMP" | awk '{print `$1}')

if [ "`$EXISTING_HASH" = "`$NEW_HASH" ]; then
  echo '[seal-config] seal-transit.hcl unchanged, skipping restart'
else
  sudo install -m 640 -o root -g vault "`$TMP" /etc/vault.d/seal-transit.hcl
  echo "[seal-config] wrote /etc/vault.d/seal-transit.hcl (hash $${NEW_HASH:0:12})"
  sudo systemctl restart vault.service
  echo '[seal-config] vault.service restarted'
fi
"@
        $bashB64 = [Convert]::ToBase64String([System.Text.UTF8Encoding]::new($false).GetBytes($bash))
        $output = ssh -o ConnectTimeout=30 -o BatchMode=yes -o StrictHostKeyChecking=no $user@$ip "echo '$bashB64' | base64 -d | bash" 2>&1 | Out-String
        if ($LASTEXITCODE -ne 0) {
          throw "[seal-config] $ip failed (rc=$LASTEXITCODE). Output:`n$output"
        }
        Write-Host $output.Trim()
      }

      # Settle time: vault.service restart + transit-seal handshake
      Write-Host "[seal-config] sleeping 10s for vault.service to settle on each node..."
      Start-Sleep -Seconds 10
      Write-Host "[seal-config] complete -- vault-1/2/3 now run with transit-seal mode"
    PWSH
  }
}
