/*
 * role-overlay-gateway-oltp-reservations.tf -- dnsmasq dhcp-host reservations
 * on nexus-gateway pinning the OLTP tier MACs to canonical VMnet11 IPs.
 *
 * Phase 0.G.1 ships the 6 Redis reservations; 0.G.2 extends with 3 Mongo
 * reservations (v2); 0.G.3 extends with 5 PXC + ProxySQL reservations (v3).
 * Later 0.G sub-phases extend further: Patroni 0.G.4 -> .61-.67, SQL FCI/AG
 * 0.G.7 -> .11-.14. The single-file shape avoids marker-version churn across
 * sub-phase ships -- the marker string carries the version and a fresh apply
 * replaces the file atomically when a new cluster's reservations are added.
 *
 * Per nexus-platform-plan/docs/infra/vms.yaml (clusters: redis + mongo + percona):
 *   redis-1     -> 192.168.70.81 (shard 1 primary)
 *   redis-2     -> 192.168.70.82 (shard 1 replica)
 *   redis-3     -> 192.168.70.83 (shard 2 primary)
 *   redis-4     -> 192.168.70.84 (shard 2 replica)
 *   redis-5     -> 192.168.70.87 (shard 3 primary -- .85/.86/.88 are kafka tier)
 *   redis-6     -> 192.168.70.89 (shard 3 replica -- .88 is kafka-rest)
 *   mongo-1     -> 192.168.70.71 (initial PRIMARY at rs.initiate; rs re-elects)
 *   mongo-2     -> 192.168.70.72 (replica set member 1)
 *   mongo-3     -> 192.168.70.73 (replica set member 2)
 *   pxc-node-1  -> 192.168.70.51 (Galera node, candidate bootstrap)
 *   pxc-node-2  -> 192.168.70.52 (Galera node)
 *   pxc-node-3  -> 192.168.70.53 (Galera node)
 *   proxysql-1  -> 192.168.70.54 (ProxySQL inst 1; keepalived MASTER for VIP .50)
 *   proxysql-2  -> 192.168.70.55 (ProxySQL inst 2; keepalived BACKUP for VIP .50)
 *
 * The ProxySQL VIP .50 is NOT a dhcp reservation -- it floats between
 * proxysql-1/proxysql-2 via keepalived/VRRP, configured by the oltp env
 * (which owns the per-node ProxySQL + keepalived config).
 *
 * Lives in foundation env (NOT in nexus-infra-oltp/) because the gateway is
 * foundation's responsibility -- consolidating gateway-state ownership in one
 * repo avoids two terraform repos racing on /etc/dnsmasq.d/. The oltp env's
 * clones consume the pinned IPs; they don't write the reservations.
 *
 * Default `enable_oltp_dhcp_reservations = true` per memory/
 * feedback_terraform_partial_apply_destroys_resources.md.
 *
 * Mirrors role-overlay-gateway-kafka-reservations.tf shape exactly:
 *   - SSH to gateway, write /etc/dnsmasq.d/foundation-oltp-reservations.conf
 *   - Marker comment includes overlay version for idempotent re-apply
 *   - systemctl restart dnsmasq (NOT reload -- doesn't re-read dhcp-host)
 *   - Destroy-time provisioner removes the conf + restarts
 */

resource "null_resource" "gateway_oltp_reservations" {
  count = var.enable_oltp_dhcp_reservations ? 1 : 0

  triggers = {
    gateway_ip          = "192.168.70.1"
    mac_redis_1         = var.mac_oltp_redis_1_primary
    mac_redis_2         = var.mac_oltp_redis_2_primary
    mac_redis_3         = var.mac_oltp_redis_3_primary
    mac_redis_4         = var.mac_oltp_redis_4_primary
    mac_redis_5         = var.mac_oltp_redis_5_primary
    mac_redis_6         = var.mac_oltp_redis_6_primary
    mac_mongo_1         = var.mac_oltp_mongo_1_primary
    mac_mongo_2         = var.mac_oltp_mongo_2_primary
    mac_mongo_3         = var.mac_oltp_mongo_3_primary
    mac_pxc_1           = var.mac_oltp_pxc_1_primary
    mac_pxc_2           = var.mac_oltp_pxc_2_primary
    mac_pxc_3           = var.mac_oltp_pxc_3_primary
    mac_proxysql_1      = var.mac_oltp_proxysql_1_primary
    mac_proxysql_2      = var.mac_oltp_proxysql_2_primary
    oltp_reservations_v = "3" # v3 (0.G.3) = +5 PXC/ProxySQL reservations (.51-.55). v2 (0.G.2) added +3 mongo (.71-.73). v1 was redis only (.81-.84/.87/.89).
  }

  provisioner "local-exec" {
    when        = create
    interpreter = ["pwsh", "-NoProfile", "-Command"]
    command     = <<-PWSH
      $gw      = '192.168.70.1'
      $mac_r1  = '${var.mac_oltp_redis_1_primary}'
      $mac_r2  = '${var.mac_oltp_redis_2_primary}'
      $mac_r3  = '${var.mac_oltp_redis_3_primary}'
      $mac_r4  = '${var.mac_oltp_redis_4_primary}'
      $mac_r5  = '${var.mac_oltp_redis_5_primary}'
      $mac_r6  = '${var.mac_oltp_redis_6_primary}'
      $mac_m1  = '${var.mac_oltp_mongo_1_primary}'
      $mac_m2  = '${var.mac_oltp_mongo_2_primary}'
      $mac_m3  = '${var.mac_oltp_mongo_3_primary}'
      $mac_p1  = '${var.mac_oltp_pxc_1_primary}'
      $mac_p2  = '${var.mac_oltp_pxc_2_primary}'
      $mac_p3  = '${var.mac_oltp_pxc_3_primary}'
      $mac_x1  = '${var.mac_oltp_proxysql_1_primary}'
      $mac_x2  = '${var.mac_oltp_proxysql_2_primary}'
      $marker  = '# OLTP tier dhcp-host reservations managed by terraform/envs/foundation/role-overlay-gateway-oltp-reservations.tf v3'

      # Idempotent insert: marker matches v3 specifically. v1 (redis-only) and
      # v2 (redis + mongo) files get replaced atomically -- write-through tee
      # handles the transition without an intermediate "empty conf" window.
      $existing = ssh nexusadmin@$gw "test -f /etc/dnsmasq.d/foundation-oltp-reservations.conf && cat /etc/dnsmasq.d/foundation-oltp-reservations.conf || true"
      if ($existing -match [regex]::Escape($marker)) {
        Write-Host "[gateway oltp-reservations] v3 reservations already present, no-op."
        exit 0
      }

      # Per nexus-platform-plan/docs/infra/vms.yaml (clusters: redis + mongo + percona).
      $confLines = @(
        $marker
        "dhcp-host=$mac_r1,192.168.70.81,redis-1"
        "dhcp-host=$mac_r2,192.168.70.82,redis-2"
        "dhcp-host=$mac_r3,192.168.70.83,redis-3"
        "dhcp-host=$mac_r4,192.168.70.84,redis-4"
        "dhcp-host=$mac_r5,192.168.70.87,redis-5"
        "dhcp-host=$mac_r6,192.168.70.89,redis-6"
        "dhcp-host=$mac_m1,192.168.70.71,mongo-1"
        "dhcp-host=$mac_m2,192.168.70.72,mongo-2"
        "dhcp-host=$mac_m3,192.168.70.73,mongo-3"
        "dhcp-host=$mac_p1,192.168.70.51,pxc-node-1"
        "dhcp-host=$mac_p2,192.168.70.52,pxc-node-2"
        "dhcp-host=$mac_p3,192.168.70.53,pxc-node-3"
        "dhcp-host=$mac_x1,192.168.70.54,proxysql-1"
        "dhcp-host=$mac_x2,192.168.70.55,proxysql-2"
        ""
      ) -join "`n"

      $script = @"
        echo '$confLines' | sudo tee /etc/dnsmasq.d/foundation-oltp-reservations.conf > /dev/null
        sudo systemctl restart dnsmasq && echo OK
"@
      Write-Host "[gateway oltp-reservations] writing 14 dhcp-host reservations (6 Redis + 3 Mongo + 3 PXC + 2 ProxySQL) + restarting dnsmasq..."
      ssh nexusadmin@$gw $script
      if ($LASTEXITCODE -ne 0) { throw "[gateway oltp-reservations] ssh tee/restart failed (rc=$LASTEXITCODE)" }
      Write-Host "[gateway oltp-reservations] reservations live: redis-1..6 (.81-.84/.87/.89), mongo-1..3 (.71/.72/.73), pxc-node-1..3 (.51/.52/.53), proxysql-1..2 (.54/.55)"
    PWSH
  }

  provisioner "local-exec" {
    when        = destroy
    interpreter = ["pwsh", "-NoProfile", "-Command"]
    command     = <<-PWSH
      $gw = '${self.triggers.gateway_ip}'
      Write-Host "[gateway oltp-reservations] removing reservations + restarting dnsmasq..."
      ssh nexusadmin@$gw "sudo rm -f /etc/dnsmasq.d/foundation-oltp-reservations.conf && sudo systemctl restart dnsmasq" 2>$null
      exit 0
    PWSH
  }
}
