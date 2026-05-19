/*
 * role-overlay-vault-sqlserver-cluster-creds-seed.tf -- Phase 0.G.7 setup
 *
 * Sticky-seeds the 5 SQL Server cluster credentials + 1 GMSA pointer in
 * Vault KV:
 *
 *   nexus/oltp/sqlserver/sa-password                       (32-char hex)
 *     - SQL Server `sa` login password. Disabled by default but available
 *       as emergency operator access (auth = SQL Server + Windows mixed
 *       mode is required for AG endpoint cert-auth to function on a
 *       Windows-domain-joined fleet without granting per-endpoint Windows
 *       logins).
 *     - Consumer: all 4 SQL nodes (rendered to C:\ProgramData\nexus\sql\
 *       creds\sa-password.txt by Vault Agent for emergency operator use)
 *
 *   nexus/oltp/sqlserver/ag-endpoint-cert-password         (32-char hex)
 *     - PFX password protecting the AG endpoint certs created on each node
 *       via `CREATE CERTIFICATE Hadr_endpoint_cert ENCRYPTION BY PASSWORD =
 *       '<this>'`. Each node imports the OTHER nodes' .CER public-key parts
 *       to validate inbound HADR endpoint TLS handshakes per ADR-0027 (AG
 *       endpoint cert-based auth -- mirrors the patroni `pg_hba` cert-based
 *       streaming replication pattern, scaled to Windows endpoint auth).
 *     - Consumer: all 4 SQL nodes
 *
 *   nexus/oltp/sqlserver/wsfc-cluster-admin-password       (32-char hex)
 *     - Local-Administrator password used during WSFC bootstrap on the FCI
 *       pair. Once nexus.lab\Domain Admins inherits cluster admin via
 *       `Add-ClusterNode -StaticAddress`, this password is for break-glass
 *       only (rotated daily via Vault KV operator workflow if compliance
 *       requires; sticky-seeded otherwise).
 *     - Consumer: 2 FCI nodes (sql-fci-1/2)
 *
 *   nexus/oltp/sqlserver/iscsi-chap-secret                 (32-char hex)
 *     - CHAP secret for the iSCSI target `iqn.2026-05.local.nexus:sql-fci.
 *       lun1` on nexus-gateway. Also written to host-side sidecar
 *       $HOME\.nexus\iscsi-sqlfci-chap.json so foundation's iSCSI target
 *       overlay (role-overlay-gateway-iscsi-sqlfci.tf) can pick it up
 *       without a shared state backend (mirrors vault-ad-bind.json /
 *       vault-init.json pattern).
 *     - Consumer: 2 FCI nodes (sql-fci-1/2 iSCSI initiator) + nexus-gateway
 *       (tgt target incominguser)
 *
 *   nexus/oltp/sqlserver/listener-cert-password            (32-char hex)
 *     - PFX password protecting the AG Listener leaf cert (CN `sql-ag-
 *       listener.nexus.lab`, IP-SAN .70.17). Imported on all 4 SQL nodes'
 *       LocalMachine\My store so SQL Server's TLS-on-Listener (1433) wire
 *       presents the listener cert regardless of which node currently owns
 *       the Listener IP -- the cert IP-SAN makes
 *       `Encrypt=True;TrustServerCertificate=False` validate across
 *       failover.
 *     - Consumer: all 4 SQL nodes
 *
 *   nexus/oltp/sqlserver/gmsa-info                         (JSON pointer)
 *     - NOT a password; GMSA passwords are AD-managed (rotated every 30
 *       days by the KDS root key from 0.D.5; retrieved by the 4 SQL nodes
 *       via `Install-ADServiceAccount -Identity gmsa-sql-engine`).
 *     - This KV path holds a JSON pointer: {gmsa_name, domain, ou} -- read
 *       by the oltp env's role-overlay-sqlserver-vault-agents.tf to template
 *       the SQL Server service-account config (`SQLSVCACCOUNT=
 *       nexus.lab\gmsa-sql-engine$` in setup.exe's config.ini).
 *
 * Sticky-seed pattern (mirrors role-overlay-vault-patroni-cluster-creds-
 * seed.tf): each KV path is probed; if already populated, that secret is
 * left alone (operator rotation preserved). Generation happens server-side
 * on vault-1 via openssl; values never transit over the SSH wire to the
 * build host except for iscsi-chap-secret which IS fetched to write the
 * host-side sidecar (chap secret has to leave the vault for the gateway
 * overlay to consume; same pattern as vault-init.json for the root token).
 *
 * Why 32-char hex (`openssl rand -hex 16` = 16 random bytes -> 32 hex
 * chars): SQL Server password complexity policy accepts any non-empty
 * string when set via T-SQL; hex is the safest portable character set
 * across SQL Server + PowerShell + Windows config files + iSCSI CHAP (which
 * forbids special chars).
 *
 * Selective ops: var.enable_sqlserver_cluster_creds_seed (master). Pre-req:
 * vault cluster initialized + KV-v2 mount at nexus/.
 */

resource "null_resource" "vault_sqlserver_cluster_creds_seed" {
  count = var.enable_vault_cluster && var.enable_vault_init && var.enable_sqlserver_cluster_creds_seed ? 1 : 0

  triggers = {
    post_init_id           = null_resource.vault_post_init[0].id
    kv_paths               = "nexus/oltp/sqlserver/{sa,ag-endpoint-cert,wsfc-cluster-admin,iscsi-chap-secret,listener-cert}-password + gmsa-info"
    sqlserver_creds_seed_v = "1" # v1 (0.G.7) = initial 5 sticky-seeded 32-char hex creds + 1 JSON pointer (gmsa-info).
  }

  depends_on = [null_resource.vault_post_init]

  provisioner "local-exec" {
    when        = create
    interpreter = ["pwsh", "-NoProfile", "-Command"]
    command     = <<-PWSH
      $ip          = '${local.vault_1_ip}'
      $user        = '${local.ssh_user}'
      $keysFileRaw = '${var.vault_init_keys_file}'
      $keysFile    = $ExecutionContext.InvokeCommand.ExpandString($keysFileRaw.Replace('$HOME', $env:USERPROFILE))
      $homeDir     = $env:USERPROFILE
      $chapSidecar = Join-Path $homeDir ".nexus/iscsi-sqlfci-chap.json"

      if (-not (Test-Path $keysFile)) { throw "[sqlserver-creds-seed] keys file $keysFile missing" }
      $rootToken = (Get-Content $keysFile | ConvertFrom-Json).root_token

      # Stage 1: generate/preserve the 5 passwords + gmsa-info JSON via
      # vault-1 RPC. Logging length (not value) keeps secrets out of stdout.
      $bash = @"
set -euo pipefail
export VAULT_TOKEN='$rootToken'
export VAULT_SKIP_VERIFY=true
export VAULT_ADDR=https://127.0.0.1:8200

seed_if_absent() {
  local path="`$1"
  local label="`$2"
  if vault kv get -field=content "`$path" >/dev/null 2>&1; then
    echo "[sqlserver-creds-seed] `$path already populated -- no-op (sticky `$label)"
    return 0
  fi
  local PWD32
  PWD32=`$(openssl rand -hex 16)
  local LEN
  LEN=`$(printf '%s' "`$PWD32" | wc -c)
  if [ "`$LEN" -ne 32 ]; then
    echo "[sqlserver-creds-seed] ERROR: `$label generated length `$LEN (expected 32)" >&2
    return 1
  fi
  vault kv put "`$path" content="`$PWD32" >/dev/null
  echo "[sqlserver-creds-seed] wrote `$path (`$LEN-char hex `$label)"
}

seed_if_absent 'nexus/oltp/sqlserver/sa-password'                  'SQL Server sa login password (emergency operator use)'
seed_if_absent 'nexus/oltp/sqlserver/ag-endpoint-cert-password'    'AG endpoint cert PFX password (CREATE CERTIFICATE)'
seed_if_absent 'nexus/oltp/sqlserver/wsfc-cluster-admin-password'  'WSFC cluster bootstrap Local-Administrator password'
seed_if_absent 'nexus/oltp/sqlserver/iscsi-chap-secret'            'iSCSI CHAP secret for sql-fci.lun1 target on nexus-gateway'
seed_if_absent 'nexus/oltp/sqlserver/listener-cert-password'       'AG Listener leaf cert PFX password'

# gmsa-info is a structured JSON pointer, not a regenerated secret. Idempotent
# overwrite each apply: the GMSA name + domain don't change.
vault kv put nexus/oltp/sqlserver/gmsa-info \
  gmsa_name='gmsa-sql-engine' \
  gmsa_full='gmsa-sql-engine\`$' \
  domain='nexus.lab' \
  ou='OU=ServiceAccounts,DC=nexus,DC=lab' \
  retrieve_group='nexus-sql-cluster-members' >/dev/null
echo "[sqlserver-creds-seed] wrote nexus/oltp/sqlserver/gmsa-info pointer (gmsa-sql-engine\`$ in OU=ServiceAccounts,DC=nexus,DC=lab)"

# Echo the CHAP secret for the host-side sidecar (only secret that LEAVES
# the vault on every apply -- foundation's iSCSI target overlay needs it).
CHAP=`$(vault kv get -field=content nexus/oltp/sqlserver/iscsi-chap-secret)
echo "ISCSI_CHAP_SECRET_FOR_SIDECAR=`$CHAP"

echo "[sqlserver-creds-seed] all 5 cluster creds + 1 gmsa pointer present in nexus/oltp/sqlserver/"
"@

      $bytes = [System.Text.UTF8Encoding]::new($false).GetBytes($bash)
      $b64   = [Convert]::ToBase64String($bytes)

      Write-Host "[sqlserver-creds-seed] dispatching to $${ip} via base64"
      $output = ssh -o ConnectTimeout=30 -o BatchMode=yes -o StrictHostKeyChecking=no $user@$ip "echo '$b64' | base64 -d | bash" 2>&1 | Out-String
      $rc = $LASTEXITCODE
      if ($rc -ne 0) {
        Write-Host $output.Trim()
        throw "[sqlserver-creds-seed] script failed (rc=$rc)"
      }

      # Stage 2: parse CHAP secret from the marker line + write host-side
      # sidecar at $HOME\.nexus\iscsi-sqlfci-chap.json. The foundation env's
      # iSCSI target overlay reads this. Filter marker line out of operator-
      # visible output (keep secret out of operator's scrollback).
      $chapMatch = $output -match '(?m)^ISCSI_CHAP_SECRET_FOR_SIDECAR=([0-9a-f]{32})$'
      if (-not $chapMatch) {
        throw "[sqlserver-creds-seed] failed to parse CHAP secret marker from script output"
      }
      $chapSecret = $matches[1]

      $sanitized = ($output -split "`n" | Where-Object { $_ -notmatch '^ISCSI_CHAP_SECRET_FOR_SIDECAR=' }) -join "`n"
      Write-Host $sanitized.Trim()

      $sidecarDir = Split-Path -Parent $chapSidecar
      if (-not (Test-Path $sidecarDir)) {
        New-Item -ItemType Directory -Force -Path $sidecarDir | Out-Null
      }
      $sidecar = [PSCustomObject]@{
        target_iqn   = 'iqn.2026-05.local.nexus:sql-fci.lun1'
        chap_user    = 'sql-fci-initiator'
        chap_secret  = $chapSecret
        generated_at = (Get-Date -Format 'o')
      }
      $sidecar | ConvertTo-Json -Depth 5 | Out-File -FilePath $chapSidecar -Encoding UTF8 -Force
      icacls $chapSidecar /inheritance:r /grant:r "$($env:USERNAME):(R,W)" | Out-Null
      Write-Host "[sqlserver-creds-seed] CHAP sidecar written to $chapSidecar (consumed by foundation's iSCSI target overlay)"
    PWSH
  }
}
