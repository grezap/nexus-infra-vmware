/*
 * role-overlay-vault-pki-clickhouse.tf -- Phase 0.G.5 setup (ClickHouse mTLS)
 *
 * Defines the `clickhouse-server` PKI role at pki_int/. The leaf-cert role for
 * the 04-analytics tier's ClickHouse cluster -- all 9 nodes (3 Keeper +
 * 3 shards x 2 replicas). One role covers both engine roles (keeper + server);
 * the per-host Vault Agent template (nexus-infra-analytics's
 * role-overlay-clickhouse-tls.tf) passes per-node common_name + alt_names.
 *
 * Certs cover:
 *   - Subject CN: <hostname>.clickhouse.nexus.lab
 *   - SANs: <hostname>, <hostname>.nexus.lab, <hostname>.clickhouse.nexus.lab,
 *           clickhouse.nexus.lab (the round-robin endpoint -- ADR-0031),
 *           localhost; IPs: VMnet10 backplane + VMnet11 service + 127.0.0.1
 *
 * server+client EKU because every ClickHouse node BOTH listens (HTTPS 8443 +
 * native-TLS 9440 + interserver-HTTPS 9010; Keeper RAFT 9234 + secure client
 * 9281) AND dials peers (inter-server replication fetch + Distributed fan-out +
 * server->Keeper). 90-day leaf TTL (matches every other cluster role).
 *
 * The round-robin DNS name `clickhouse.nexus.lab` is in allowed_domains so a
 * client doing verify-full against the round-robin endpoint validates whichever
 * data node answers (the analytics analogue of the VIP-in-IP-SAN pattern).
 *
 * `vault write` on roles is upsert -- idempotent. Selective ops:
 * var.enable_vault_pki AND var.enable_clickhouse_pki.
 */

resource "null_resource" "vault_pki_clickhouse_role" {
  count = var.enable_vault_cluster && var.enable_vault_init && var.enable_vault_pki && var.enable_clickhouse_pki ? 1 : 0

  triggers = {
    int_id                    = length(null_resource.vault_pki_intermediate_ca) > 0 ? null_resource.vault_pki_intermediate_ca[0].id : "disabled"
    role_name                 = var.vault_pki_clickhouse_role_name
    leaf_ttl                  = var.vault_pki_leaf_ttl
    clickhouse_role_overlay_v = "1" # v1 (0.G.5) = initial 9-node ClickHouse cluster (3 keeper + 6 data).
  }

  depends_on = [null_resource.vault_pki_intermediate_ca]

  provisioner "local-exec" {
    when        = create
    interpreter = ["pwsh", "-NoProfile", "-Command"]
    command     = <<-PWSH
      $ip          = '${local.vault_1_ip}'
      $user        = '${local.ssh_user}'
      $roleName    = '${var.vault_pki_clickhouse_role_name}'
      $leafTtl     = '${var.vault_pki_leaf_ttl}'
      $keysFileRaw = '${var.vault_init_keys_file}'
      $keysFile    = $ExecutionContext.InvokeCommand.ExpandString($keysFileRaw.Replace('$HOME', $env:USERPROFILE))

      if (-not (Test-Path $keysFile)) { throw "[pki-clickhouse] keys file $keysFile missing" }
      $rootToken = (Get-Content $keysFile | ConvertFrom-Json).root_token

      $bash = @"
set -euo pipefail
export VAULT_TOKEN='$rootToken'
export VAULT_SKIP_VERIFY=true
export VAULT_ADDR=https://127.0.0.1:8200

echo "[pki-clickhouse] writing pki_int/roles/$roleName (idempotent overwrite)"
vault write pki_int/roles/$roleName \
  allowed_domains='nexus.lab,clickhouse.nexus.lab,ch-keeper-1,ch-keeper-2,ch-keeper-3,ch-shard1-rep1,ch-shard1-rep2,ch-shard2-rep1,ch-shard2-rep2,ch-shard3-rep1,ch-shard3-rep2,ch-keeper-1.nexus.lab,ch-keeper-2.nexus.lab,ch-keeper-3.nexus.lab,ch-shard1-rep1.nexus.lab,ch-shard1-rep2.nexus.lab,ch-shard2-rep1.nexus.lab,ch-shard2-rep2.nexus.lab,ch-shard3-rep1.nexus.lab,ch-shard3-rep2.nexus.lab,ch-keeper-1.clickhouse.nexus.lab,ch-keeper-2.clickhouse.nexus.lab,ch-keeper-3.clickhouse.nexus.lab,ch-shard1-rep1.clickhouse.nexus.lab,ch-shard1-rep2.clickhouse.nexus.lab,ch-shard2-rep1.clickhouse.nexus.lab,ch-shard2-rep2.clickhouse.nexus.lab,ch-shard3-rep1.clickhouse.nexus.lab,ch-shard3-rep2.clickhouse.nexus.lab,localhost' \
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
echo "[pki-clickhouse] role pki_int/roles/$roleName configured (allowed_domains=`$ALLOWED entries, ttl=$leafTtl, server+client EKU)"
"@

      $bytes = [System.Text.UTF8Encoding]::new($false).GetBytes($bash)
      $b64   = [Convert]::ToBase64String($bytes)

      Write-Host "[pki-clickhouse] dispatching to $${ip} via base64"
      $output = ssh -o ConnectTimeout=30 -o BatchMode=yes -o StrictHostKeyChecking=no $user@$ip "echo '$b64' | base64 -d | bash" 2>&1 | Out-String
      $rc = $LASTEXITCODE
      Write-Host $output.Trim()
      if ($rc -ne 0) { throw "[pki-clickhouse] script failed (rc=$rc)" }
    PWSH
  }
}
