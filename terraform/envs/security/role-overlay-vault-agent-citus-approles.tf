/*
 * role-overlay-vault-agent-citus-approles.tf -- Phase 0.P setup
 *
 * One AppRole per Citus-tier node Vault Agent (9 total), mirroring the 0.O
 * vitess + 0.G.4 patroni AppRole shape. Each AppRole's token_policies is the
 * like-named policy from role-overlay-vault-agent-citus-policies.tf:
 *
 *   nexus-agent-citus-etcd-{1,2,3}
 *   nexus-agent-citus-coord-{1,2}
 *   nexus-agent-citus-worker1-{1,2}
 *   nexus-agent-citus-worker2-{1,2}
 *
 * AppRole shape (matches every prior tier): token_policies=[<policy>],
 * token_ttl=1h, token_max_ttl=24h, secret_id_ttl=0, secret_id_num_uses=0,
 * bind_secret_id=true.
 *
 * Per-host JSON sidecar on the build host at:
 *   $HOME\.nexus\vault-agent-citus-<hostname>.json
 * nexus-infra-citus's role-overlay-citus-vault-agents.tf reads each sidecar +
 * scp's role-id / secret-id onto the corresponding VM. role-id is stable;
 * secret-id is regenerated each apply.
 *
 * Selective ops: var.enable_citus_agent_setup AND var.enable_citus_agent_approles.
 */

resource "null_resource" "vault_agent_citus_approles" {
  count = var.enable_vault_cluster && var.enable_vault_init && var.enable_citus_agent_setup && var.enable_citus_agent_approles ? 1 : 0

  triggers = {
    policies_id      = null_resource.vault_agent_citus_policies[0].id
    creds_dir        = var.vault_agent_citus_creds_dir
    citus_approles_v = "1" # v1 (0.P) = 9 nodes (3 etcd + coord pair + 2 worker pairs). Sidecar prefix `vault-agent-citus-`.
  }

  depends_on = [null_resource.vault_agent_citus_policies]

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
      $credsDirRaw      = '${var.vault_agent_citus_creds_dir}'
      $credsDir         = $ExecutionContext.InvokeCommand.ExpandString($credsDirRaw.Replace('$HOME', $env:USERPROFILE))

      if (-not (Test-Path $keysFile)) { throw "[citus-approles] keys file $keysFile missing" }
      $rootToken = (Get-Content $keysFile | ConvertFrom-Json).root_token

      if (-not (Test-Path $credsDir)) {
        New-Item -ItemType Directory -Force -Path $credsDir | Out-Null
        icacls $credsDir /inheritance:r /grant:r "$($env:USERNAME):(F)" | Out-Null
      }

      $approles = @(
        @{ Name = 'nexus-agent-citus-etcd-1';    Host = 'citus-etcd-1' },
        @{ Name = 'nexus-agent-citus-etcd-2';    Host = 'citus-etcd-2' },
        @{ Name = 'nexus-agent-citus-etcd-3';    Host = 'citus-etcd-3' },
        @{ Name = 'nexus-agent-citus-coord-1';   Host = 'citus-coord-1' },
        @{ Name = 'nexus-agent-citus-coord-2';   Host = 'citus-coord-2' },
        @{ Name = 'nexus-agent-citus-worker1-1'; Host = 'citus-worker1-1' },
        @{ Name = 'nexus-agent-citus-worker1-2'; Host = 'citus-worker1-2' },
        @{ Name = 'nexus-agent-citus-worker2-1'; Host = 'citus-worker2-1' },
        @{ Name = 'nexus-agent-citus-worker2-2'; Host = 'citus-worker2-2' }
      )

      foreach ($a in $approles) {
        $approleName = $a.Name
        $hostName    = $a.Host
        $credsFile   = Join-Path $credsDir "vault-agent-citus-$hostName.json"

        Write-Host "[citus-approles] provisioning AppRole $approleName for $hostName"

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
          throw "[citus-approles] $${approleName}: vault write failed (rc=$LASTEXITCODE)"
        }

        $roleIdMatch   = ($output -match '(?m)^AGENT_ROLE_ID=(.+)$')
        $roleId        = $matches[1].Trim()
        $secretIdMatch = ($output -match '(?m)^AGENT_SECRET_ID=(.+)$')
        $secretId      = $matches[1].Trim()

        if (-not $roleId -or -not $secretId) {
          throw "[citus-approles] $${approleName}: failed to parse role_id/secret_id from output"
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

        Write-Host "[citus-approles] $${approleName}: role_id=$($roleId.Substring(0,8))..., secret_id captured, sidecar -> $credsFile"
      }

      Write-Host "[citus-approles] all $($approles.Count) AppRoles + sidecars written"
    PWSH
  }
}
