/*
 * role-overlay-vault-agent-kafka-approles.tf -- Phase 0.H.2 setup
 *   (extended in 0.H.3: +3 ecosystem AppRoles)
 *
 * One AppRole per kafka-node Vault Agent. Mirrors the 0.E.2
 * `nexus-agent-swarm-*` AppRole shape, scaled to the Kafka tier:
 *
 *   nexus-agent-kafka-{east,west}-{1,2,3}  -- the 6 KRaft brokers (0.H.2)
 *   nexus-agent-schema-registry-{1,2}      -- 0.H.3
 *   nexus-agent-kafka-rest-1               -- 0.H.3
 *   nexus-agent-kafka-connect-{1,2}        -- 0.H.4
 *   nexus-agent-ksqldb-{1,2}               -- 0.H.4
 *   (mm2 joins in 0.H.5)
 *
 * Each AppRole's token_policies is the like-named policy from
 * role-overlay-vault-agent-kafka-policies.tf.
 *
 * AppRole shape (matches 0.E.2):
 *   - token_policies = [<policy>]
 *   - token_ttl = 1h, token_max_ttl = 24h    (Agent renews mid-life)
 *   - secret_id_ttl = 0                       (lab convention)
 *   - secret_id_num_uses = 0                  (unlimited)
 *   - bind_secret_id = true
 *
 * Per-host JSON sidecar on the build host at:
 *   $HOME\.nexus\vault-agent-<hostname>.json
 *
 * nexus-infra-kafka's role-overlay-kafka-vault-agents.tf reads each sidecar
 * + scp's role-id / secret-id text files onto the corresponding VM. role-id
 * is stable across applies; secret-id is regenerated each apply (the
 * kafka-side overlay always reads the freshest sidecar).
 *
 * Selective ops: var.enable_kafka_agent_setup (master) AND
 *                var.enable_kafka_agent_approles.
 */

resource "null_resource" "vault_agent_kafka_approles" {
  count = var.enable_vault_cluster && var.enable_vault_init && var.enable_kafka_agent_setup && var.enable_kafka_agent_approles ? 1 : 0

  triggers = {
    policies_id      = null_resource.vault_agent_kafka_policies[0].id
    creds_dir        = var.vault_agent_kafka_creds_dir
    kafka_approles_v = "3" # v3 (0.H.4) = +4 ecosystem AppRoles + sidecars (kafka-connect-1/2, ksqldb-1/2). v2 (0.H.3) = +3 (schema-registry-1/2, kafka-rest-1). v1 = 6 brokers only; per-host sidecars use $hostName (NOT $host -- PowerShell automatic-var collision, per memory/feedback_powershell_automatic_variables.md).
  }

  depends_on = [null_resource.vault_agent_kafka_policies]

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
      $credsDirRaw      = '${var.vault_agent_kafka_creds_dir}'
      $credsDir         = $ExecutionContext.InvokeCommand.ExpandString($credsDirRaw.Replace('$HOME', $env:USERPROFILE))

      if (-not (Test-Path $keysFile)) { throw "[kafka-approles] keys file $keysFile missing" }
      $rootToken = (Get-Content $keysFile | ConvertFrom-Json).root_token

      if (-not (Test-Path $credsDir)) {
        New-Item -ItemType Directory -Force -Path $credsDir | Out-Null
        # Lock down: owner-only access (matches the 0.E.2 swarm pattern).
        icacls $credsDir /inheritance:r /grant:r "$($env:USERNAME):(F)" | Out-Null
      }

      $approles = @(
        @{ Name = 'nexus-agent-kafka-east-1'; Host = 'kafka-east-1' },
        @{ Name = 'nexus-agent-kafka-east-2'; Host = 'kafka-east-2' },
        @{ Name = 'nexus-agent-kafka-east-3'; Host = 'kafka-east-3' },
        @{ Name = 'nexus-agent-kafka-west-1'; Host = 'kafka-west-1' },
        @{ Name = 'nexus-agent-kafka-west-2'; Host = 'kafka-west-2' },
        @{ Name = 'nexus-agent-kafka-west-3'; Host = 'kafka-west-3' },
        # 0.H.3 ecosystem nodes:
        @{ Name = 'nexus-agent-schema-registry-1'; Host = 'schema-registry-1' },
        @{ Name = 'nexus-agent-schema-registry-2'; Host = 'schema-registry-2' },
        @{ Name = 'nexus-agent-kafka-rest-1';      Host = 'kafka-rest-1' },
        # 0.H.4 ecosystem nodes:
        @{ Name = 'nexus-agent-kafka-connect-1'; Host = 'kafka-connect-1' },
        @{ Name = 'nexus-agent-kafka-connect-2'; Host = 'kafka-connect-2' },
        @{ Name = 'nexus-agent-ksqldb-1';        Host = 'ksqldb-1' },
        @{ Name = 'nexus-agent-ksqldb-2';        Host = 'ksqldb-2' }
      )

      foreach ($a in $approles) {
        $approleName = $a.Name
        $hostName    = $a.Host
        $credsFile   = Join-Path $credsDir "vault-agent-$hostName.json"

        Write-Host "[kafka-approles] provisioning AppRole $approleName for $hostName"

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
          throw "[kafka-approles] $${approleName}: vault write failed (rc=$LASTEXITCODE)"
        }

        # Parse role_id + secret_id from output via marker lines (per
        # memory/feedback_smoke_gate_probe_robustness.md -- marker tokens +
        # -match, NOT strict equality, since sudo+ssh stderr can pollute).
        $roleIdMatch   = ($output -match '(?m)^AGENT_ROLE_ID=(.+)$')
        $roleId        = $matches[1].Trim()
        $secretIdMatch = ($output -match '(?m)^AGENT_SECRET_ID=(.+)$')
        $secretId      = $matches[1].Trim()

        if (-not $roleId -or -not $secretId) {
          throw "[kafka-approles] $${approleName}: failed to parse role_id/secret_id from output"
        }

        # Build JSON sidecar (matches the 0.E.2 swarm shape so the kafka-side
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

        Write-Host "[kafka-approles] $${approleName}: role_id=$($roleId.Substring(0,8))..., secret_id captured, sidecar -> $credsFile"
      }

      Write-Host "[kafka-approles] all $($approles.Count) AppRoles + sidecars written"
    PWSH
  }
}
