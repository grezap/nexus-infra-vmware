/*
 * role-overlay-vault-agent-platform-tools-policies.tf -- Phase 0.Q.1 setup (ADR-0043)
 *
 * One narrow Vault policy per platform-tools-node Vault Agent (3 nodes):
 *   nexus-agent-platform-tools-marquez / -marquez-pg-1 / -marquez-pg-2
 *
 * Permissions: PKI issue on pki_int/issue/<platform_tools_role> + KV read on
 * nexus/data/platform-tools/* (Marquez DB / replication / superuser passwords)
 * + token self. Idempotent upsert.
 *
 * LANDMINE: the KV read path is the KV-v2 *data* path (nexus/data/...), not the
 * logical path the operator types (nexus/...). Getting that wrong yields a
 * permission-denied that looks like a missing secret.
 *
 * Selective ops: var.enable_platform_tools_agent_setup AND
 *                var.enable_platform_tools_agent_policies.
 */

locals {
  platform_tools_agent_policy_specs = {
    "nexus-agent-platform-tools-marquez"      = { host = "marquez" }
    "nexus-agent-platform-tools-marquez-pg-1" = { host = "marquez-pg-1" }
    "nexus-agent-platform-tools-marquez-pg-2" = { host = "marquez-pg-2" }
  }
}

resource "null_resource" "vault_agent_platform_tools_policies" {
  count = var.enable_vault_cluster && var.enable_vault_init && var.enable_platform_tools_agent_setup && var.enable_platform_tools_agent_policies ? 1 : 0

  triggers = {
    post_init_id                      = null_resource.vault_post_init[0].id
    platform_tools_role_id            = length(null_resource.vault_pki_platform_tools_role) > 0 ? null_resource.vault_pki_platform_tools_role[0].id : "disabled"
    platform_tools_role_name          = var.vault_pki_platform_tools_role_name
    platform_tools_policies_overlay_v = "1"
  }

  depends_on = [null_resource.vault_post_init, null_resource.vault_pki_platform_tools_role]

  provisioner "local-exec" {
    when        = create
    interpreter = ["pwsh", "-NoProfile", "-Command"]
    command     = <<-PWSH
      $ip          = '${local.vault_1_ip}'
      $user        = '${local.ssh_user}'
      $keysFileRaw = '${var.vault_init_keys_file}'
      $keysFile    = $ExecutionContext.InvokeCommand.ExpandString($keysFileRaw.Replace('$HOME', $env:USERPROFILE))

      if (-not (Test-Path $keysFile)) { throw "[platform-tools-policies] keys file $keysFile missing" }
      $rootToken = (Get-Content $keysFile | ConvertFrom-Json).root_token

      $platformToolsPolicy = @"
# Phase 0.Q.1 setup -- agent policy for platform-tools nodes (HOSTNAME).
path "pki_int/issue/${var.vault_pki_platform_tools_role_name}" {
  capabilities = ["create", "update"]
}
path "nexus/data/platform-tools/*" {
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
%{for name, spec in local.platform_tools_agent_policy_specs~}
        @{ Name = '${name}'; Host = '${spec.host}' },
%{endfor~}
        $null
      ) | Where-Object { $_ -ne $null }

      foreach ($s in $specs) {
        $name = $s.Name
        $hostName = $s.Host
        $bodyRendered = $platformToolsPolicy -replace 'HOSTNAME', $hostName
        $bodyB64 = [Convert]::ToBase64String([System.Text.UTF8Encoding]::new($false).GetBytes($bodyRendered))

        $remoteBash = @"
set -euo pipefail
export VAULT_TOKEN='$rootToken'
export VAULT_SKIP_VERIFY=true
export VAULT_ADDR=https://127.0.0.1:8200
echo '$bodyB64' | base64 -d | vault policy write $name - >/dev/null
echo "[platform-tools-policies] wrote policy $name"
"@
        $remoteB64 = [Convert]::ToBase64String([System.Text.UTF8Encoding]::new($false).GetBytes($remoteBash))
        Write-Host "[platform-tools-policies] writing $name (policy for $hostName)"
        $output = ssh -o ConnectTimeout=15 -o BatchMode=yes -o StrictHostKeyChecking=no $user@$ip "echo '$remoteB64' | base64 -d | bash" 2>&1 | Out-String
        if ($LASTEXITCODE -ne 0) { Write-Host $output.Trim(); throw "[platform-tools-policies] failed writing $name (rc=$LASTEXITCODE)" }
        Write-Host $output.Trim()
      }

      Write-Host "[platform-tools-policies] all $($specs.Count) platform-tools-node policies written"
    PWSH
  }
}
