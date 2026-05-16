/*
 * role-overlay-vault-agent-mongo-policies.tf -- Phase 0.G.2 setup
 *
 * One narrow Vault policy per mongo-node Vault Agent. Mirrors the 0.G.1
 * `nexus-agent-redis-*` shape, plus the KV read grant needed for the
 * shared replica set keyFile:
 *
 *   nexus-agent-mongo-1  -- initial PRIMARY at rs.initiate (rs re-elects)
 *   nexus-agent-mongo-2  -- RS member 1
 *   nexus-agent-mongo-3  -- RS member 2
 *
 * Permissions (mongo needs the keyFile KV grant, unlike redis):
 *   - PKI issue on pki_int/issue/<mongo_role>        (all 3 -- TLS leaf cert)
 *   - KV read on nexus/data/oltp/mongo/keyfile       (all 3 -- RS internal auth shared secret)
 *   - token self-lookup + self-renew                 (all 3)
 *
 * The KV path uses the v2 secrets engine convention: `nexus/data/oltp/
 * mongo/keyfile` is the policy capability path (KV-v2 inserts the `/data/`
 * segment); `nexus/oltp/mongo/keyfile` is the CLI-facing path. The
 * mongo-keyfile-seed overlay seeds the CLI path; this policy grants read
 * on the corresponding policy path.
 *
 * Idempotency: vault policy write is upsert.
 *
 * Selective ops: var.enable_mongo_agent_setup (master) AND
 *                var.enable_mongo_agent_policies.
 */

locals {
  mongo_agent_policy_specs = {
    "nexus-agent-mongo-1" = { host = "mongo-1" }
    "nexus-agent-mongo-2" = { host = "mongo-2" }
    "nexus-agent-mongo-3" = { host = "mongo-3" }
  }
}

resource "null_resource" "vault_agent_mongo_policies" {
  count = var.enable_vault_cluster && var.enable_vault_init && var.enable_mongo_agent_setup && var.enable_mongo_agent_policies ? 1 : 0

  triggers = {
    post_init_id             = null_resource.vault_post_init[0].id
    mongo_role_id            = length(null_resource.vault_pki_mongo_role) > 0 ? null_resource.vault_pki_mongo_role[0].id : "disabled"
    mongo_role_name          = var.vault_pki_mongo_role_name
    mongo_policies_overlay_v = "2" # v2 (0.G.2 ratification fix 2026-05-17) = +KV read on nexus/data/oltp/mongo/smoke-user-password (sticky-seeded by role-overlay-vault-mongo-smoke-user-seed.tf; mongo-tls overlay renders it to /etc/nexus-mongo/smoke-user-password for the rs-initiate createUser flow + smoke gate auth). v1 = initial 3-node MongoDB RS; added KV read on nexus/data/oltp/mongo/keyfile for RS internal auth.
  }

  depends_on = [null_resource.vault_post_init, null_resource.vault_pki_mongo_role, null_resource.vault_mongo_keyfile_seed]

  provisioner "local-exec" {
    when        = create
    interpreter = ["pwsh", "-NoProfile", "-Command"]
    command     = <<-PWSH
      $ip          = '${local.vault_1_ip}'
      $user        = '${local.ssh_user}'
      $keysFileRaw = '${var.vault_init_keys_file}'
      $keysFile    = $ExecutionContext.InvokeCommand.ExpandString($keysFileRaw.Replace('$HOME', $env:USERPROFILE))

      if (-not (Test-Path $keysFile)) { throw "[mongo-policies] keys file $keysFile missing" }
      $rootToken = (Get-Content $keysFile | ConvertFrom-Json).root_token

      # One policy body for all 3 mongo nodes -- interchangeable from
      # Vault's perspective (same PKI role, same KV path). HOSTNAME
      # placeholder is kept for symmetry with kafka/redis patterns + so a
      # future per-host KV grant is a one-line change.
      $mongoPolicy = @"
# Phase 0.G.2 setup -- agent policy for mongo RS nodes (HOSTNAME placeholder
# substituted per-policy below). Grants PKI leaf issuance + KV read on the
# RS internal auth keyFile + token self-mgmt.
path "pki_int/issue/${var.vault_pki_mongo_role_name}" {
  capabilities = ["create", "update"]
}
path "nexus/data/oltp/mongo/keyfile" {
  capabilities = ["read"]
}
path "nexus/data/oltp/mongo/smoke-user-password" {
  capabilities = ["read"]
}
path "auth/token/lookup-self" {
  capabilities = ["read"]
}
path "auth/token/renew-self" {
  capabilities = ["update"]
}
"@

      $specs = @(
%{for name, spec in local.mongo_agent_policy_specs~}
        @{ Name = '${name}'; Host = '${spec.host}' },
%{endfor~}
        $null
      ) | Where-Object { $_ -ne $null }

      foreach ($s in $specs) {
        $name = $s.Name
        $hostName = $s.Host
        $bodyRendered = $mongoPolicy -replace 'HOSTNAME', $hostName

        $bodyBytes = [System.Text.UTF8Encoding]::new($false).GetBytes($bodyRendered)
        $bodyB64   = [Convert]::ToBase64String($bodyBytes)

        $remoteBash = @"
set -euo pipefail
export VAULT_TOKEN='$rootToken'
export VAULT_SKIP_VERIFY=true
export VAULT_ADDR=https://127.0.0.1:8200
echo '$bodyB64' | base64 -d | vault policy write $name - >/dev/null
echo "[mongo-policies] wrote policy $name"
"@
        $remoteBytes = [System.Text.UTF8Encoding]::new($false).GetBytes($remoteBash)
        $remoteB64   = [Convert]::ToBase64String($remoteBytes)

        Write-Host "[mongo-policies] writing $name (mongo policy for $hostName)"
        $output = ssh -o ConnectTimeout=15 -o BatchMode=yes -o StrictHostKeyChecking=no $user@$ip "echo '$remoteB64' | base64 -d | bash" 2>&1 | Out-String
        if ($LASTEXITCODE -ne 0) {
          Write-Host $output.Trim()
          throw "[mongo-policies] failed writing $name (rc=$LASTEXITCODE)"
        }
        Write-Host $output.Trim()
      }

      Write-Host "[mongo-policies] all $($specs.Count) mongo-node policies written"
    PWSH
  }
}
