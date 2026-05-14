/*
 * role-overlay-vault-pki-kafka.tf -- Phase 0.H.2 setup
 *
 * Defines the `kafka-broker` PKI role at pki_int/. Used by the 6 kafka-node
 * Vault Agents (nexus-infra-kafka, Phase 0.H.2) to issue Kafka broker TLS
 * leaf certs that cover:
 *
 *   - Subject CN: <hostname>.kafka.nexus.lab
 *   - SANs: <hostname>, <hostname>.nexus.lab, <hostname>.kafka.nexus.lab,
 *           localhost
 *           IPs: 192.168.10.21-26 (VMnet10 backplane), 192.168.70.21-26
 *           (VMnet11 service), 127.0.0.1
 *
 * Per nexus-platform-plan/MASTER-PLAN.md line 160 (Phase 0.H) + ADR-0012 PKI
 * hierarchy: 90-day leaf TTL (matches the consul-server / nomad-server roles).
 * server+client EKU because Kafka brokers BOTH listen (client + controller
 * + inter-broker SSL listeners) AND dial peers (inter-broker replication +
 * controller-quorum RPC). Same shape as the `consul-server` role; differs
 * from the single-purpose `vault-server` role (server-only).
 *
 * Why allowed_domains enumerates every literal name: allow_subdomains=false
 * + allow_bare_domains=true means each CN/SAN must match a literal entry.
 * The kafka-node Vault Agent template (nexus-infra-kafka's
 * role-overlay-kafka-tls.tf) passes per-broker common_name + alt_names that
 * must all be covered here.
 *
 * `vault write` on roles is upsert -- always-overwrite is naturally
 * idempotent. Triggers track config so a knob change re-applies.
 *
 * Selective ops: var.enable_vault_pki AND var.enable_kafka_pki.
 */

resource "null_resource" "vault_pki_kafka_role" {
  count = var.enable_vault_cluster && var.enable_vault_init && var.enable_vault_pki && var.enable_kafka_pki ? 1 : 0

  triggers = {
    int_id               = length(null_resource.vault_pki_intermediate_ca) > 0 ? null_resource.vault_pki_intermediate_ca[0].id : "disabled"
    role_name            = var.vault_pki_kafka_role_name
    leaf_ttl             = var.vault_pki_leaf_ttl
    kafka_role_overlay_v = "1"
  }

  depends_on = [null_resource.vault_pki_intermediate_ca]

  provisioner "local-exec" {
    when        = create
    interpreter = ["pwsh", "-NoProfile", "-Command"]
    command     = <<-PWSH
      $ip          = '${local.vault_1_ip}'
      $user        = '${local.ssh_user}'
      $roleName    = '${var.vault_pki_kafka_role_name}'
      $leafTtl     = '${var.vault_pki_leaf_ttl}'
      $keysFileRaw = '${var.vault_init_keys_file}'
      $keysFile    = $ExecutionContext.InvokeCommand.ExpandString($keysFileRaw.Replace('$HOME', $env:USERPROFILE))

      if (-not (Test-Path $keysFile)) { throw "[pki-kafka] keys file $keysFile missing" }
      $rootToken = (Get-Content $keysFile | ConvertFrom-Json).root_token

      $bash = @"
set -euo pipefail
export VAULT_TOKEN='$rootToken'
export VAULT_SKIP_VERIFY=true
export VAULT_ADDR=https://127.0.0.1:8200

echo "[pki-kafka] writing pki_int/roles/$roleName (idempotent overwrite)"
vault write pki_int/roles/$roleName \
  allowed_domains='nexus.lab,kafka.nexus.lab,kafka-east-1,kafka-east-2,kafka-east-3,kafka-west-1,kafka-west-2,kafka-west-3,kafka-east-1.nexus.lab,kafka-east-2.nexus.lab,kafka-east-3.nexus.lab,kafka-west-1.nexus.lab,kafka-west-2.nexus.lab,kafka-west-3.nexus.lab,kafka-east-1.kafka.nexus.lab,kafka-east-2.kafka.nexus.lab,kafka-east-3.kafka.nexus.lab,kafka-west-1.kafka.nexus.lab,kafka-west-2.kafka.nexus.lab,kafka-west-3.kafka.nexus.lab,localhost' \
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
echo "[pki-kafka] role pki_int/roles/$roleName configured (allowed_domains=`$ALLOWED entries, ttl=$leafTtl, server+client EKU)"
"@

      $bytes = [System.Text.UTF8Encoding]::new($false).GetBytes($bash)
      $b64   = [Convert]::ToBase64String($bytes)

      Write-Host "[pki-kafka] dispatching to $${ip} via base64"
      $output = ssh -o ConnectTimeout=30 -o BatchMode=yes -o StrictHostKeyChecking=no $user@$ip "echo '$b64' | base64 -d | bash" 2>&1 | Out-String
      $rc = $LASTEXITCODE
      Write-Host $output.Trim()
      if ($rc -ne 0) {
        throw "[pki-kafka] script failed (rc=$rc)"
      }
    PWSH
  }
}
