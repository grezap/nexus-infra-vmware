/*
 * role-overlay-vault-agent-swarm-approles.tf -- Phase 0.E.2 setup
 *
 * Six AppRoles -- one per swarm-node Vault Agent. Mirrors 0.D.5.4's
 * dc-nexus / nexus-jumpbox AppRole shape, scaled to the orchestration
 * tier:
 *
 *   nexus-agent-swarm-manager-{1,2,3} -> nexus-agent-swarm-manager-{1,2,3} policy
 *   nexus-agent-swarm-worker-{1,2,3}  -> nexus-agent-swarm-worker-{1,2,3} policy
 *
 * AppRole shape (matches 0.D.5.4):
 *   - token_policies = [<policy>]
 *   - token_ttl = 1h, token_max_ttl = 24h    (Agent renews mid-life)
 *   - secret_id_ttl = 0                       (lab convention; production
 *                                              would use 24h with rotation)
 *   - secret_id_num_uses = 0                  (unlimited)
 *   - bind_secret_id = true
 *
 * Per-host JSON sidecar on the build host at:
 *   $HOME\.nexus\vault-agent-swarm-{manager,worker}-{1,2,3}.json
 *
 * The swarm-nomad env's role-overlay-swarm-vault-agents.tf reads each
 * sidecar + scp's role-id / secret-id text files onto the corresponding
 * VM. role-id is stable across applies; secret-id is regenerated each
 * apply (the swarm-nomad-side overlay always reads the freshest sidecar).
 *
 * Selective ops: var.enable_swarm_agent_setup (master) AND
 *                var.enable_swarm_agent_approles.
 */

resource "null_resource" "vault_agent_swarm_approles" {
  count = var.enable_vault_cluster && var.enable_vault_init && var.enable_swarm_agent_setup && var.enable_swarm_agent_approles ? 1 : 0

  triggers = {
    policies_id      = null_resource.vault_agent_swarm_policies[0].id
    creds_dir        = var.vault_agent_swarm_creds_dir
    swarm_approles_v = "2" # v2 = $host renamed to $hostName (PowerShell automatic-var collision; v1 wrote 6 sidecars with garbage filename `vault-agent-System.Management.Automation.Internal.Host.InternalHost.json`, all overwriting the same path). v1 = original.
  }

  depends_on = [null_resource.vault_agent_swarm_policies]

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
      $credsDirRaw      = '${var.vault_agent_swarm_creds_dir}'
      $credsDir         = $ExecutionContext.InvokeCommand.ExpandString($credsDirRaw.Replace('$HOME', $env:USERPROFILE))

      if (-not (Test-Path $keysFile)) { throw "[swarm-approles] keys file $keysFile missing" }
      $rootToken = (Get-Content $keysFile | ConvertFrom-Json).root_token

      if (-not (Test-Path $credsDir)) {
        New-Item -ItemType Directory -Force -Path $credsDir | Out-Null
        # Lock down: owner-only access (matches 0.D.4 / 0.D.5.4 pattern).
        icacls $credsDir /inheritance:r /grant:r "$($env:USERNAME):(F)" | Out-Null
      }

      $approles = @(
        @{ Name = 'nexus-agent-swarm-manager-1'; Host = 'swarm-manager-1' },
        @{ Name = 'nexus-agent-swarm-manager-2'; Host = 'swarm-manager-2' },
        @{ Name = 'nexus-agent-swarm-manager-3'; Host = 'swarm-manager-3' },
        @{ Name = 'nexus-agent-swarm-worker-1';  Host = 'swarm-worker-1' },
        @{ Name = 'nexus-agent-swarm-worker-2';  Host = 'swarm-worker-2' },
        @{ Name = 'nexus-agent-swarm-worker-3';  Host = 'swarm-worker-3' }
      )

      foreach ($a in $approles) {
        $approleName = $a.Name
        $hostName        = $a.Host
        $credsFile   = Join-Path $credsDir "vault-agent-$hostName.json"

        Write-Host "[swarm-approles] provisioning AppRole $approleName for $hostName"

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
          throw "[swarm-approles] $${approleName}: vault write failed (rc=$LASTEXITCODE)"
        }

        # Parse role_id + secret_id from output via marker lines (per
        # memory feedback_smoke_gate_probe_robustness.md -- marker tokens +
        # -match, NOT strict equality, since sudo+ssh stderr can pollute).
        $roleIdMatch   = ($output -match '(?m)^AGENT_ROLE_ID=(.+)$')
        $roleId        = $matches[1].Trim()
        $secretIdMatch = ($output -match '(?m)^AGENT_SECRET_ID=(.+)$')
        $secretId      = $matches[1].Trim()

        if (-not $roleId -or -not $secretId) {
          throw "[swarm-approles] $${approleName}: failed to parse role_id/secret_id from output"
        }

        # Build JSON sidecar (matches 0.D.5.4 shape so the swarm-nomad-side
        # consumer can use the same parsing logic).
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
        # Owner-only ACL on the file
        icacls $credsFile /inheritance:r /grant:r "$($env:USERNAME):(R,W)" | Out-Null

        Write-Host "[swarm-approles] $${approleName}: role_id=$($roleId.Substring(0,8))..., secret_id captured, sidecar -> $credsFile"
      }

      Write-Host "[swarm-approles] all 6 AppRoles + sidecars written"
    PWSH
  }
}
