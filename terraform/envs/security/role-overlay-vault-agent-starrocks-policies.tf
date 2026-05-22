/*
 * role-overlay-vault-agent-starrocks-policies.tf -- Phase 0.G.6 setup
 *
 * One narrow Vault policy per StarRocks-node Vault Agent (6 nodes: 3 FE + 3 BE).
 *   nexus-agent-starrocks-sr-fe-leader / -follower-1/2
 *   nexus-agent-starrocks-sr-be-1/2/3
 *
 * Permissions: PKI issue on pki_int/issue/<starrocks_role> + KV read on
 * nexus/data/analytics/starrocks/* (root/app passwords for the schema-bootstrap)
 * + token self. Idempotent upsert.
 *
 * Selective ops: var.enable_starrocks_agent_setup AND var.enable_starrocks_agent_policies.
 */

locals {
  starrocks_agent_policy_specs = {
    "nexus-agent-starrocks-sr-fe-leader"     = { host = "sr-fe-leader" }
    "nexus-agent-starrocks-sr-fe-follower-1" = { host = "sr-fe-follower-1" }
    "nexus-agent-starrocks-sr-fe-follower-2" = { host = "sr-fe-follower-2" }
    "nexus-agent-starrocks-sr-be-1"          = { host = "sr-be-1" }
    "nexus-agent-starrocks-sr-be-2"          = { host = "sr-be-2" }
    "nexus-agent-starrocks-sr-be-3"          = { host = "sr-be-3" }
  }
}

resource "null_resource" "vault_agent_starrocks_policies" {
  count = var.enable_vault_cluster && var.enable_vault_init && var.enable_starrocks_agent_setup && var.enable_starrocks_agent_policies ? 1 : 0

  triggers = {
    post_init_id                 = null_resource.vault_post_init[0].id
    starrocks_role_id            = length(null_resource.vault_pki_starrocks_role) > 0 ? null_resource.vault_pki_starrocks_role[0].id : "disabled"
    starrocks_role_name          = var.vault_pki_starrocks_role_name
    starrocks_policies_overlay_v = "1"
  }

  depends_on = [null_resource.vault_post_init, null_resource.vault_pki_starrocks_role]

  provisioner "local-exec" {
    when        = create
    interpreter = ["pwsh", "-NoProfile", "-Command"]
    command     = <<-PWSH
      $ip          = '${local.vault_1_ip}'
      $user        = '${local.ssh_user}'
      $keysFileRaw = '${var.vault_init_keys_file}'
      $keysFile    = $ExecutionContext.InvokeCommand.ExpandString($keysFileRaw.Replace('$HOME', $env:USERPROFILE))

      if (-not (Test-Path $keysFile)) { throw "[starrocks-policies] keys file $keysFile missing" }
      $rootToken = (Get-Content $keysFile | ConvertFrom-Json).root_token

      $starrocksPolicy = @"
# Phase 0.G.6 setup -- agent policy for StarRocks nodes (HOSTNAME).
path "pki_int/issue/${var.vault_pki_starrocks_role_name}" {
  capabilities = ["create", "update"]
}
path "nexus/data/analytics/starrocks/*" {
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
%{for name, spec in local.starrocks_agent_policy_specs~}
        @{ Name = '${name}'; Host = '${spec.host}' },
%{endfor~}
        $null
      ) | Where-Object { $_ -ne $null }

      foreach ($s in $specs) {
        $name = $s.Name
        $hostName = $s.Host
        $bodyRendered = $starrocksPolicy -replace 'HOSTNAME', $hostName
        $bodyB64 = [Convert]::ToBase64String([System.Text.UTF8Encoding]::new($false).GetBytes($bodyRendered))

        $remoteBash = @"
set -euo pipefail
export VAULT_TOKEN='$rootToken'
export VAULT_SKIP_VERIFY=true
export VAULT_ADDR=https://127.0.0.1:8200
echo '$bodyB64' | base64 -d | vault policy write $name - >/dev/null
echo "[starrocks-policies] wrote policy $name"
"@
        $remoteB64 = [Convert]::ToBase64String([System.Text.UTF8Encoding]::new($false).GetBytes($remoteBash))
        Write-Host "[starrocks-policies] writing $name (policy for $hostName)"
        $output = ssh -o ConnectTimeout=15 -o BatchMode=yes -o StrictHostKeyChecking=no $user@$ip "echo '$remoteB64' | base64 -d | bash" 2>&1 | Out-String
        if ($LASTEXITCODE -ne 0) { Write-Host $output.Trim(); throw "[starrocks-policies] failed writing $name (rc=$LASTEXITCODE)" }
        Write-Host $output.Trim()
      }

      Write-Host "[starrocks-policies] all $($specs.Count) StarRocks-node policies written"
    PWSH
  }
}
