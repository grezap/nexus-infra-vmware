/*
 * role-overlay-vault-agent-spark-policies.tf -- Phase 0.L.3 setup
 *
 * One narrow Vault policy per spark-node Vault Agent (5 nodes):
 *   nexus-agent-spark-spark-master-1 / -master-2 / -worker-1 / -worker-2 / -worker-3
 *
 * Permissions: PKI issue on pki_int/issue/<spark_role> + KV read on
 * nexus/data/lakehouse/spark/* (the spark.authenticate secret) AND
 * nexus/data/lakehouse/minio/* (the nexus-lakehouse-app S3 key for the S3A
 * warehouse) + token self. Idempotent upsert. ZooKeeper nodes get no policy
 * (no Vault footprint -- backplane-plaintext, ADR-0035).
 *
 * Selective ops: var.enable_spark_agent_setup AND var.enable_spark_agent_policies.
 */

locals {
  spark_agent_policy_specs = {
    "nexus-agent-spark-spark-master-1" = { host = "spark-master-1" }
    "nexus-agent-spark-spark-master-2" = { host = "spark-master-2" }
    "nexus-agent-spark-spark-worker-1" = { host = "spark-worker-1" }
    "nexus-agent-spark-spark-worker-2" = { host = "spark-worker-2" }
    "nexus-agent-spark-spark-worker-3" = { host = "spark-worker-3" }
  }
}

resource "null_resource" "vault_agent_spark_policies" {
  count = var.enable_vault_cluster && var.enable_vault_init && var.enable_spark_agent_setup && var.enable_spark_agent_policies ? 1 : 0

  triggers = {
    post_init_id             = null_resource.vault_post_init[0].id
    spark_role_id            = length(null_resource.vault_pki_spark_role) > 0 ? null_resource.vault_pki_spark_role[0].id : "disabled"
    spark_role_name          = var.vault_pki_spark_role_name
    spark_policies_overlay_v = "1"
  }

  depends_on = [null_resource.vault_post_init, null_resource.vault_pki_spark_role]

  provisioner "local-exec" {
    when        = create
    interpreter = ["pwsh", "-NoProfile", "-Command"]
    command     = <<-PWSH
      $ip          = '${local.vault_1_ip}'
      $user        = '${local.ssh_user}'
      $keysFileRaw = '${var.vault_init_keys_file}'
      $keysFile    = $ExecutionContext.InvokeCommand.ExpandString($keysFileRaw.Replace('$HOME', $env:USERPROFILE))

      if (-not (Test-Path $keysFile)) { throw "[spark-policies] keys file $keysFile missing" }
      $rootToken = (Get-Content $keysFile | ConvertFrom-Json).root_token

      $sparkPolicy = @"
# Phase 0.L.3 setup -- agent policy for spark nodes (HOSTNAME).
path "pki_int/issue/${var.vault_pki_spark_role_name}" {
  capabilities = ["create", "update"]
}
path "nexus/data/lakehouse/spark/*" {
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
%{for name, spec in local.spark_agent_policy_specs~}
        @{ Name = '${name}'; Host = '${spec.host}' },
%{endfor~}
        $null
      ) | Where-Object { $_ -ne $null }

      foreach ($s in $specs) {
        $name = $s.Name
        $hostName = $s.Host
        $bodyRendered = $sparkPolicy -replace 'HOSTNAME', $hostName
        $bodyB64 = [Convert]::ToBase64String([System.Text.UTF8Encoding]::new($false).GetBytes($bodyRendered))

        $remoteBash = @"
set -euo pipefail
export VAULT_TOKEN='$rootToken'
export VAULT_SKIP_VERIFY=true
export VAULT_ADDR=https://127.0.0.1:8200
echo '$bodyB64' | base64 -d | vault policy write $name - >/dev/null
echo "[spark-policies] wrote policy $name"
"@
        $remoteB64 = [Convert]::ToBase64String([System.Text.UTF8Encoding]::new($false).GetBytes($remoteBash))
        Write-Host "[spark-policies] writing $name (policy for $hostName)"
        $output = ssh -o ConnectTimeout=15 -o BatchMode=yes -o StrictHostKeyChecking=no $user@$ip "echo '$remoteB64' | base64 -d | bash" 2>&1 | Out-String
        if ($LASTEXITCODE -ne 0) { Write-Host $output.Trim(); throw "[spark-policies] failed writing $name (rc=$LASTEXITCODE)" }
        Write-Host $output.Trim()
      }

      Write-Host "[spark-policies] all $($specs.Count) spark-node policies written"
    PWSH
  }
}
