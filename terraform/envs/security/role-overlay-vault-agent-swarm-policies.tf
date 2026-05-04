/*
 * role-overlay-vault-agent-swarm-policies.tf -- Phase 0.E.2 setup
 *
 * Six narrow Vault policies, one per swarm-node Vault Agent. Mirrors
 * 0.D.5.4's `nexus-agent-dc-nexus` / `nexus-agent-nexus-jumpbox` shape,
 * scaled to the orchestration tier:
 *
 *   nexus-agent-swarm-manager-{1,2,3}  (3 managers)
 *   nexus-agent-swarm-worker-{1,2,3}   (3 workers)
 *
 * Permissions across the full 0.E.2 scope (2.1 gossip + 2.2 TLS + 2.3 ACL):
 *   - read on nexus/swarm/consul-gossip-key                (all 6)
 *   - PKI issue on pki_int/issue/consul-server             (all 6 -- 2.2)
 *   - read on nexus/swarm/agent-tokens/<host>              (all 6 -- 2.3)
 *   - read+write on nexus/swarm/consul-bootstrap-token     (managers only;
 *                                                          one of them runs
 *                                                          `consul acl
 *                                                          bootstrap` and
 *                                                          writes the
 *                                                          token in 2.3)
 *   - token self-lookup + self-renew                       (all 6)
 *
 * Idempotency: vault policy write is upsert.
 *
 * Selective ops: var.enable_swarm_agent_setup (master) AND
 *                var.enable_swarm_agent_policies.
 */

locals {
  swarm_agent_policy_specs = {
    "nexus-agent-swarm-manager-1" = { role = "manager", host = "swarm-manager-1" }
    "nexus-agent-swarm-manager-2" = { role = "manager", host = "swarm-manager-2" }
    "nexus-agent-swarm-manager-3" = { role = "manager", host = "swarm-manager-3" }
    "nexus-agent-swarm-worker-1"  = { role = "worker", host = "swarm-worker-1" }
    "nexus-agent-swarm-worker-2"  = { role = "worker", host = "swarm-worker-2" }
    "nexus-agent-swarm-worker-3"  = { role = "worker", host = "swarm-worker-3" }
  }
}

resource "null_resource" "vault_agent_swarm_policies" {
  count = var.enable_vault_cluster && var.enable_vault_init && var.enable_swarm_agent_setup && var.enable_swarm_agent_policies ? 1 : 0

  triggers = {
    post_init_id             = null_resource.vault_post_init[0].id
    seed_id                  = length(null_resource.vault_swarm_secrets_seed) > 0 ? null_resource.vault_swarm_secrets_seed[0].id : "disabled"
    kv_mount_path            = var.vault_kv_mount_path
    swarm_policies_overlay_v = "1"
  }

  depends_on = [null_resource.vault_post_init, null_resource.vault_swarm_secrets_seed]

  provisioner "local-exec" {
    when        = create
    interpreter = ["pwsh", "-NoProfile", "-Command"]
    command     = <<-PWSH
      $ip          = '${local.vault_1_ip}'
      $user        = '${local.ssh_user}'
      $kvPath      = '${var.vault_kv_mount_path}'
      $keysFileRaw = '${var.vault_init_keys_file}'
      $keysFile    = $ExecutionContext.InvokeCommand.ExpandString($keysFileRaw.Replace('$HOME', $env:USERPROFILE))

      if (-not (Test-Path $keysFile)) { throw "[swarm-policies] keys file $keysFile missing" }
      $rootToken = (Get-Content $keysFile | ConvertFrom-Json).root_token

      # Build all 6 policy bodies. Manager policies get extra read+write on
      # consul-bootstrap-token; workers don't.
      $managerPolicy = @"
# Phase 0.E.2 setup -- agent policy for swarm managers (HOSTNAME placeholder
# substituted per-policy below).
path "$kvPath/data/swarm/consul-gossip-key" {
  capabilities = ["read"]
}
path "$kvPath/data/swarm/consul-bootstrap-token" {
  capabilities = ["read", "create", "update"]
}
path "$kvPath/data/swarm/agent-tokens/HOSTNAME" {
  capabilities = ["read"]
}
path "pki_int/issue/${var.vault_pki_consul_role_name}" {
  capabilities = ["create", "update"]
}
path "auth/token/lookup-self" {
  capabilities = ["read"]
}
path "auth/token/renew-self" {
  capabilities = ["update"]
}
"@

      $workerPolicy = @"
# Phase 0.E.2 setup -- agent policy for swarm workers (HOSTNAME placeholder
# substituted per-policy below).
path "$kvPath/data/swarm/consul-gossip-key" {
  capabilities = ["read"]
}
path "$kvPath/data/swarm/agent-tokens/HOSTNAME" {
  capabilities = ["read"]
}
path "pki_int/issue/${var.vault_pki_consul_role_name}" {
  capabilities = ["create", "update"]
}
path "auth/token/lookup-self" {
  capabilities = ["read"]
}
path "auth/token/renew-self" {
  capabilities = ["update"]
}
"@

      $specs = @(
%{for name, spec in local.swarm_agent_policy_specs~}
        @{ Name = '${name}'; Role = '${spec.role}'; Host = '${spec.host}' },
%{endfor~}
        $null
      ) | Where-Object { $_ -ne $null }

      foreach ($s in $specs) {
        $name = $s.Name
        $host = $s.Host
        $body = if ($s.Role -eq 'manager') { $managerPolicy } else { $workerPolicy }
        $bodyRendered = $body -replace 'HOSTNAME', $host

        $bodyBytes = [System.Text.UTF8Encoding]::new($false).GetBytes($bodyRendered)
        $bodyB64   = [Convert]::ToBase64String($bodyBytes)

        $remoteBash = @"
set -euo pipefail
export VAULT_TOKEN='$rootToken'
export VAULT_SKIP_VERIFY=true
export VAULT_ADDR=https://127.0.0.1:8200
echo '$bodyB64' | base64 -d | vault policy write $name - >/dev/null
echo "[swarm-policies] wrote policy $name"
"@
        $remoteBytes = [System.Text.UTF8Encoding]::new($false).GetBytes($remoteBash)
        $remoteB64   = [Convert]::ToBase64String($remoteBytes)

        Write-Host "[swarm-policies] writing $name ($($s.Role) policy for $host)"
        $output = ssh -o ConnectTimeout=15 -o BatchMode=yes -o StrictHostKeyChecking=no $user@$ip "echo '$remoteB64' | base64 -d | bash" 2>&1 | Out-String
        if ($LASTEXITCODE -ne 0) {
          Write-Host $output.Trim()
          throw "[swarm-policies] failed writing $name (rc=$LASTEXITCODE)"
        }
        Write-Host $output.Trim()
      }

      Write-Host "[swarm-policies] all 6 swarm-node policies written"
    PWSH
  }
}
