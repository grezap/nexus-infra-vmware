/*
 * role-overlay-gateway-nfs-portainer.tf -- Phase 0.E.4a setup
 *
 * Stands up an NFSv4-only export on nexus-gateway for Portainer CE's `/data`
 * directory. Portainer CE has no native HA -- a single Server replica runs
 * at a time -- but Swarm reschedules the replica on a different manager
 * if the current one fails. Without shared storage that reschedule means
 * total state loss (BoltDB gone, all stack/endpoint metadata reset). NFS
 * fixes that: all 3 managers see the same /data via the gateway.
 *
 * Why nexus-gateway as the NFS server (not a dedicated VM):
 *   - Gateway already plays infra-host role (dnsmasq + nftables + chrony +
 *     node_exporter); adding nfs-kernel-server doesn't compromise its
 *     purpose.
 *   - No new VM = no new tier in vms.yaml = lower portfolio churn.
 *   - Production would split this onto a dedicated NFS appliance (NetApp,
 *     TrueNAS, etc.) -- documented as a deviation; canonical pattern is
 *     "the lab consolidates state services on the edge router."
 *
 * NFSv4-only (no portmapper/rpcbind/mountd/lockd dynamic ports):
 *   - Single TCP/2049 listener; firewall rules are simple + auditable.
 *   - `vers=4.2` on the client side; default mount options work.
 *   - `fsid=0` on the export makes NFSv4's pseudo-root match the export
 *     path so the client mounts via `:/srv/nfs/portainer-data` (Linux
 *     auto-resolves `:/path` against the pseudo-root).
 *
 * Choreography (single PWSH local-exec):
 *   Stage 1: apt install nfs-kernel-server (idempotent; skip if already
 *     installed at expected version).
 *   Stage 2: mkdir /srv/nfs/portainer-data (root:root 0755).
 *   Stage 3: drop /etc/exports.d/portainer.exports with the manager IPs
 *     (per `var.portainer_nfs_allowed_clients`); chown root:root 0644.
 *   Stage 4: patch /etc/nftables.conf in-place to add inbound TCP/2049
 *     accept rule from manager IPs on nic1 (per memory feedback_nftables
 *     _runtime_add_after_drop.md -- runtime `nft add rule` lands at chain
 *     end AFTER the counter-drop, so the rule is unreachable; in-place
 *     patch + `nft -f /etc/nftables.conf` for atomic ruleset reload IS
 *     persistent).
 *   Stage 5: enable + start nfs-kernel-server; exportfs -ra; verify
 *     `exportfs -v` lists the export + `ss -tlnp | grep ':2049'` shows
 *     a listener.
 *
 * Idempotency:
 *   - Stage 1: apt-get install is no-op if package present at any version.
 *   - Stage 2: mkdir -p is idempotent.
 *   - Stage 3: file write is content-stable.
 *   - Stage 4: grep marker comment in /etc/nftables.conf -> skip if
 *     already patched. Re-applies don't duplicate the rule.
 *   - Stage 5: systemctl enable is idempotent; exportfs -ra is idempotent.
 *
 * Selective ops: var.enable_gateway_nfs_portainer (default true).
 *
 * Reachability invariant (per memory/feedback_lab_host_reachability.md):
 *   The gateway's existing SSH:22 + DNS:53 + DHCP:67 rules from the
 *   Packer-baked /etc/nftables.conf are PRESERVED -- our patch only ADDS
 *   the new 2049/tcp rule between two existing accept lines. Build-host
 *   SSH access is unaffected.
 */

resource "null_resource" "gateway_nfs_portainer" {
  count = var.enable_gateway_nfs_portainer ? 1 : 0

  triggers = {
    gateway_ip      = "192.168.70.1"
    export_path     = var.portainer_nfs_export_path
    allowed_clients = var.portainer_nfs_allowed_clients
    overlay_v       = "2" # v2 = mkdir /etc/exports.d before writing portainer.exports (the directory is not created by the nfs-kernel-server package on Debian 13; first apply hit `tee: /etc/exports.d/portainer.exports: No such file or directory`). v1 = original (NFSv4-only export on nexus-gateway; in-place /etc/nftables.conf patch for 2049/tcp from manager IPs).
  }

  provisioner "local-exec" {
    when        = create
    interpreter = ["pwsh", "-NoProfile", "-Command"]
    command     = <<-PWSH
      $gw         = '192.168.70.1'
      $sshUser    = 'nexusadmin'
      $sshOpts    = @('-o','ConnectTimeout=10','-o','BatchMode=yes','-o','StrictHostKeyChecking=no')
      $exportPath = '${var.portainer_nfs_export_path}'
      $clients    = '${var.portainer_nfs_allowed_clients}'

      # Bash script body. Single-quoted here-string -- no PS interpolation;
      # we substitute terraform-side values via simple -replace below.
      # Mirrors role-overlay-nomad-tls.tf placeholder pattern.
      $bashTmpl = @'
set -euo pipefail
EXPORT_PATH='__EXPORT_PATH__'
ALLOWED_CLIENTS='__ALLOWED_CLIENTS__'

# ── Stage 1: install nfs-kernel-server (idempotent) ────────────────────
if ! dpkg -s nfs-kernel-server >/dev/null 2>&1; then
  echo '[gw-nfs] installing nfs-kernel-server'
  sudo DEBIAN_FRONTEND=noninteractive apt-get update -qq
  sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq nfs-kernel-server
else
  echo '[gw-nfs] nfs-kernel-server already installed'
fi

# Disable NFSv2/v3 explicitly (NFSv4-only). Drop a defaults override.
if ! grep -q 'RPCNFSDOPTS=.*-N 2 -N 3' /etc/default/nfs-kernel-server 2>/dev/null; then
  echo '[gw-nfs] forcing NFSv4-only mode'
  echo 'RPCNFSDOPTS="-N 2 -N 3"' | sudo tee -a /etc/default/nfs-kernel-server > /dev/null
fi

# ── Stage 2: export root directory ─────────────────────────────────────
sudo mkdir -p "$EXPORT_PATH"
sudo chown root:root "$EXPORT_PATH"
sudo chmod 0755 "$EXPORT_PATH"

# ── Stage 3: build per-client export lines + write exports file ───────
EXPORTS=''
IFS=',' read -ra CLIENT_LIST <<< "$ALLOWED_CLIENTS"
for client in "$${CLIENT_LIST[@]}"; do
  client=$(echo "$client" | tr -d ' ')
  EXPORTS="$${EXPORTS}$${EXPORT_PATH}  $${client}(rw,sync,no_root_squash,no_subtree_check,fsid=0)
"
done

# /etc/exports.d/ is not created by the nfs-kernel-server package on
# Debian 13 -- mkdir it before writing.
sudo mkdir -p /etc/exports.d
sudo chmod 0755 /etc/exports.d

# Render final exports file via printf (preserves embedded newlines).
{
  echo '# /etc/exports.d/portainer.exports -- managed by terraform/envs/foundation/role-overlay-gateway-nfs-portainer.tf'
  echo "# NFSv4-only export of $EXPORT_PATH for the swarm managers (Portainer CE shared /data)."
  echo '# fsid=0 makes this path the NFSv4 pseudo-root.'
  printf '%s' "$EXPORTS"
} | sudo tee /etc/exports.d/portainer.exports > /dev/null
sudo chown root:root /etc/exports.d/portainer.exports
sudo chmod 0644 /etc/exports.d/portainer.exports

# ── Stage 4: patch /etc/nftables.conf in-place (add 2049 rule before drop) ─
# Idempotent: check for marker comment first.
MARKER='# portainer NFSv4 access (managed by terraform/envs/foundation)'
if ! grep -qF "$MARKER" /etc/nftables.conf; then
  echo '[gw-nfs] patching /etc/nftables.conf to allow tcp/2049 from managers'

  # Build per-client nftables accept rules.
  NFT_RULES=''
  for client in "$${CLIENT_LIST[@]}"; do
    client=$(echo "$client" | tr -d ' ')
    NFT_RULES="$${NFT_RULES}        iifname \"nic1\" ip saddr $${client} tcp dport 2049 accept comment \"NFSv4 from $${client} (portainer)\"
"
  done

  # Insert the rules just before the `counter drop` line in the input chain.
  # The marker comment goes immediately before so we can detect on re-apply.
  sudo cp /etc/nftables.conf /etc/nftables.conf.bak.portainer
  sudo awk -v marker="$MARKER" -v rules="$NFT_RULES" '
    /^[[:space:]]*counter drop[[:space:]]*$/ && !inserted {
      print "        " marker
      printf "%s", rules
      print ""
      inserted = 1
    }
    { print }
  ' /etc/nftables.conf.bak.portainer | sudo tee /etc/nftables.conf > /dev/null

  # Atomic ruleset reload (per memory feedback_nftables_runtime_add_after_drop.md).
  sudo nft -f /etc/nftables.conf
  echo '[gw-nfs] nftables ruleset reloaded'
else
  echo '[gw-nfs] /etc/nftables.conf already patched (idempotent skip)'
fi

# ── Stage 5: enable + start NFS server ─────────────────────────────────
sudo systemctl enable nfs-kernel-server >/dev/null 2>&1 || true
sudo systemctl restart nfs-kernel-server
sudo exportfs -ra
sleep 2

# ── Verify ─────────────────────────────────────────────────────────────
echo '--- nfs-kernel-server status ---'
sudo systemctl is-active nfs-kernel-server
echo '--- exportfs -v ---'
sudo exportfs -v
echo '--- :2049 listener ---'
sudo ss -tlnp 2>/dev/null | grep -E ':2049 ' || (echo 'NO_2049_LISTENER' >&2; exit 1)
echo '--- nftables input chain (portainer rules) ---'
sudo nft list chain inet filter input | grep -E '2049|portainer' || true
echo '[gw-nfs] OK'
'@

      $bash = $bashTmpl `
        -replace '__EXPORT_PATH__', $exportPath `
        -replace '__ALLOWED_CLIENTS__', $clients
      $bashLf = $bash -replace "`r`n", "`n"
      $bashB64 = [Convert]::ToBase64String([System.Text.UTF8Encoding]::new($false).GetBytes($bashLf))

      $output = ssh @sshOpts "$sshUser@$gw" "echo '$bashB64' | base64 -d | bash" 2>&1 | Out-String
      $rc = $LASTEXITCODE
      Write-Host $output.Trim()
      if ($rc -ne 0) {
        throw "[gateway-nfs-portainer] script failed (rc=$rc)"
      }
    PWSH
  }

  # Destroy: stop the NFS server, remove the export file, revert nftables
  # patch via the .bak.portainer backup. Keeps the directory + data on
  # disk (operator must rm -rf manually if desired).
  provisioner "local-exec" {
    when        = destroy
    interpreter = ["pwsh", "-NoProfile", "-Command"]
    command     = <<-PWSH
      $gw      = '192.168.70.1'
      $sshUser = 'nexusadmin'
      $sshOpts = @('-o','ConnectTimeout=5','-o','BatchMode=yes','-o','StrictHostKeyChecking=no')

      $cleanup = @'
set -euo pipefail
echo '[gw-nfs destroy] stopping nfs-kernel-server + removing export'
sudo systemctl disable --now nfs-kernel-server 2>/dev/null || true
sudo rm -f /etc/exports.d/portainer.exports
if [ -f /etc/nftables.conf.bak.portainer ]; then
  sudo cp /etc/nftables.conf.bak.portainer /etc/nftables.conf
  sudo nft -f /etc/nftables.conf
  sudo rm -f /etc/nftables.conf.bak.portainer
  echo '[gw-nfs destroy] reverted /etc/nftables.conf from .bak.portainer'
fi
'@
      $b64 = [Convert]::ToBase64String([System.Text.UTF8Encoding]::new($false).GetBytes(($cleanup -replace "`r`n", "`n")))
      ssh @sshOpts "$sshUser@$gw" "echo '$b64' | base64 -d | bash" 2>$null
      exit 0
    PWSH
  }
}
