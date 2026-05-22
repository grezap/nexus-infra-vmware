/*
 * role-overlay-vault-agent-clickhouse-approles.tf -- Phase 0.G.5 setup
 *
 * One AppRole per ClickHouse-node Vault Agent (9 nodes). Mirrors the redis
 * AppRole shape. Each AppRole's token_policies is the like-named policy from
 * role-overlay-vault-agent-clickhouse-policies.tf:
 *
 *   nexus-agent-clickhouse-ch-keeper-1/2/3
 *   nexus-agent-clickhouse-ch-shard{1,2,3}-rep{1,2}
 *
 * AppRole shape: token_ttl 1h / token_max_ttl 24h (Agent renews mid-life),
 * secret_id_ttl 0, secret_id_num_uses 0, bind_secret_id true.
 *
 * Per-host JSON sidecar on the build host at:
 *   $HOME\.nexus\vault-agent-analytics-clickhouse-<hostname>.json
 *
 * The `analytics-clickhouse-` prefix namespaces the sidecars per tier+cluster
 * (the analytics analogue of oltp's `vault-agent-oltp-redis-` prefix), so the
 * sibling StarRocks cluster (0.G.6) gets its own sidecar family without
 * colliding on $HOME/.nexus. nexus-infra-analytics's role-overlay-clickhouse-
 * vault-agents.tf reads each sidecar.
 *
 * Selective ops: var.enable_clickhouse_agent_setup AND
 *                var.enable_clickhouse_agent_approles.
 */

resource "null_resource" "vault_agent_clickhouse_approles" {
  count = var.enable_vault_cluster && var.enable_vault_init && var.enable_clickhouse_agent_setup && var.enable_clickhouse_agent_approles ? 1 : 0

  triggers = {
    policies_id           = null_resource.vault_agent_clickhouse_policies[0].id
    creds_dir             = var.vault_agent_clickhouse_creds_dir
    clickhouse_approles_v = "1" # v1 (0.G.5) = initial 9-node ClickHouse cluster; sidecars use $hostName (PowerShell automatic-var collision avoidance) + prefix vault-agent-analytics-clickhouse-.
  }

  depends_on = [null_resource.vault_agent_clickhouse_policies]

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
      $credsDirRaw      = '${var.vault_agent_clickhouse_creds_dir}'
      $credsDir         = $ExecutionContext.InvokeCommand.ExpandString($credsDirRaw.Replace('$HOME', $env:USERPROFILE))

      if (-not (Test-Path $keysFile)) { throw "[clickhouse-approles] keys file $keysFile missing" }
      $rootToken = (Get-Content $keysFile | ConvertFrom-Json).root_token

      if (-not (Test-Path $credsDir)) {
        New-Item -ItemType Directory -Force -Path $credsDir | Out-Null
        icacls $credsDir /inheritance:r /grant:r "$($env:USERNAME):(F)" | Out-Null
      }

      $approles = @(
        @{ Name = 'nexus-agent-clickhouse-ch-keeper-1';    Host = 'ch-keeper-1' },
        @{ Name = 'nexus-agent-clickhouse-ch-keeper-2';    Host = 'ch-keeper-2' },
        @{ Name = 'nexus-agent-clickhouse-ch-keeper-3';    Host = 'ch-keeper-3' },
        @{ Name = 'nexus-agent-clickhouse-ch-shard1-rep1'; Host = 'ch-shard1-rep1' },
        @{ Name = 'nexus-agent-clickhouse-ch-shard1-rep2'; Host = 'ch-shard1-rep2' },
        @{ Name = 'nexus-agent-clickhouse-ch-shard2-rep1'; Host = 'ch-shard2-rep1' },
        @{ Name = 'nexus-agent-clickhouse-ch-shard2-rep2'; Host = 'ch-shard2-rep2' },
        @{ Name = 'nexus-agent-clickhouse-ch-shard3-rep1'; Host = 'ch-shard3-rep1' },
        @{ Name = 'nexus-agent-clickhouse-ch-shard3-rep2'; Host = 'ch-shard3-rep2' }
      )

      foreach ($a in $approles) {
        $approleName = $a.Name
        $hostName    = $a.Host
        $credsFile   = Join-Path $credsDir "vault-agent-analytics-clickhouse-$hostName.json"

        Write-Host "[clickhouse-approles] provisioning AppRole $approleName for $hostName"

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

        $bashBytes = [System.Text.UTF8Encoding]::new($false).GetBytes($remoteBash)
        $bashB64   = [Convert]::ToBase64String($bashBytes)

        $output = ssh -o ConnectTimeout=15 -o BatchMode=yes -o StrictHostKeyChecking=no $user@$ip "echo '$bashB64' | base64 -d | bash" 2>&1 | Out-String
        if ($LASTEXITCODE -ne 0) {
          Write-Host $output.Trim()
          throw "[clickhouse-approles] $${approleName}: vault write failed (rc=$LASTEXITCODE)"
        }

        $roleIdMatch   = ($output -match '(?m)^AGENT_ROLE_ID=(.+)$')
        $roleId        = $matches[1].Trim()
        $secretIdMatch = ($output -match '(?m)^AGENT_SECRET_ID=(.+)$')
        $secretId      = $matches[1].Trim()

        if (-not $roleId -or -not $secretId) {
          throw "[clickhouse-approles] $${approleName}: failed to parse role_id/secret_id from output"
        }

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

        Write-Host "[clickhouse-approles] $${approleName}: role_id=$($roleId.Substring(0,8))..., secret_id captured, sidecar -> $credsFile"
      }

      Write-Host "[clickhouse-approles] all $($approles.Count) AppRoles + sidecars written"
    PWSH
  }
}
