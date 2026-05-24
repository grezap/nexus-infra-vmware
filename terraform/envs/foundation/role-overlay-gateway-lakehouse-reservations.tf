/*
 * role-overlay-gateway-lakehouse-reservations.tf -- dnsmasq dhcp-host
 * reservations on nexus-gateway pinning the 08-spark lakehouse tier MACs to
 * canonical VMnet11 IPs.
 *
 * Phase 0.L layer. Per nexus-platform-plan/docs/infra/vms.yaml (cluster: minio
 * + cluster: spark + cluster: iceberg), the lakehouse nodes come up at:
 *   MinIO (0.L.1):        minio-1/2/3/4         -> .141 / .142 / .143 / .144
 *   Spark (0.L.3):        spark-master-1/2      -> .140 / .153  (HA pair)
 *                         spark-worker-1/2/3    -> .145 / .146 / .154
 *   ZooKeeper (0.L.3):    zookeeper-1/2/3       -> .155 / .156 / .157
 *   Iceberg REST (0.L.2): iceberg-rest-1/2      -> .147 / .148
 *   Iceberg PG  (0.L.2):  iceberg-pg-1/2        -> .149 / .150
 *
 * MAC block :99-:A3 (after the analytics tier, :98) for 0.L.1/0.L.2; the 0.L.3
 * Spark HA expansion (spark-master-2, spark-worker-3, zookeeper-1..3) uses
 * :AA-:AE -- the :A4-:A9 gap is reserved for 0.L.4 registry + 0.L.5 StarRocks
 * shared-data. All 16 reservations are written here (idle reservations for
 * not-yet-built nodes are harmless); subsequent sub-phases just clone into them.
 * Mirrors role-overlay-gateway-analytics-reservations.tf shape exactly.
 *
 * Default enable_lakehouse_dhcp_reservations = true per memory/
 * feedback_terraform_partial_apply_destroys_resources.md.
 */

resource "null_resource" "gateway_lakehouse_reservations" {
  count = var.enable_lakehouse_dhcp_reservations ? 1 : 0

  triggers = {
    gateway_ip               = "192.168.70.1"
    mac_spark_master         = var.mac_lakehouse_spark_master_primary
    mac_minio_1              = var.mac_lakehouse_minio_1_primary
    mac_minio_2              = var.mac_lakehouse_minio_2_primary
    mac_minio_3              = var.mac_lakehouse_minio_3_primary
    mac_minio_4              = var.mac_lakehouse_minio_4_primary
    mac_spark_worker_1       = var.mac_lakehouse_spark_worker_1_primary
    mac_spark_worker_2       = var.mac_lakehouse_spark_worker_2_primary
    mac_iceberg_rest_1       = var.mac_lakehouse_iceberg_rest_1_primary
    mac_iceberg_rest_2       = var.mac_lakehouse_iceberg_rest_2_primary
    mac_iceberg_pg_1         = var.mac_lakehouse_iceberg_pg_1_primary
    mac_iceberg_pg_2         = var.mac_lakehouse_iceberg_pg_2_primary
    mac_spark_master_2       = var.mac_lakehouse_spark_master_2_primary
    mac_spark_worker_3       = var.mac_lakehouse_spark_worker_3_primary
    mac_zookeeper_1          = var.mac_lakehouse_zookeeper_1_primary
    mac_zookeeper_2          = var.mac_lakehouse_zookeeper_2_primary
    mac_zookeeper_3          = var.mac_lakehouse_zookeeper_3_primary
    lakehouse_reservations_v = "2" # v2 (0.L.3) renames spark-master->spark-master-1 + adds spark-master-2/worker-3/zookeeper-1..3
  }

  provisioner "local-exec" {
    when        = create
    interpreter = ["pwsh", "-NoProfile", "-Command"]
    command     = <<-PWSH
      $gw     = '192.168.70.1'
      $mac_sm  = '${var.mac_lakehouse_spark_master_primary}'
      $mac_m1  = '${var.mac_lakehouse_minio_1_primary}'
      $mac_m2  = '${var.mac_lakehouse_minio_2_primary}'
      $mac_m3  = '${var.mac_lakehouse_minio_3_primary}'
      $mac_m4  = '${var.mac_lakehouse_minio_4_primary}'
      $mac_sw1 = '${var.mac_lakehouse_spark_worker_1_primary}'
      $mac_sw2 = '${var.mac_lakehouse_spark_worker_2_primary}'
      $mac_ir1 = '${var.mac_lakehouse_iceberg_rest_1_primary}'
      $mac_ir2 = '${var.mac_lakehouse_iceberg_rest_2_primary}'
      $mac_ip1 = '${var.mac_lakehouse_iceberg_pg_1_primary}'
      $mac_ip2 = '${var.mac_lakehouse_iceberg_pg_2_primary}'
      $mac_sm2 = '${var.mac_lakehouse_spark_master_2_primary}'
      $mac_sw3 = '${var.mac_lakehouse_spark_worker_3_primary}'
      $mac_zk1 = '${var.mac_lakehouse_zookeeper_1_primary}'
      $mac_zk2 = '${var.mac_lakehouse_zookeeper_2_primary}'
      $mac_zk3 = '${var.mac_lakehouse_zookeeper_3_primary}'
      $marker = '# Lakehouse tier (MinIO + Spark + ZooKeeper + Iceberg) dhcp-host reservations managed by terraform/envs/foundation/role-overlay-gateway-lakehouse-reservations.tf v2'

      $existing = ssh nexusadmin@$gw "test -f /etc/dnsmasq.d/foundation-lakehouse-reservations.conf && cat /etc/dnsmasq.d/foundation-lakehouse-reservations.conf || true"
      if ($existing -match [regex]::Escape($marker)) {
        Write-Host "[gateway lakehouse-reservations] v1 reservations already present, no-op."
        exit 0
      }

      $confLines = @(
        $marker
        "dhcp-host=$mac_sm,192.168.70.140,spark-master-1"
        "dhcp-host=$mac_m1,192.168.70.141,minio-1"
        "dhcp-host=$mac_m2,192.168.70.142,minio-2"
        "dhcp-host=$mac_m3,192.168.70.143,minio-3"
        "dhcp-host=$mac_m4,192.168.70.144,minio-4"
        "dhcp-host=$mac_sw1,192.168.70.145,spark-worker-1"
        "dhcp-host=$mac_sw2,192.168.70.146,spark-worker-2"
        "dhcp-host=$mac_ir1,192.168.70.147,iceberg-rest-1"
        "dhcp-host=$mac_ir2,192.168.70.148,iceberg-rest-2"
        "dhcp-host=$mac_ip1,192.168.70.149,iceberg-pg-1"
        "dhcp-host=$mac_ip2,192.168.70.150,iceberg-pg-2"
        "dhcp-host=$mac_sm2,192.168.70.153,spark-master-2"
        "dhcp-host=$mac_sw3,192.168.70.154,spark-worker-3"
        "dhcp-host=$mac_zk1,192.168.70.155,zookeeper-1"
        "dhcp-host=$mac_zk2,192.168.70.156,zookeeper-2"
        "dhcp-host=$mac_zk3,192.168.70.157,zookeeper-3"
        ""
      ) -join "`n"

      $script = @"
        echo '$confLines' | sudo tee /etc/dnsmasq.d/foundation-lakehouse-reservations.conf > /dev/null
        sudo systemctl restart dnsmasq && echo OK
"@
      Write-Host "[gateway lakehouse-reservations] writing 16 lakehouse dhcp-host reservations (4 MinIO + 2 Spark masters + 3 Spark workers + 3 ZooKeeper + 2 Iceberg REST + 2 Iceberg PG) + restarting dnsmasq..."
      ssh nexusadmin@$gw $script
      if ($LASTEXITCODE -ne 0) { throw "[gateway lakehouse-reservations] ssh tee/restart failed (rc=$LASTEXITCODE)" }
      Write-Host "[gateway lakehouse-reservations] reservations live: minio .141-.144, spark-master .140/.153, spark-worker .145/.146/.154, zookeeper .155-.157, iceberg-rest .147/.148, iceberg-pg .149/.150"
    PWSH
  }

  provisioner "local-exec" {
    when        = destroy
    interpreter = ["pwsh", "-NoProfile", "-Command"]
    command     = <<-PWSH
      $gw = '${self.triggers.gateway_ip}'
      Write-Host "[gateway lakehouse-reservations] removing reservations + restarting dnsmasq..."
      ssh nexusadmin@$gw "sudo rm -f /etc/dnsmasq.d/foundation-lakehouse-reservations.conf && sudo systemctl restart dnsmasq" 2>$null
      exit 0
    PWSH
  }
}
