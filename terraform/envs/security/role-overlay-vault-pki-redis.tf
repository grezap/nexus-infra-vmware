/*
 * role-overlay-vault-pki-redis.tf -- Phase 0.G.1 setup (Redis Cluster mTLS)
 *
 * Defines the `redis-server` PKI role at pki_int/. The leaf-cert role for the
 * 05-oltp tier's Redis Cluster -- the 6 nodes (3 masters + 3 replicas) of
 * the redis-1..6 cluster. Certs cover:
 *
 *   - Subject CN: <hostname>.redis.nexus.lab
 *   - SANs: <hostname>, <hostname>.nexus.lab, <hostname>.redis.nexus.lab,
 *           localhost
 *           IPs: VMnet10 backplane + VMnet11 service IP + 127.0.0.1
 *
 * Per nexus-platform-plan/MASTER-PLAN.md Phase 0.G + ADR-0024 + ADR-0012 PKI
 * hierarchy: 90-day leaf TTL (matches the kafka-broker / consul-server /
 * nomad-server / vault-server roles). server+client EKU because every redis
 * node BOTH listens (TLS on 6379 + cluster bus 16379) AND dials peers (the
 * cluster bus is a full mesh -- every node opens a connection to every other
 * node's port 16379 for gossip + failover voting).
 *
 * Why allowed_domains enumerates every literal name: allow_subdomains=false
 * + allow_bare_domains=true means each CN/SAN must match a literal entry.
 * The redis-node Vault Agent templates (nexus-infra-oltp's
 * role-overlay-redis-tls.tf) pass per-node common_name + alt_names that
 * must all be covered here -- so the list spans all 6 cluster hostnames in
 * bare + .nexus.lab + .redis.nexus.lab forms.
 *
 * `vault write` on roles is upsert -- always-overwrite is naturally
 * idempotent. Triggers track config so a knob change re-applies.
 *
 * Selective ops: var.enable_vault_pki AND var.enable_redis_pki.
 */

resource "null_resource" "vault_pki_redis_role" {
  count = var.enable_vault_cluster && var.enable_vault_init && var.enable_vault_pki && var.enable_redis_pki ? 1 : 0

  triggers = {
    int_id               = length(null_resource.vault_pki_intermediate_ca) > 0 ? null_resource.vault_pki_intermediate_ca[0].id : "disabled"
    role_name            = var.vault_pki_redis_role_name
    leaf_ttl             = var.vault_pki_leaf_ttl
    redis_role_overlay_v = "1" # v1 (0.G.1) = initial 6-node Redis Cluster (redis-1..6).
  }

  depends_on = [null_resource.vault_pki_intermediate_ca]

  provisioner "local-exec" {
    when        = create
    interpreter = ["pwsh", "-NoProfile", "-Command"]
    command     = <<-PWSH
      $ip          = '${local.vault_1_ip}'
      $user        = '${local.ssh_user}'
      $roleName    = '${var.vault_pki_redis_role_name}'
      $leafTtl     = '${var.vault_pki_leaf_ttl}'
      $keysFileRaw = '${var.vault_init_keys_file}'
      $keysFile    = $ExecutionContext.InvokeCommand.ExpandString($keysFileRaw.Replace('$HOME', $env:USERPROFILE))

      if (-not (Test-Path $keysFile)) { throw "[pki-redis] keys file $keysFile missing" }
      $rootToken = (Get-Content $keysFile | ConvertFrom-Json).root_token

      $bash = @"
set -euo pipefail
export VAULT_TOKEN='$rootToken'
export VAULT_SKIP_VERIFY=true
export VAULT_ADDR=https://127.0.0.1:8200

echo "[pki-redis] writing pki_int/roles/$roleName (idempotent overwrite)"
vault write pki_int/roles/$roleName \
  allowed_domains='nexus.lab,redis.nexus.lab,redis-1,redis-2,redis-3,redis-4,redis-5,redis-6,redis-1.nexus.lab,redis-2.nexus.lab,redis-3.nexus.lab,redis-4.nexus.lab,redis-5.nexus.lab,redis-6.nexus.lab,redis-1.redis.nexus.lab,redis-2.redis.nexus.lab,redis-3.redis.nexus.lab,redis-4.redis.nexus.lab,redis-5.redis.nexus.lab,redis-6.redis.nexus.lab,localhost' \
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
echo "[pki-redis] role pki_int/roles/$roleName configured (allowed_domains=`$ALLOWED entries, ttl=$leafTtl, server+client EKU)"
"@

      $bytes = [System.Text.UTF8Encoding]::new($false).GetBytes($bash)
      $b64   = [Convert]::ToBase64String($bytes)

      Write-Host "[pki-redis] dispatching to $${ip} via base64"
      $output = ssh -o ConnectTimeout=30 -o BatchMode=yes -o StrictHostKeyChecking=no $user@$ip "echo '$b64' | base64 -d | bash" 2>&1 | Out-String
      $rc = $LASTEXITCODE
      Write-Host $output.Trim()
      if ($rc -ne 0) {
        throw "[pki-redis] script failed (rc=$rc)"
      }
    PWSH
  }
}
