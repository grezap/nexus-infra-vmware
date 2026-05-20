/*
 * role-overlay-gateway-iscsi-sqlfci.tf -- iSCSI target on nexus-gateway
 * exporting a shared LUN to the SQL Server FCI pair (sql-fci-1/-2).
 *
 * Phase 0.G.7. Per ADR-0026 (SQL FCI iSCSI shared storage on nexus-gateway).
 *
 * Why iSCSI on nexus-gateway (and not S2D, multi-writer VMDK, or SMB Direct):
 *  - VMware Workstation Pro has NO shared-disk primitive. The vmx
 *    `scsi0:N.sharing = "multi-writer"` flag is ESXi-only; Workstation's
 *    UI doesn't expose it, and even setting it manually in the .vmx doesn't
 *    activate sharing semantics (verified at 0.G.7 scaffold 2026-05-20).
 *  - Storage Spaces Direct (S2D) requires 2+ Windows Server nodes pooling
 *    locally-attached disks across an RDMA-capable network -- overkill for
 *    a 4-VM lab and stages a chicken-and-egg with WSFC (S2D needs WSFC, WSFC
 *    needs shared storage).
 *  - SMB 3 file-share witness style "shared storage" is supported by SQL
 *    FCI from 2017+, but the share would itself need HA -- pushing the
 *    SPOF up one layer.
 *  - iSCSI from nexus-gateway is the smallest tractable shim: the gateway
 *    is already canon (DNS + DHCP + NTP + NFS for portainer in 0.E.4a; one
 *    more daemon is in the same operational envelope). The LUN is a
 *    sparse-file backing -- uses ~0 host disk until SQL writes data.
 *
 * Daemon: tgt (Linux SCSI Target Framework). Available in apt's main repo
 * (debian-13 trixie), single binary, simple conf-file config. Drops a single
 * iSCSI target with CHAP auth, ACL-restricted to the two FCI initiators by
 * source IP.
 *
 * Backing file: /srv/iscsi/sql-fci-shared.img (60 GB sparse by default).
 * Lives outside /srv/nfs/ (the 0.E.4a portainer-data export) for isolation.
 *
 * Network: tcp/3260 on VMnet11. nftables overlay patches the gateway's
 * existing /etc/nftables.conf to allow 3260/tcp from .70.11 + .70.12 only
 * (FCI nodes' canonical IPs). AG replica nodes (.70.13/.14) do NOT need
 * iSCSI -- their databases are local-storage.
 *
 * CHAP: incoming-user/password pair seeded into the target by reading the
 * sticky-seeded password from $HOME/.nexus/iscsi-sqlfci-chap.json (written
 * by the security env's role-overlay-vault-sqlserver-cluster-creds-seed.tf
 * after pulling from Vault KV nexus/oltp/sqlserver/iscsi-chap-secret). This
 * matches the same KV-fetch-then-write-to-host-disk pattern that the foundation
 * env uses for vault-ad-bind.json + vault-init.json (pre-Phase-0.E Consul KV).
 *
 * Idempotency: marker line in /etc/tgt/conf.d/sql-fci.conf carries the
 * overlay version (v1 = initial 0.G.7). Bump on schema change. Apply is
 * idempotent: probe -> compare -> write-if-different -> reload via
 * `tgt-admin --update ALL` (no service restart needed; tgt's admin tool
 * incrementally activates new exports). Restart fallback if reload fails.
 *
 * Default `enable_iscsi_target_sqlfci = true` per
 * memory/feedback_terraform_partial_apply_destroys_resources.md.
 */

resource "null_resource" "gateway_iscsi_sqlfci" {
  count = var.enable_iscsi_target_sqlfci ? 1 : 0

  # depends_on the dhcp reservations because the iSCSI ACL references the FCI
  # nodes' canonical IPs (.70.11/.12) which only become permanent once the
  # dhcp-host reservations are live. Without this ordering the ACL would
  # allow connections from VMs that haven't been DHCP-pinned yet -- a brief
  # window of accidentally-permissive access on every apply.
  depends_on = [null_resource.gateway_oltp_reservations]

  triggers = {
    gateway_ip         = "192.168.70.1"
    lun_size_gb        = var.iscsi_sqlfci_lun_size_gb
    target_iqn         = var.iscsi_sqlfci_target_iqn
    chap_username      = var.iscsi_sqlfci_chap_username
    initiator_ip_fci_1 = "192.168.70.11"
    initiator_ip_fci_2 = "192.168.70.12"
    iscsi_target_v     = "4" # v4 (0.G.7 ratify 2026-05-20) = simplify tgt verify probe to grep backing-store path (transient #6: PS+bash double-escape mangled awk's $0 reference). v3 = fix nftables anchor (transient #5) + tgt-admin->systemctl restart (transient #4). v2 = remove backticks (transient #3). v1 = initial.
  }

  provisioner "local-exec" {
    when        = create
    interpreter = ["pwsh", "-NoProfile", "-Command"]
    command     = <<-PWSH
      $gw         = '192.168.70.1'
      $lunSizeGb  = ${var.iscsi_sqlfci_lun_size_gb}
      $targetIqn  = '${var.iscsi_sqlfci_target_iqn}'
      $chapUser   = '${var.iscsi_sqlfci_chap_username}'
      $initFci1   = '192.168.70.11'
      $initFci2   = '192.168.70.12'
      $chapSecretFile = Join-Path $HOME ".nexus/iscsi-sqlfci-chap.json"

      # Pull the CHAP secret from the host-side sidecar JSON. Written by the
      # security env's role-overlay-vault-sqlserver-cluster-creds-seed.tf
      # after it pulls the value from Vault KV. This indirection is the
      # canonical pre-Phase-0.E pattern (same as vault-ad-bind.json shape).
      if (-not (Test-Path $chapSecretFile)) {
        throw "[gateway iscsi-sqlfci] CHAP secret sidecar not found at $chapSecretFile -- run security.ps1 apply first (writes via role-overlay-vault-sqlserver-cluster-creds-seed.tf)."
      }
      $chapSecret = (Get-Content $chapSecretFile -Raw | ConvertFrom-Json).chap_secret
      if (-not $chapSecret -or $chapSecret.Length -lt 12) {
        throw "[gateway iscsi-sqlfci] CHAP secret in $chapSecretFile is missing or too short (<12 chars). iSCSI initiators reject short CHAP secrets per RFC 3720 -- regenerate the KV seed at nexus/oltp/sqlserver/iscsi-chap-secret with at least 12 chars."
      }

      $marker = '# SQL FCI iSCSI target managed by terraform/envs/foundation/role-overlay-gateway-iscsi-sqlfci.tf v1'

      # Idempotent insert: marker matches v1 specifically. Bump on schema
      # change. Apply re-renders + reloads tgt-admin.
      $existing = ssh nexusadmin@$gw "test -f /etc/tgt/conf.d/sql-fci.conf && cat /etc/tgt/conf.d/sql-fci.conf || true"
      if ($existing -match [regex]::Escape($marker)) {
        Write-Host "[gateway iscsi-sqlfci] v1 target already configured, no-op."
        exit 0
      }

      # Stage 1: install tgt + nftables rule + create the LUN backing file.
      # Idempotent: apt install is no-op if already installed; nft add rule
      # is wrapped in pattern-match to avoid duplicate rules; truncate -s is
      # only run if the file doesn't already exist.
      $installCmd = @"
        set -euo pipefail
        # tgt (SCSI Target Framework) -- single daemon, conf-file-driven.
        if ! command -v tgtadm >/dev/null 2>&1; then
          sudo DEBIAN_FRONTEND=noninteractive apt-get update -qq
          sudo DEBIAN_FRONTEND=noninteractive apt-get install -y tgt
        fi
        # Disable the default systemd unit's auto-config from /etc/tgt/conf.d
        # since we manage that file ourselves. tgt service still starts; the
        # explicit 'tgt-admin --update ALL' after our config-write is what
        # actually loads our target into the running daemon.
        sudo systemctl enable tgt.service
        sudo systemctl is-active --quiet tgt.service || sudo systemctl start tgt.service

        # Backing file. 60 GB sparse -- truncate -s creates a file of the
        # requested size with zero blocks allocated. Becomes thin until
        # initialized + written by sql-fci-1 during the FCI install.
        sudo install -d -m 0750 -o root -g root /srv/iscsi
        if [ ! -f /srv/iscsi/sql-fci-shared.img ]; then
          sudo truncate -s $${lunSizeGb}G /srv/iscsi/sql-fci-shared.img
          sudo chmod 0640 /srv/iscsi/sql-fci-shared.img
        fi

        # nftables: allow tcp/3260 from FCI initiators only. Patch the
        # gateway's /etc/nftables.conf in-place; runtime 'nft add rule'
        # lands AFTER the canonical 'counter drop' (per
        # feedback_nftables_runtime_add_after_drop.md), so we edit the
        # conf-file + reload via 'nft -f'. Pattern mirrors the NFSv4
        # Portainer rules from 0.E.4a (iifname "nic1" ip saddr X tcp dport
        # Y accept comment Z) -- insert just before the 'counter drop' line
        # in the input chain. Transient #5 at 0.G.7 ratify: anchor pattern
        # 'ct state established,related accept' did NOT match the actual
        # gateway grammar 'ct state { established, related } accept'; using
        # 'counter drop' instead (single-occurrence + last-line-in-chain).
        if ! sudo grep -q 'sql-fci-1' /etc/nftables.conf; then
          sudo sed -i '/# === iSCSI for SQL FCI ===/,/# === end iSCSI ===/d' /etc/nftables.conf
          sudo awk '
            BEGIN { inserted=0 }
            /^        counter drop$/ && inserted==0 {
              print "        # === iSCSI for SQL FCI ==="
              print "        iifname \"nic1\" ip saddr 192.168.70.11 tcp dport 3260 accept comment \"iSCSI from sql-fci-1\""
              print "        iifname \"nic1\" ip saddr 192.168.70.12 tcp dport 3260 accept comment \"iSCSI from sql-fci-2\""
              print "        # === end iSCSI ==="
              inserted=1
            }
            { print }
          ' /etc/nftables.conf | sudo tee /etc/nftables.conf.new >/dev/null
          sudo mv /etc/nftables.conf.new /etc/nftables.conf
          sudo nft -f /etc/nftables.conf
          # Docker iptables-nft conflict (feedback_nftables_flush_ruleset_
          # wipes_docker.md): the gateway doesn't run Docker, so no need to
          # restart dockerd. (Reminder for envs that do.)
        fi
        echo OK
"@
      Write-Host "[gateway iscsi-sqlfci] installing tgt + creating $${lunSizeGb}GB sparse LUN + nftables rule..."
      ssh nexusadmin@$gw $installCmd
      if ($LASTEXITCODE -ne 0) { throw "[gateway iscsi-sqlfci] install/nft phase failed (rc=$LASTEXITCODE)" }

      # Stage 2: write the tgt conf-file + reload via tgt-admin.
      # tgt's syntax: <target> block with backing-store + incominguser
      # (CHAP) + initiator-address (IP ACL).
      $confLines = @(
        $marker
        "default-driver iscsi"
        ""
        "<target $targetIqn>"
        "    backing-store /srv/iscsi/sql-fci-shared.img"
        "    incominguser $chapUser $chapSecret"
        "    initiator-address $initFci1"
        "    initiator-address $initFci2"
        "    # MaxRecvDataSegmentLength + FirstBurstLength tuned for SQL"
        "    # workloads (default 8 KB is too low; 256 KB matches Windows"
        "    # iSCSI initiator default + reduces interrupt overhead)."
        "    MaxRecvDataSegmentLength 262144"
        "    FirstBurstLength 262144"
        "    MaxBurstLength 1048576"
        "</target>"
        ""
      ) -join "`n"

      $writeCmd = @"
        echo '$confLines' | sudo tee /etc/tgt/conf.d/sql-fci.conf > /dev/null
        sudo chmod 0640 /etc/tgt/conf.d/sql-fci.conf
        # Transient #4 at 0.G.7 ratify: tgt-admin --update on an existing
        # target does NOT attach the backing-store from a freshly-written
        # conf -- the target is loaded by tgt-init at service start. The
        # only reliable way to pick up new <target>/backing-store/CHAP/ACL
        # entries is systemctl restart tgt.service. Restart is fast (~1s);
        # any active iSCSI sessions reconnect transparently on the next
        # initiator probe.
        sudo systemctl restart tgt.service
        sleep 2
        # Verify the backing-store LUN is actually attached to the target.
        # Mere IQN presence isn't enough (tgt creates a controller LUN 0
        # without backing on bare service start; the real disk LUN 1 with
        # /srv/iscsi/sql-fci-shared.img backing only attaches after the
        # conf file is loaded by service restart). The backing-file path
        # is unique enough to be the canonical verify probe.
        sudo tgtadm --mode target --op show | grep -q '/srv/iscsi/sql-fci-shared.img' && echo OK
"@
      Write-Host "[gateway iscsi-sqlfci] writing tgt config + reloading target..."
      ssh nexusadmin@$gw $writeCmd
      if ($LASTEXITCODE -ne 0) { throw "[gateway iscsi-sqlfci] config-write/reload failed (rc=$LASTEXITCODE)" }
      Write-Host "[gateway iscsi-sqlfci] live: target $targetIqn exporting /srv/iscsi/sql-fci-shared.img ($${lunSizeGb}GB sparse) to $initFci1 + $initFci2 (CHAP user=$chapUser); tcp/3260 allowed from those 2 IPs only."
    PWSH
  }

  provisioner "local-exec" {
    when        = destroy
    interpreter = ["pwsh", "-NoProfile", "-Command"]
    command     = <<-PWSH
      $gw = '${self.triggers.gateway_ip}'
      Write-Host "[gateway iscsi-sqlfci] removing target + nftables rule (LUN backing file preserved -- delete manually if needed)..."
      $rmCmd = @"
        sudo rm -f /etc/tgt/conf.d/sql-fci.conf
        sudo sed -i '/# === iSCSI for SQL FCI ===/,/# === end iSCSI ===/d' /etc/nftables.conf
        sudo nft -f /etc/nftables.conf 2>/dev/null
        sudo tgt-admin --update ALL --force 2>/dev/null || sudo systemctl restart tgt.service 2>/dev/null
        # NOT removing /srv/iscsi/sql-fci-shared.img -- contains user data; operator must rm manually.
        exit 0
"@
      ssh nexusadmin@$gw $rmCmd 2>$null
      exit 0
    PWSH
  }
}
