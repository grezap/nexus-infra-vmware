/*
 * role-overlay-gateway-kafka-reservations.tf -- dnsmasq dhcp-host reservations
 * on nexus-gateway pinning the 15-VM Kafka tier MACs to canonical VMnet11 IPs.
 *
 * Phase 0.H layer. Per nexus-platform-plan/docs/infra/vms.yaml lines 84-112,
 * the Kafka tier nodes must come up at canonical IPs:
 *   kafka-east-1/2/3    -> 192.168.70.21 / .22 / .23
 *   kafka-west-1/2/3    -> 192.168.70.24 / .25 / .26
 *   schema-registry-1/2 -> 192.168.70.91 / .92
 *   kafka-connect-1/2   -> 192.168.70.95 / .96
 *   ksqldb-1/2          -> 192.168.70.97 / .98   (.98 -- vms.yaml line 109's
 *                          .99 is a typo, fixed at the 0.H.6 close-out batch)
 *   mm2-1/2             -> 192.168.70.85 / .86
 *   kafka-rest-1        -> 192.168.70.88
 *
 * nexus-gateway's dnsmasq dynamic DHCP pool is .200-.250; dnsmasq honors
 * `dhcp-host=<MAC>,<IP>,<hostname>` reservations regardless of whether the
 * IP falls inside dhcp-range, so we add per-MAC reservations here without
 * modifying the gateway template.
 *
 * Lives in foundation env (NOT in nexus-infra-kafka/) because the gateway is
 * foundation's responsibility -- consolidating gateway-state ownership in one
 * repo avoids two terraform repos racing on /etc/dnsmasq.d/. The kafka env's
 * clones consume the pinned IPs; they don't write the reservations.
 *
 * All 15 reservations land in one v1 file even though Phase 0.H deploys the
 * tier in sub-phases (brokers in 0.H.1, ecosystem in 0.H.3-0.H.5) -- a
 * reservation for a not-yet-cloned VM is harmless (dnsmasq just holds the
 * MAC->IP binding ready), and one v1 file avoids marker-version churn.
 *
 * Default `enable_kafka_dhcp_reservations = true` per memory/
 * feedback_terraform_partial_apply_destroys_resources.md.
 *
 * Mirrors role-overlay-gateway-swarm-reservations.tf shape exactly:
 *   - SSH to gateway, write /etc/dnsmasq.d/foundation-kafka-reservations.conf
 *   - Marker comment includes overlay version for idempotent re-apply
 *   - systemctl restart dnsmasq (NOT reload -- doesn't re-read dhcp-host)
 *   - Destroy-time provisioner removes the conf + restarts
 */

resource "null_resource" "gateway_kafka_reservations" {
  count = var.enable_kafka_dhcp_reservations ? 1 : 0

  triggers = {
    gateway_ip           = "192.168.70.1"
    mac_e1               = var.mac_kafka_east_1_primary
    mac_e2               = var.mac_kafka_east_2_primary
    mac_e3               = var.mac_kafka_east_3_primary
    mac_w1               = var.mac_kafka_west_1_primary
    mac_w2               = var.mac_kafka_west_2_primary
    mac_w3               = var.mac_kafka_west_3_primary
    mac_sr1              = var.mac_kafka_schema_registry_1_primary
    mac_sr2              = var.mac_kafka_schema_registry_2_primary
    mac_kc1              = var.mac_kafka_connect_1_primary
    mac_kc2              = var.mac_kafka_connect_2_primary
    mac_kq1              = var.mac_kafka_ksqldb_1_primary
    mac_kq2              = var.mac_kafka_ksqldb_2_primary
    mac_mm1              = var.mac_kafka_mm2_1_primary
    mac_mm2              = var.mac_kafka_mm2_2_primary
    mac_rest             = var.mac_kafka_rest_1_primary
    kafka_reservations_v = "1"
  }

  provisioner "local-exec" {
    when        = create
    interpreter = ["pwsh", "-NoProfile", "-Command"]
    command     = <<-PWSH
      $gw       = '192.168.70.1'
      $mac_e1   = '${var.mac_kafka_east_1_primary}'
      $mac_e2   = '${var.mac_kafka_east_2_primary}'
      $mac_e3   = '${var.mac_kafka_east_3_primary}'
      $mac_w1   = '${var.mac_kafka_west_1_primary}'
      $mac_w2   = '${var.mac_kafka_west_2_primary}'
      $mac_w3   = '${var.mac_kafka_west_3_primary}'
      $mac_sr1  = '${var.mac_kafka_schema_registry_1_primary}'
      $mac_sr2  = '${var.mac_kafka_schema_registry_2_primary}'
      $mac_kc1  = '${var.mac_kafka_connect_1_primary}'
      $mac_kc2  = '${var.mac_kafka_connect_2_primary}'
      $mac_kq1  = '${var.mac_kafka_ksqldb_1_primary}'
      $mac_kq2  = '${var.mac_kafka_ksqldb_2_primary}'
      $mac_mm1  = '${var.mac_kafka_mm2_1_primary}'
      $mac_mm2  = '${var.mac_kafka_mm2_2_primary}'
      $mac_rest = '${var.mac_kafka_rest_1_primary}'
      $marker   = '# Kafka tier dhcp-host reservations managed by terraform/envs/foundation/role-overlay-gateway-kafka-reservations.tf v1'

      # Idempotent insert: marker matches v1 specifically.
      $existing = ssh nexusadmin@$gw "test -f /etc/dnsmasq.d/foundation-kafka-reservations.conf && cat /etc/dnsmasq.d/foundation-kafka-reservations.conf || true"
      if ($existing -match [regex]::Escape($marker)) {
        Write-Host "[gateway kafka-reservations] v1 reservations already present, no-op."
        exit 0
      }

      # Per nexus-platform-plan/docs/infra/vms.yaml lines 88-112.
      $confLines = @(
        $marker
        "dhcp-host=$mac_e1,192.168.70.21,kafka-east-1"
        "dhcp-host=$mac_e2,192.168.70.22,kafka-east-2"
        "dhcp-host=$mac_e3,192.168.70.23,kafka-east-3"
        "dhcp-host=$mac_w1,192.168.70.24,kafka-west-1"
        "dhcp-host=$mac_w2,192.168.70.25,kafka-west-2"
        "dhcp-host=$mac_w3,192.168.70.26,kafka-west-3"
        "dhcp-host=$mac_sr1,192.168.70.91,schema-registry-1"
        "dhcp-host=$mac_sr2,192.168.70.92,schema-registry-2"
        "dhcp-host=$mac_kc1,192.168.70.95,kafka-connect-1"
        "dhcp-host=$mac_kc2,192.168.70.96,kafka-connect-2"
        "dhcp-host=$mac_kq1,192.168.70.97,ksqldb-1"
        "dhcp-host=$mac_kq2,192.168.70.98,ksqldb-2"
        "dhcp-host=$mac_mm1,192.168.70.85,mm2-1"
        "dhcp-host=$mac_mm2,192.168.70.86,mm2-2"
        "dhcp-host=$mac_rest,192.168.70.88,kafka-rest-1"
        ""
      ) -join "`n"

      $script = @"
        echo '$confLines' | sudo tee /etc/dnsmasq.d/foundation-kafka-reservations.conf > /dev/null
        sudo systemctl restart dnsmasq && echo OK
"@
      Write-Host "[gateway kafka-reservations] writing 15 dhcp-host reservations + restarting dnsmasq..."
      ssh nexusadmin@$gw $script
      if ($LASTEXITCODE -ne 0) { throw "[gateway kafka-reservations] ssh tee/restart failed (rc=$LASTEXITCODE)" }
      Write-Host "[gateway kafka-reservations] reservations live: brokers .21-.26, ecosystem .85/.86/.88/.91/.92/.95-.98"
    PWSH
  }

  provisioner "local-exec" {
    when        = destroy
    interpreter = ["pwsh", "-NoProfile", "-Command"]
    command     = <<-PWSH
      $gw = '${self.triggers.gateway_ip}'
      Write-Host "[gateway kafka-reservations] removing reservations + restarting dnsmasq..."
      ssh nexusadmin@$gw "sudo rm -f /etc/dnsmasq.d/foundation-kafka-reservations.conf && sudo systemctl restart dnsmasq" 2>$null
      exit 0
    PWSH
  }
}
