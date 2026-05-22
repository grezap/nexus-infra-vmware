/*
 * role-overlay-gateway-nfs-analytics.tf -- Phase 0.G.5 setup (ADR-0032)
 *
 * Stands up an NFS export on nexus-gateway for the analytics backup repository
 * (ClickHouse BACKUP/RESTORE + StarRocks BACKUP/RESTORE SNAPSHOT). MinIO/S3 is
 * deferred to Phase 0.L; until then the gateway is the lab's NFS server (same
 * pattern as the Portainer export, role-overlay-gateway-nfs-portainer.tf).
 *
 * Export: /srv/nfs/analytics-backups, rw, the 6 ClickHouse data-node IPs (the
 * StarRocks BE IPs are added at 0.G.6 via var.analytics_nfs_allowed_clients).
 *
 * fsid COEXISTENCE NOTE (settled at live ratification -- handbook §3.x transient):
 * the Portainer export holds fsid=0 (NFSv4 pseudo-root) on /srv/nfs/portainer-
 * data for clients .111-.113. An explicit fsid=0 anywhere DISABLES knfsd's
 * automatic v4 pseudo-fs server-wide, so a sibling fsid=1 export is unreachable
 * (mount -> "No such file or directory"). The fix that does NOT touch the live
 * portainer pseudo-root: give THIS export its own fsid=0 for the analytics
 * client set (.31-.36/.44-.49), which is disjoint from portainer's -- each
 * client matches exactly one export, so each set gets its own pseudo-root with
 * no fsid conflict. Analytics clients therefore mount via 192.168.70.1:/ (no
 * path), exactly as the portainer clients do (feedback_nfsv4_fsid0_pseudo_root).
 *
 * The export forces NFSv4-only (parity with the portainer export's
 * RPCNFSDOPTS="-N 2 -N 3"); the in-place /etc/nftables.conf patch adds tcp/2049
 * accept from the analytics IPs (per memory/feedback_nftables_runtime_add_after_drop.md).
 *
 * Selective ops: var.enable_gateway_nfs_analytics (default true).
 */

resource "null_resource" "gateway_nfs_analytics" {
  count = var.enable_gateway_nfs_analytics ? 1 : 0

  triggers = {
    gateway_ip      = "192.168.70.1"
    export_path     = var.analytics_nfs_export_path
    allowed_clients = var.analytics_nfs_allowed_clients
    overlay_v       = "2" # v2: export uses fsid=0 (own pseudo-root for the disjoint analytics client set); clients mount via :/ -- the fsid=1 sibling was unreachable because portainer's fsid=0 disables knfsd auto pseudo-fs server-wide.
  }

  provisioner "local-exec" {
    when        = create
    interpreter = ["pwsh", "-NoProfile", "-Command"]
    command     = <<-PWSH
      $gw         = '192.168.70.1'
      $sshUser    = 'nexusadmin'
      $sshOpts    = @('-o','ConnectTimeout=10','-o','BatchMode=yes','-o','StrictHostKeyChecking=no')
      $exportPath = '${var.analytics_nfs_export_path}'
      $clients    = '${var.analytics_nfs_allowed_clients}'

      $bashTmpl = @'
set -euo pipefail
EXPORT_PATH='__EXPORT_PATH__'
ALLOWED_CLIENTS='__ALLOWED_CLIENTS__'

# Stage 1: ensure nfs-kernel-server installed (likely already, from portainer).
if ! dpkg -s nfs-kernel-server >/dev/null 2>&1; then
  echo '[gw-nfs-analytics] installing nfs-kernel-server'
  sudo DEBIAN_FRONTEND=noninteractive apt-get update -qq
  sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq nfs-kernel-server
else
  echo '[gw-nfs-analytics] nfs-kernel-server already installed'
fi

# Stage 2: export directory.
sudo mkdir -p "$EXPORT_PATH"
sudo chown root:root "$EXPORT_PATH"
sudo chmod 0777 "$EXPORT_PATH"   # backup writers run as the clickhouse/starrocks uid on the clients; world-writable keeps the lab simple (no uid mapping). Tighten with idmap in production.

# Stage 3: per-client export lines. fsid=0 makes THIS export the NFSv4 pseudo-
# root for the analytics client set. The portainer export also uses fsid=0 but
# for a DISJOINT client set (.111-.113); since a client only ever matches one
# export, each client set gets its own pseudo-root and they never conflict. An
# explicit fsid=0 anywhere on the server disables knfsd's auto pseudo-fs, so a
# sibling fsid=1 export is NOT reachable (mount -> ENOENT) -- the analytics
# clients therefore need their own fsid=0 and mount via ':/' (no path).
EXPORTS=''
IFS=',' read -ra CLIENT_LIST <<< "$ALLOWED_CLIENTS"
for client in "$${CLIENT_LIST[@]}"; do
  client=$(echo "$client" | tr -d ' ')
  EXPORTS="$${EXPORTS}$${EXPORT_PATH}  $${client}(rw,sync,no_root_squash,no_subtree_check,fsid=0)
"
done
sudo mkdir -p /etc/exports.d
sudo chmod 0755 /etc/exports.d
{
  echo '# /etc/exports.d/analytics.exports -- managed by terraform/envs/foundation/role-overlay-gateway-nfs-analytics.tf'
  echo "# NFSv4 export of $EXPORT_PATH for the analytics data nodes (backup repository, ADR-0032)."
  echo '# fsid=0 = per-client-set NFSv4 pseudo-root (disjoint from portainer fsid=0); clients mount via :/'
  printf '%s' "$EXPORTS"
} | sudo tee /etc/exports.d/analytics.exports > /dev/null
sudo chown root:root /etc/exports.d/analytics.exports
sudo chmod 0644 /etc/exports.d/analytics.exports

# Stage 4: patch /etc/nftables.conf in-place (add 2049 from analytics IPs).
MARKER='# analytics NFSv4 access (managed by terraform/envs/foundation)'
if ! grep -qF "$MARKER" /etc/nftables.conf; then
  echo '[gw-nfs-analytics] patching /etc/nftables.conf to allow tcp/2049 from analytics nodes'
  NFT_RULES=''
  for client in "$${CLIENT_LIST[@]}"; do
    client=$(echo "$client" | tr -d ' ')
    NFT_RULES="$${NFT_RULES}        iifname \"nic1\" ip saddr $${client} tcp dport 2049 accept comment \"NFSv4 from $${client} (analytics)\"
"
  done
  sudo cp /etc/nftables.conf /etc/nftables.conf.bak.analytics
  sudo awk -v marker="$MARKER" -v rules="$NFT_RULES" '
    /^[[:space:]]*counter drop[[:space:]]*$/ && !inserted {
      print "        " marker
      printf "%s", rules
      print ""
      inserted = 1
    }
    { print }
  ' /etc/nftables.conf.bak.analytics | sudo tee /etc/nftables.conf > /dev/null
  sudo nft -f /etc/nftables.conf
  echo '[gw-nfs-analytics] nftables ruleset reloaded'
else
  echo '[gw-nfs-analytics] /etc/nftables.conf already patched (idempotent skip)'
fi

# Stage 5: enable + reload exports.
sudo systemctl enable nfs-kernel-server >/dev/null 2>&1 || true
sudo systemctl restart nfs-kernel-server
sudo exportfs -ra
sleep 2

echo '--- exportfs -v (analytics) ---'
sudo exportfs -v | grep -F "$EXPORT_PATH" || (echo 'NO_ANALYTICS_EXPORT' >&2; exit 1)
echo '--- :2049 listener ---'
sudo ss -tlnp 2>/dev/null | grep -E ':2049 ' || (echo 'NO_2049_LISTENER' >&2; exit 1)
echo '[gw-nfs-analytics] OK'
'@

      $bash = $bashTmpl `
        -replace '__EXPORT_PATH__', $exportPath `
        -replace '__ALLOWED_CLIENTS__', $clients
      $bashLf  = $bash -replace "`r`n", "`n"
      $bashB64 = [Convert]::ToBase64String([System.Text.UTF8Encoding]::new($false).GetBytes($bashLf))

      $output = ssh @sshOpts "$sshUser@$gw" "echo '$bashB64' | base64 -d | bash" 2>&1 | Out-String
      $rc = $LASTEXITCODE
      Write-Host $output.Trim()
      if ($rc -ne 0) { throw "[gateway-nfs-analytics] script failed (rc=$rc)" }
    PWSH
  }

  provisioner "local-exec" {
    when        = destroy
    interpreter = ["pwsh", "-NoProfile", "-Command"]
    command     = <<-PWSH
      $gw      = '192.168.70.1'
      $sshUser = 'nexusadmin'
      $sshOpts = @('-o','ConnectTimeout=5','-o','BatchMode=yes','-o','StrictHostKeyChecking=no')
      $cleanup = @'
set -euo pipefail
echo '[gw-nfs-analytics destroy] removing analytics export'
sudo rm -f /etc/exports.d/analytics.exports
sudo exportfs -ra 2>/dev/null || true
if [ -f /etc/nftables.conf.bak.analytics ]; then
  sudo cp /etc/nftables.conf.bak.analytics /etc/nftables.conf
  sudo nft -f /etc/nftables.conf
  sudo rm -f /etc/nftables.conf.bak.analytics
  echo '[gw-nfs-analytics destroy] reverted /etc/nftables.conf from .bak.analytics'
fi
'@
      $b64 = [Convert]::ToBase64String([System.Text.UTF8Encoding]::new($false).GetBytes(($cleanup -replace "`r`n", "`n")))
      ssh @sshOpts "$sshUser@$gw" "echo '$b64' | base64 -d | bash" 2>$null
      exit 0
    PWSH
  }
}
