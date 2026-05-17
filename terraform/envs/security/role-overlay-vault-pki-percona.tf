/*
 * role-overlay-vault-pki-percona.tf -- Phase 0.G.3 setup (Percona XtraDB
 *   Cluster + ProxySQL mTLS)
 *
 * Defines the `percona-server` PKI role at pki_int/. The leaf-cert role
 * for the 05-oltp tier's Percona + ProxySQL stack -- the 3 PXC nodes
 * (pxc-node-1/2/3, Galera-replicated MySQL data plane on 3306 + Galera
 * SST/IST on 4444/4567/4568) plus the 2 ProxySQL nodes (proxysql-1/2,
 * connection pooler + LB on 6033 with admin interface on 6032). All 5
 * share one PKI role; certs cover:
 *
 *   - Subject CN: <hostname>.percona.nexus.lab
 *   - SANs: <hostname>, <hostname>.nexus.lab, <hostname>.percona.nexus.lab,
 *           localhost
 *           IPs: VMnet10 backplane + VMnet11 service IP + 127.0.0.1
 *           (ProxySQL nodes also include the VIP 192.168.70.50 -- the
 *           VRRP-floated address that may land on either ProxySQL node)
 *
 * Per nexus-platform-plan/MASTER-PLAN.md Phase 0.G + ADR-0024 + ADR-0012
 * PKI hierarchy: 90-day leaf TTL (matches redis-server / mongo-server /
 * kafka-broker / consul-server / nomad-server / vault-server roles).
 * server+client EKU because PXC nodes both listen (MySQL on 3306 + Galera
 * SST/IST on 4444/4567/4568) AND dial peers (Galera replication is a full
 * mesh between all members; SST donor connects to joiner); ProxySQL nodes
 * listen (6032 admin + 6033 client) AND dial backends (PXC on 3306).
 *
 * Why allowed_domains enumerates every literal name: allow_subdomains=false
 * + allow_bare_domains=true means each CN/SAN must match a literal entry.
 * The percona-node Vault Agent templates (nexus-infra-oltp's
 * role-overlay-percona-tls.tf, coming in chunk 3) pass per-node common_name
 * + alt_names that must all be covered here -- so the list spans all 5
 * hostnames in bare + .nexus.lab + .percona.nexus.lab forms.
 *
 * Cluster internal auth in 0.G.3 uses the wsrep_sst_auth user/password
 * sticky-seeded at nexus/oltp/percona/cluster-password (see
 * role-overlay-vault-percona-cluster-creds-seed.tf) -- TLS is for wire
 * encryption; SST/IST authentication is via MySQL credentials. A later
 * phase could flip SST/IST to x509 cluster identity -- explicitly deferred
 * for 0.G.3 simplicity.
 *
 * `vault write` on roles is upsert -- always-overwrite is naturally
 * idempotent. Triggers track config so a knob change re-applies.
 *
 * Selective ops: var.enable_vault_pki AND var.enable_percona_pki.
 */

resource "null_resource" "vault_pki_percona_role" {
  count = var.enable_vault_cluster && var.enable_vault_init && var.enable_vault_pki && var.enable_percona_pki ? 1 : 0

  triggers = {
    int_id                 = length(null_resource.vault_pki_intermediate_ca) > 0 ? null_resource.vault_pki_intermediate_ca[0].id : "disabled"
    role_name              = var.vault_pki_percona_role_name
    leaf_ttl               = var.vault_pki_leaf_ttl
    percona_role_overlay_v = "1" # v1 (0.G.3) = initial 3 PXC + 2 ProxySQL = 5 nodes.
  }

  depends_on = [null_resource.vault_pki_intermediate_ca]

  provisioner "local-exec" {
    when        = create
    interpreter = ["pwsh", "-NoProfile", "-Command"]
    command     = <<-PWSH
      $ip          = '${local.vault_1_ip}'
      $user        = '${local.ssh_user}'
      $roleName    = '${var.vault_pki_percona_role_name}'
      $leafTtl     = '${var.vault_pki_leaf_ttl}'
      $keysFileRaw = '${var.vault_init_keys_file}'
      $keysFile    = $ExecutionContext.InvokeCommand.ExpandString($keysFileRaw.Replace('$HOME', $env:USERPROFILE))

      if (-not (Test-Path $keysFile)) { throw "[pki-percona] keys file $keysFile missing" }
      $rootToken = (Get-Content $keysFile | ConvertFrom-Json).root_token

      $bash = @"
set -euo pipefail
export VAULT_TOKEN='$rootToken'
export VAULT_SKIP_VERIFY=true
export VAULT_ADDR=https://127.0.0.1:8200

echo "[pki-percona] writing pki_int/roles/$roleName (idempotent overwrite)"
vault write pki_int/roles/$roleName \
  allowed_domains='nexus.lab,percona.nexus.lab,pxc-node-1,pxc-node-2,pxc-node-3,proxysql-1,proxysql-2,pxc-node-1.nexus.lab,pxc-node-2.nexus.lab,pxc-node-3.nexus.lab,proxysql-1.nexus.lab,proxysql-2.nexus.lab,pxc-node-1.percona.nexus.lab,pxc-node-2.percona.nexus.lab,pxc-node-3.percona.nexus.lab,proxysql-1.percona.nexus.lab,proxysql-2.percona.nexus.lab,localhost' \
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
echo "[pki-percona] role pki_int/roles/$roleName configured (allowed_domains=`$ALLOWED entries, ttl=$leafTtl, server+client EKU)"
"@

      $bytes = [System.Text.UTF8Encoding]::new($false).GetBytes($bash)
      $b64   = [Convert]::ToBase64String($bytes)

      Write-Host "[pki-percona] dispatching to $${ip} via base64"
      $output = ssh -o ConnectTimeout=30 -o BatchMode=yes -o StrictHostKeyChecking=no $user@$ip "echo '$b64' | base64 -d | bash" 2>&1 | Out-String
      $rc = $LASTEXITCODE
      Write-Host $output.Trim()
      if ($rc -ne 0) {
        throw "[pki-percona] script failed (rc=$rc)"
      }
    PWSH
  }
}
