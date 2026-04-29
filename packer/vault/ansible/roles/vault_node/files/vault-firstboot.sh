#!/bin/bash
# vault-firstboot.sh — runs once at first boot per Vault clone.
#
# Responsibilities:
#   1. Detect both ethernet NICs by MAC OUI pattern (primary :00:??,
#      secondary :01:??), remediate if 10-nic0.link picked the wrong one
#      as nic0 (kernel enumeration order is non-deterministic with two
#      en* interfaces).
#   2. Wait for nic0 to have its DHCP-assigned IP (canonical via gateway
#      dhcp-host MAC reservation: vault-1=.121, vault-2=.122, vault-3=.123).
#   3. Map IP -> canonical hostname + VMnet10 IP. Set hostname.
#   4. Configure secondary NIC (nic1) with static VMnet10 IP.
#   5. Generate fresh self-signed TLS cert per-clone.
#   6. Render /etc/vault.d/vault.hcl from vault.hcl.tpl.
#   7. Mark complete (idempotent re-run guard).
#
# CRITICAL DESIGN -- NIC enumeration:
#   The deb13 baseline ships /etc/systemd/network/10-nic0.link with
#   `OriginalName=en*` which renames the FIRST en* interface to nic0.
#   With two en* interfaces (Vault has VMnet11 primary + VMnet10
#   backplane), kernel enumeration order determines which gets renamed.
#   This is non-deterministic across clones -- empirically, some clones
#   landed nic0 on the secondary (VMnet10) NIC, which has no DHCP server,
#   so DHCP fails and the clone is unreachable.
#
#   Fix: identify NICs by MAC OUI byte 5 (0x00 = primary VMnet11,
#   0x01 = secondary VMnet10), regardless of kernel name. If nic0 has
#   the wrong MAC, swap kernel names via `ip link set ... name ...` and
#   restart systemd-networkd to re-trigger DHCP on the correct NIC.
#   Discovered 2026-04-30 during 0.D.1 cluster bring-up.
#
# Idempotent: marker file at /var/lib/vault-firstboot-done short-circuits
# re-runs. Removing the marker forces re-run on next boot.

set -euo pipefail

MARKER=/var/lib/vault-firstboot-done
LOG_PREFIX="[vault-firstboot]"

if [ -f "$MARKER" ]; then
  echo "$LOG_PREFIX already done, skipping (remove $MARKER to force re-run)"
  exit 0
fi

# ─── 1. Discover both NICs by MAC OUI pattern ──────────────────────────────
# Primary MAC: 00:50:56:?f:00:?? (byte 5 = 00) -> VMnet11 service
# Secondary MAC: 00:50:56:?f:01:?? (byte 5 = 01) -> VMnet10 backplane
PRIMARY_IF=""
PRIMARY_MAC=""
SECONDARY_IF=""
SECONDARY_MAC=""
for ifdir in /sys/class/net/*; do
  ifname=$(basename "$ifdir")
  [ "$ifname" = "lo" ] && continue
  [ -e "$ifdir/device" ] || continue
  ifmac=$(cat "$ifdir/address" 2>/dev/null || true)
  case "$ifmac" in
    00:50:56:*:00:*) PRIMARY_IF=$ifname; PRIMARY_MAC=$ifmac ;;
    00:50:56:*:01:*) SECONDARY_IF=$ifname; SECONDARY_MAC=$ifmac ;;
  esac
done

if [ -z "$PRIMARY_IF" ]; then
  echo "$LOG_PREFIX ERROR: no primary NIC (MAC pattern 00:50:56:*:00:*) found" >&2
  echo "$LOG_PREFIX available interfaces:" >&2
  ip -br link >&2
  exit 1
fi
echo "$LOG_PREFIX detected primary NIC: $PRIMARY_IF (MAC $PRIMARY_MAC)"
if [ -n "$SECONDARY_IF" ]; then
  echo "$LOG_PREFIX detected secondary NIC: $SECONDARY_IF (MAC $SECONDARY_MAC)"
else
  echo "$LOG_PREFIX no secondary NIC detected (single-NIC clone? VMnet10 backplane unavailable)"
fi

# ─── 2. Ensure nic0 == primary NIC; rename secondary -> nic1 ───────────────
# If 10-nic0.link picked the wrong NIC (e.g., the secondary became nic0),
# swap. Renaming requires the interface to be DOWN first.
NEED_NETWORKD_RESTART=0

if [ "$PRIMARY_IF" != "nic0" ]; then
  echo "$LOG_PREFIX nic0 swap needed: $PRIMARY_IF should be nic0"
  # Move whatever is currently named nic0 (if anything) out of the way
  if [ -e /sys/class/net/nic0 ]; then
    CURRENT_NIC0_MAC=$(cat /sys/class/net/nic0/address 2>/dev/null || true)
    echo "$LOG_PREFIX moving current nic0 (MAC $CURRENT_NIC0_MAC) aside as nic-old"
    ip link set nic0 down 2>/dev/null || true
    ip link set nic0 name nic-old
    # If the previous nic0 was the secondary we already detected, track
    # its new name so the secondary rename below finds it.
    if [ "$CURRENT_NIC0_MAC" = "$SECONDARY_MAC" ]; then
      SECONDARY_IF="nic-old"
    fi
  fi
  # Rename the primary interface to nic0
  ip link set "$PRIMARY_IF" down 2>/dev/null || true
  ip link set "$PRIMARY_IF" name nic0
  ip link set nic0 up
  PRIMARY_IF="nic0"
  NEED_NETWORKD_RESTART=1
  echo "$LOG_PREFIX nic0 now has primary MAC $PRIMARY_MAC"
fi

# Rename secondary to nic1 (if we have one and it's not already nic1).
# Bringing the interface down before rename is mandatory -- can't rename
# a UP interface; previous firstboot version silently failed this step.
if [ -n "$SECONDARY_IF" ] && [ "$SECONDARY_IF" != "nic1" ]; then
  echo "$LOG_PREFIX renaming secondary $SECONDARY_IF -> nic1"
  ip link set "$SECONDARY_IF" down 2>/dev/null || true
  ip link set "$SECONDARY_IF" name nic1
  SECONDARY_IF="nic1"
  NEED_NETWORKD_RESTART=1
fi

if [ "$NEED_NETWORKD_RESTART" = "1" ]; then
  echo "$LOG_PREFIX restarting systemd-networkd after NIC rename(s)"
  systemctl restart systemd-networkd
  sleep 3
fi

# ─── 3. Wait for nic0 to have its DHCP-assigned IP ─────────────────────────
# Now that nic0 is correctly assigned to the primary (VMnet11) NIC, DHCP
# can succeed. The gateway's dhcp-host reservation pins the per-MAC IP.
# Retry up to 10x (50 sec) -- DHCP can take a moment after the rename.
VMNET11_IP=""
for i in 1 2 3 4 5 6 7 8 9 10; do
  VMNET11_IP=$(ip -4 -o addr show nic0 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -1)
  [ -n "$VMNET11_IP" ] && break
  echo "$LOG_PREFIX waiting for nic0 IPv4 (attempt $i/10)..."
  sleep 5
done

if [ -z "$VMNET11_IP" ]; then
  echo "$LOG_PREFIX ERROR: nic0 has no IPv4 address after 50s -- DHCP failed?" >&2
  echo "$LOG_PREFIX nic0 state:" >&2
  ip -br addr show nic0 >&2 || true
  echo "$LOG_PREFIX systemd-networkd status:" >&2
  systemctl status systemd-networkd --no-pager >&2 || true
  exit 1
fi
echo "$LOG_PREFIX nic0 (VMnet11) IP: $VMNET11_IP"

# ─── 4. Map VMnet11 IP -> canonical hostname + VMnet10 IP ──────────────────
case "$VMNET11_IP" in
  192.168.70.121) HOSTNAME=vault-1; VMNET10_IP=192.168.10.121 ;;
  192.168.70.122) HOSTNAME=vault-2; VMNET10_IP=192.168.10.122 ;;
  192.168.70.123) HOSTNAME=vault-3; VMNET10_IP=192.168.10.123 ;;
  *)
    echo "$LOG_PREFIX ERROR: unknown VMnet11 IP '$VMNET11_IP' (expected .121/.122/.123)" >&2
    exit 1
    ;;
esac
echo "$LOG_PREFIX mapped: hostname=$HOSTNAME VMnet10 (backplane) IP=$VMNET10_IP/24"

# ─── 5. Set the system hostname ────────────────────────────────────────────
CURRENT_HOSTNAME=$(cat /etc/hostname 2>/dev/null || echo '')
if [ "$CURRENT_HOSTNAME" != "$HOSTNAME" ]; then
  echo "$LOG_PREFIX renaming hostname: '$CURRENT_HOSTNAME' -> '$HOSTNAME'"
  hostnamectl set-hostname "$HOSTNAME"
else
  echo "$LOG_PREFIX hostname already '$HOSTNAME', no rename needed"
fi

# ─── 6. Configure secondary NIC (nic1) for VMnet10 backplane ───────────────
# .link file pins the rename across reboots; .network applies the static IP.
# Also do `ip addr add` directly so the IP comes up immediately (networkd
# restart with .network alone has been observed to leave the interface
# without an IP if it was already DOWN at restart time).
if [ -n "$SECONDARY_MAC" ]; then
  echo "$LOG_PREFIX configuring nic1 (VMnet10 backplane)"
  cat > /etc/systemd/network/20-nic1.link <<EOF
[Match]
MACAddress=$SECONDARY_MAC

[Link]
Name=nic1
EOF
  cat > /etc/systemd/network/20-nic1.network <<EOF
[Match]
Name=nic1

[Network]
Address=$VMNET10_IP/24
LinkLocalAddressing=no
DHCP=no
IPv6AcceptRA=no
EOF
  ip link set nic1 up 2>/dev/null || true
  # Idempotent: only add the address if it's not already there.
  if ! ip -4 -o addr show nic1 2>/dev/null | grep -q "$VMNET10_IP"; then
    ip addr add "$VMNET10_IP/24" dev nic1 || true
  fi
  systemctl restart systemd-networkd
  sleep 3
fi

# ─── 7. Generate self-signed TLS cert per-clone ────────────────────────────
TLS_DIR=/etc/vault.d/tls
mkdir -p "$TLS_DIR"
chown vault:vault "$TLS_DIR"
chmod 750 "$TLS_DIR"

# SANs cover all reasonable identities: hostname FQDN, short hostname,
# both IPs, localhost. Phase 0.D.2 reissues from Vault PKI.
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

# ─── 8. Render vault.hcl from template ─────────────────────────────────────
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

# ─── 9. Mark complete ──────────────────────────────────────────────────────
touch "$MARKER"
echo "$LOG_PREFIX done -- vault.service can now start"
