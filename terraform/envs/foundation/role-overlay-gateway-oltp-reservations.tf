/*
 * role-overlay-gateway-oltp-reservations.tf -- dnsmasq dhcp-host reservations
 * on nexus-gateway pinning the OLTP tier MACs to canonical VMnet11 IPs.
 *
 * Phase 0.G.1 shipped the 6 Redis reservations (v1); 0.G.2 extended with 3
 * Mongo reservations (v2); 0.G.3 extended with 5 PXC + ProxySQL reservations
 * (v3); 0.G.4 extended with 8 Patroni-tier reservations (v5; v4 was the
 * single-HAProxy variant superseded mid-scaffold by the HA pair design to
 * align with the proxysql-1/2 pattern); 0.G.7 extends with 4 SQL Server
 * FCI/AG reservations (v6); 0.N extends with 11 sharded-Mongo reservations
 * (v7 -- this version: 3 cfg + 6 shards + 2 mongos). The single-file shape avoids
 * marker-version churn across sub-phase ships -- the marker string carries
 * the version and a fresh apply replaces the file atomically when a new
 * cluster's reservations are added.
 *
 * Per nexus-platform-plan/docs/infra/vms.yaml (clusters: redis + mongo + percona
 * + postgres + sqlserver):
 *   redis-1       -> 192.168.70.81  (shard 1 primary)
 *   redis-2       -> 192.168.70.82  (shard 1 replica)
 *   redis-3       -> 192.168.70.83  (shard 2 primary)
 *   redis-4       -> 192.168.70.84  (shard 2 replica)
 *   redis-5       -> 192.168.70.87  (shard 3 primary -- .85/.86/.88 are kafka tier)
 *   redis-6       -> 192.168.70.89  (shard 3 replica -- .88 is kafka-rest)
 *   mongo-1       -> 192.168.70.71  (initial PRIMARY at rs.initiate; rs re-elects)
 *   mongo-2       -> 192.168.70.72  (replica set member 1)
 *   mongo-3       -> 192.168.70.73  (replica set member 2)
 *   pxc-node-1    -> 192.168.70.51  (Galera node, candidate bootstrap)
 *   pxc-node-2    -> 192.168.70.52  (Galera node)
 *   pxc-node-3    -> 192.168.70.53  (Galera node)
 *   proxysql-1    -> 192.168.70.54  (ProxySQL inst 1; keepalived MASTER for VIP .50)
 *   proxysql-2    -> 192.168.70.55  (ProxySQL inst 2; keepalived BACKUP for VIP .50)
 *   pg-primary    -> 192.168.70.61  (Patroni candidate leader; etcd elects)
 *   pg-replica-1  -> 192.168.70.62  (Patroni replica)
 *   pg-replica-2  -> 192.168.70.63  (Patroni replica)
 *   etcd-1        -> 192.168.70.64  (etcd member for Patroni DCS)
 *   etcd-2        -> 192.168.70.65  (etcd member for Patroni DCS)
 *   etcd-3        -> 192.168.70.66  (etcd member for Patroni DCS)
 *   haproxy-pg-1  -> 192.168.70.67  (HAProxy LB; keepalived MASTER for VIP .60)
 *   haproxy-pg-2  -> 192.168.70.68  (HAProxy LB; keepalived BACKUP for VIP .60)
 *   sql-fci-1     -> 192.168.70.11  (WSFC FCI node 1; shares iSCSI LUN .16)
 *   sql-fci-2     -> 192.168.70.12  (WSFC FCI node 2; shares iSCSI LUN .16)
 *   sql-ag-rep-1  -> 192.168.70.13  (AG async replica 1)
 *   sql-ag-rep-2  -> 192.168.70.14  (AG async replica 2)
 *   mongo-cfg-1       -> 192.168.70.74  (Phase 0.N config-server RS member, initial PRIMARY)
 *   mongo-cfg-2       -> 192.168.70.75  (config-server RS member)
 *   mongo-cfg-3       -> 192.168.70.76  (config-server RS member)
 *   mongo-shard-1-1   -> 192.168.70.77  (shard-1 RS, initial PRIMARY)
 *   mongo-shard-1-2   -> 192.168.70.78  (shard-1 RS)
 *   mongo-shard-1-3   -> 192.168.70.79  (shard-1 RS)
 *   mongo-shard-2-1   -> 192.168.70.80  (shard-2 RS, initial PRIMARY)
 *   mongo-shard-2-2   -> 192.168.70.56  (shard-2 RS -- decade-spill from .80 to first free .56)
 *   mongo-shard-2-3   -> 192.168.70.57  (shard-2 RS)
 *   mongo-mongos-1    -> 192.168.70.58  (mongos query router; round-robin DNS partner)
 *   mongo-mongos-2    -> 192.168.70.59  (mongos query router)
 *
 * The ProxySQL VIP .50, HAProxy VIP .60, and the 3 SQL VIPs .15/.16/.17 are
 * NOT dhcp reservations -- the LB tier VIPs float between their respective
 * pairs via keepalived/VRRP unicast (proxysql/haproxy) and the SQL VIPs are
 * owned by WSFC (cluster IP .15, FCI virtual server .16, AG Listener .17).
 * VMware Workstation's VMnet11 doesn't reliably forward IPv4 multicast
 * 224.0.0.18 -- lesson baked at 0.G.3.5c chunk 1 transient #22; both Linux
 * VRRP pairs use unicast for that reason. WSFC's cluster network adapter
 * uses NetFT (Network Fault Tolerance) with broadcast heartbeats which DOES
 * work on Host-Only -- proven at 0.D.1 dc-nexus bringup.
 *
 * Lives in foundation env (NOT in nexus-infra-oltp/) because the gateway is
 * foundation's responsibility -- consolidating gateway-state ownership in one
 * repo avoids two terraform repos racing on /etc/dnsmasq.d/. The oltp env's
 * clones consume the pinned IPs; they don't write the reservations.
 *
 * Default `enable_oltp_dhcp_reservations = true` per memory/
 * feedback_terraform_partial_apply_destroys_resources.md.
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
    mac_pg_primary      = var.mac_oltp_pg_primary_primary
    mac_pg_replica_1    = var.mac_oltp_pg_replica_1_primary
    mac_pg_replica_2    = var.mac_oltp_pg_replica_2_primary
    mac_etcd_1          = var.mac_oltp_etcd_1_primary
    mac_etcd_2          = var.mac_oltp_etcd_2_primary
    mac_etcd_3          = var.mac_oltp_etcd_3_primary
    mac_haproxy_pg_1    = var.mac_oltp_haproxy_pg_1_primary
    mac_haproxy_pg_2    = var.mac_oltp_haproxy_pg_2_primary
    mac_sql_fci_1       = var.mac_oltp_sql_fci_1_primary
    mac_sql_fci_2       = var.mac_oltp_sql_fci_2_primary
    mac_sql_ag_rep_1    = var.mac_oltp_sql_ag_rep_1_primary
    mac_sql_ag_rep_2    = var.mac_oltp_sql_ag_rep_2_primary
    oltp_reservations_v = "6" # v6 (0.G.7) = +4 SQL Server FCI/AG reservations (sql-fci-1/2 .11/.12, sql-ag-rep-1/2 .13/.14). VIPs .15/.16/.17 (WSFC/FCI/Listener) are NOT dhcp reservations -- owned by WSFC. v5 (0.G.4) added Patroni-tier. v4 was the abandoned single-HAProxy variant. v3 (0.G.3) added Percona/ProxySQL. v2 (0.G.2) added mongo. v1 was redis only.
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
      $mac_pg0 = '${var.mac_oltp_pg_primary_primary}'
      $mac_pg1 = '${var.mac_oltp_pg_replica_1_primary}'
      $mac_pg2 = '${var.mac_oltp_pg_replica_2_primary}'
      $mac_e1  = '${var.mac_oltp_etcd_1_primary}'
      $mac_e2  = '${var.mac_oltp_etcd_2_primary}'
      $mac_e3  = '${var.mac_oltp_etcd_3_primary}'
      $mac_h1  = '${var.mac_oltp_haproxy_pg_1_primary}'
      $mac_h2  = '${var.mac_oltp_haproxy_pg_2_primary}'
      $mac_sf1 = '${var.mac_oltp_sql_fci_1_primary}'
      $mac_sf2 = '${var.mac_oltp_sql_fci_2_primary}'
      $mac_sa1 = '${var.mac_oltp_sql_ag_rep_1_primary}'
      $mac_sa2 = '${var.mac_oltp_sql_ag_rep_2_primary}'
      $mac_cfg1 = '${var.mac_oltp_mongo_cfg_1_primary}'
      $mac_cfg2 = '${var.mac_oltp_mongo_cfg_2_primary}'
      $mac_cfg3 = '${var.mac_oltp_mongo_cfg_3_primary}'
      $mac_s11  = '${var.mac_oltp_mongo_shard_1_1_primary}'
      $mac_s12  = '${var.mac_oltp_mongo_shard_1_2_primary}'
      $mac_s13  = '${var.mac_oltp_mongo_shard_1_3_primary}'
      $mac_s21  = '${var.mac_oltp_mongo_shard_2_1_primary}'
      $mac_s22  = '${var.mac_oltp_mongo_shard_2_2_primary}'
      $mac_s23  = '${var.mac_oltp_mongo_shard_2_3_primary}'
      $mac_mr1  = '${var.mac_oltp_mongo_mongos_1_primary}'
      $mac_mr2  = '${var.mac_oltp_mongo_mongos_2_primary}'
      $marker  = '# OLTP tier dhcp-host reservations managed by terraform/envs/foundation/role-overlay-gateway-oltp-reservations.tf v7'

      # Idempotent insert: marker matches v7 specifically. Earlier versions
      # (v1 redis only, v2 redis+mongo, v3 +percona, v4 the abandoned single-
      # HAProxy variant, v5 +patroni-tier, v6 +sqlserver) all get replaced
      # atomically via write-through tee.
      $existing = ssh nexusadmin@$gw "test -f /etc/dnsmasq.d/foundation-oltp-reservations.conf && cat /etc/dnsmasq.d/foundation-oltp-reservations.conf || true"
      if ($existing -match [regex]::Escape($marker)) {
        Write-Host "[gateway oltp-reservations] v6 reservations already present, no-op."
        exit 0
      }

      # Per nexus-platform-plan/docs/infra/vms.yaml (clusters: redis + mongo + percona + postgres + sqlserver).
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
        "dhcp-host=$mac_pg0,192.168.70.61,pg-primary"
        "dhcp-host=$mac_pg1,192.168.70.62,pg-replica-1"
        "dhcp-host=$mac_pg2,192.168.70.63,pg-replica-2"
        "dhcp-host=$mac_e1,192.168.70.64,etcd-1"
        "dhcp-host=$mac_e2,192.168.70.65,etcd-2"
        "dhcp-host=$mac_e3,192.168.70.66,etcd-3"
        "dhcp-host=$mac_h1,192.168.70.67,haproxy-pg-1"
        "dhcp-host=$mac_h2,192.168.70.68,haproxy-pg-2"
        "dhcp-host=$mac_sf1,192.168.70.11,sql-fci-1"
        "dhcp-host=$mac_sf2,192.168.70.12,sql-fci-2"
        "dhcp-host=$mac_sa1,192.168.70.13,sql-ag-rep-1"
        "dhcp-host=$mac_sa2,192.168.70.14,sql-ag-rep-2"
        "dhcp-host=$mac_cfg1,192.168.70.74,mongo-cfg-1"
        "dhcp-host=$mac_cfg2,192.168.70.75,mongo-cfg-2"
        "dhcp-host=$mac_cfg3,192.168.70.76,mongo-cfg-3"
        "dhcp-host=$mac_s11,192.168.70.77,mongo-shard-1-1"
        "dhcp-host=$mac_s12,192.168.70.78,mongo-shard-1-2"
        "dhcp-host=$mac_s13,192.168.70.79,mongo-shard-1-3"
        "dhcp-host=$mac_s21,192.168.70.80,mongo-shard-2-1"
        "dhcp-host=$mac_s22,192.168.70.56,mongo-shard-2-2"
        "dhcp-host=$mac_s23,192.168.70.57,mongo-shard-2-3"
        "dhcp-host=$mac_mr1,192.168.70.58,mongo-mongos-1"
        "dhcp-host=$mac_mr2,192.168.70.59,mongo-mongos-2"
        ""
      ) -join "`n"

      $script = @"
        echo '$confLines' | sudo tee /etc/dnsmasq.d/foundation-oltp-reservations.conf > /dev/null
        sudo systemctl restart dnsmasq && echo OK
"@
      Write-Host "[gateway oltp-reservations] writing 37 dhcp-host reservations (6 Redis + 3 Mongo + 3 PXC + 2 ProxySQL + 3 Patroni + 3 etcd + 2 HAProxy + 2 SQL-FCI + 2 SQL-AG-replica + 3 Mongo-cfg + 6 Mongo-shards + 2 Mongos) + restarting dnsmasq..."
      ssh nexusadmin@$gw $script
      if ($LASTEXITCODE -ne 0) { throw "[gateway oltp-reservations] ssh tee/restart failed (rc=$LASTEXITCODE)" }
      Write-Host "[gateway oltp-reservations] reservations live: redis-1..6 (.81-.84/.87/.89), mongo-1..3 (.71/.72/.73), pxc-node-1..3 (.51/.52/.53), proxysql-1..2 (.54/.55), pg-primary/pg-replica-1/pg-replica-2 (.61-.63), etcd-1..3 (.64/.65/.66), haproxy-pg-1..2 (.67/.68), sql-fci-1..2 (.11/.12), sql-ag-rep-1..2 (.13/.14), mongo-cfg-1..3 (.74/.75/.76), mongo-shard-1-1..3 (.77/.78/.79), mongo-shard-2-1..3 (.80/.56/.57), mongo-mongos-1..2 (.58/.59)"
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
