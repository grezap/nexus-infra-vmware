/*
 * role-overlay-vault-pki-vitess.tf -- Phase 0.O setup (Vitess-sharded MySQL,
 *   full mTLS per ADR-0041)
 *
 * Defines the `vitess-server` PKI role at pki_int/. The leaf-cert role for the
 * 07-vitess tier's 12 nodes -- 3 etcd topo (.190-.192), 1 control vtctld+VTOrc
 * (.193), 2 vtgate routers (.194/.195), 2x3 tablets vttablet+Percona (.196-.201).
 * All 12 share one PKI role. Certs cover every Vitess gRPC channel
 * (vtgate<->vttablet, vtctld<->vttablet, VTOrc<->vttablet, *<->etcd) + the
 * mysqld wire + the vtgate MySQL listener. Certs cover:
 *
 *   - Subject CN: <hostname>.vitess.nexus.lab
 *   - SANs: <hostname>, <hostname>.nexus.lab, <hostname>.vitess.nexus.lab,
 *           vtgate.nexus.lab (the round-robin client front door -- so a TLS
 *           handshake against either vtgate validates), localhost
 *           IPs: VMnet10 backplane + VMnet11 service IP + 127.0.0.1
 *
 * Per MASTER-PLAN Phase 0.O + ADR-0024 + ADR-0012 PKI hierarchy: 90-day leaf
 * TTL (matches patroni-server / mongo-server / percona-server / etc.).
 * server+client EKU because every Vitess component both listens AND dials
 * (vtgate dials tablets; vttablet dials etcd + serves vtgate/vtctld; vtctld
 * dials tablets; VTOrc dials tablets + mysqld; etcd peers dial each other).
 *
 * allow_subdomains=false + allow_bare_domains=true -> each CN/SAN must match a
 * literal allowed_domains entry. The vitess Vault Agent templates (nexus-infra-
 * vitess role-overlay-vitess-tls.tf) pass per-node common_name + alt_names that
 * must all be covered here, so the list spans all 12 hostnames in bare +
 * .nexus.lab + .vitess.nexus.lab forms, plus vtgate.nexus.lab + localhost.
 *
 * Application-layer auth uses KV-seeded MySQL + VTOrc creds (see
 * role-overlay-vault-vitess-cluster-creds-seed.tf). TLS is for wire encryption
 * + identity; the passwords gate what the wire-authenticated peer can do.
 *
 * `vault write` on roles is upsert -- idempotent. Triggers track config.
 *
 * Selective ops: var.enable_vault_pki AND var.enable_vitess_pki.
 */

resource "null_resource" "vault_pki_vitess_role" {
  count = var.enable_vault_cluster && var.enable_vault_init && var.enable_vault_pki && var.enable_vitess_pki ? 1 : 0

  triggers = {
    int_id                = length(null_resource.vault_pki_intermediate_ca) > 0 ? null_resource.vault_pki_intermediate_ca[0].id : "disabled"
    role_name             = var.vault_pki_vitess_role_name
    leaf_ttl              = var.vault_pki_leaf_ttl
    vitess_role_overlay_v = "1" # v1 (0.O) = 12 nodes (3 etcd + 1 control + 2 vtgate + 2x3 tablets), full mTLS per ADR-0041.
  }

  depends_on = [null_resource.vault_pki_intermediate_ca]

  provisioner "local-exec" {
    when        = create
    interpreter = ["pwsh", "-NoProfile", "-Command"]
    command     = <<-PWSH
      $ip          = '${local.vault_1_ip}'
      $user        = '${local.ssh_user}'
      $roleName    = '${var.vault_pki_vitess_role_name}'
      $leafTtl     = '${var.vault_pki_leaf_ttl}'
      $keysFileRaw = '${var.vault_init_keys_file}'
      $keysFile    = $ExecutionContext.InvokeCommand.ExpandString($keysFileRaw.Replace('$HOME', $env:USERPROFILE))

      if (-not (Test-Path $keysFile)) { throw "[pki-vitess] keys file $keysFile missing" }
      $rootToken = (Get-Content $keysFile | ConvertFrom-Json).root_token

      $bash = @"
set -euo pipefail
export VAULT_TOKEN='$rootToken'
export VAULT_SKIP_VERIFY=true
export VAULT_ADDR=https://127.0.0.1:8200

echo "[pki-vitess] writing pki_int/roles/$roleName (idempotent overwrite)"
vault write pki_int/roles/$roleName \
  allowed_domains='nexus.lab,vitess.nexus.lab,vtgate.nexus.lab,vitess-etcd-1,vitess-etcd-2,vitess-etcd-3,vitess-control-1,vitess-vtgate-1,vitess-vtgate-2,vitess-shard1-tablet-1,vitess-shard1-tablet-2,vitess-shard1-tablet-3,vitess-shard2-tablet-1,vitess-shard2-tablet-2,vitess-shard2-tablet-3,vitess-etcd-1.nexus.lab,vitess-etcd-2.nexus.lab,vitess-etcd-3.nexus.lab,vitess-control-1.nexus.lab,vitess-vtgate-1.nexus.lab,vitess-vtgate-2.nexus.lab,vitess-shard1-tablet-1.nexus.lab,vitess-shard1-tablet-2.nexus.lab,vitess-shard1-tablet-3.nexus.lab,vitess-shard2-tablet-1.nexus.lab,vitess-shard2-tablet-2.nexus.lab,vitess-shard2-tablet-3.nexus.lab,vitess-etcd-1.vitess.nexus.lab,vitess-etcd-2.vitess.nexus.lab,vitess-etcd-3.vitess.nexus.lab,vitess-control-1.vitess.nexus.lab,vitess-vtgate-1.vitess.nexus.lab,vitess-vtgate-2.vitess.nexus.lab,vitess-shard1-tablet-1.vitess.nexus.lab,vitess-shard1-tablet-2.vitess.nexus.lab,vitess-shard1-tablet-3.vitess.nexus.lab,vitess-shard2-tablet-1.vitess.nexus.lab,vitess-shard2-tablet-2.vitess.nexus.lab,vitess-shard2-tablet-3.vitess.nexus.lab,localhost' \
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
echo "[pki-vitess] role pki_int/roles/$roleName configured (allowed_domains=`$ALLOWED entries, ttl=$leafTtl, server+client EKU)"
"@

      $bytes = [System.Text.UTF8Encoding]::new($false).GetBytes($bash)
      $b64   = [Convert]::ToBase64String($bytes)

      Write-Host "[pki-vitess] dispatching to $${ip} via base64"
      $output = ssh -o ConnectTimeout=30 -o BatchMode=yes -o StrictHostKeyChecking=no $user@$ip "echo '$b64' | base64 -d | bash" 2>&1 | Out-String
      $rc = $LASTEXITCODE
      Write-Host $output.Trim()
      if ($rc -ne 0) {
        throw "[pki-vitess] script failed (rc=$rc)"
      }
    PWSH
  }
}
