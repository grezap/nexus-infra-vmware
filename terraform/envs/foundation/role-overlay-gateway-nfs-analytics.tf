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
 * fsid COEXISTENCE NOTE: the Portainer export already holds fsid=0 (the NFSv4
 * pseudo-root) on /srv/nfs/portainer-data. This analytics export uses fsid=1
 * and is mounted client-side via its real path (192.168.70.1:/srv/nfs/
 * analytics-backups, vers=4.2). On modern nfsd an export with an explicit
 * non-zero fsid is individually mountable; if the single-pseudo-root semantics
 * block this sibling at live ratification, the documented fix is to migrate the
 * gateway pseudo-root to /srv/nfs (export /srv/nfs fsid=0 crossmnt with both
 * portainer-data + analytics-backups as subdirs). Chronicled in handbook §3.x.
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
    overlay_v       = "1"
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

# Stage 3: per-client export lines (fsid=1 -- portainer holds fsid=0).
EXPORTS=''
IFS=',' read -ra CLIENT_LIST <<< "$ALLOWED_CLIENTS"
for client in "$${CLIENT_LIST[@]}"; do
  client=$(echo "$client" | tr -d ' ')
  EXPORTS="$${EXPORTS}$${EXPORT_PATH}  $${client}(rw,sync,no_root_squash,no_subtree_check,fsid=1)
"
done
sudo mkdir -p /etc/exports.d
sudo chmod 0755 /etc/exports.d
{
  echo '# /etc/exports.d/analytics.exports -- managed by terraform/envs/foundation/role-overlay-gateway-nfs-analytics.tf'
  echo "# NFSv4 export of $EXPORT_PATH for the analytics data nodes (backup repository, ADR-0032)."
  echo '# fsid=1 (portainer holds fsid=0 / the pseudo-root).'
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
