/*
 * role-overlay-vault-agent-starrocks-sd-policies.tf -- Phase 0.L.5 setup
 *
 * One narrow Vault policy per StarRocks-shared-data-node Vault Agent (5 nodes:
 * 3 FE + 2 CN):
 *   nexus-agent-starrocks-sd-sr-sd-fe-1/2/3
 *   nexus-agent-starrocks-sd-sr-sd-cn-1/2
 *
 * Permissions: PKI issue on pki_int/issue/<starrocks_sd_role> + KV read on
 * nexus/data/analytics/starrocks-sd/* (root/app passwords + S3 access/secret
 * for the MinIO storage volume) + token self. Idempotent upsert.
 *
 * Selective ops: var.enable_starrocks_sd_agent_setup AND var.enable_starrocks_sd_agent_policies.
 */

locals {
  starrocks_sd_agent_policy_specs = {
    "nexus-agent-starrocks-sd-sr-sd-fe-1" = { host = "sr-sd-fe-1" }
    "nexus-agent-starrocks-sd-sr-sd-fe-2" = { host = "sr-sd-fe-2" }
    "nexus-agent-starrocks-sd-sr-sd-fe-3" = { host = "sr-sd-fe-3" }
    "nexus-agent-starrocks-sd-sr-sd-cn-1" = { host = "sr-sd-cn-1" }
    "nexus-agent-starrocks-sd-sr-sd-cn-2" = { host = "sr-sd-cn-2" }
  }
}

resource "null_resource" "vault_agent_starrocks_sd_policies" {
  count = var.enable_vault_cluster && var.enable_vault_init && var.enable_starrocks_sd_agent_setup && var.enable_starrocks_sd_agent_policies ? 1 : 0

  triggers = {
    post_init_id                    = null_resource.vault_post_init[0].id
    starrocks_sd_role_id            = length(null_resource.vault_pki_starrocks_sd_role) > 0 ? null_resource.vault_pki_starrocks_sd_role[0].id : "disabled"
    starrocks_sd_role_name          = var.vault_pki_starrocks_sd_role_name
    starrocks_sd_policies_overlay_v = "1"
  }

  depends_on = [null_resource.vault_post_init, null_resource.vault_pki_starrocks_sd_role]

  provisioner "local-exec" {
    when        = create
    interpreter = ["pwsh", "-NoProfile", "-Command"]
    command     = <<-PWSH
      $ip          = '${local.vault_1_ip}'
      $user        = '${local.ssh_user}'
      $keysFileRaw = '${var.vault_init_keys_file}'
      $keysFile    = $ExecutionContext.InvokeCommand.ExpandString($keysFileRaw.Replace('$HOME', $env:USERPROFILE))

      if (-not (Test-Path $keysFile)) { throw "[starrocks-sd-policies] keys file $keysFile missing" }
      $rootToken = (Get-Content $keysFile | ConvertFrom-Json).root_token

      $starrocksSdPolicy = @"
# Phase 0.L.5 setup -- agent policy for StarRocks shared-data nodes (HOSTNAME).
path "pki_int/issue/${var.vault_pki_starrocks_sd_role_name}" {
  capabilities = ["create", "update"]
}
path "nexus/data/analytics/starrocks-sd/*" {
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
%{for name, spec in local.starrocks_sd_agent_policy_specs~}
        @{ Name = '${name}'; Host = '${spec.host}' },
%{endfor~}
        $null
      ) | Where-Object { $_ -ne $null }

      foreach ($s in $specs) {
        $policyName = $s.Name
        $hostName   = $s.Host
        $bodyRendered = $starrocksSdPolicy -replace 'HOSTNAME', $hostName
        $bodyB64 = [Convert]::ToBase64String([System.Text.UTF8Encoding]::new($false).GetBytes($bodyRendered))

        $remoteBash = @"
set -euo pipefail
export VAULT_TOKEN='$rootToken'
export VAULT_SKIP_VERIFY=true
export VAULT_ADDR=https://127.0.0.1:8200
echo '$bodyB64' | base64 -d | vault policy write $policyName - >/dev/null
echo "[starrocks-sd-policies] wrote policy $policyName"
"@
        $remoteB64 = [Convert]::ToBase64String([System.Text.UTF8Encoding]::new($false).GetBytes($remoteBash))
        Write-Host "[starrocks-sd-policies] writing $policyName (policy for $hostName)"
        $output = ssh -o ConnectTimeout=15 -o BatchMode=yes -o StrictHostKeyChecking=no $user@$ip "echo '$remoteB64' | base64 -d | bash" 2>&1 | Out-String
        if ($LASTEXITCODE -ne 0) { Write-Host $output.Trim(); throw "[starrocks-sd-policies] failed writing $policyName (rc=$LASTEXITCODE)" }
        Write-Host $output.Trim()
      }

      Write-Host "[starrocks-sd-policies] all $($specs.Count) StarRocks-shared-data-node policies written"
    PWSH
  }
}
