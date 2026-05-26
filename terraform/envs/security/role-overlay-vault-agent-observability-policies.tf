/*
 * role-overlay-vault-agent-observability-policies.tf -- Phase 0.I setup
 *
 * One narrow Vault policy per obs-node Vault Agent (14 nodes total -- all 14
 * sub-phase nodes get their policy provisioned from day one, even if the
 * underlying service node hasn't been cloned yet; idle policies are harmless).
 *
 * Permissions: PKI issue on pki_int/issue/<obs_role> + KV read on
 * nexus/data/observability/* + token self. Idempotent upsert.
 *
 * Selective ops: var.enable_observability_agent_setup AND var.enable_observability_agent_policies.
 */

locals {
  observability_agent_policy_specs = {
    "nexus-agent-observability-prom-1"           = { host = "prom-1" }
    "nexus-agent-observability-prom-2"           = { host = "prom-2" }
    "nexus-agent-observability-loki-1"           = { host = "loki-1" }
    "nexus-agent-observability-loki-2"           = { host = "loki-2" }
    "nexus-agent-observability-loki-3"           = { host = "loki-3" }
    "nexus-agent-observability-tempo-1"          = { host = "tempo-1" }
    "nexus-agent-observability-tempo-2"          = { host = "tempo-2" }
    "nexus-agent-observability-tempo-3"          = { host = "tempo-3" }
    "nexus-agent-observability-grafana-1"        = { host = "grafana-1" }
    "nexus-agent-observability-grafana-2"        = { host = "grafana-2" }
    "nexus-agent-observability-grafana-pg-1"     = { host = "grafana-pg-1" }
    "nexus-agent-observability-grafana-pg-2"     = { host = "grafana-pg-2" }
    "nexus-agent-observability-otel-collector-1" = { host = "otel-collector-1" }
    "nexus-agent-observability-otel-collector-2" = { host = "otel-collector-2" }
  }
}

resource "null_resource" "vault_agent_observability_policies" {
  count = var.enable_vault_cluster && var.enable_vault_init && var.enable_observability_agent_setup && var.enable_observability_agent_policies ? 1 : 0

  triggers = {
    post_init_id           = null_resource.vault_post_init[0].id
    obs_role_id            = length(null_resource.vault_pki_observability_role) > 0 ? null_resource.vault_pki_observability_role[0].id : "disabled"
    obs_role_name          = var.vault_pki_obs_role_name
    obs_policies_overlay_v = "1"
  }

  depends_on = [null_resource.vault_post_init, null_resource.vault_pki_observability_role]

  provisioner "local-exec" {
    when        = create
    interpreter = ["pwsh", "-NoProfile", "-Command"]
    command     = <<-PWSH
      $ip          = '${local.vault_1_ip}'
      $user        = '${local.ssh_user}'
      $keysFileRaw = '${var.vault_init_keys_file}'
      $keysFile    = $ExecutionContext.InvokeCommand.ExpandString($keysFileRaw.Replace('$HOME', $env:USERPROFILE))

      if (-not (Test-Path $keysFile)) { throw "[obs-policies] keys file $keysFile missing" }
      $rootToken = (Get-Content $keysFile | ConvertFrom-Json).root_token

      $obsPolicy = @"
# Phase 0.I setup -- agent policy for obs node (HOSTNAME).
path "pki_int/issue/${var.vault_pki_obs_role_name}" {
  capabilities = ["create", "update"]
}
path "nexus/data/observability/*" {
  capabilities = ["read"]
}
path "auth/token/lookup-self" {
  capabilities = ["read"]
}
path "auth/token/renew-self" {
  capabilities = ["update"]
}
"@

      $specs = @(
%{for name, spec in local.observability_agent_policy_specs~}
        @{ Name = '${name}'; Host = '${spec.host}' },
%{endfor~}
        $null
      ) | Where-Object { $_ -ne $null }

      foreach ($s in $specs) {
        $name = $s.Name
        $hostName = $s.Host
        $bodyRendered = $obsPolicy -replace 'HOSTNAME', $hostName
        $bodyB64 = [Convert]::ToBase64String([System.Text.UTF8Encoding]::new($false).GetBytes($bodyRendered))

        $remoteBash = @"
set -euo pipefail
export VAULT_TOKEN='$rootToken'
export VAULT_SKIP_VERIFY=true
export VAULT_ADDR=https://127.0.0.1:8200
echo '$bodyB64' | base64 -d | vault policy write $name - >/dev/null
echo "[obs-policies] wrote policy $name"
"@
        $remoteB64 = [Convert]::ToBase64String([System.Text.UTF8Encoding]::new($false).GetBytes($remoteBash))
        Write-Host "[obs-policies] writing $name (policy for $hostName)"
        $output = ssh -o ConnectTimeout=15 -o BatchMode=yes -o StrictHostKeyChecking=no $user@$ip "echo '$remoteB64' | base64 -d | bash" 2>&1 | Out-String
        if ($LASTEXITCODE -ne 0) { Write-Host $output.Trim(); throw "[obs-policies] failed writing $name (rc=$LASTEXITCODE)" }
        Write-Host $output.Trim()
      }

      Write-Host "[obs-policies] all $($specs.Count) obs-node policies written"
    PWSH
  }
}
