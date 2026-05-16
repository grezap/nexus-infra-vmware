/*
 * role-overlay-vault-agent-mongo-approles.tf -- Phase 0.G.2 setup
 *
 * One AppRole per mongo-node Vault Agent. Mirrors the 0.G.1
 * `nexus-agent-redis-*` AppRole shape, scaled to the 3-node MongoDB
 * Replica Set:
 *
 *   nexus-agent-mongo-1  -- initial PRIMARY at rs.initiate (rs re-elects)
 *   nexus-agent-mongo-2  -- RS member 1
 *   nexus-agent-mongo-3  -- RS member 2
 *
 * Each AppRole's token_policies is the like-named policy from
 * role-overlay-vault-agent-mongo-policies.tf.
 *
 * AppRole shape (matches 0.E.2 / 0.H.2 / 0.G.1):
 *   - token_policies = [<policy>]
 *   - token_ttl = 1h, token_max_ttl = 24h    (Agent renews mid-life)
 *   - secret_id_ttl = 0                       (lab convention)
 *   - secret_id_num_uses = 0                  (unlimited)
 *   - bind_secret_id = true
 *
 * Per-host JSON sidecar on the build host at:
 *   $HOME\.nexus\vault-agent-oltp-mongo-<hostname>.json
 *
 * The `oltp-mongo-` prefix (vs swarm/kafka's bare `vault-agent-<host>.json`)
 * namespaces sidecars per tier+cluster -- same pattern as 0.G.1's
 * `oltp-redis-` prefix. Sidecar filename literal-expands to
 * `vault-agent-oltp-mongo-mongo-N.json` (the `mongo-` repetition matches
 * how 0.G.1's `vault-agent-oltp-redis-redis-N.json` reads).
 *
 * nexus-infra-oltp's role-overlay-mongo-vault-agents.tf reads each
 * sidecar + scp's role-id / secret-id text files onto the corresponding
 * VM. role-id is stable across applies; secret-id is regenerated each
 * apply (the oltp-side overlay always reads the freshest sidecar).
 *
 * Selective ops: var.enable_mongo_agent_setup (master) AND
 *                var.enable_mongo_agent_approles.
 */

resource "null_resource" "vault_agent_mongo_approles" {
  count = var.enable_vault_cluster && var.enable_vault_init && var.enable_mongo_agent_setup && var.enable_mongo_agent_approles ? 1 : 0

  triggers = {
    policies_id      = null_resource.vault_agent_mongo_policies[0].id
    creds_dir        = var.vault_agent_mongo_creds_dir
    mongo_approles_v = "1" # v1 (0.G.2) = initial 3-node MongoDB RS. Sidecar prefix `vault-agent-oltp-mongo-` (vs redis's `vault-agent-oltp-redis-`) namespaces per tier+cluster.
  }

  depends_on = [null_resource.vault_agent_mongo_policies]

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
      $credsDirRaw      = '${var.vault_agent_mongo_creds_dir}'
      $credsDir         = $ExecutionContext.InvokeCommand.ExpandString($credsDirRaw.Replace('$HOME', $env:USERPROFILE))

      if (-not (Test-Path $keysFile)) { throw "[mongo-approles] keys file $keysFile missing" }
      $rootToken = (Get-Content $keysFile | ConvertFrom-Json).root_token

      if (-not (Test-Path $credsDir)) {
        New-Item -ItemType Directory -Force -Path $credsDir | Out-Null
        icacls $credsDir /inheritance:r /grant:r "$($env:USERNAME):(F)" | Out-Null
      }

      $approles = @(
        @{ Name = 'nexus-agent-mongo-1'; Host = 'mongo-1' },
        @{ Name = 'nexus-agent-mongo-2'; Host = 'mongo-2' },
        @{ Name = 'nexus-agent-mongo-3'; Host = 'mongo-3' }
      )

      foreach ($a in $approles) {
        $approleName = $a.Name
        $hostName    = $a.Host
        $credsFile   = Join-Path $credsDir "vault-agent-oltp-mongo-$hostName.json"

        Write-Host "[mongo-approles] provisioning AppRole $approleName for $hostName"

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
          throw "[mongo-approles] $${approleName}: vault write failed (rc=$LASTEXITCODE)"
        }

        # Marker-line parsing per feedback_smoke_gate_probe_robustness.md.
        $roleIdMatch   = ($output -match '(?m)^AGENT_ROLE_ID=(.+)$')
        $roleId        = $matches[1].Trim()
        $secretIdMatch = ($output -match '(?m)^AGENT_SECRET_ID=(.+)$')
        $secretId      = $matches[1].Trim()

        if (-not $roleId -or -not $secretId) {
          throw "[mongo-approles] $${approleName}: failed to parse role_id/secret_id from output"
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

        Write-Host "[mongo-approles] $${approleName}: role_id=$($roleId.Substring(0,8))..., secret_id captured, sidecar -> $credsFile"
      }

      Write-Host "[mongo-approles] all $($approles.Count) AppRoles + sidecars written"
    PWSH
  }
}
