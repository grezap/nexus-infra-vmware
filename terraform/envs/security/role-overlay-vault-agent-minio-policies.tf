/*
 * role-overlay-vault-agent-minio-policies.tf -- Phase 0.L.1 setup
 *
 * One narrow Vault policy per MinIO-node Vault Agent (4 nodes):
 *   nexus-agent-minio-minio-1 / -2 / -3 / -4
 *
 * Permissions: PKI issue on pki_int/issue/<minio_role> + KV read on
 * nexus/data/lakehouse/minio/* (root + app creds for config + bucket-bootstrap)
 * + token self. Idempotent upsert.
 *
 * Selective ops: var.enable_minio_agent_setup AND var.enable_minio_agent_policies.
 */

locals {
  minio_agent_policy_specs = {
    "nexus-agent-minio-minio-1" = { host = "minio-1" }
    "nexus-agent-minio-minio-2" = { host = "minio-2" }
    "nexus-agent-minio-minio-3" = { host = "minio-3" }
    "nexus-agent-minio-minio-4" = { host = "minio-4" }
  }
}

resource "null_resource" "vault_agent_minio_policies" {
  count = var.enable_vault_cluster && var.enable_vault_init && var.enable_minio_agent_setup && var.enable_minio_agent_policies ? 1 : 0

  triggers = {
    post_init_id             = null_resource.vault_post_init[0].id
    minio_role_id            = length(null_resource.vault_pki_minio_role) > 0 ? null_resource.vault_pki_minio_role[0].id : "disabled"
    minio_role_name          = var.vault_pki_minio_role_name
    minio_policies_overlay_v = "1"
  }

  depends_on = [null_resource.vault_post_init, null_resource.vault_pki_minio_role]

  provisioner "local-exec" {
    when        = create
    interpreter = ["pwsh", "-NoProfile", "-Command"]
    command     = <<-PWSH
      $ip          = '${local.vault_1_ip}'
      $user        = '${local.ssh_user}'
      $keysFileRaw = '${var.vault_init_keys_file}'
      $keysFile    = $ExecutionContext.InvokeCommand.ExpandString($keysFileRaw.Replace('$HOME', $env:USERPROFILE))

      if (-not (Test-Path $keysFile)) { throw "[minio-policies] keys file $keysFile missing" }
      $rootToken = (Get-Content $keysFile | ConvertFrom-Json).root_token

      $minioPolicy = @"
# Phase 0.L.1 setup -- agent policy for MinIO nodes (HOSTNAME).
path "pki_int/issue/${var.vault_pki_minio_role_name}" {
  capabilities = ["create", "update"]
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
%{for name, spec in local.minio_agent_policy_specs~}
        @{ Name = '${name}'; Host = '${spec.host}' },
%{endfor~}
        $null
      ) | Where-Object { $_ -ne $null }

      foreach ($s in $specs) {
        $name = $s.Name
        $hostName = $s.Host
        $bodyRendered = $minioPolicy -replace 'HOSTNAME', $hostName
        $bodyB64 = [Convert]::ToBase64String([System.Text.UTF8Encoding]::new($false).GetBytes($bodyRendered))

        $remoteBash = @"
set -euo pipefail
export VAULT_TOKEN='$rootToken'
export VAULT_SKIP_VERIFY=true
export VAULT_ADDR=https://127.0.0.1:8200
echo '$bodyB64' | base64 -d | vault policy write $name - >/dev/null
echo "[minio-policies] wrote policy $name"
"@
        $remoteB64 = [Convert]::ToBase64String([System.Text.UTF8Encoding]::new($false).GetBytes($remoteBash))
        Write-Host "[minio-policies] writing $name (policy for $hostName)"
        $output = ssh -o ConnectTimeout=15 -o BatchMode=yes -o StrictHostKeyChecking=no $user@$ip "echo '$remoteB64' | base64 -d | bash" 2>&1 | Out-String
        if ($LASTEXITCODE -ne 0) { Write-Host $output.Trim(); throw "[minio-policies] failed writing $name (rc=$LASTEXITCODE)" }
        Write-Host $output.Trim()
      }

      Write-Host "[minio-policies] all $($specs.Count) MinIO-node policies written"
    PWSH
  }
}
