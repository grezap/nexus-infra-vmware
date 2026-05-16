/*
 * role-overlay-vault-pki-mongo.tf -- Phase 0.G.2 setup (MongoDB RS mTLS)
 *
 * Defines the `mongo-server` PKI role at pki_int/. The leaf-cert role for
 * the 05-oltp tier's MongoDB Replica Set -- the 3 members of the
 * mongo-1/2/3 RS. Certs cover:
 *
 *   - Subject CN: <hostname>.mongo.nexus.lab
 *   - SANs: <hostname>, <hostname>.nexus.lab, <hostname>.mongo.nexus.lab,
 *           localhost
 *           IPs: VMnet10 backplane + VMnet11 service IP + 127.0.0.1
 *
 * Per nexus-platform-plan/MASTER-PLAN.md Phase 0.G + ADR-0024 + ADR-0012
 * PKI hierarchy: 90-day leaf TTL (matches redis-server / kafka-broker /
 * consul-server / nomad-server / vault-server roles). server+client EKU
 * because every mongo node BOTH listens (`--tlsMode requireTLS` on 27017)
 * AND dials peers (the replica set members open connections to each other
 * for heartbeat + replication + election traffic).
 *
 * Why allowed_domains enumerates every literal name: allow_subdomains=false
 * + allow_bare_domains=true means each CN/SAN must match a literal entry.
 * The mongo-node Vault Agent templates (nexus-infra-oltp's
 * role-overlay-mongo-tls.tf) pass per-node common_name + alt_names that
 * must all be covered here -- so the list spans all 3 mongo hostnames in
 * bare + .nexus.lab + .mongo.nexus.lab forms.
 *
 * Cluster internal auth in 0.G.2 uses a SHARED keyFile (sticky-seeded in
 * nexus/oltp/mongo/keyfile -- see role-overlay-vault-mongo-keyfile-seed.tf)
 * rather than x509 cluster identity. The PKI role here only needs to issue
 * per-node TLS leaves; the cluster-membership identity is the shared
 * keyFile. A later phase could flip to x509 internal auth (would require
 * `allow_organization=true` + role config to issue all 3 certs with
 * O=nexus-mongo-cluster) -- explicitly deferred for 0.G.2 simplicity.
 *
 * `vault write` on roles is upsert -- always-overwrite is naturally
 * idempotent. Triggers track config so a knob change re-applies.
 *
 * Selective ops: var.enable_vault_pki AND var.enable_mongo_pki.
 */

resource "null_resource" "vault_pki_mongo_role" {
  count = var.enable_vault_cluster && var.enable_vault_init && var.enable_vault_pki && var.enable_mongo_pki ? 1 : 0

  triggers = {
    int_id               = length(null_resource.vault_pki_intermediate_ca) > 0 ? null_resource.vault_pki_intermediate_ca[0].id : "disabled"
    role_name            = var.vault_pki_mongo_role_name
    leaf_ttl             = var.vault_pki_leaf_ttl
    mongo_role_overlay_v = "1" # v1 (0.G.2) = initial 3-node MongoDB Replica Set (mongo-1..3).
  }

  depends_on = [null_resource.vault_pki_intermediate_ca]

  provisioner "local-exec" {
    when        = create
    interpreter = ["pwsh", "-NoProfile", "-Command"]
    command     = <<-PWSH
      $ip          = '${local.vault_1_ip}'
      $user        = '${local.ssh_user}'
      $roleName    = '${var.vault_pki_mongo_role_name}'
      $leafTtl     = '${var.vault_pki_leaf_ttl}'
      $keysFileRaw = '${var.vault_init_keys_file}'
      $keysFile    = $ExecutionContext.InvokeCommand.ExpandString($keysFileRaw.Replace('$HOME', $env:USERPROFILE))

      if (-not (Test-Path $keysFile)) { throw "[pki-mongo] keys file $keysFile missing" }
      $rootToken = (Get-Content $keysFile | ConvertFrom-Json).root_token

      $bash = @"
set -euo pipefail
export VAULT_TOKEN='$rootToken'
export VAULT_SKIP_VERIFY=true
export VAULT_ADDR=https://127.0.0.1:8200

echo "[pki-mongo] writing pki_int/roles/$roleName (idempotent overwrite)"
vault write pki_int/roles/$roleName \
  allowed_domains='nexus.lab,mongo.nexus.lab,mongo-1,mongo-2,mongo-3,mongo-1.nexus.lab,mongo-2.nexus.lab,mongo-3.nexus.lab,mongo-1.mongo.nexus.lab,mongo-2.mongo.nexus.lab,mongo-3.mongo.nexus.lab,localhost' \
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
echo "[pki-mongo] role pki_int/roles/$roleName configured (allowed_domains=`$ALLOWED entries, ttl=$leafTtl, server+client EKU)"
"@

      $bytes = [System.Text.UTF8Encoding]::new($false).GetBytes($bash)
      $b64   = [Convert]::ToBase64String($bytes)

      Write-Host "[pki-mongo] dispatching to $${ip} via base64"
      $output = ssh -o ConnectTimeout=30 -o BatchMode=yes -o StrictHostKeyChecking=no $user@$ip "echo '$b64' | base64 -d | bash" 2>&1 | Out-String
      $rc = $LASTEXITCODE
      Write-Host $output.Trim()
      if ($rc -ne 0) {
        throw "[pki-mongo] script failed (rc=$rc)"
      }
    PWSH
  }
}
