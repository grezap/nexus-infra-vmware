/*
 * role-overlay-vault-agent-policies.tf -- Phase 0.D.5.4 step 1/2 (security)
 *
 * Two narrow Vault policies, one per Windows host that runs Vault
 * Agent in 0.D.5.4 scope. Each policy grants read on ONLY the KV
 * paths that host actually consumes. Token-self lookup/renew also
 * granted so Agent can keep its token alive without needing 'default'
 * policy stacked on top.
 *
 *   nexus-agent-dc-nexus -> read on:
 *     nexus/data/foundation/dc-nexus/*       (DSRM, local-administrator)
 *     nexus/data/foundation/identity/nexusadmin
 *     nexus/data/foundation/ad/svc-vault-ldap (bind cred consumed by AD-side ops)
 *
 *   nexus-agent-nexus-jumpbox -> read on:
 *     nexus/data/foundation/identity/nexusadmin   (Add-Computer / RDP login)
 *     nexus/data/foundation/ad/svc-vault-smoke    (smoke gate proof-of-concept)
 *
 * Idempotency: vault policy write is upsert.
 *
 * Selective ops: enable_vault_agent_setup (master) AND
 *                enable_vault_agent_policies.
 */

resource "null_resource" "vault_agent_policies" {
  count = var.enable_vault_cluster && var.enable_vault_init && var.enable_vault_agent_setup && var.enable_vault_agent_policies ? 1 : 0

  triggers = {
    post_init_id       = null_resource.vault_post_init[0].id
    kv_mount_path      = var.vault_kv_mount_path
    policies_overlay_v = "1"
  }

  depends_on = [null_resource.vault_post_init]

  provisioner "local-exec" {
    when        = create
    interpreter = ["pwsh", "-NoProfile", "-Command"]
    command     = <<-PWSH
      $ip          = '${local.vault_1_ip}'
      $user        = '${local.ssh_user}'
      $kvPath      = '${var.vault_kv_mount_path}'
      $keysFileRaw = '${var.vault_init_keys_file}'
      $keysFile    = $ExecutionContext.InvokeCommand.ExpandString($keysFileRaw.Replace('$HOME', $env:USERPROFILE))

      if (-not (Test-Path $keysFile)) {
        throw "[agent-policies] keys file $keysFile missing"
      }
      $rootToken = (Get-Content $keysFile | ConvertFrom-Json).root_token

      $policyDcNexus = @"
# nexus-agent-dc-nexus -- Phase 0.D.5.4 Vault Agent policy for dc-nexus.
# Narrow read on the foundation creds dc-nexus actually consumes.
path "$kvPath/data/foundation/dc-nexus/*" {
  capabilities = ["read"]
}
path "$kvPath/data/foundation/identity/nexusadmin" {
  capabilities = ["read"]
}
path "$kvPath/data/foundation/ad/svc-vault-ldap" {
  capabilities = ["read"]
}
path "auth/token/lookup-self" {
  capabilities = ["read"]
}
path "auth/token/renew-self" {
  capabilities = ["update"]
}
"@

      $policyJumpbox = @"
# nexus-agent-nexus-jumpbox -- Phase 0.D.5.4 Vault Agent policy for nexus-jumpbox.
path "$kvPath/data/foundation/identity/nexusadmin" {
  capabilities = ["read"]
}
path "$kvPath/data/foundation/ad/svc-vault-smoke" {
  capabilities = ["read"]
}
path "auth/token/lookup-self" {
  capabilities = ["read"]
}
path "auth/token/renew-self" {
  capabilities = ["update"]
}
"@

      $policies = @{
        'nexus-agent-dc-nexus'      = $policyDcNexus
        'nexus-agent-nexus-jumpbox' = $policyJumpbox
      }

      foreach ($name in $policies.Keys) {
        $body  = $policies[$name]
        $bytes = [System.Text.UTF8Encoding]::new($false).GetBytes($body)
        $b64   = [Convert]::ToBase64String($bytes)

        $remoteBash = @"
set -euo pipefail
export VAULT_TOKEN='$rootToken'
export VAULT_SKIP_VERIFY=true
export VAULT_ADDR=https://127.0.0.1:8200

TMP=`$(mktemp)
trap 'rm -f "`$TMP"' EXIT
echo '$b64' | base64 -d > "`$TMP"
vault policy write '$name' "`$TMP" >/dev/null
echo "[agent-policies] wrote policy '$name' (`$(wc -c < "`$TMP") bytes)"
"@
        $bashBytes = [System.Text.UTF8Encoding]::new($false).GetBytes($remoteBash)
        $bashB64   = [Convert]::ToBase64String($bashBytes)
        $output = ssh -o ConnectTimeout=30 -o BatchMode=yes -o StrictHostKeyChecking=no $user@$ip "echo '$bashB64' | base64 -d | bash" 2>&1 | Out-String
        if ($LASTEXITCODE -ne 0) {
          throw "[agent-policies] vault policy write '$name' failed (rc=$LASTEXITCODE). Output:`n$output"
        }
        Write-Host $output.Trim()
      }

      Write-Host "[agent-policies] complete -- nexus-agent-dc-nexus + nexus-agent-nexus-jumpbox written"
    PWSH
  }
}
