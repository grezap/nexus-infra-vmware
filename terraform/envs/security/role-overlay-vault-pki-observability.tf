/*
 * role-overlay-vault-pki-observability.tf -- Phase 0.I setup (obs tier mTLS)
 *
 * Defines the `observability-server` PKI role at pki_int/. Leaf-cert role for
 * all 14 obs nodes (2 Prom + 3 Loki + 3 Tempo + 2 Grafana + 2 Grafana PG + 2
 * OTel). Per-host CN/SAN passed at issue time by the respective obs sub-phase
 * TLS overlays in nexus-infra-observability.
 *
 * Certs cover: CN <hostname>.nexus.lab; SANs <hostname>, <hostname>.nexus.lab,
 * 5 round-robin DNS names (prometheus / alertmanager / loki / tempo / otel),
 * the 2 VRRP VIP DNS names (grafana / grafana-db), localhost; IPs the 14
 * node service IPs + 2 VRRP VIPs (.184, .185) + the backplane IPs + 127.0.0.1.
 * server+client EKU; 90-day TTL.
 *
 * Selective ops: var.enable_vault_pki AND var.enable_observability_pki.
 */

resource "null_resource" "vault_pki_observability_role" {
  count = var.enable_vault_cluster && var.enable_vault_init && var.enable_vault_pki && var.enable_observability_pki ? 1 : 0

  triggers = {
    int_id           = length(null_resource.vault_pki_intermediate_ca) > 0 ? null_resource.vault_pki_intermediate_ca[0].id : "disabled"
    role_name        = var.vault_pki_obs_role_name
    leaf_ttl         = var.vault_pki_leaf_ttl
    obs_role_overlay = "1"
  }

  depends_on = [null_resource.vault_pki_intermediate_ca]

  provisioner "local-exec" {
    when        = create
    interpreter = ["pwsh", "-NoProfile", "-Command"]
    command     = <<-PWSH
      $ip          = '${local.vault_1_ip}'
      $user        = '${local.ssh_user}'
      $roleName    = '${var.vault_pki_obs_role_name}'
      $leafTtl     = '${var.vault_pki_leaf_ttl}'
      $keysFileRaw = '${var.vault_init_keys_file}'
      $keysFile    = $ExecutionContext.InvokeCommand.ExpandString($keysFileRaw.Replace('$HOME', $env:USERPROFILE))

      if (-not (Test-Path $keysFile)) { throw "[pki-observability] keys file $keysFile missing" }
      $rootToken = (Get-Content $keysFile | ConvertFrom-Json).root_token

      $allowed = @(
        'nexus.lab'
        # 5 RR DNS names + 2 VIP names + observability subdomain root
        'prometheus.nexus.lab'
        'alertmanager.nexus.lab'
        'loki.nexus.lab'
        'tempo.nexus.lab'
        'otel.nexus.lab'
        'grafana.nexus.lab'
        'grafana-db.nexus.lab'
        # 14 hostnames bare + .nexus.lab
        'prom-1'; 'prom-2'
        'loki-1'; 'loki-2'; 'loki-3'
        'tempo-1'; 'tempo-2'; 'tempo-3'
        'grafana-1'; 'grafana-2'
        'grafana-pg-1'; 'grafana-pg-2'
        'otel-collector-1'; 'otel-collector-2'
        'prom-1.nexus.lab'; 'prom-2.nexus.lab'
        'loki-1.nexus.lab'; 'loki-2.nexus.lab'; 'loki-3.nexus.lab'
        'tempo-1.nexus.lab'; 'tempo-2.nexus.lab'; 'tempo-3.nexus.lab'
        'grafana-1.nexus.lab'; 'grafana-2.nexus.lab'
        'grafana-pg-1.nexus.lab'; 'grafana-pg-2.nexus.lab'
        'otel-collector-1.nexus.lab'; 'otel-collector-2.nexus.lab'
        'localhost'
      ) -join ','

      $bash = @"
set -euo pipefail
export VAULT_TOKEN='$rootToken'
export VAULT_SKIP_VERIFY=true
export VAULT_ADDR=https://127.0.0.1:8200

echo "[pki-observability] writing pki_int/roles/$roleName (idempotent overwrite)"
vault write pki_int/roles/$roleName \
  allowed_domains='$allowed' \
  allow_subdomains=false \
  allow_bare_domains=true \
  allow_glob_domains=false \
  allow_ip_sans=true \
  enforce_hostnames=false \
  server_flag=true \
  client_flag=true \
  key_type=rsa \
  key_bits=4096 \
  ttl='$leafTtl' \
  max_ttl='$leafTtl' \
  no_store=false >/dev/null

ALLOWED=`$(vault read -format=json pki_int/roles/$roleName | jq -r '.data.allowed_domains | length')
echo "[pki-observability] role pki_int/roles/$roleName configured (allowed_domains=`$ALLOWED entries, ttl=$leafTtl, server+client EKU)"
"@

      $b64 = [Convert]::ToBase64String([System.Text.UTF8Encoding]::new($false).GetBytes($bash))
      Write-Host "[pki-observability] dispatching to $${ip} via base64"
      $output = ssh -o ConnectTimeout=30 -o BatchMode=yes -o StrictHostKeyChecking=no $user@$ip "echo '$b64' | base64 -d | bash" 2>&1 | Out-String
      $rc = $LASTEXITCODE
      Write-Host $output.Trim()
      if ($rc -ne 0) { throw "[pki-observability] script failed (rc=$rc)" }
    PWSH
  }
}
