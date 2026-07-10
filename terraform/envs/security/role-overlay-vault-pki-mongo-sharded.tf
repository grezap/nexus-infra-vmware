/*
 * role-overlay-vault-pki-mongo-sharded.tf -- Phase 0.N.1 (sharded MongoDB wire mTLS)
 *
 * Defines the `mongo-sharded-server` PKI role at pki_int/. The leaf-cert role
 * for the 05-oltp tier's 11-VM sharded MongoDB cluster (config RS ×3 + 2 shard
 * RSes ×3 + 2 mongos). Brings the sharded cluster to wire-mTLS parity with the
 * 0.G.2 `mongo` RS (which uses the separate `mongo-server` role). Certs cover:
 *
 *   - Subject CN: <hostname>.mongo.nexus.lab
 *   - SANs: <hostname>, <hostname>.nexus.lab, <hostname>.mongo.nexus.lab,
 *           localhost   +   IPs: VMnet10 backplane + VMnet11 service + 127.0.0.1
 *
 * Separate from `mongo-server` so the two mongo clusters version independently
 * (per-cluster PKI role convention: redis-server, kafka-broker, vitess-server,
 * citus-server...). 90-day leaf TTL; server+client EKU because every node BOTH
 * listens (requireTLS on 27017/27018/27019) AND dials peers (RS heartbeat +
 * replication + election, and mongos↔shard/config traffic).
 *
 * Cluster internal auth stays the SHARED keyFile (nexus/oltp/mongo/keyfile,
 * clusterAuthMode: keyFile) -- 0.N.1 adds wire TLS only, not x509 member auth
 * (a later phase could flip to x509). `vault write` on roles is upsert.
 *
 * Selective ops: var.enable_vault_pki AND var.enable_mongo_sharded_pki.
 */

resource "null_resource" "vault_pki_mongo_sharded_role" {
  count = var.enable_vault_cluster && var.enable_vault_init && var.enable_vault_pki && var.enable_mongo_sharded_pki ? 1 : 0

  triggers = {
    int_id                       = length(null_resource.vault_pki_intermediate_ca) > 0 ? null_resource.vault_pki_intermediate_ca[0].id : "disabled"
    role_name                    = var.vault_pki_mongo_sharded_role_name
    leaf_ttl                     = var.vault_pki_leaf_ttl
    mongo_sharded_role_overlay_v = "1" # v1 (0.N.1) = initial 11-node sharded MongoDB (config ×3 + shard-1 ×3 + shard-2 ×3 + mongos ×2).
  }

  depends_on = [null_resource.vault_pki_intermediate_ca]

  provisioner "local-exec" {
    when        = create
    interpreter = ["pwsh", "-NoProfile", "-Command"]
    command     = <<-PWSH
      $ip          = '${local.vault_1_ip}'
      $user        = '${local.ssh_user}'
      $roleName    = '${var.vault_pki_mongo_sharded_role_name}'
      $leafTtl     = '${var.vault_pki_leaf_ttl}'
      $keysFileRaw = '${var.vault_init_keys_file}'
      $keysFile    = $ExecutionContext.InvokeCommand.ExpandString($keysFileRaw.Replace('$HOME', $env:USERPROFILE))

      if (-not (Test-Path $keysFile)) { throw "[pki-mongo-sharded] keys file $keysFile missing" }
      $rootToken = (Get-Content $keysFile | ConvertFrom-Json).root_token

      $bash = @"
set -euo pipefail
export VAULT_TOKEN='$rootToken'
export VAULT_SKIP_VERIFY=true
export VAULT_ADDR=https://127.0.0.1:8200

echo "[pki-mongo-sharded] writing pki_int/roles/$roleName (idempotent overwrite)"
vault write pki_int/roles/$roleName \
  allowed_domains='nexus.lab,mongo.nexus.lab,localhost,mongo-cfg-1,mongo-cfg-1.nexus.lab,mongo-cfg-1.mongo.nexus.lab,mongo-cfg-2,mongo-cfg-2.nexus.lab,mongo-cfg-2.mongo.nexus.lab,mongo-cfg-3,mongo-cfg-3.nexus.lab,mongo-cfg-3.mongo.nexus.lab,mongo-shard-1-1,mongo-shard-1-1.nexus.lab,mongo-shard-1-1.mongo.nexus.lab,mongo-shard-1-2,mongo-shard-1-2.nexus.lab,mongo-shard-1-2.mongo.nexus.lab,mongo-shard-1-3,mongo-shard-1-3.nexus.lab,mongo-shard-1-3.mongo.nexus.lab,mongo-shard-2-1,mongo-shard-2-1.nexus.lab,mongo-shard-2-1.mongo.nexus.lab,mongo-shard-2-2,mongo-shard-2-2.nexus.lab,mongo-shard-2-2.mongo.nexus.lab,mongo-shard-2-3,mongo-shard-2-3.nexus.lab,mongo-shard-2-3.mongo.nexus.lab,mongo-mongos-1,mongo-mongos-1.nexus.lab,mongo-mongos-1.mongo.nexus.lab,mongo-mongos-2,mongo-mongos-2.nexus.lab,mongo-mongos-2.mongo.nexus.lab' \
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
echo "[pki-mongo-sharded] role pki_int/roles/$roleName configured (allowed_domains=`$ALLOWED entries, ttl=$leafTtl, server+client EKU)"
"@

      $bytes = [System.Text.UTF8Encoding]::new($false).GetBytes($bash)
      $b64   = [Convert]::ToBase64String($bytes)

      Write-Host "[pki-mongo-sharded] dispatching to $${ip} via base64"
      $output = ssh -o ConnectTimeout=30 -o BatchMode=yes -o StrictHostKeyChecking=no $user@$ip "echo '$b64' | base64 -d | bash" 2>&1 | Out-String
      $rc = $LASTEXITCODE
      Write-Host $output.Trim()
      if ($rc -ne 0) {
        throw "[pki-mongo-sharded] script failed (rc=$rc)"
      }
    PWSH
  }
}
