/*
 * role-overlay-vault-pki-rotate.tf -- Phase 0.D.2 step 5/7
 *
 * Per-node leaf cert reissuance: each Vault node gets a fresh PKI-issued
 * cert from pki_int/, atomic-swapped into /etc/vault.d/tls/, then
 * SIGHUP-reloaded via systemctl reload vault.service (the unit ships
 * ExecReload=/bin/kill --signal HUP $MAINPID, verified in
 * packer/vault/ansible/roles/vault_node/templates/vault.service.j2).
 *
 * Cert SAN list (per memory/feedback_lab_host_reachability.md -- all
 * client-reachable identities must validate):
 *   common_name: vault-N.nexus.lab
 *   alt_names  : vault-N, localhost
 *   ip_sans    : 192.168.70.N (VMnet11 service), 192.168.10.N (VMnet10
 *                cluster backplane), 127.0.0.1 (in-node CLI)
 *
 * Atomic swap pattern: write to /etc/vault.d/tls/<file>.new, mv into
 * place (atomic rename within same fs), then SIGHUP. If anything in
 * the cert-write step fails, the live file is unchanged. If SIGHUP
 * fails post-mv, Vault keeps serving the OLD cert (the new files are
 * on disk but unread); next apply re-detects via post-reload openssl
 * verify and either retries or surfaces the issue.
 *
 * Idempotency: per-node probe -- if the current /etc/vault.d/tls/vault.crt
 * is already issued by our intermediate AND has >30 days remaining,
 * skip. Otherwise reissue. This makes terraform apply safe to re-run
 * without thrashing certs every time.
 *
 * Why we always go through the leader (192.168.70.121:8200) for the
 * issue call: PKI writes are forwarded by Raft followers to the leader
 * anyway, and pinning the address makes diagnostics consistent. Still
 * VAULT_SKIP_VERIFY=true at this point because the leader's listener
 * cert is the 0.D.1 self-signed one until vault-1's own rotation in
 * this loop completes (after which vault-2/3 hit a PKI-signed cert
 * but skip-verify is still benign).
 *
 * Selective ops: var.enable_vault_pki AND var.enable_vault_pki_rotate.
 */

resource "null_resource" "vault_pki_rotate_listener" {
  count = var.enable_vault_cluster && var.enable_vault_init && var.enable_vault_pki && var.enable_vault_pki_rotate ? 1 : 0

  triggers = {
    roles_id         = length(null_resource.vault_pki_roles) > 0 ? null_resource.vault_pki_roles[0].id : "disabled"
    int_common_name  = var.vault_pki_intermediate_common_name
    leaf_ttl         = var.vault_pki_leaf_ttl
    role_name        = var.vault_pki_role_name
    rotate_overlay_v = "1"
  }

  depends_on = [null_resource.vault_pki_roles]

  provisioner "local-exec" {
    when        = create
    interpreter = ["pwsh", "-NoProfile", "-Command"]
    command     = <<-PWSH
      $user           = '${local.ssh_user}'
      $leaderIp       = '${local.vault_1_ip}'
      $roleName       = '${var.vault_pki_role_name}'
      $leafTtl        = '${var.vault_pki_leaf_ttl}'
      $intCommonName  = '${var.vault_pki_intermediate_common_name}'
      $keysFileRaw    = '${var.vault_init_keys_file}'
      $keysFile       = $ExecutionContext.InvokeCommand.ExpandString($keysFileRaw.Replace('$HOME', $env:USERPROFILE))

      if (-not (Test-Path $keysFile)) {
        throw "[pki-rotate] keys file $keysFile missing"
      }
      $rootToken = (Get-Content $keysFile | ConvertFrom-Json).root_token

      $nodes = @(
        @{ Name = 'vault-1'; Ip = '${local.vault_1_ip}'; Vmnet10 = '192.168.10.121' },
        @{ Name = 'vault-2'; Ip = '${local.vault_2_ip}'; Vmnet10 = '192.168.10.122' },
        @{ Name = 'vault-3'; Ip = '${local.vault_3_ip}'; Vmnet10 = '192.168.10.123' }
      )

      foreach ($node in $nodes) {
        $hostname    = $node.Name
        $ip          = $node.Ip
        $vmnet10_ip  = $node.Vmnet10
        Write-Host "[pki-rotate] $${hostname}: dispatching rotation script"

        $bash = @"
set -euo pipefail
export VAULT_TOKEN='$rootToken'
export VAULT_SKIP_VERIFY=true
export VAULT_ADDR='https://$${leaderIp}:8200'

HOSTNAME='$hostname'
VMNET11_IP='$ip'
VMNET10_IP='$vmnet10_ip'
LEAF_TTL='$leafTtl'
ROLE_NAME='$roleName'
INT_CN='$intCommonName'

CRT=/etc/vault.d/tls/vault.crt
KEY=/etc/vault.d/tls/vault.key

# ─── Idempotency probe: skip if current cert is already PKI-issued + fresh ──
SKIP_REASON=''
if sudo test -f "`$CRT"; then
  CUR_ISSUER=`$(sudo openssl x509 -in "`$CRT" -noout -issuer 2>/dev/null | sed 's/^issuer= *//' | sed 's/^issuer=//')
  if echo "`$CUR_ISSUER" | grep -qF "`$INT_CN"; then
    EXPIRY=`$(sudo openssl x509 -in "`$CRT" -noout -enddate 2>/dev/null | sed 's/^notAfter=//')
    EXPIRY_EPOCH=`$(date -d "`$EXPIRY" +%s 2>/dev/null || echo 0)
    NOW_EPOCH=`$(date +%s)
    REMAINING_DAYS=`$(( (EXPIRY_EPOCH - NOW_EPOCH) / 86400 ))
    if [ "`$REMAINING_DAYS" -gt 30 ]; then
      SKIP_REASON="cert is PKI-issued (issuer=`$CUR_ISSUER) and `$REMAINING_DAYS days remaining"
    else
      echo "[pki-rotate] `$HOSTNAME: cert is PKI-issued but only `$REMAINING_DAYS days remaining; re-issuing"
    fi
  else
    echo "[pki-rotate] `$HOSTNAME: current cert issuer='`$CUR_ISSUER' is not the PKI intermediate; rotating"
  fi
fi

if [ -n "`$SKIP_REASON" ]; then
  echo "[pki-rotate] `$HOSTNAME: skipping rotation (`$SKIP_REASON)"
  exit 0
fi

# ─── Issue fresh leaf cert via the leader ───────────────────────────────────
echo "[pki-rotate] `$HOSTNAME: issuing leaf via pki_int/issue/`$ROLE_NAME (ttl=`$LEAF_TTL)"
ISSUED=`$(vault write -format=json pki_int/issue/`$ROLE_NAME \
  common_name="`$HOSTNAME.nexus.lab" \
  alt_names="`$HOSTNAME,localhost" \
  ip_sans="`$VMNET11_IP,`$VMNET10_IP,127.0.0.1" \
  ttl="`$LEAF_TTL")

if [ -z "`$ISSUED" ]; then
  echo "[pki-rotate] `$HOSTNAME: empty response from vault write pki_int/issue" >&2
  exit 1
fi

LEAF=`$(echo "`$ISSUED" | jq -r '.data.certificate')
LEAF_KEY=`$(echo "`$ISSUED" | jq -r '.data.private_key')
ISSUING_CA=`$(echo "`$ISSUED" | jq -r '.data.issuing_ca')

if [ -z "`$LEAF" ] || [ -z "`$LEAF_KEY" ] || [ -z "`$ISSUING_CA" ]; then
  echo "[pki-rotate] `$HOSTNAME: issued data missing one of certificate/private_key/issuing_ca" >&2
  exit 1
fi

# Build the fullchain PEM (leaf + issuing intermediate) so TLS handshakes serve the chain
TMPDIR=`$(mktemp -d)
trap 'rm -rf "`$TMPDIR"' EXIT
{
  echo "`$LEAF"
  echo "`$ISSUING_CA"
} > "`$TMPDIR/vault.crt"
echo "`$LEAF_KEY" > "`$TMPDIR/vault.key"

# ─── Atomic swap into /etc/vault.d/tls/ ─────────────────────────────────────
# install(1) atomically copies + sets owner/group/mode in a single rename.
echo "[pki-rotate] `$HOSTNAME: atomic-swap cert + key into /etc/vault.d/tls/"
sudo install -o vault -g vault -m 0644 "`$TMPDIR/vault.crt" "`$CRT.new"
sudo install -o vault -g vault -m 0600 "`$TMPDIR/vault.key" "`$KEY.new"
sudo mv "`$CRT.new" "`$CRT"
sudo mv "`$KEY.new" "`$KEY"

# ─── SIGHUP via systemctl reload (vault.service ships ExecReload) ──────────
echo "[pki-rotate] `$HOSTNAME: systemctl reload vault.service"
sudo systemctl reload vault.service
# Brief settle -- listener re-reads config in <1s typically
sleep 3

# ─── Verify the new cert is being served ──────────────────────────────────
NEW_ISSUER=`$(echo Q | openssl s_client -connect 127.0.0.1:8200 -servername "`$HOSTNAME.nexus.lab" 2>/dev/null \
              | openssl x509 -noout -issuer 2>/dev/null \
              | sed 's/^issuer= *//' | sed 's/^issuer=//')
if ! echo "`$NEW_ISSUER" | grep -qF "`$INT_CN"; then
  echo "[pki-rotate] `$HOSTNAME: ERROR -- post-reload listener issuer is '`$NEW_ISSUER', expected to contain '`$INT_CN'" >&2
  exit 1
fi
echo "[pki-rotate] `$HOSTNAME: rotated -- listener issuer=`$NEW_ISSUER"
"@

        $bytes = [System.Text.UTF8Encoding]::new($false).GetBytes($bash)
        $b64   = [Convert]::ToBase64String($bytes)

        $output = ssh -o ConnectTimeout=60 -o BatchMode=yes -o StrictHostKeyChecking=no $user@$ip "echo '$b64' | base64 -d | bash" 2>&1 | Out-String
        $rc = $LASTEXITCODE
        Write-Host $output.Trim()
        if ($rc -ne 0) {
          throw "[pki-rotate] $${hostname}: rotation script failed (rc=$rc)"
        }
      }

      Write-Host "[pki-rotate] all 3 nodes rotated to PKI-issued certs"
    PWSH
  }
}
