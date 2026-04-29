#!/bin/bash
# vault-firstboot.sh — runs once at first boot per Vault clone.
#
# Responsibilities:
#   1. Discover the VMnet11 IP (DHCP-assigned via gateway dhcp-host MAC
#      reservation), map to canonical hostname + VMnet10 IP per
#      nexus-platform-plan/docs/infra/vms.yaml (vault-1=.121, etc.)
#   2. Set /etc/hostname to the canonical name via hostnamectl
#   3. Identify the secondary NIC (the one that's NOT nic0), rename it to
#      nic1 via systemd .link drop-in, assign the static VMnet10 IP
#   4. Generate fresh self-signed TLS cert per-clone with the clone's
#      actual hostname + IPs in SAN (Vault PKI in Phase 0.D.2 reissues)
#   5. Render /etc/vault.d/vault.hcl from vault.hcl.tpl, substituting
#      @HOSTNAME@, @VMNET11_IP@, @VMNET10_IP@
#   6. Mark complete (idempotent re-run guard)
#
# CRITICAL DESIGN: identifies clone by its DHCP-acquired VMnet11 IP, NOT
# by /etc/hostname. The Packer template bakes hostname=vault (template
# name); `vmrun clone -cloneName=vault-N` only changes the Workstation
# display name, NOT the guest's /etc/hostname. The dnsmasq dhcp-host MAC
# reservations on nexus-gateway pin each clone's MAC to canonical
# .121/.122/.123 -- making the VMnet11 IP the reliable per-clone
# discriminator. Discovered 2026-04-30 during 0.D.1 first cycle.
#
# Idempotent: marker file at /var/lib/vault-firstboot-done short-circuits
# re-runs. Removing the marker forces re-run on next boot (useful when
# IP scheme changes or TLS cert needs regenerating).

set -euo pipefail

MARKER=/var/lib/vault-firstboot-done
LOG_PREFIX="[vault-firstboot]"

if [ -f "$MARKER" ]; then
  echo "$LOG_PREFIX already done, skipping (remove $MARKER to force re-run)"
  exit 0
fi

# ─── 1. Wait for nic0 to have its DHCP-assigned IP ─────────────────────────
# vault-firstboot.service has After=systemd-networkd-wait-online.service so
# nic0 should be configured before we run, but defensively retry in case
# of races. If after 25 sec we still don't have an IP, DHCP genuinely failed
# (gateway down, dhcp-host reservation missing, etc.).
VMNET11_IP=""
for i in 1 2 3 4 5; do
  VMNET11_IP=$(ip -4 -o addr show nic0 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -1)
  [ -n "$VMNET11_IP" ] && break
  echo "$LOG_PREFIX waiting for nic0 IPv4 (attempt $i/5)..."
  sleep 5
done

if [ -z "$VMNET11_IP" ]; then
  echo "$LOG_PREFIX ERROR: nic0 has no IPv4 address after 25s -- DHCP failed?" >&2
  exit 1
fi
echo "$LOG_PREFIX nic0 (VMnet11) IP: $VMNET11_IP"

# ─── 2. Map VMnet11 IP -> canonical hostname + VMnet10 IP ──────────────────
# Authoritative source: nexus-platform-plan/docs/infra/vms.yaml lines 55-57.
# IP -> hostname mapping is canonical because the dhcp-host MAC reservations
# on nexus-gateway are themselves canonical.
case "$VMNET11_IP" in
  192.168.70.121) HOSTNAME=vault-1; VMNET10_IP=192.168.10.121 ;;
  192.168.70.122) HOSTNAME=vault-2; VMNET10_IP=192.168.10.122 ;;
  192.168.70.123) HOSTNAME=vault-3; VMNET10_IP=192.168.10.123 ;;
  *)
    echo "$LOG_PREFIX ERROR: unknown VMnet11 IP '$VMNET11_IP' (expected .121/.122/.123 per vms.yaml + gateway dhcp-host reservations)" >&2
    exit 1
    ;;
esac
echo "$LOG_PREFIX mapped: hostname=$HOSTNAME VMnet10 (backplane) IP=$VMNET10_IP/24"

# ─── 3. Set the system hostname to the canonical name ─────────────────────
# Packer template bakes hostname=vault (template name). We replace it with
# the canonical per-clone name so subsequent operator SSH, vault.hcl's
# node_id, and journalctl/syslog all show the right identifier.
CURRENT_HOSTNAME=$(cat /etc/hostname 2>/dev/null || echo '')
if [ "$CURRENT_HOSTNAME" != "$HOSTNAME" ]; then
  echo "$LOG_PREFIX renaming hostname: '$CURRENT_HOSTNAME' -> '$HOSTNAME'"
  hostnamectl set-hostname "$HOSTNAME"
else
  echo "$LOG_PREFIX hostname already '$HOSTNAME', no rename needed"
fi

# ─── 4. Identify + rename + configure the secondary NIC (VMnet10) ─────────
# nic0 is renamed by nexus_network's role's 10-nic0.link (matches en*).
# nic1 is whatever ethernet device exists with a different MAC.
NIC0_MAC=$(cat /sys/class/net/nic0/address 2>/dev/null || true)
if [ -z "$NIC0_MAC" ]; then
  echo "$LOG_PREFIX ERROR: nic0 not found -- nexus_network role didn't run?" >&2
  exit 1
fi
echo "$LOG_PREFIX nic0 MAC: $NIC0_MAC"

# Find any ethernet interface that's not nic0 (or already named nic1).
SECONDARY_IF=""
for ifdir in /sys/class/net/*; do
  ifname=$(basename "$ifdir")
  case "$ifname" in
    lo|nic0|nic1) continue ;;
  esac
  # Skip non-ethernet (wireless, virtual, etc)
  [ -e "$ifdir/device" ] || continue
  ifmac=$(cat "$ifdir/address" 2>/dev/null || true)
  if [ -n "$ifmac" ] && [ "$ifmac" != "$NIC0_MAC" ]; then
    SECONDARY_IF=$ifname
    SECONDARY_MAC=$ifmac
    break
  fi
done

if [ -z "$SECONDARY_IF" ]; then
  echo "$LOG_PREFIX WARNING: no secondary NIC found -- single-NIC clone? VMnet10 backplane unavailable; raft will fall back to nic0 only" >&2
else
  echo "$LOG_PREFIX secondary NIC found: $SECONDARY_IF (MAC $SECONDARY_MAC)"

  # systemd .link drop-in to rename to nic1 by MAC. Persists across reboots.
  cat > /etc/systemd/network/20-nic1.link <<EOF
[Match]
MACAddress=$SECONDARY_MAC

[Link]
Name=nic1
EOF

  # systemd .network for nic1 -- static address on VMnet10 backplane.
  # VMnet10 has no DHCP server in the lab; hosts assign their own IPs.
  cat > /etc/systemd/network/20-nic1.network <<EOF
[Match]
Name=nic1

[Network]
Address=$VMNET10_IP/24
LinkLocalAddressing=no
DHCP=no
IPv6AcceptRA=no
EOF

  echo "$LOG_PREFIX restarting systemd-networkd to apply NIC config"
  udevadm control --reload
  udevadm trigger --action=move --subsystem-match=net 2>/dev/null || true
  systemctl restart systemd-networkd

  # Brief settle for the rename + IP assignment to take effect
  sleep 3
fi

# ─── 5. Generate self-signed TLS cert per-clone ───────────────────────────
# (VMnet11 IP was already discovered in step 1; reusing $VMNET11_IP)
TLS_DIR=/etc/vault.d/tls
mkdir -p "$TLS_DIR"
chown vault:vault "$TLS_DIR"
chmod 750 "$TLS_DIR"

# SANs cover all reasonable identities: hostname FQDN, short hostname, both
# IPs, localhost. Phase 0.D.2 reissues from Vault PKI.
openssl req -new -newkey rsa:4096 -days 3650 -nodes -x509 \
  -subj "/CN=$HOSTNAME.nexus.lab" \
  -addext "subjectAltName=DNS:$HOSTNAME.nexus.lab,DNS:$HOSTNAME,IP:$VMNET11_IP,IP:$VMNET10_IP,IP:127.0.0.1" \
  -keyout "$TLS_DIR/vault.key" \
  -out    "$TLS_DIR/vault.crt" \
  >/dev/null 2>&1

chown vault:vault "$TLS_DIR/vault.key" "$TLS_DIR/vault.crt"
chmod 600 "$TLS_DIR/vault.key"
chmod 644 "$TLS_DIR/vault.crt"
echo "$LOG_PREFIX TLS cert generated for CN=$HOSTNAME.nexus.lab"

# ─── 6. Render vault.hcl from template ────────────────────────────────────
TPL=/etc/vault.d/vault.hcl.tpl
DST=/etc/vault.d/vault.hcl

if [ ! -f "$TPL" ]; then
  echo "$LOG_PREFIX ERROR: $TPL missing -- vault_node Ansible role didn't install it?" >&2
  exit 1
fi

sed -e "s|@HOSTNAME@|$HOSTNAME|g" \
    -e "s|@VMNET11_IP@|$VMNET11_IP|g" \
    -e "s|@VMNET10_IP@|$VMNET10_IP|g" \
    "$TPL" > "$DST"
chown root:vault "$DST"
chmod 640 "$DST"
echo "$LOG_PREFIX rendered $DST"

# ─── 7. Mark complete ─────────────────────────────────────────────────────
touch "$MARKER"
echo "$LOG_PREFIX done -- vault.service can now start"
