/*
 * role-overlay-vault-agent-sqlserver-approles.tf -- Phase 0.G.7 setup
 *
 * One AppRole per SQL Server node Vault Agent. Mirrors the 0.G.4
 * `nexus-agent-pg-*`/`nexus-agent-etcd-*`/`nexus-agent-haproxy-pg-*` AppRole
 * shape, scaled to the 4-node SQL Server FCI + AG stack:
 *
 *   nexus-agent-sql-fci-1     -- FCI node 1
 *   nexus-agent-sql-fci-2     -- FCI node 2
 *   nexus-agent-sql-ag-rep-1  -- AG async replica 1
 *   nexus-agent-sql-ag-rep-2  -- AG async replica 2
 *
 * Each AppRole's token_policies is the like-named policy from
 * role-overlay-vault-agent-sqlserver-policies.tf.
 *
 * AppRole shape (matches every 0.G.* + 0.E.* + 0.H.* pattern):
 *   - token_policies = [<policy>]
 *   - token_ttl = 1h, token_max_ttl = 24h    (Agent renews mid-life)
 *   - secret_id_ttl = 0                       (lab convention)
 *   - secret_id_num_uses = 0                  (unlimited)
 *   - bind_secret_id = true
 *
 * Per-host JSON sidecar on the build host at:
 *   $HOME\.nexus\vault-agent-oltp-sqlserver-<hostname>.json
 *
 * The `oltp-sqlserver-` prefix namespaces sidecars per tier+cluster (mirrors
 * the 0.G.4 `oltp-patroni-` prefix). Sidecar filenames literal-expand to:
 *   vault-agent-oltp-sqlserver-sql-fci-1.json
 *   vault-agent-oltp-sqlserver-sql-fci-2.json
 *   vault-agent-oltp-sqlserver-sql-ag-rep-1.json
 *   vault-agent-oltp-sqlserver-sql-ag-rep-2.json
 * -- 4 files total in $HOME/.nexus.
 *
 * nexus-infra-oltp's role-overlay-sqlserver-vault-agents.tf (stage 5 of
 * 0.G.7) reads each sidecar + uses `New-Service` to install the Windows-
 * native nexus-vault-agent service on each SQL node (mirrors the foundation
 * env's role-overlay-windows-vault-agent.tf pattern for dc-nexus + jumpbox).
 * role-id is stable across applies; secret-id is regenerated each apply.
 *
 * Selective ops: var.enable_sqlserver_agent_setup (master) AND
 *                var.enable_sqlserver_agent_approles.
 */

resource "null_resource" "vault_agent_sqlserver_approles" {
  count = var.enable_vault_cluster && var.enable_vault_init && var.enable_sqlserver_agent_setup && var.enable_sqlserver_agent_approles ? 1 : 0

  triggers = {
    policies_id          = null_resource.vault_agent_sqlserver_policies[0].id
    creds_dir            = var.vault_agent_sqlserver_creds_dir
    sqlserver_approles_v = "1" # v1 (0.G.7) = initial 4 nodes (2 FCI + 2 AG-replica). Sidecar prefix `vault-agent-oltp-sqlserver-` namespaces per tier+cluster.
  }

  depends_on = [null_resource.vault_agent_sqlserver_policies]

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
      $credsDirRaw      = '${var.vault_agent_sqlserver_creds_dir}'
      $credsDir         = $ExecutionContext.InvokeCommand.ExpandString($credsDirRaw.Replace('$HOME', $env:USERPROFILE))

      if (-not (Test-Path $keysFile)) { throw "[sqlserver-approles] keys file $keysFile missing" }
      $rootToken = (Get-Content $keysFile | ConvertFrom-Json).root_token

      if (-not (Test-Path $credsDir)) {
        New-Item -ItemType Directory -Force -Path $credsDir | Out-Null
        icacls $credsDir /inheritance:r /grant:r "$($env:USERNAME):(F)" | Out-Null
      }

      $approles = @(
        @{ Name = 'nexus-agent-sql-fci-1';    Host = 'sql-fci-1' },
        @{ Name = 'nexus-agent-sql-fci-2';    Host = 'sql-fci-2' },
        @{ Name = 'nexus-agent-sql-ag-rep-1'; Host = 'sql-ag-rep-1' },
        @{ Name = 'nexus-agent-sql-ag-rep-2'; Host = 'sql-ag-rep-2' }
      )

      foreach ($a in $approles) {
        $approleName = $a.Name
        $hostName    = $a.Host
        $credsFile   = Join-Path $credsDir "vault-agent-oltp-sqlserver-$hostName.json"

        Write-Host "[sqlserver-approles] provisioning AppRole $approleName for $hostName"

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
          throw "[sqlserver-approles] $${approleName}: vault write failed (rc=$LASTEXITCODE)"
        }

        # Marker-line parsing per feedback_smoke_gate_probe_robustness.md.
        $roleIdMatch   = ($output -match '(?m)^AGENT_ROLE_ID=(.+)$')
        $roleId        = $matches[1].Trim()
        $secretIdMatch = ($output -match '(?m)^AGENT_SECRET_ID=(.+)$')
        $secretId      = $matches[1].Trim()

        if (-not $roleId -or -not $secretId) {
          throw "[sqlserver-approles] $${approleName}: failed to parse role_id/secret_id from output"
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

        Write-Host "[sqlserver-approles] $${approleName}: role_id=$($roleId.Substring(0,8))..., secret_id captured, sidecar -> $credsFile"
      }

      Write-Host "[sqlserver-approles] all $($approles.Count) AppRoles + sidecars written"
    PWSH
  }
}
