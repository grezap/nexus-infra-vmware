/*
 * role-overlay-vault-agent-redis-approles.tf -- Phase 0.G.1 setup
 *
 * One AppRole per redis-node Vault Agent. Mirrors the 0.H.2
 * `nexus-agent-kafka-*` AppRole shape, scaled to the 6-node Redis Cluster:
 *
 *   nexus-agent-redis-1  -- master shard 1
 *   nexus-agent-redis-2  -- master shard 2
 *   nexus-agent-redis-3  -- master shard 3
 *   nexus-agent-redis-4  -- replica of shard 1
 *   nexus-agent-redis-5  -- replica of shard 2
 *   nexus-agent-redis-6  -- replica of shard 3
 *
 * Each AppRole's token_policies is the like-named policy from
 * role-overlay-vault-agent-redis-policies.tf.
 *
 * AppRole shape (matches 0.E.2 / 0.H.2):
 *   - token_policies = [<policy>]
 *   - token_ttl = 1h, token_max_ttl = 24h    (Agent renews mid-life)
 *   - secret_id_ttl = 0                       (lab convention)
 *   - secret_id_num_uses = 0                  (unlimited)
 *   - bind_secret_id = true
 *
 * Per-host JSON sidecar on the build host at:
 *   $HOME\.nexus\vault-agent-oltp-redis-<hostname>.json
 *
 * The `oltp-redis-` prefix (vs swarm/kafka's bare `vault-agent-<host>.json`)
 * namespaces the sidecars per tier+cluster so future 0.G.* clusters
 * (mongo / percona / postgres) get their own `vault-agent-oltp-<svc>-<host>`
 * sidecar family without colliding on a shared $HOME/.nexus directory.
 *
 * nexus-infra-oltp's role-overlay-redis-vault-agents.tf reads each sidecar
 * + scp's role-id / secret-id text files onto the corresponding VM. role-id
 * is stable across applies; secret-id is regenerated each apply (the
 * oltp-side overlay always reads the freshest sidecar).
 *
 * Selective ops: var.enable_redis_agent_setup (master) AND
 *                var.enable_redis_agent_approles.
 */

resource "null_resource" "vault_agent_redis_approles" {
  count = var.enable_vault_cluster && var.enable_vault_init && var.enable_redis_agent_setup && var.enable_redis_agent_approles ? 1 : 0

  triggers = {
    policies_id      = null_resource.vault_agent_redis_policies[0].id
    creds_dir        = var.vault_agent_redis_creds_dir
    redis_approles_v = "1" # v1 (0.G.1) = initial 6-node Redis Cluster; per-host sidecars use $hostName (NOT $host -- PowerShell automatic-var collision, per memory/feedback_powershell_automatic_variables.md). Sidecar prefix `vault-agent-oltp-redis-` namespaces per tier+cluster (vs kafka/swarm's bare `vault-agent-`) so future oltp clusters share $HOME/.nexus without collisions.
  }

  depends_on = [null_resource.vault_agent_redis_policies]

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
      $credsDirRaw      = '${var.vault_agent_redis_creds_dir}'
      $credsDir         = $ExecutionContext.InvokeCommand.ExpandString($credsDirRaw.Replace('$HOME', $env:USERPROFILE))

      if (-not (Test-Path $keysFile)) { throw "[redis-approles] keys file $keysFile missing" }
      $rootToken = (Get-Content $keysFile | ConvertFrom-Json).root_token

      if (-not (Test-Path $credsDir)) {
        New-Item -ItemType Directory -Force -Path $credsDir | Out-Null
        # Lock down: owner-only access (matches the 0.E.2 / 0.H.2 pattern).
        icacls $credsDir /inheritance:r /grant:r "$($env:USERNAME):(F)" | Out-Null
      }

      $approles = @(
        @{ Name = 'nexus-agent-redis-1'; Host = 'redis-1' },
        @{ Name = 'nexus-agent-redis-2'; Host = 'redis-2' },
        @{ Name = 'nexus-agent-redis-3'; Host = 'redis-3' },
        @{ Name = 'nexus-agent-redis-4'; Host = 'redis-4' },
        @{ Name = 'nexus-agent-redis-5'; Host = 'redis-5' },
        @{ Name = 'nexus-agent-redis-6'; Host = 'redis-6' }
      )

      foreach ($a in $approles) {
        $approleName = $a.Name
        $hostName    = $a.Host
        $credsFile   = Join-Path $credsDir "vault-agent-oltp-redis-$hostName.json"

        Write-Host "[redis-approles] provisioning AppRole $approleName for $hostName"

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
          throw "[redis-approles] $${approleName}: vault write failed (rc=$LASTEXITCODE)"
        }

        # Parse role_id + secret_id from output via marker lines (per
        # memory/feedback_smoke_gate_probe_robustness.md -- marker tokens +
        # -match, NOT strict equality, since sudo+ssh stderr can pollute).
        $roleIdMatch   = ($output -match '(?m)^AGENT_ROLE_ID=(.+)$')
        $roleId        = $matches[1].Trim()
        $secretIdMatch = ($output -match '(?m)^AGENT_SECRET_ID=(.+)$')
        $secretId      = $matches[1].Trim()

        if (-not $roleId -or -not $secretId) {
          throw "[redis-approles] $${approleName}: failed to parse role_id/secret_id from output"
        }

        # Build JSON sidecar (matches the 0.E.2 / 0.H.2 shape so the oltp-side
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

        Write-Host "[redis-approles] $${approleName}: role_id=$($roleId.Substring(0,8))..., secret_id captured, sidecar -> $credsFile"
      }

      Write-Host "[redis-approles] all $($approles.Count) AppRoles + sidecars written"
    PWSH
  }
}
