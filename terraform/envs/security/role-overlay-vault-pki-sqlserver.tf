/*
 * role-overlay-vault-pki-sqlserver.tf -- Phase 0.G.7 setup (SQL Server FCI + AG)
 *
 * Defines the `sqlserver-server` PKI role at pki_int/. The leaf-cert role for
 * the 02-sqlserver tier's 4 nodes + the 2 WSFC-managed VIPs (FCI virtual
 * server + AG Listener). Single role covers all leaf-cert use cases:
 *
 *   - sql-fci-1, sql-fci-2 -- 2-node WSFC FCI sharing iSCSI LUN .16 (mTLS
 *     for SQL :1433, AG endpoint :5022, peer auth between FCI partners,
 *     iSCSI initiator identity)
 *   - sql-ag-rep-1, sql-ag-rep-2 -- 2 standalone SQL instances as AG async
 *     replicas (mTLS for SQL :1433, AG endpoint :5022)
 *   - sql-fci-cluster -- FCI virtual server identity (CN); IP-SAN includes
 *     .70.16 so client TLS handshakes against the FCI virtual IP validate
 *     across FCI node failover (cert moves with the role via WSFC)
 *   - sql-ag-listener -- AG Listener identity (CN); IP-SAN includes .70.17
 *     so client `Encrypt=True;TrustServerCertificate=False` validates against
 *     the floating Listener IP across AG failover (per ADR-0025 the Listener
 *     IS the LB-tier HA primitive; cert IP-SAN is the canonical wire-validation
 *     for floating VIPs).
 *
 * Cert subject + SANs each Vault Agent template renders:
 *   - Subject CN: <hostname>.sqlserver.nexus.lab
 *   - SANs: <hostname>, <hostname>.nexus.lab, <hostname>.sqlserver.nexus.lab,
 *           localhost
 *           IPs: VMnet10 backplane + VMnet11 service IP + 127.0.0.1
 *           + .70.16 for sql-fci-1/2 (FCI virtual server cert)
 *           + .70.17 only for the listener cert
 *
 * Per nexus-platform-plan/MASTER-PLAN.md Phase 0.G + ADR-0012 PKI hierarchy:
 * 90-day leaf TTL (matches every other 0.G PKI role). server+client EKU
 * because SQL Server endpoints both listen (1433/5022) AND dial peers (AG
 * synchronous-commit replica seeding initiates from the primary to each
 * secondary; once initial seeding completes, log streaming flips to a
 * secondary-initiated pull). iSCSI initiator identity uses the same cert
 * (client EKU side) for CHAP-mutual auth between sql-fci-1/2 and the tgt
 * target on nexus-gateway.
 *
 * Why allowed_domains enumerates every literal name: allow_subdomains=false
 * + allow_bare_domains=true means each CN/SAN must match a literal entry.
 * The sqlserver-tier Vault Agent templates (nexus-infra-oltp's
 * role-overlay-sqlserver-tls.tf) pass per-node common_name + alt_names that
 * must all be covered here -- so the list spans all 6 hostnames (4 nodes +
 * FCI virtual + Listener) in bare + .nexus.lab + .sqlserver.nexus.lab forms.
 *
 * Cluster internal auth in 0.G.7 uses 5 KV-seeded passwords (see
 * role-overlay-vault-sqlserver-cluster-creds-seed.tf) for application-layer
 * auth + the AG endpoint cert auth (CREATE ENDPOINT ... AUTHENTICATION =
 * CERTIFICATE; mirrors the patroni-server cert-based replication pattern).
 *
 * `vault write` on roles is upsert -- always-overwrite is naturally
 * idempotent. Triggers track config so a knob change re-applies.
 *
 * Selective ops: var.enable_vault_pki AND var.enable_sqlserver_pki.
 */

resource "null_resource" "vault_pki_sqlserver_role" {
  count = var.enable_vault_cluster && var.enable_vault_init && var.enable_vault_pki && var.enable_sqlserver_pki ? 1 : 0

  triggers = {
    int_id                   = length(null_resource.vault_pki_intermediate_ca) > 0 ? null_resource.vault_pki_intermediate_ca[0].id : "disabled"
    role_name                = var.vault_pki_sqlserver_role_name
    leaf_ttl                 = var.vault_pki_leaf_ttl
    sqlserver_role_overlay_v = "1" # v1 (0.G.7) = initial 4 SQL nodes + FCI virtual server + AG Listener = 6 identities (4 nodes + 2 VIP-anchored).
  }

  depends_on = [null_resource.vault_pki_intermediate_ca]

  provisioner "local-exec" {
    when        = create
    interpreter = ["pwsh", "-NoProfile", "-Command"]
    command     = <<-PWSH
      $ip          = '${local.vault_1_ip}'
      $user        = '${local.ssh_user}'
      $roleName    = '${var.vault_pki_sqlserver_role_name}'
      $leafTtl     = '${var.vault_pki_leaf_ttl}'
      $keysFileRaw = '${var.vault_init_keys_file}'
      $keysFile    = $ExecutionContext.InvokeCommand.ExpandString($keysFileRaw.Replace('$HOME', $env:USERPROFILE))

      if (-not (Test-Path $keysFile)) { throw "[pki-sqlserver] keys file $keysFile missing" }
      $rootToken = (Get-Content $keysFile | ConvertFrom-Json).root_token

      $bash = @"
set -euo pipefail
export VAULT_TOKEN='$rootToken'
export VAULT_SKIP_VERIFY=true
export VAULT_ADDR=https://127.0.0.1:8200

echo "[pki-sqlserver] writing pki_int/roles/$roleName (idempotent overwrite)"
vault write pki_int/roles/$roleName \
  allowed_domains='nexus.lab,sqlserver.nexus.lab,sql-fci-1,sql-fci-2,sql-ag-rep-1,sql-ag-rep-2,sql-fci-cluster,sql-ag-listener,sql-fci-1.nexus.lab,sql-fci-2.nexus.lab,sql-ag-rep-1.nexus.lab,sql-ag-rep-2.nexus.lab,sql-fci-cluster.nexus.lab,sql-ag-listener.nexus.lab,sql-fci-1.sqlserver.nexus.lab,sql-fci-2.sqlserver.nexus.lab,sql-ag-rep-1.sqlserver.nexus.lab,sql-ag-rep-2.sqlserver.nexus.lab,sql-fci-cluster.sqlserver.nexus.lab,sql-ag-listener.sqlserver.nexus.lab,localhost' \
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
echo "[pki-sqlserver] role pki_int/roles/$roleName configured (allowed_domains=`$ALLOWED entries, ttl=$leafTtl, server+client EKU, allow_ip_sans=true for FCI .70.16 + Listener .70.17)"
"@

      $bytes = [System.Text.UTF8Encoding]::new($false).GetBytes($bash)
      $b64   = [Convert]::ToBase64String($bytes)

      Write-Host "[pki-sqlserver] dispatching to $${ip} via base64"
      $output = ssh -o ConnectTimeout=30 -o BatchMode=yes -o StrictHostKeyChecking=no $user@$ip "echo '$b64' | base64 -d | bash" 2>&1 | Out-String
      $rc = $LASTEXITCODE
      Write-Host $output.Trim()
      if ($rc -ne 0) {
        throw "[pki-sqlserver] script failed (rc=$rc)"
      }
    PWSH
  }
}
