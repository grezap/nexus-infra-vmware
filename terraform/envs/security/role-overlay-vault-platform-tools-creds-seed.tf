/*
 * role-overlay-vault-platform-tools-creds-seed.tf -- Phase 0.Q.1 setup (ADR-0043)
 *
 * Sticky-seeds the Marquez / Marquez-PG creds in Vault KV (field `value`, the
 * registry-tier convention -- see role-overlay-vault-registry-creds-seed.tf):
 *   nexus/platform-tools/marquez/db-password          (PG `marquez` app role --
 *                                                      Marquez API's JDBC user)
 *   nexus/platform-tools/marquez/replication-password (PG `repluser` streaming-
 *                                                      repl role, pg-1 -> pg-2)
 *   nexus/platform-tools/marquez/superuser-password   (PG `postgres` role)
 *
 * All read on-node via the per-host Vault Agent token; never transit the host.
 * Sticky -- never overwrites a populated path (operator rotation preserved).
 *
 * LANDMINES:
 *  - Field name is `value`, matching the registry tier. Obs (0.I) uses
 *    `password`/`password_bcrypt`; do NOT cross-copy a consumer template from
 *    that tier or the lookup returns empty.
 *  - Passwords are hex only (openssl rand -hex). Deliberate: hex survives
 *    JDBC URLs, docker-compose env interpolation and libpq conninfo without
 *    quoting/escaping. No special characters by design.
 *  - Generation happens on-node inside the seeded bash, not via a Terraform
 *    random_password resource -- that keeps the plaintext out of tfstate
 *    (feedback_never_git_add_all_state).
 *
 * Selective ops: var.enable_platform_tools_creds_seed (master).
 */

resource "null_resource" "vault_platform_tools_creds_seed" {
  count = var.enable_vault_cluster && var.enable_vault_init && var.enable_platform_tools_creds_seed ? 1 : 0

  triggers = {
    post_init_id                = null_resource.vault_post_init[0].id
    kv_paths                    = "nexus/platform-tools/marquez/{db-password,replication-password,superuser-password}"
    platform_tools_creds_seed_v = "1"
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

      if (-not (Test-Path $keysFile)) { throw "[platform-tools-creds-seed] keys file $keysFile missing" }
      $rootToken = (Get-Content $keysFile | ConvertFrom-Json).root_token

      $bash = @"
set -euo pipefail
export VAULT_TOKEN='$rootToken'
export VAULT_SKIP_VERIFY=true
export VAULT_ADDR=https://127.0.0.1:8200

seed() {
  local path="`$1"; local val="`$2"; local label="`$3"
  if vault kv get -field=value "`$path" >/dev/null 2>&1; then
    echo "[platform-tools-creds-seed] `$path already populated -- no-op (sticky `$label)"
    return 0
  fi
  vault kv put "`$path" value="`$val" >/dev/null
  echo "[platform-tools-creds-seed] wrote `$path (`$label)"
}

seed 'nexus/platform-tools/marquez/db-password'          "`$(openssl rand -hex 20)" 'PG marquez app DB role'
seed 'nexus/platform-tools/marquez/replication-password' "`$(openssl rand -hex 20)" 'PG replication'
seed 'nexus/platform-tools/marquez/superuser-password'   "`$(openssl rand -hex 20)" 'PG postgres superuser'

echo "[platform-tools-creds-seed] all Marquez datastore creds present in nexus/platform-tools/marquez/"
"@

      $b64 = [Convert]::ToBase64String([System.Text.UTF8Encoding]::new($false).GetBytes($bash))
      Write-Host "[platform-tools-creds-seed] dispatching to $${ip} via base64"
      $output = ssh -o ConnectTimeout=30 -o BatchMode=yes -o StrictHostKeyChecking=no $user@$ip "echo '$b64' | base64 -d | bash" 2>&1 | Out-String
      $rc = $LASTEXITCODE
      Write-Host $output.Trim()
      if ($rc -ne 0) { throw "[platform-tools-creds-seed] script failed (rc=$rc)" }
    PWSH
  }
}
