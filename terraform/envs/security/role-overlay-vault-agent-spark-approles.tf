/*
 * role-overlay-vault-agent-spark-approles.tf -- Phase 0.L.3 setup
 *
 * One AppRole per spark-node Vault Agent (5 nodes). token_policies is the
 * like-named policy. Per-host JSON sidecar at
 *   $HOME\.nexus\vault-agent-lakehouse-spark-<hostname>.json
 * (read by nexus-infra-lakehouse's role-overlay-spark-vault-agents.tf).
 *
 * Selective ops: var.enable_spark_agent_setup AND var.enable_spark_agent_approles.
 */

resource "null_resource" "vault_agent_spark_approles" {
  count = var.enable_vault_cluster && var.enable_vault_init && var.enable_spark_agent_setup && var.enable_spark_agent_approles ? 1 : 0

  triggers = {
    policies_id      = null_resource.vault_agent_spark_policies[0].id
    creds_dir        = var.vault_agent_spark_creds_dir
    spark_approles_v = "1"
  }

  depends_on = [null_resource.vault_agent_spark_policies]

  provisioner "local-exec" {
    when        = create
    interpreter = ["pwsh", "-NoProfile", "-Command"]
    command     = <<-PWSH
      $ip               = '${local.vault_1_ip}'
      $user             = '${local.ssh_user}'
      $keysFileRaw      = '${var.vault_init_keys_file}'
      $keysFile         = $ExecutionContext.InvokeCommand.ExpandString($keysFileRaw.Replace('$HOME', $env:USERPROFILE))
      $caBundlePathRaw  = '${var.vault_pki_ca_bundle_path}'
      $caBundlePath     = $ExecutionContext.InvokeCommand.ExpandString($caBundlePathRaw.Replace('$HOME', $env:USERPROFILE))
      $credsDirRaw      = '${var.vault_agent_spark_creds_dir}'
      $credsDir         = $ExecutionContext.InvokeCommand.ExpandString($credsDirRaw.Replace('$HOME', $env:USERPROFILE))

      if (-not (Test-Path $keysFile)) { throw "[spark-approles] keys file $keysFile missing" }
      $rootToken = (Get-Content $keysFile | ConvertFrom-Json).root_token

      if (-not (Test-Path $credsDir)) {
        New-Item -ItemType Directory -Force -Path $credsDir | Out-Null
        icacls $credsDir /inheritance:r /grant:r "$($env:USERNAME):(F)" | Out-Null
      }

      $approles = @(
        @{ Name = 'nexus-agent-spark-spark-master-1'; Host = 'spark-master-1' },
        @{ Name = 'nexus-agent-spark-spark-master-2'; Host = 'spark-master-2' },
        @{ Name = 'nexus-agent-spark-spark-worker-1'; Host = 'spark-worker-1' },
        @{ Name = 'nexus-agent-spark-spark-worker-2'; Host = 'spark-worker-2' },
        @{ Name = 'nexus-agent-spark-spark-worker-3'; Host = 'spark-worker-3' }
      )

      foreach ($a in $approles) {
        $approleName = $a.Name
        $hostName    = $a.Host
        $credsFile   = Join-Path $credsDir "vault-agent-lakehouse-spark-$hostName.json"

        Write-Host "[spark-approles] provisioning AppRole $approleName for $hostName"
        $remoteBash = @"
set -euo pipefail
export VAULT_TOKEN='$rootToken'
export VAULT_SKIP_VERIFY=true
export VAULT_ADDR=https://127.0.0.1:8200
vault write auth/approle/role/$approleName \
  token_policies=$approleName \
  token_ttl=1h \
  token_max_ttl=24h \
  secret_id_ttl=0 \
  secret_id_num_uses=0 \
  bind_secret_id=true >/dev/null
ROLE_ID=`$(vault read -field=role_id auth/approle/role/$approleName/role-id)
SECRET_ID=`$(vault write -field=secret_id -f auth/approle/role/$approleName/secret-id)
echo "AGENT_ROLE_ID=`$ROLE_ID"
echo "AGENT_SECRET_ID=`$SECRET_ID"
"@
        $bashB64 = [Convert]::ToBase64String([System.Text.UTF8Encoding]::new($false).GetBytes($remoteBash))
        $output = ssh -o ConnectTimeout=15 -o BatchMode=yes -o StrictHostKeyChecking=no $user@$ip "echo '$bashB64' | base64 -d | bash" 2>&1 | Out-String
        if ($LASTEXITCODE -ne 0) { Write-Host $output.Trim(); throw "[spark-approles] $${approleName}: vault write failed (rc=$LASTEXITCODE)" }

        $roleIdMatch   = ($output -match '(?m)^AGENT_ROLE_ID=(.+)$')
        $roleId        = $matches[1].Trim()
        $secretIdMatch = ($output -match '(?m)^AGENT_SECRET_ID=(.+)$')
        $secretId      = $matches[1].Trim()
        if (-not $roleId -or -not $secretId) { throw "[spark-approles] $${approleName}: failed to parse role_id/secret_id" }

        $sidecar = [PSCustomObject]@{
          role_name      = $approleName
          host           = $hostName
          role_id        = $roleId
          secret_id      = $secretId
          ca_bundle_path = $caBundlePath
          vault_addr     = "https://${local.vault_1_ip}:8200"
          generated_at   = (Get-Date -Format 'o')
        }
        $sidecar | ConvertTo-Json -Depth 5 | Out-File -FilePath $credsFile -Encoding UTF8 -Force
        icacls $credsFile /inheritance:r /grant:r "$($env:USERNAME):(R,W)" | Out-Null
        Write-Host "[spark-approles] $${approleName}: role_id=$($roleId.Substring(0,8))..., sidecar -> $credsFile"
      }

      Write-Host "[spark-approles] all $($approles.Count) AppRoles + sidecars written"
    PWSH
  }
}
