/*
 * role-overlay-vault-pki-patroni.tf -- Phase 0.G.4 setup (Patroni PostgreSQL
 *   HA + etcd DCS + HAProxy mTLS)
 *
 * Defines the `patroni-server` PKI role at pki_int/. The leaf-cert role for
 * the 05-oltp tier's Patroni stack -- the 3 Patroni nodes (pg-primary,
 * pg-replica-1, pg-replica-2; streaming-replication PG 17 data plane on
 * 5432 + Patroni REST on 8008) plus the 3 etcd nodes (etcd-1/2/3; raft DCS
 * on 2380 + client API on 2379) plus the 2 HAProxy nodes (haproxy-pg-1/-2;
 * :5432 LB + :8404 stats + keepalived VRRP MASTER/BACKUP for VIP .60).
 * All 8 share one PKI role; haproxy nodes additionally carry the VIP .60
 * in their cert IP-SANs so handshakes against the floating VIP validate
 * regardless of which haproxy currently holds it. Certs cover:
 *
 *   - Subject CN: <hostname>.patroni.nexus.lab
 *   - SANs: <hostname>, <hostname>.nexus.lab, <hostname>.patroni.nexus.lab,
 *           localhost
 *           IPs: VMnet10 backplane + VMnet11 service IP + 127.0.0.1
 *
 * Per nexus-platform-plan/MASTER-PLAN.md Phase 0.G + ADR-0024 + ADR-0012
 * PKI hierarchy: 90-day leaf TTL (matches redis-server / mongo-server /
 * percona-server / kafka-broker / consul-server / nomad-server / vault-server
 * roles). server+client EKU because:
 *   - Patroni nodes listen (PG 5432 + Patroni REST 8008) AND dial peers
 *     (streaming replication is leader→replica mesh; Patroni REST does
 *     cross-node /switchover, /restart calls during cluster ops).
 *   - etcd nodes listen (2379 client API for Patroni's DCS reads/writes
 *     + 2380 peer raft) AND dial peers (raft heartbeat mesh).
 *   - HAProxy listens (5432 LB + 8404 stats) AND dials Patroni REST
 *     (:8008/leader) for backend health probes.
 *
 * Why allowed_domains enumerates every literal name: allow_subdomains=false
 * + allow_bare_domains=true means each CN/SAN must match a literal entry.
 * The patroni-tier Vault Agent templates (nexus-infra-oltp's
 * role-overlay-patroni-tls.tf, coming in stage 6) pass per-node common_name
 * + alt_names that must all be covered here -- so the list spans all 7
 * hostnames in bare + .nexus.lab + .patroni.nexus.lab forms.
 *
 * Cluster internal auth in 0.G.4 uses 5 KV-seeded passwords (see
 * role-overlay-vault-patroni-cluster-creds-seed.tf) for application-layer
 * auth (PG superuser, PG replicator, Patroni REST basic-auth, etcd root,
 * HAProxy stats). TLS is for wire encryption + identity; passwords gate
 * what the wire-authenticated peer can do.
 *
 * `vault write` on roles is upsert -- always-overwrite is naturally
 * idempotent. Triggers track config so a knob change re-applies.
 *
 * Selective ops: var.enable_vault_pki AND var.enable_patroni_pki.
 */

resource "null_resource" "vault_pki_patroni_role" {
  count = var.enable_vault_cluster && var.enable_vault_init && var.enable_vault_pki && var.enable_patroni_pki ? 1 : 0

  triggers = {
    int_id                 = length(null_resource.vault_pki_intermediate_ca) > 0 ? null_resource.vault_pki_intermediate_ca[0].id : "disabled"
    role_name              = var.vault_pki_patroni_role_name
    leaf_ttl               = var.vault_pki_leaf_ttl
    patroni_role_overlay_v = "2" # v2 (0.G.4) = initial 3 Patroni + 3 etcd + 2 HAProxy = 8 nodes. v1 was the abandoned single-HAProxy variant superseded mid-scaffold by the HA pair design.
  }

  depends_on = [null_resource.vault_pki_intermediate_ca]

  provisioner "local-exec" {
    when        = create
    interpreter = ["pwsh", "-NoProfile", "-Command"]
    command     = <<-PWSH
      $ip          = '${local.vault_1_ip}'
      $user        = '${local.ssh_user}'
      $roleName    = '${var.vault_pki_patroni_role_name}'
      $leafTtl     = '${var.vault_pki_leaf_ttl}'
      $keysFileRaw = '${var.vault_init_keys_file}'
      $keysFile    = $ExecutionContext.InvokeCommand.ExpandString($keysFileRaw.Replace('$HOME', $env:USERPROFILE))

      if (-not (Test-Path $keysFile)) { throw "[pki-patroni] keys file $keysFile missing" }
      $rootToken = (Get-Content $keysFile | ConvertFrom-Json).root_token

      $bash = @"
set -euo pipefail
export VAULT_TOKEN='$rootToken'
export VAULT_SKIP_VERIFY=true
export VAULT_ADDR=https://127.0.0.1:8200

echo "[pki-patroni] writing pki_int/roles/$roleName (idempotent overwrite)"
vault write pki_int/roles/$roleName \
  allowed_domains='nexus.lab,patroni.nexus.lab,pg-primary,pg-replica-1,pg-replica-2,etcd-1,etcd-2,etcd-3,haproxy-pg-1,haproxy-pg-2,pg-primary.nexus.lab,pg-replica-1.nexus.lab,pg-replica-2.nexus.lab,etcd-1.nexus.lab,etcd-2.nexus.lab,etcd-3.nexus.lab,haproxy-pg-1.nexus.lab,haproxy-pg-2.nexus.lab,pg-primary.patroni.nexus.lab,pg-replica-1.patroni.nexus.lab,pg-replica-2.patroni.nexus.lab,etcd-1.patroni.nexus.lab,etcd-2.patroni.nexus.lab,etcd-3.patroni.nexus.lab,haproxy-pg-1.patroni.nexus.lab,haproxy-pg-2.patroni.nexus.lab,localhost' \
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
echo "[pki-patroni] role pki_int/roles/$roleName configured (allowed_domains=`$ALLOWED entries, ttl=$leafTtl, server+client EKU)"
"@

      $bytes = [System.Text.UTF8Encoding]::new($false).GetBytes($bash)
      $b64   = [Convert]::ToBase64String($bytes)

      Write-Host "[pki-patroni] dispatching to $${ip} via base64"
      $output = ssh -o ConnectTimeout=30 -o BatchMode=yes -o StrictHostKeyChecking=no $user@$ip "echo '$b64' | base64 -d | bash" 2>&1 | Out-String
      $rc = $LASTEXITCODE
      Write-Host $output.Trim()
      if ($rc -ne 0) {
        throw "[pki-patroni] script failed (rc=$rc)"
      }
    PWSH
  }
}
