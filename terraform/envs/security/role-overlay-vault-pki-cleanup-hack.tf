/*
 * role-overlay-vault-pki-cleanup-hack.tf -- Phase 0.D.2 step 7/7
 *
 * Remove the per-clone /usr/local/share/ca-certificates/vault-leader.crt
 * residue from followers (vault-2, vault-3). This file was installed
 * during 0.D.1's raft join cold-start (see role-overlay-vault-cluster.tf
 * vault_join_followers, the "fetch leader cert + install in system trust
 * store" block) because PKI didn't exist yet at that moment so each
 * follower needed the leader's per-clone self-signed cert as a trust
 * anchor.
 *
 * After step 6 (distribute) installed the shared PKI root CA in every
 * node's trust store, the per-clone cert is redundant and should be
 * pruned -- otherwise a future clone replacement would re-trust an old
 * stale cert. vault-1 never had this file (it's the leader, never a
 * follower joining anyone), so we only clean vault-2 + vault-3.
 *
 * Idempotency: file existence check; if not present, no-op.
 *
 * Why we don't fix the join step itself: the cold-start trust shuffle
 * is structurally needed (chicken-and-egg -- PKI requires cluster up;
 * cluster up requires followers trusting leader; first cluster bring-up
 * predates PKI). The clean approach is to leave the cold-start path
 * unchanged and have this overlay retire the residue post-PKI. A future
 * 0.D.5+ refactor could move PKI bootstrap earlier (e.g. a minimal
 * Packer-baked CA), at which point the join shuffle goes away too.
 *
 * Selective ops: var.enable_vault_pki AND var.enable_vault_pki_cleanup_legacy_trust.
 */

resource "null_resource" "vault_pki_cleanup_legacy_trust" {
  count = var.enable_vault_cluster && var.enable_vault_init && var.enable_vault_pki && var.enable_vault_pki_cleanup_legacy_trust ? 1 : 0

  triggers = {
    distribute_id     = length(null_resource.vault_pki_distribute_root) > 0 ? null_resource.vault_pki_distribute_root[0].id : "disabled"
    cleanup_overlay_v = "1"
  }

  depends_on = [null_resource.vault_pki_distribute_root]

  provisioner "local-exec" {
    when        = create
    interpreter = ["pwsh", "-NoProfile", "-Command"]
    command     = <<-PWSH
      $user      = '${local.ssh_user}'
      $followers = @('${local.vault_2_ip}', '${local.vault_3_ip}')

      foreach ($ip in $followers) {
        Write-Host "[pki-cleanup] $${ip}: probing for legacy /usr/local/share/ca-certificates/vault-leader.crt"

        $bash = @'
set -euo pipefail
LEGACY=/usr/local/share/ca-certificates/vault-leader.crt
if sudo test -f "$LEGACY"; then
  echo "[pki-cleanup] removing legacy trust anchor $LEGACY"
  sudo rm -f "$LEGACY"
  # update-ca-certificates --fresh rebuilds /etc/ssl/certs/ca-certificates.crt
  # cleanly (drops the deleted entry) and is the canonical post-removal step.
  sudo update-ca-certificates --fresh 2>&1 | tail -3
  echo "[pki-cleanup] legacy trust anchor pruned"
else
  echo "[pki-cleanup] no legacy trust anchor present, skipping"
fi
'@
        $bytes = [System.Text.UTF8Encoding]::new($false).GetBytes($bash)
        $b64   = [Convert]::ToBase64String($bytes)
        $output = ssh -o ConnectTimeout=30 -o BatchMode=yes -o StrictHostKeyChecking=no $user@$ip "echo '$b64' | base64 -d | bash" 2>&1 | Out-String
        $rc = $LASTEXITCODE
        Write-Host $output.Trim()
        if ($rc -ne 0) {
          throw "[pki-cleanup] $${ip}: cleanup script failed (rc=$rc)"
        }
      }

      Write-Host "[pki-cleanup] legacy per-clone trust anchors retired on followers; PKI shared root is the sole trust anchor"
    PWSH
  }
}
