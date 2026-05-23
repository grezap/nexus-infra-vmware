/*
 * role-overlay-vault-agent-iceberg-policies.tf -- Phase 0.L.2 setup
 *
 * One narrow Vault policy per iceberg-node Vault Agent (4 nodes):
 *   nexus-agent-iceberg-iceberg-rest-1 / -rest-2 / -pg-1 / -pg-2
 *
 * Permissions: PKI issue on pki_int/issue/<iceberg_role> + KV read on
 * nexus/data/lakehouse/iceberg/* (PG + nessie-db creds) AND
 * nexus/data/lakehouse/minio/* (the Nessie REST nodes need the nexus-lakehouse-app
 * S3 key for the warehouse) + token self. Idempotent upsert.
 *
 * Selective ops: var.enable_iceberg_agent_setup AND var.enable_iceberg_agent_policies.
 */

locals {
  iceberg_agent_policy_specs = {
    "nexus-agent-iceberg-iceberg-rest-1" = { host = "iceberg-rest-1" }
    "nexus-agent-iceberg-iceberg-rest-2" = { host = "iceberg-rest-2" }
    "nexus-agent-iceberg-iceberg-pg-1"   = { host = "iceberg-pg-1" }
    "nexus-agent-iceberg-iceberg-pg-2"   = { host = "iceberg-pg-2" }
  }
}

resource "null_resource" "vault_agent_iceberg_policies" {
  count = var.enable_vault_cluster && var.enable_vault_init && var.enable_iceberg_agent_setup && var.enable_iceberg_agent_policies ? 1 : 0

  triggers = {
    post_init_id               = null_resource.vault_post_init[0].id
    iceberg_role_id            = length(null_resource.vault_pki_iceberg_role) > 0 ? null_resource.vault_pki_iceberg_role[0].id : "disabled"
    iceberg_role_name          = var.vault_pki_iceberg_role_name
    iceberg_policies_overlay_v = "1"
  }

  depends_on = [null_resource.vault_post_init, null_resource.vault_pki_iceberg_role]

  provisioner "local-exec" {
    when        = create
    interpreter = ["pwsh", "-NoProfile", "-Command"]
    command     = <<-PWSH
      $ip          = '${local.vault_1_ip}'
      $user        = '${local.ssh_user}'
      $keysFileRaw = '${var.vault_init_keys_file}'
      $keysFile    = $ExecutionContext.InvokeCommand.ExpandString($keysFileRaw.Replace('$HOME', $env:USERPROFILE))

      if (-not (Test-Path $keysFile)) { throw "[iceberg-policies] keys file $keysFile missing" }
      $rootToken = (Get-Content $keysFile | ConvertFrom-Json).root_token

      $icebergPolicy = @"
# Phase 0.L.2 setup -- agent policy for iceberg nodes (HOSTNAME).
path "pki_int/issue/${var.vault_pki_iceberg_role_name}" {
  capabilities = ["create", "update"]
}
path "nexus/data/lakehouse/iceberg/*" {
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
%{for name, spec in local.iceberg_agent_policy_specs~}
        @{ Name = '${name}'; Host = '${spec.host}' },
%{endfor~}
        $null
      ) | Where-Object { $_ -ne $null }

      foreach ($s in $specs) {
        $name = $s.Name
        $hostName = $s.Host
        $bodyRendered = $icebergPolicy -replace 'HOSTNAME', $hostName
        $bodyB64 = [Convert]::ToBase64String([System.Text.UTF8Encoding]::new($false).GetBytes($bodyRendered))

        $remoteBash = @"
set -euo pipefail
export VAULT_TOKEN='$rootToken'
export VAULT_SKIP_VERIFY=true
export VAULT_ADDR=https://127.0.0.1:8200
echo '$bodyB64' | base64 -d | vault policy write $name - >/dev/null
echo "[iceberg-policies] wrote policy $name"
"@
        $remoteB64 = [Convert]::ToBase64String([System.Text.UTF8Encoding]::new($false).GetBytes($remoteBash))
        Write-Host "[iceberg-policies] writing $name (policy for $hostName)"
        $output = ssh -o ConnectTimeout=15 -o BatchMode=yes -o StrictHostKeyChecking=no $user@$ip "echo '$remoteB64' | base64 -d | bash" 2>&1 | Out-String
        if ($LASTEXITCODE -ne 0) { Write-Host $output.Trim(); throw "[iceberg-policies] failed writing $name (rc=$LASTEXITCODE)" }
        Write-Host $output.Trim()
      }

      Write-Host "[iceberg-policies] all $($specs.Count) iceberg-node policies written"
    PWSH
  }
}
