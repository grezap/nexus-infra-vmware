/*
 * role-overlay-vault-agent-vitess-policies.tf -- Phase 0.O setup
 *
 * One narrow Vault policy per Vitess-tier node Vault Agent, role-differentiated
 * across tablet vs etcd vs control vs vtgate:
 *
 *   nexus-agent-vitess-etcd-{1,2,3}            -- etcd topo members
 *   nexus-agent-vitess-control-1               -- vtctld + VTOrc
 *   nexus-agent-vitess-vtgate-{1,2}            -- vtgate routers
 *   nexus-agent-vitess-shard{1,2}-tablet-{1,2,3} -- vttablet + Percona tablets
 *
 * Permissions matrix:
 *   tablet (6): PKI issue + KV read on ALL 5 mysql/vtorc creds (root, app,
 *               allprivs, repl, vtorc-topo) -- the tablet renders init_db.sql +
 *               db creds + grants the VTOrc topo user.
 *   etcd   (3): PKI issue + token self-mgmt only (topo store, no mysqld).
 *   control(1): PKI issue + KV read on vtorc-topo (VTOrc) + mysql-app (vtctld).
 *   vtgate (2): PKI issue + KV read on mysql-app (the vtgate MySQL listener
 *               static-auth password) + token self-mgmt.
 *
 * KV-v2 path convention: `nexus/data/vitess/<name>-password` is the policy
 * capability path (KV-v2 inserts `/data/`); `nexus/vitess/<name>-password` is
 * the CLI path the creds-seed overlay writes.
 *
 * Idempotency: vault policy write is upsert.
 * Selective ops: var.enable_vitess_agent_setup AND var.enable_vitess_agent_policies.
 */

locals {
  vitess_agent_policy_specs = {
    "nexus-agent-vitess-etcd-1"          = { host = "vitess-etcd-1", role = "etcd" }
    "nexus-agent-vitess-etcd-2"          = { host = "vitess-etcd-2", role = "etcd" }
    "nexus-agent-vitess-etcd-3"          = { host = "vitess-etcd-3", role = "etcd" }
    "nexus-agent-vitess-control-1"       = { host = "vitess-control-1", role = "control" }
    "nexus-agent-vitess-vtgate-1"        = { host = "vitess-vtgate-1", role = "vtgate" }
    "nexus-agent-vitess-vtgate-2"        = { host = "vitess-vtgate-2", role = "vtgate" }
    "nexus-agent-vitess-shard1-tablet-1" = { host = "vitess-shard1-tablet-1", role = "tablet" }
    "nexus-agent-vitess-shard1-tablet-2" = { host = "vitess-shard1-tablet-2", role = "tablet" }
    "nexus-agent-vitess-shard1-tablet-3" = { host = "vitess-shard1-tablet-3", role = "tablet" }
    "nexus-agent-vitess-shard2-tablet-1" = { host = "vitess-shard2-tablet-1", role = "tablet" }
    "nexus-agent-vitess-shard2-tablet-2" = { host = "vitess-shard2-tablet-2", role = "tablet" }
    "nexus-agent-vitess-shard2-tablet-3" = { host = "vitess-shard2-tablet-3", role = "tablet" }
  }
}

resource "null_resource" "vault_agent_vitess_policies" {
  count = var.enable_vault_cluster && var.enable_vault_init && var.enable_vitess_agent_setup && var.enable_vitess_agent_policies ? 1 : 0

  triggers = {
    post_init_id              = null_resource.vault_post_init[0].id
    vitess_role_id            = length(null_resource.vault_pki_vitess_role) > 0 ? null_resource.vault_pki_vitess_role[0].id : "disabled"
    vitess_role_name          = var.vault_pki_vitess_role_name
    creds_seed_id             = length(null_resource.vault_vitess_cluster_creds_seed) > 0 ? null_resource.vault_vitess_cluster_creds_seed[0].id : "disabled"
    vitess_policies_overlay_v = "1" # v1 (0.O) = 12 narrow policies (3 etcd + 1 control + 2 vtgate + 2x3 tablets) with role-differentiated KV grants.
  }

  depends_on = [
    null_resource.vault_post_init,
    null_resource.vault_pki_vitess_role,
    null_resource.vault_vitess_cluster_creds_seed,
  ]

  provisioner "local-exec" {
    when        = create
    interpreter = ["pwsh", "-NoProfile", "-Command"]
    command     = <<-PWSH
      $ip          = '${local.vault_1_ip}'
      $user        = '${local.ssh_user}'
      $keysFileRaw = '${var.vault_init_keys_file}'
      $keysFile    = $ExecutionContext.InvokeCommand.ExpandString($keysFileRaw.Replace('$HOME', $env:USERPROFILE))

      if (-not (Test-Path $keysFile)) { throw "[vitess-policies] keys file $keysFile missing" }
      $rootToken = (Get-Content $keysFile | ConvertFrom-Json).root_token

      $tabletPolicy = @"
# Phase 0.O -- agent policy for Vitess tablet nodes. PKI leaf issuance + KV
# reads on all 5 mysql/vtorc creds + token self-mgmt.
path "pki_int/issue/${var.vault_pki_vitess_role_name}" {
  capabilities = ["create", "update"]
}
path "nexus/data/vitess/mysql-root-password" {
  capabilities = ["read"]
}
path "nexus/data/vitess/mysql-app-password" {
  capabilities = ["read"]
}
path "nexus/data/vitess/mysql-allprivs-password" {
  capabilities = ["read"]
}
path "nexus/data/vitess/mysql-repl-password" {
  capabilities = ["read"]
}
path "nexus/data/vitess/vtorc-topo-password" {
  capabilities = ["read"]
}
path "auth/token/lookup-self" {
  capabilities = ["read"]
}
path "auth/token/renew-self" {
  capabilities = ["update"]
}
"@

      $etcdPolicy = @"
# Phase 0.O -- agent policy for Vitess etcd topo nodes. PKI leaf issuance +
# token self-mgmt (topo store, no mysqld creds).
path "pki_int/issue/${var.vault_pki_vitess_role_name}" {
  capabilities = ["create", "update"]
}
path "auth/token/lookup-self" {
  capabilities = ["read"]
}
path "auth/token/renew-self" {
  capabilities = ["update"]
}
"@

      $controlPolicy = @"
# Phase 0.O -- agent policy for the Vitess control node (vtctld + VTOrc). PKI
# leaf issuance + KV read on vtorc-topo (VTOrc) + mysql-app (vtctld) + token.
path "pki_int/issue/${var.vault_pki_vitess_role_name}" {
  capabilities = ["create", "update"]
}
path "nexus/data/vitess/vtorc-topo-password" {
  capabilities = ["read"]
}
path "nexus/data/vitess/mysql-app-password" {
  capabilities = ["read"]
}
path "auth/token/lookup-self" {
  capabilities = ["read"]
}
path "auth/token/renew-self" {
  capabilities = ["update"]
}
"@

      $vtgatePolicy = @"
# Phase 0.O -- agent policy for Vitess vtgate nodes. PKI leaf issuance + KV
# read on mysql-app (the vtgate MySQL listener static-auth password) + token.
path "pki_int/issue/${var.vault_pki_vitess_role_name}" {
  capabilities = ["create", "update"]
}
path "nexus/data/vitess/mysql-app-password" {
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
%{for name, spec in local.vitess_agent_policy_specs~}
        @{ Name = '${name}'; Host = '${spec.host}'; Role = '${spec.role}' },
%{endfor~}
        $null
      ) | Where-Object { $_ -ne $null }

      foreach ($s in $specs) {
        $name = $s.Name
        $role = $s.Role
        $policyBody = switch ($role) {
          'tablet'  { $tabletPolicy }
          'etcd'    { $etcdPolicy }
          'control' { $controlPolicy }
          'vtgate'  { $vtgatePolicy }
        }

        $bodyBytes = [System.Text.UTF8Encoding]::new($false).GetBytes($policyBody)
        $bodyB64   = [Convert]::ToBase64String($bodyBytes)

        $remoteBash = @"
set -euo pipefail
export VAULT_TOKEN='$rootToken'
export VAULT_SKIP_VERIFY=true
export VAULT_ADDR=https://127.0.0.1:8200
echo '$bodyB64' | base64 -d | vault policy write $name - >/dev/null
echo "[vitess-policies] wrote policy $name ($role)"
"@
        $remoteBytes = [System.Text.UTF8Encoding]::new($false).GetBytes($remoteBash)
        $remoteB64   = [Convert]::ToBase64String($remoteBytes)

        Write-Host "[vitess-policies] writing $name ($role policy)"
        $output = ssh -o ConnectTimeout=15 -o BatchMode=yes -o StrictHostKeyChecking=no $user@$ip "echo '$remoteB64' | base64 -d | bash" 2>&1 | Out-String
        if ($LASTEXITCODE -ne 0) {
          Write-Host $output.Trim()
          throw "[vitess-policies] failed writing $name (rc=$LASTEXITCODE)"
        }
        Write-Host $output.Trim()
      }

      Write-Host "[vitess-policies] all $($specs.Count) Vitess-tier policies written"
    PWSH
  }
}
