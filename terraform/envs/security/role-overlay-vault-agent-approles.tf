/*
 * role-overlay-vault-agent-approles.tf -- Phase 0.D.5.4 step 2/2 (security)
 *
 * Defines the two AppRoles consumed by the Vault Agent on dc-nexus +
 * nexus-jumpbox. Each AppRole has its corresponding narrow policy
 * (from role-overlay-vault-agent-policies.tf) and persists its
 * role-id + secret-id to a JSON sidecar on the build host.
 *
 * The foundation env's Vault Agent install overlays read the JSON
 * sidecars + scp role-id / secret-id text files onto each host.
 *
 * AppRole shape:
 *   - token_policies = [<host-policy>]
 *   - token_ttl = 1h, token_max_ttl = 24h    (Agent renews mid-life)
 *   - secret_id_ttl = 0                       (lab convention; production
 *                                              would use 24h with auto-
 *                                              rotation via security re-apply)
 *   - secret_id_num_uses = 0                  (unlimited)
 *   - bind_secret_id = true
 *
 * Idempotency: role upsert; role-id stable; secret-id regenerated per
 * apply (foundation env reads the freshest from JSON on its next apply).
 *
 * Selective ops: enable_vault_agent_setup (master) AND
 *                enable_vault_agent_approles.
 */

resource "null_resource" "vault_agent_approles" {
  count = var.enable_vault_cluster && var.enable_vault_init && var.enable_vault_agent_setup && var.enable_vault_agent_approles ? 1 : 0

  triggers = {
    policies_id         = null_resource.vault_agent_policies[0].id
    dc_nexus_creds_file = var.vault_agent_dc_nexus_creds_file
    jumpbox_creds_file  = var.vault_agent_nexus_jumpbox_creds_file
    approles_overlay_v  = "1"
  }

  depends_on = [null_resource.vault_agent_policies]

  provisioner "local-exec" {
    when        = create
    interpreter = ["pwsh", "-NoProfile", "-Command"]
    command     = <<-PWSH
      $ip                       = '${local.vault_1_ip}'
      $user                     = '${local.ssh_user}'
      $keysFileRaw              = '${var.vault_init_keys_file}'
      $keysFile                 = $ExecutionContext.InvokeCommand.ExpandString($keysFileRaw.Replace('$HOME', $env:USERPROFILE))
      $caBundlePathRaw          = '${var.vault_pki_ca_bundle_path}'
      $caBundlePath             = $ExecutionContext.InvokeCommand.ExpandString($caBundlePathRaw.Replace('$HOME', $env:USERPROFILE))
      $dcNexusCredsFileRaw      = '${var.vault_agent_dc_nexus_creds_file}'
      $dcNexusCredsFile         = $ExecutionContext.InvokeCommand.ExpandString($dcNexusCredsFileRaw.Replace('$HOME', $env:USERPROFILE))
      $jumpboxCredsFileRaw      = '${var.vault_agent_nexus_jumpbox_creds_file}'
      $jumpboxCredsFile         = $ExecutionContext.InvokeCommand.ExpandString($jumpboxCredsFileRaw.Replace('$HOME', $env:USERPROFILE))

      if (-not (Test-Path $keysFile)) { throw "[agent-approles] keys file $keysFile missing" }
      $rootToken = (Get-Content $keysFile | ConvertFrom-Json).root_token

      $approles = @(
        @{ Name = 'nexus-agent-dc-nexus';      Policy = 'nexus-agent-dc-nexus';      CredsFile = $dcNexusCredsFile },
        @{ Name = 'nexus-agent-nexus-jumpbox'; Policy = 'nexus-agent-nexus-jumpbox'; CredsFile = $jumpboxCredsFile }
      )

      foreach ($a in $approles) {
        $approleName = $a.Name
        $policyName  = $a.Policy
        $credsFile   = $a.CredsFile

        Write-Host "[agent-approles] provisioning AppRole $approleName"

        # 1. Upsert role + fetch role-id + new secret-id on vault-1
        $remoteBash = @"
set -euo pipefail
export VAULT_TOKEN='$rootToken'
export VAULT_SKIP_VERIFY=true
export VAULT_ADDR=https://127.0.0.1:8200

vault write auth/approle/role/$approleName \
  token_policies=$policyName \
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
        $output    = ssh -o ConnectTimeout=30 -o BatchMode=yes -o StrictHostKeyChecking=no $user@$ip "echo '$bashB64' | base64 -d | bash" 2>&1 | Out-String
        if ($LASTEXITCODE -ne 0) {
          throw "[agent-approles] AppRole '$approleName' provisioning failed (rc=$LASTEXITCODE). Output:`n$output"
        }

        $roleId   = $null
        $secretId = $null
        if ($output -match '(?m)^AGENT_ROLE_ID=(.+)$')   { $roleId   = $Matches[1].Trim() }
        if ($output -match '(?m)^AGENT_SECRET_ID=(.+)$') { $secretId = $Matches[1].Trim() }
        if (-not $roleId -or -not $secretId) {
          throw "[agent-approles] AppRole '$approleName' role-id/secret-id parse failed. Output:`n$output"
        }

        # 2. Persist to JSON sidecar (mode 0600 via icacls)
        $credsDir = Split-Path -Parent $credsFile
        New-Item -ItemType Directory -Force -Path $credsDir | Out-Null
        $h = @{
          role_name      = $approleName
          policy_name    = $policyName
          role_id        = $roleId
          secret_id      = $secretId
          vault_addr     = "https://${local.vault_1_ip}:8200"
          ca_bundle_path = '${var.vault_pki_ca_bundle_path}'
          rotated_at     = (Get-Date).ToUniversalTime().ToString('o')
        }
        ($h | ConvertTo-Json -Depth 4) | Set-Content -Path $credsFile -Encoding UTF8
        icacls $credsFile /inheritance:r /grant:r "$($env:USERNAME):F" 2>&1 | Out-Null

        Write-Host "[agent-approles] persisted $approleName creds to $credsFile (role_id length=$($roleId.Length); secret_id length=$($secretId.Length))"
      }

      Write-Host "[agent-approles] complete -- 2 AppRoles provisioned + JSON sidecars written"
    PWSH
  }
}
