/*
 * role-overlay-vault-agent-platform-tools-approles.tf -- Phase 0.Q.1 setup (ADR-0043)
 *
 * One AppRole per platform-tools-node Vault Agent (3 nodes). token_policies is
 * the like-named policy. Per-host JSON sidecar at
 *   $HOME\.nexus\vault-agent-platform-tools-<hostname>.json
 * (read by nexus-infra-platform-tools' vault-agents overlay).
 *
 * LANDMINES:
 *  - secret_id_ttl=0 / secret_id_num_uses=0 -- the sidecar SecretID must stay
 *    valid across cold rebuilds; a bounded SecretID silently expires and the
 *    Agent then fails to auth long after apply reported green.
 *  - The sidecar is written with a fresh SecretID on every create. Re-running
 *    this overlay after a taint invalidates nothing, but the node must re-read
 *    the sidecar -- re-run the platform-tools-side vault-agents overlay too.
 *
 * Selective ops: var.enable_platform_tools_agent_setup AND
 *                var.enable_platform_tools_agent_approles.
 */

resource "null_resource" "vault_agent_platform_tools_approles" {
  count = var.enable_vault_cluster && var.enable_vault_init && var.enable_platform_tools_agent_setup && var.enable_platform_tools_agent_approles ? 1 : 0

  triggers = {
    policies_id               = null_resource.vault_agent_platform_tools_policies[0].id
    creds_dir                 = var.vault_agent_platform_tools_creds_dir
    platform_tools_approles_v = "1"
  }

  depends_on = [null_resource.vault_agent_platform_tools_policies]

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
      $credsDirRaw      = '${var.vault_agent_platform_tools_creds_dir}'
      $credsDir         = $ExecutionContext.InvokeCommand.ExpandString($credsDirRaw.Replace('$HOME', $env:USERPROFILE))

      if (-not (Test-Path $keysFile)) { throw "[platform-tools-approles] keys file $keysFile missing" }
      $rootToken = (Get-Content $keysFile | ConvertFrom-Json).root_token

      if (-not (Test-Path $credsDir)) {
        New-Item -ItemType Directory -Force -Path $credsDir | Out-Null
        icacls $credsDir /inheritance:r /grant:r "$($env:USERNAME):(F)" | Out-Null
      }

      $approles = @(
        @{ Name = 'nexus-agent-platform-tools-marquez';      Host = 'marquez' },
        @{ Name = 'nexus-agent-platform-tools-marquez-pg-1'; Host = 'marquez-pg-1' },
        @{ Name = 'nexus-agent-platform-tools-marquez-pg-2'; Host = 'marquez-pg-2' }
      )

      foreach ($a in $approles) {
        $approleName = $a.Name
        $hostName    = $a.Host
        $credsFile   = Join-Path $credsDir "vault-agent-platform-tools-$hostName.json"

        Write-Host "[platform-tools-approles] provisioning AppRole $approleName for $hostName"
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
        if ($LASTEXITCODE -ne 0) { Write-Host $output.Trim(); throw "[platform-tools-approles] $${approleName}: vault write failed (rc=$LASTEXITCODE)" }

        $roleIdMatch   = ($output -match '(?m)^AGENT_ROLE_ID=(.+)$')
        $roleId        = $matches[1].Trim()
        $secretIdMatch = ($output -match '(?m)^AGENT_SECRET_ID=(.+)$')
        $secretId      = $matches[1].Trim()
        if (-not $roleId -or -not $secretId) { throw "[platform-tools-approles] $${approleName}: failed to parse role_id/secret_id" }

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
        Write-Host "[platform-tools-approles] $${approleName}: role_id=$($roleId.Substring(0,8))..., sidecar -> $credsFile"
      }

      Write-Host "[platform-tools-approles] all $($approles.Count) AppRoles + sidecars written"
    PWSH
  }
}
