/*
 * role-overlay-vault-swarm-secrets-seed.tf -- Phase 0.E.2 setup
 *
 * Seeds two KV paths under nexus/swarm/* that subsequent 0.E.2.1-3 sub-
 * phases consume:
 *
 *   - nexus/swarm/consul-gossip-key  (0.E.2.1)
 *       Single 32-byte symmetric key for Consul LAN gossip encryption.
 *       Generated server-side with `consul keygen` (vault-1 has consul
 *       binary baked? no -- generate via openssl rand -base64 32).
 *       Sticky one-time seed: never overwrite if a key already exists,
 *       so re-applies don't churn cluster keyrings.
 *
 *   - nexus/swarm/consul-bootstrap-token  (placeholder for 0.E.2.3)
 *       Empty placeholder written here so the KV path exists with a
 *       known shape. The 0.E.2.3 swarm-nomad-side overlay runs
 *       `consul acl bootstrap` on the leader after ACLs land + writes
 *       the resulting management token here. The placeholder value
 *       lets per-agent policies grant `read` on the path even before
 *       the real value is written, simplifying the role-binding flow.
 *
 * Sticky seed semantics mirror 0.D.4's `vault_foundation_seed`:
 *   read first; only write if absent OR field missing. Never overwrite
 *   populated values (operator might rotate by hand; we don't churn).
 *
 * Selective ops: var.enable_swarm_secrets_seed (default true).
 */

resource "null_resource" "vault_swarm_secrets_seed" {
  count = var.enable_vault_cluster && var.enable_vault_init && var.enable_swarm_secrets_seed ? 1 : 0

  triggers = {
    post_init_id   = null_resource.vault_post_init[0].id
    kv_mount_path  = var.vault_kv_mount_path
    secrets_seed_v = "1"
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

      if (-not (Test-Path $keysFile)) { throw "[swarm-seed] keys file $keysFile missing" }
      $rootToken = (Get-Content $keysFile | ConvertFrom-Json).root_token

      $bash = @"
set -euo pipefail
export VAULT_TOKEN='$rootToken'
export VAULT_SKIP_VERIFY=true
export VAULT_ADDR=https://127.0.0.1:8200

# ── Sticky seed: nexus/swarm/consul-gossip-key ─────────────────────────
EXISTING_KEY=`$(vault kv get -field=gossip_key -mount=$kvPath swarm/consul-gossip-key 2>/dev/null || true)
if [ -z "`$EXISTING_KEY" ]; then
  GOSSIP_KEY=`$(openssl rand -base64 32 | tr -d '\n')
  vault kv put -mount=$kvPath swarm/consul-gossip-key gossip_key="`$GOSSIP_KEY" >/dev/null
  echo "[swarm-seed] nexus/swarm/consul-gossip-key seeded (32-byte base64; first 8 chars: `$${GOSSIP_KEY:0:8}...)"
else
  echo "[swarm-seed] nexus/swarm/consul-gossip-key already populated (first 8: `$${EXISTING_KEY:0:8}...) -- preserving"
fi

# ── Sticky placeholder: nexus/swarm/consul-bootstrap-token ─────────────
# Empty placeholder so per-agent policies can grant read before 0.E.2.3
# actually runs `consul acl bootstrap`. The 0.E.2.3 swarm-nomad overlay
# writes the real management token to this path.
EXISTING_TOKEN=`$(vault kv get -field=management_token -mount=$kvPath swarm/consul-bootstrap-token 2>/dev/null || true)
if [ -z "`$EXISTING_TOKEN" ]; then
  vault kv put -mount=$kvPath swarm/consul-bootstrap-token management_token="" status="not-bootstrapped" >/dev/null
  echo "[swarm-seed] nexus/swarm/consul-bootstrap-token placeholder seeded (status=not-bootstrapped)"
else
  echo "[swarm-seed] nexus/swarm/consul-bootstrap-token already populated -- preserving"
fi

echo "[swarm-seed] complete"
"@

      $bytes = [System.Text.UTF8Encoding]::new($false).GetBytes($bash)
      $b64   = [Convert]::ToBase64String($bytes)

      Write-Host "[swarm-seed] dispatching to $${ip} via base64"
      $output = ssh -o ConnectTimeout=30 -o BatchMode=yes -o StrictHostKeyChecking=no $user@$ip "echo '$b64' | base64 -d | bash" 2>&1 | Out-String
      $rc = $LASTEXITCODE
      Write-Host $output.Trim()
      if ($rc -ne 0) {
        throw "[swarm-seed] script failed (rc=$rc)"
      }
    PWSH
  }
}
