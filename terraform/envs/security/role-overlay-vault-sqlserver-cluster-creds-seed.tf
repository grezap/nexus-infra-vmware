/*
 * role-overlay-vault-sqlserver-cluster-creds-seed.tf -- Phase 0.G.7 setup
 *
 * Sticky-seeds the 6 SQL Server cluster credentials + 1 GMSA pointer in
 * Vault KV (the 6th -- operator-password, field `password` -- added v3 for
 * the nexus-cli v0.6.6 SqlFci/SqlAg adapter operator login; see its seed
 * block + role-overlay-sqlserver-operator-login.tf in nexus-infra-oltp):
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
    kv_paths               = "nexus/oltp/sqlserver/{sa,ag-endpoint-cert,wsfc-cluster-admin,iscsi-chap-secret,listener-cert}-password + operator-password + gmsa-info"
    sqlserver_creds_seed_v = "3" # v3 (0.G.7 / nexus-cli v0.6.6, 2026-06-12) = +operator-password (field `password`, sqlcomplex) for the nexus-cluster-admin SQL login the SqlFciAdapter/SqlAgAdapter authenticate as (ADR-0011 family; LOCKED Vault-KV operator-credential model). Created on the FCI by nexus-infra-oltp's role-overlay-sqlserver-operator-login.tf. v2 = relax CHAP marker regex `\s*$` to tolerate CRLF from SSH-piped vault-1 output (feedback_pwsh_ssh_stdin_cr_injection.md + feedback_smoke_gate_probe_robustness.md). v1 = initial seeds.
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

# seed_if_absent <path> <label> [format]
#   format = 'hex32'    (default) -- 32-char hex (openssl rand -hex 16)
#          = 'chap16'   -- 16-char hex (openssl rand -hex 8); Windows iSCSI
#                          initiator caps CHAP secrets at 12-16 chars
#                          (transient #26 at 0.G.7 ratify 2026-05-21).
#          = 'sqlcomplex' -- 32-hex + 'Aa9!' suffix; SQL Server strong-
#                          password policy needs 3 of 4 char categories
#                          (upper+lower+digit+symbol); pure hex is only
#                          lower+digit (transient #28i at 0.G.7 ratify).
seed_if_absent() {
  local path="`$1"
  local label="`$2"
  local format="`$3"
  if [ -z "`$format" ]; then format=hex32; fi
  if vault kv get -field=content "`$path" >/dev/null 2>&1; then
    echo "[sqlserver-creds-seed] `$path already populated -- no-op (sticky `$label)"
    return 0
  fi
  local SECRET
  case "`$format" in
    chap16)     SECRET=`$(openssl rand -hex 8) ;;
    sqlcomplex) SECRET="`$(openssl rand -hex 16)Aa9!" ;;
    *)          SECRET=`$(openssl rand -hex 16) ;;
  esac
  local LEN
  LEN=`$(printf '%s' "`$SECRET" | wc -c)
  vault kv put "`$path" content="`$SECRET" >/dev/null
  echo "[sqlserver-creds-seed] wrote `$path (`$LEN-char `$format `$label)"
}

seed_if_absent 'nexus/oltp/sqlserver/sa-password'                  'SQL Server sa login password (emergency operator use)' 'sqlcomplex'
seed_if_absent 'nexus/oltp/sqlserver/ag-endpoint-cert-password'    'AG endpoint cert PFX password (CREATE CERTIFICATE)' 'sqlcomplex'
seed_if_absent 'nexus/oltp/sqlserver/wsfc-cluster-admin-password'  'WSFC cluster bootstrap Local-Administrator password' 'sqlcomplex'
seed_if_absent 'nexus/oltp/sqlserver/iscsi-chap-secret'            'iSCSI CHAP secret for sql-fci.lun1 target on nexus-gateway' 'chap16'
seed_if_absent 'nexus/oltp/sqlserver/listener-cert-password'       'AG Listener leaf cert PFX password' 'sqlcomplex'

# operator-password (field 'password', NOT 'content'): the dedicated
# nexus-cluster-admin SQL login the nexus-cli SqlFciAdapter/SqlAgAdapter
# authenticate as (the LOCKED Vault-KV operator-credential model, ADR-0011
# family; password ONLY in Vault KV, fetched at runtime via INexusVaultClient).
# Created on the FCI by nexus-infra-oltp's role-overlay-sqlserver-operator-login.tf.
# Uses field 'password' to match the adapter convention across all 6 password-auth
# adapters (mongo/percona/patroni/clickhouse/starrocks/sqlserver). sqlcomplex
# (hex + Aa9!) so it satisfies SQL Server's strong-password policy.
seed_pw_if_absent() {
  local path="`$1"; local label="`$2"
  if vault kv get -field=password "`$path" >/dev/null 2>&1; then
    echo "[sqlserver-creds-seed] `$path already populated -- no-op (sticky `$label)"
    return 0
  fi
  local SECRET="`$(openssl rand -hex 16)Aa9!"
  local LEN
  LEN=`$(printf '%s' "`$SECRET" | wc -c)
  vault kv put "`$path" password="`$SECRET" >/dev/null
  echo "[sqlserver-creds-seed] wrote `$path (`$LEN-char sqlcomplex `$label)"
}
seed_pw_if_absent 'nexus/oltp/sqlserver/operator-password' 'nexus-cluster-admin SQL login operator password (nexus-cli SqlFci/SqlAg adapters)'

# gmsa-info is a structured JSON pointer, not a regenerated secret. Idempotent
# overwrite each apply: the GMSA name + domain don't change.
vault kv put nexus/oltp/sqlserver/gmsa-info \
  gmsa_name='gmsa-sql-engine' \
  gmsa_full='gmsa-sql-engine`$' \
  domain='nexus.lab' \
  ou='OU=ServiceAccounts,DC=nexus,DC=lab' \
  retrieve_group='nexus-sql-cluster-members' >/dev/null
echo "[sqlserver-creds-seed] wrote nexus/oltp/sqlserver/gmsa-info pointer (gmsa-sql-engine`$ in OU=ServiceAccounts,DC=nexus,DC=lab)"

# Echo the CHAP secret for the host-side sidecar (only secret that LEAVES
# the vault on every apply -- foundation's iSCSI target overlay needs it).
CHAP=`$(vault kv get -field=content nexus/oltp/sqlserver/iscsi-chap-secret)
echo "ISCSI_CHAP_SECRET_FOR_SIDECAR=`$CHAP"

echo "[sqlserver-creds-seed] all 5 cluster creds + 1 gmsa pointer present in nexus/oltp/sqlserver/"
"@

      $bytes = [System.Text.UTF8Encoding]::new($false).GetBytes($bash)
      $b64   = [Convert]::ToBase64String($bytes)

      # `tr -d '\r'` strips any CR the terraform-heredoc -> pwsh here-string path
      # injects into $bash before it reaches bash on the node (a stray CR turns
      # the first line into `set -euo pipefail\r`, which bash rejects with
      # "set: pipefail: invalid option name"). Mirrors the sibling overlays'
      # `tr -d '\r' | bash -s` idiom (role-overlay-mongo-keyfile.tf;
      # memory/feedback_pwsh_ssh_stdin_cr_injection.md).
      Write-Host "[sqlserver-creds-seed] dispatching to $${ip} via base64"
      $output = ssh -o ConnectTimeout=30 -o BatchMode=yes -o StrictHostKeyChecking=no $user@$ip "echo '$b64' | base64 -d | tr -d '\r' | bash" 2>&1 | Out-String
      $rc = $LASTEXITCODE
      if ($rc -ne 0) {
        Write-Host $output.Trim()
        throw "[sqlserver-creds-seed] script failed (rc=$rc)"
      }

      # Stage 2: parse CHAP secret from the marker line + write host-side
      # sidecar at $HOME\.nexus\iscsi-sqlfci-chap.json. The foundation env's
      # iSCSI target overlay reads this. Filter marker line out of operator-
      # visible output (keep secret out of operator's scrollback).
      # Per memory/feedback_smoke_gate_probe_robustness.md + feedback_pwsh_
      # ssh_stdin_cr_injection.md: SSH-piped output ends each line with CRLF
      # on Windows; PS regex (?m)^...$ matches before \n but a fixed-length
      # hex class doesn't allow a trailing \r. Use \s*$ to tolerate CR/spaces.
      # The CHAP secret is seeded as 'chap16' = openssl rand -hex 8 = 16 hex
      # chars (the Windows iSCSI initiator caps CHAP secrets at 12-16 chars,
      # transient #26). Match {12,32} so it accepts the chap16 value (and any
      # legacy 32-char hex) -- the stale {32}-only class never matched the
      # 16-char secret and threw "failed to parse CHAP secret marker".
      # First transient surfaced at 0.G.7 ratification 2026-05-20.
      $chapMatch = $output -match '(?m)^ISCSI_CHAP_SECRET_FOR_SIDECAR=([0-9a-f]{12,32})\s*$'
      if (-not $chapMatch) {
        Write-Host "[sqlserver-creds-seed] script output for diag:"
        Write-Host $output
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
