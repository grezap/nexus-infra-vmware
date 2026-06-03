/*
 * role-overlay-vault-pki-citus.tf -- Phase 0.P setup (Citus-sharded PostgreSQL,
 *   full Patroni HA + mTLS per ADR-0042)
 *
 * Defines the `citus-server` PKI role at pki_int/. The leaf-cert role for the
 * 08-citus tier's 9 nodes -- 3 etcd DCS (.202-.204), coordinator Patroni pair
 * (.205/.206), worker1 Patroni pair (.207/.208), worker2 Patroni pair
 * (.209/.210). All 9 share one PKI role. Certs cover the PostgreSQL wire
 * (client<->coordinator, coordinator<->worker, Patroni<->PG, streaming
 * replication), the etcd peer+client channels, and the Patroni REST API. Certs
 * cover:
 *
 *   - Subject CN: <hostname>.citus.nexus.lab
 *   - SANs: <hostname>, <hostname>.nexus.lab, <hostname>.citus.nexus.lab,
 *           coord.citus.nexus.lab / worker1.citus.nexus.lab /
 *           worker2.citus.nexus.lab (the 3 VRRP VIP DNS names -- so a TLS
 *           handshake against a VIP validates regardless of which leader holds
 *           it), localhost
 *           IPs: VMnet10 backplane + VMnet11 service IP + the group's VIP
 *                (.211/.212/.213) + 127.0.0.1
 *
 * Per MASTER-PLAN Phase 0.P + ADR-0024 + ADR-0012 PKI hierarchy: 90-day leaf
 * TTL (matches patroni-server / vitess-server / etc.). server+client EKU
 * because every Citus PG node both listens (serves clients / the coordinator)
 * AND dials (coordinator dials workers; replicas dial the leader for streaming;
 * Patroni dials etcd + peers).
 *
 * allow_subdomains=false + allow_bare_domains=true -> each CN/SAN must match a
 * literal allowed_domains entry. The citus Vault Agent templates (nexus-infra-
 * citus role-overlay-citus-tls.tf) pass per-node common_name + alt_names that
 * must all be covered here, so the list spans all 9 hostnames in bare +
 * .nexus.lab + .citus.nexus.lab forms, plus the 3 VIP DNS names + localhost.
 *
 * Application-layer auth uses KV-seeded PG creds (see
 * role-overlay-vault-citus-cluster-creds-seed.tf). TLS is for wire encryption
 * + identity; the passwords + pg_hba clientcert gate what the wire-
 * authenticated peer can do.
 *
 * `vault write` on roles is upsert -- idempotent. Triggers track config.
 *
 * Selective ops: var.enable_vault_pki AND var.enable_citus_pki.
 */

resource "null_resource" "vault_pki_citus_role" {
  count = var.enable_vault_cluster && var.enable_vault_init && var.enable_vault_pki && var.enable_citus_pki ? 1 : 0

  triggers = {
    int_id               = length(null_resource.vault_pki_intermediate_ca) > 0 ? null_resource.vault_pki_intermediate_ca[0].id : "disabled"
    role_name            = var.vault_pki_citus_role_name
    leaf_ttl             = var.vault_pki_leaf_ttl
    citus_role_overlay_v = "1" # v1 (0.P) = 9 nodes (3 etcd + coord pair + 2 worker pairs), full mTLS per ADR-0042.
  }

  depends_on = [null_resource.vault_pki_intermediate_ca]

  provisioner "local-exec" {
    when        = create
    interpreter = ["pwsh", "-NoProfile", "-Command"]
    command     = <<-PWSH
      $ip          = '${local.vault_1_ip}'
      $user        = '${local.ssh_user}'
      $roleName    = '${var.vault_pki_citus_role_name}'
      $leafTtl     = '${var.vault_pki_leaf_ttl}'
      $keysFileRaw = '${var.vault_init_keys_file}'
      $keysFile    = $ExecutionContext.InvokeCommand.ExpandString($keysFileRaw.Replace('$HOME', $env:USERPROFILE))

      if (-not (Test-Path $keysFile)) { throw "[pki-citus] keys file $keysFile missing" }
      $rootToken = (Get-Content $keysFile | ConvertFrom-Json).root_token

      $bash = @"
set -euo pipefail
export VAULT_TOKEN='$rootToken'
export VAULT_SKIP_VERIFY=true
export VAULT_ADDR=https://127.0.0.1:8200

echo "[pki-citus] writing pki_int/roles/$roleName (idempotent overwrite)"
vault write pki_int/roles/$roleName \
  allowed_domains='nexus.lab,citus.nexus.lab,coord.citus.nexus.lab,worker1.citus.nexus.lab,worker2.citus.nexus.lab,citus-etcd-1,citus-etcd-2,citus-etcd-3,citus-coord-1,citus-coord-2,citus-worker1-1,citus-worker1-2,citus-worker2-1,citus-worker2-2,citus-etcd-1.nexus.lab,citus-etcd-2.nexus.lab,citus-etcd-3.nexus.lab,citus-coord-1.nexus.lab,citus-coord-2.nexus.lab,citus-worker1-1.nexus.lab,citus-worker1-2.nexus.lab,citus-worker2-1.nexus.lab,citus-worker2-2.nexus.lab,citus-etcd-1.citus.nexus.lab,citus-etcd-2.citus.nexus.lab,citus-etcd-3.citus.nexus.lab,citus-coord-1.citus.nexus.lab,citus-coord-2.citus.nexus.lab,citus-worker1-1.citus.nexus.lab,citus-worker1-2.citus.nexus.lab,citus-worker2-1.citus.nexus.lab,citus-worker2-2.citus.nexus.lab,localhost' \
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
echo "[pki-citus] role pki_int/roles/$roleName configured (allowed_domains=`$ALLOWED entries, ttl=$leafTtl, server+client EKU)"
"@

      $bytes = [System.Text.UTF8Encoding]::new($false).GetBytes($bash)
      $b64   = [Convert]::ToBase64String($bytes)

      Write-Host "[pki-citus] dispatching to $${ip} via base64"
      $output = ssh -o ConnectTimeout=30 -o BatchMode=yes -o StrictHostKeyChecking=no $user@$ip "echo '$b64' | base64 -d | bash" 2>&1 | Out-String
      $rc = $LASTEXITCODE
      Write-Host $output.Trim()
      if ($rc -ne 0) {
        throw "[pki-citus] script failed (rc=$rc)"
      }
    PWSH
  }
}
