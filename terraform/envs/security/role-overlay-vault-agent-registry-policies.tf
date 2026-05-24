/*
 * role-overlay-vault-agent-registry-policies.tf -- Phase 0.L.4 setup
 *
 * One narrow Vault policy per registry-node Vault Agent (4 nodes):
 *   nexus-agent-registry-registry-1 / -registry-2 / -registry-pg-1 / -registry-pg-2
 *
 * Permissions: PKI issue on pki_int/issue/<registry_role> + KV read on
 * nexus/data/registry/* (harbor admin/secret-key/db/redis/oidc/pg creds) AND
 * nexus/data/lakehouse/minio/* (the nexus-lakehouse-app S3 key + root creds for
 * the `harbor` bucket) + token self. Idempotent upsert.
 *
 * Selective ops: var.enable_registry_agent_setup AND var.enable_registry_agent_policies.
 */

locals {
  registry_agent_policy_specs = {
    "nexus-agent-registry-registry-1"    = { host = "registry-1" }
    "nexus-agent-registry-registry-2"    = { host = "registry-2" }
    "nexus-agent-registry-registry-pg-1" = { host = "registry-pg-1" }
    "nexus-agent-registry-registry-pg-2" = { host = "registry-pg-2" }
  }
}

resource "null_resource" "vault_agent_registry_policies" {
  count = var.enable_vault_cluster && var.enable_vault_init && var.enable_registry_agent_setup && var.enable_registry_agent_policies ? 1 : 0

  triggers = {
    post_init_id                = null_resource.vault_post_init[0].id
    registry_role_id            = length(null_resource.vault_pki_registry_role) > 0 ? null_resource.vault_pki_registry_role[0].id : "disabled"
    registry_role_name          = var.vault_pki_registry_role_name
    registry_policies_overlay_v = "1"
  }

  depends_on = [null_resource.vault_post_init, null_resource.vault_pki_registry_role]

  provisioner "local-exec" {
    when        = create
    interpreter = ["pwsh", "-NoProfile", "-Command"]
    command     = <<-PWSH
      $ip          = '${local.vault_1_ip}'
      $user        = '${local.ssh_user}'
      $keysFileRaw = '${var.vault_init_keys_file}'
      $keysFile    = $ExecutionContext.InvokeCommand.ExpandString($keysFileRaw.Replace('$HOME', $env:USERPROFILE))

      if (-not (Test-Path $keysFile)) { throw "[registry-policies] keys file $keysFile missing" }
      $rootToken = (Get-Content $keysFile | ConvertFrom-Json).root_token

      $registryPolicy = @"
# Phase 0.L.4 setup -- agent policy for registry nodes (HOSTNAME).
path "pki_int/issue/${var.vault_pki_registry_role_name}" {
  capabilities = ["create", "update"]
}
path "nexus/data/registry/*" {
  capabilities = ["read"]
}
path "nexus/data/lakehouse/minio/*" {
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
%{for name, spec in local.registry_agent_policy_specs~}
        @{ Name = '${name}'; Host = '${spec.host}' },
%{endfor~}
        $null
      ) | Where-Object { $_ -ne $null }

      foreach ($s in $specs) {
        $name = $s.Name
        $hostName = $s.Host
        $bodyRendered = $registryPolicy -replace 'HOSTNAME', $hostName
        $bodyB64 = [Convert]::ToBase64String([System.Text.UTF8Encoding]::new($false).GetBytes($bodyRendered))

        $remoteBash = @"
set -euo pipefail
export VAULT_TOKEN='$rootToken'
export VAULT_SKIP_VERIFY=true
export VAULT_ADDR=https://127.0.0.1:8200
echo '$bodyB64' | base64 -d | vault policy write $name - >/dev/null
echo "[registry-policies] wrote policy $name"
"@
        $remoteB64 = [Convert]::ToBase64String([System.Text.UTF8Encoding]::new($false).GetBytes($remoteBash))
        Write-Host "[registry-policies] writing $name (policy for $hostName)"
        $output = ssh -o ConnectTimeout=15 -o BatchMode=yes -o StrictHostKeyChecking=no $user@$ip "echo '$remoteB64' | base64 -d | bash" 2>&1 | Out-String
        if ($LASTEXITCODE -ne 0) { Write-Host $output.Trim(); throw "[registry-policies] failed writing $name (rc=$LASTEXITCODE)" }
        Write-Host $output.Trim()
      }

      Write-Host "[registry-policies] all $($specs.Count) registry-node policies written"
    PWSH
  }
}
