/*
 * role-overlay-vault-pki-consul.tf -- Phase 0.E.2 setup
 *
 * Defines the `consul-server` PKI role at pki_int/. Used by the 6 swarm-node
 * Vault Agents (Phase 0.E.2.1+) to issue Consul TLS leaf certs that cover:
 *
 *   - Subject CN: <hostname>.consul.nexus.lab
 *   - SANs: <hostname>, <hostname>.nexus.lab, <hostname>.consul.nexus.lab
 *           IPs: 192.168.10.111-113 + .131-.133 (VMnet10), 192.168.70.111-113
 *           + .131-.133 (VMnet11), 127.0.0.1
 *
 * Per nexus-platform-plan/MASTER-PLAN.md s 5.4 + ADR-0012 PKI hierarchy:
 * 90-day leaf TTL (matches 0.D.5.2 cadence). server+client EKU because Consul
 * agents BOTH listen (RPC server, HTTP server) AND connect outbound (joining
 * peers). This differs from the existing `vault-server` role (server-only).
 *
 * `vault write` on roles is upsert -- always-overwrite is naturally
 * idempotent. Triggers track config so a knob change re-applies.
 *
 * Selective ops: var.enable_vault_pki AND var.enable_swarm_pki.
 */

resource "null_resource" "vault_pki_consul_role" {
  count = var.enable_vault_cluster && var.enable_vault_init && var.enable_vault_pki && var.enable_swarm_pki ? 1 : 0

  triggers = {
    int_id                = length(null_resource.vault_pki_intermediate_ca) > 0 ? null_resource.vault_pki_intermediate_ca[0].id : "disabled"
    role_name             = var.vault_pki_consul_role_name
    leaf_ttl              = var.vault_pki_leaf_ttl
    consul_role_overlay_v = "1"
  }

  depends_on = [null_resource.vault_pki_intermediate_ca]

  provisioner "local-exec" {
    when        = create
    interpreter = ["pwsh", "-NoProfile", "-Command"]
    command     = <<-PWSH
      $ip          = '${local.vault_1_ip}'
      $user        = '${local.ssh_user}'
      $roleName    = '${var.vault_pki_consul_role_name}'
      $leafTtl     = '${var.vault_pki_leaf_ttl}'
      $keysFileRaw = '${var.vault_init_keys_file}'
      $keysFile    = $ExecutionContext.InvokeCommand.ExpandString($keysFileRaw.Replace('$HOME', $env:USERPROFILE))

      if (-not (Test-Path $keysFile)) { throw "[pki-consul] keys file $keysFile missing" }
      $rootToken = (Get-Content $keysFile | ConvertFrom-Json).root_token

      $bash = @"
set -euo pipefail
export VAULT_TOKEN='$rootToken'
export VAULT_SKIP_VERIFY=true
export VAULT_ADDR=https://127.0.0.1:8200

echo "[pki-consul] writing pki_int/roles/$roleName (idempotent overwrite)"
vault write pki_int/roles/$roleName \
  allowed_domains='nexus.lab,consul.nexus.lab,swarm-manager-1,swarm-manager-2,swarm-manager-3,swarm-worker-1,swarm-worker-2,swarm-worker-3,swarm-manager-1.nexus.lab,swarm-manager-2.nexus.lab,swarm-manager-3.nexus.lab,swarm-worker-1.nexus.lab,swarm-worker-2.nexus.lab,swarm-worker-3.nexus.lab,swarm-manager-1.consul.nexus.lab,swarm-manager-2.consul.nexus.lab,swarm-manager-3.consul.nexus.lab,swarm-worker-1.consul.nexus.lab,swarm-worker-2.consul.nexus.lab,swarm-worker-3.consul.nexus.lab,localhost,server.nexus-lab.consul' \
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
echo "[pki-consul] role pki_int/roles/$roleName configured (allowed_domains=`$ALLOWED entries, ttl=$leafTtl, server+client EKU)"
"@

      $bytes = [System.Text.UTF8Encoding]::new($false).GetBytes($bash)
      $b64   = [Convert]::ToBase64String($bytes)

      Write-Host "[pki-consul] dispatching to $${ip} via base64"
      $output = ssh -o ConnectTimeout=30 -o BatchMode=yes -o StrictHostKeyChecking=no $user@$ip "echo '$b64' | base64 -d | bash" 2>&1 | Out-String
      $rc = $LASTEXITCODE
      Write-Host $output.Trim()
      if ($rc -ne 0) {
        throw "[pki-consul] script failed (rc=$rc)"
      }
    PWSH
  }
}
