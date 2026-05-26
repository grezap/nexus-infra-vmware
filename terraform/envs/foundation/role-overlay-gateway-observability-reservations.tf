/*
 * role-overlay-gateway-observability-reservations.tf -- dnsmasq dhcp-host
 * reservations on nexus-gateway pinning the 14 Phase 0.I observability tier
 * MACs to canonical VMnet11 IPs.
 *
 * Phase 0.I layer (ADR-0038). Per nexus-platform-plan/docs/infra/vms.yaml
 * (cluster: observability), the obs nodes come up at:
 *   Prom HA (0.I.1):       prom-1/2                .170 / .171
 *   Loki SSD (0.I.2):      loki-1/2/3              .172 / .173 / .174
 *   Tempo (0.I.3):         tempo-1/2/3             .175 / .176 / .177
 *   Grafana HA (0.I.4):    grafana-1/2             .178 / .179
 *   Grafana PG HA (0.I.4): grafana-pg-1/2          .180 / .181
 *   OTel (0.I.5):          otel-collector-1/2      .182 / .183
 *
 * MAC block :B2-:BF (just past the registry tier high-water :B1). All 14
 * reservations are written here from day one; idle reservations for not-yet-
 * built nodes (e.g. loki-1 before 0.I.2 ratifies) are harmless. Mirrors
 * role-overlay-gateway-lakehouse-reservations.tf shape exactly.
 *
 * Default enable_observability_dhcp_reservations = true per memory/
 * feedback_terraform_partial_apply_destroys_resources.md.
 */

resource "null_resource" "gateway_observability_reservations" {
  count = var.enable_observability_dhcp_reservations ? 1 : 0

  triggers = {
    gateway_ip                   = "192.168.70.1"
    mac_prom_1                   = var.mac_obs_prom_1_primary
    mac_prom_2                   = var.mac_obs_prom_2_primary
    mac_loki_1                   = var.mac_obs_loki_1_primary
    mac_loki_2                   = var.mac_obs_loki_2_primary
    mac_loki_3                   = var.mac_obs_loki_3_primary
    mac_tempo_1                  = var.mac_obs_tempo_1_primary
    mac_tempo_2                  = var.mac_obs_tempo_2_primary
    mac_tempo_3                  = var.mac_obs_tempo_3_primary
    mac_grafana_1                = var.mac_obs_grafana_1_primary
    mac_grafana_2                = var.mac_obs_grafana_2_primary
    mac_grafana_pg_1             = var.mac_obs_grafana_pg_1_primary
    mac_grafana_pg_2             = var.mac_obs_grafana_pg_2_primary
    mac_otel_1                   = var.mac_obs_otel_1_primary
    mac_otel_2                   = var.mac_obs_otel_2_primary
    observability_reservations_v = "1"
  }

  provisioner "local-exec" {
    when        = create
    interpreter = ["pwsh", "-NoProfile", "-Command"]
    command     = <<-PWSH
      $gw       = '192.168.70.1'
      $mac_p1   = '${var.mac_obs_prom_1_primary}'
      $mac_p2   = '${var.mac_obs_prom_2_primary}'
      $mac_l1   = '${var.mac_obs_loki_1_primary}'
      $mac_l2   = '${var.mac_obs_loki_2_primary}'
      $mac_l3   = '${var.mac_obs_loki_3_primary}'
      $mac_t1   = '${var.mac_obs_tempo_1_primary}'
      $mac_t2   = '${var.mac_obs_tempo_2_primary}'
      $mac_t3   = '${var.mac_obs_tempo_3_primary}'
      $mac_g1   = '${var.mac_obs_grafana_1_primary}'
      $mac_g2   = '${var.mac_obs_grafana_2_primary}'
      $mac_gpg1 = '${var.mac_obs_grafana_pg_1_primary}'
      $mac_gpg2 = '${var.mac_obs_grafana_pg_2_primary}'
      $mac_o1   = '${var.mac_obs_otel_1_primary}'
      $mac_o2   = '${var.mac_obs_otel_2_primary}'
      $marker = '# Observability tier (Prom + Loki + Tempo + Grafana + Grafana-PG + OTel) dhcp-host reservations managed by terraform/envs/foundation/role-overlay-gateway-observability-reservations.tf v1'

      $existing = ssh nexusadmin@$gw "test -f /etc/dnsmasq.d/foundation-observability-reservations.conf && cat /etc/dnsmasq.d/foundation-observability-reservations.conf || true"
      if ($existing -match [regex]::Escape($marker)) {
        Write-Host "[gateway observability-reservations] v1 reservations already present, no-op."
        exit 0
      }

      $confLines = @(
        $marker
        "dhcp-host=$mac_p1,192.168.70.170,prom-1"
        "dhcp-host=$mac_p2,192.168.70.171,prom-2"
        "dhcp-host=$mac_l1,192.168.70.172,loki-1"
        "dhcp-host=$mac_l2,192.168.70.173,loki-2"
        "dhcp-host=$mac_l3,192.168.70.174,loki-3"
        "dhcp-host=$mac_t1,192.168.70.175,tempo-1"
        "dhcp-host=$mac_t2,192.168.70.176,tempo-2"
        "dhcp-host=$mac_t3,192.168.70.177,tempo-3"
        "dhcp-host=$mac_g1,192.168.70.178,grafana-1"
        "dhcp-host=$mac_g2,192.168.70.179,grafana-2"
        "dhcp-host=$mac_gpg1,192.168.70.180,grafana-pg-1"
        "dhcp-host=$mac_gpg2,192.168.70.181,grafana-pg-2"
        "dhcp-host=$mac_o1,192.168.70.182,otel-collector-1"
        "dhcp-host=$mac_o2,192.168.70.183,otel-collector-2"
        ""
      ) -join "`n"

      $script = @"
        echo '$confLines' | sudo tee /etc/dnsmasq.d/foundation-observability-reservations.conf > /dev/null
        sudo systemctl restart dnsmasq && echo OK
"@
      Write-Host "[gateway observability-reservations] writing 14 obs dhcp-host reservations (2 Prom + 3 Loki + 3 Tempo + 2 Grafana + 2 Grafana-PG + 2 OTel) + restarting dnsmasq..."
      ssh nexusadmin@$gw $script
      if ($LASTEXITCODE -ne 0) { throw "[gateway observability-reservations] ssh tee/restart failed (rc=$LASTEXITCODE)" }
      Write-Host "[gateway observability-reservations] reservations live: prom .170-.171, loki .172-.174, tempo .175-.177, grafana .178-.179, grafana-pg .180-.181, otel .182-.183"
    PWSH
  }

  provisioner "local-exec" {
    when        = destroy
    interpreter = ["pwsh", "-NoProfile", "-Command"]
    command     = <<-PWSH
      $gw = '${self.triggers.gateway_ip}'
      Write-Host "[gateway observability-reservations] removing reservations + restarting dnsmasq..."
      ssh nexusadmin@$gw "sudo rm -f /etc/dnsmasq.d/foundation-observability-reservations.conf && sudo systemctl restart dnsmasq" 2>$null
      exit 0
    PWSH
  }
}
