/*
 * role-overlay-vault-agent-patroni-policies.tf -- Phase 0.G.4 setup
 *
 * One narrow Vault policy per Patroni-tier node Vault Agent, with
 * role-differentiated KV grants across Patroni nodes vs etcd nodes vs the
 * HAProxy HA pair:
 *
 *   nexus-agent-pg-primary       -- Patroni node (initial leader candidate)
 *   nexus-agent-pg-replica-1     -- Patroni node (streaming replica)
 *   nexus-agent-pg-replica-2     -- Patroni node (streaming replica)
 *   nexus-agent-etcd-1           -- etcd DCS member 1
 *   nexus-agent-etcd-2           -- etcd DCS member 2
 *   nexus-agent-etcd-3           -- etcd DCS member 3
 *   nexus-agent-haproxy-pg-1     -- HAProxy LB (keepalived MASTER for VIP .60)
 *   nexus-agent-haproxy-pg-2     -- HAProxy LB (keepalived BACKUP for VIP .60)
 *
 * Permissions matrix (Patroni vs etcd vs HAProxy):
 *
 *   Patroni nodes (nexus-agent-pg-{primary,replica-1,replica-2}):
 *     - PKI issue on pki_int/issue/<patroni_role>                    (all 3)
 *     - KV read on nexus/data/oltp/patroni/etcd-root-password        (all 3 -- optional operator path; patroni uses cert auth to etcd in normal ops)
 *     - KV read on nexus/data/oltp/patroni/patroni-rest-password     (all 3 -- REST listener config)
 *     - KV read on nexus/data/oltp/patroni/postgres-superuser-password (all 3 -- PG initdb + cluster ops)
 *     - KV read on nexus/data/oltp/patroni/postgres-replication-password (all 3 -- streaming replication)
 *     - token self-lookup + self-renew                               (all 3)
 *
 *   etcd nodes (nexus-agent-etcd-{1,2,3}):
 *     - PKI issue on pki_int/issue/<patroni_role>                    (all 3)
 *     - KV read on nexus/data/oltp/patroni/etcd-root-password        (all 3 -- etcdctl auth setup + ongoing root binds)
 *     - KV read on nexus/data/oltp/patroni/patroni-rest-password     (all 3 -- parity with operator workflow that may etcdctl-then-patronictl)
 *     - token self-lookup + self-renew                               (all 3)
 *
 *   HAProxy nodes (nexus-agent-haproxy-pg-{1,2}):
 *     - PKI issue on pki_int/issue/<patroni_role>                          (both)
 *     - KV read on nexus/data/oltp/patroni/patroni-rest-password           (both -- operator backlink convenience; HAProxy itself probes unauth /leader)
 *     - KV read on nexus/data/oltp/patroni/haproxy-stats-password          (both -- stats UI auth)
 *     - token self-lookup + self-renew                                     (both)
 *
 * The KV paths use the v2 secrets engine convention: `nexus/data/oltp/
 * patroni/<name>-password` is the policy capability path (KV-v2 inserts
 * the `/data/` segment); `nexus/oltp/patroni/<name>-password` is the
 * CLI-facing path. The patroni-cluster-creds-seed overlay seeds the CLI
 * paths; these policies grant read on the corresponding policy paths.
 *
 * Idempotency: vault policy write is upsert.
 *
 * Selective ops: var.enable_patroni_agent_setup (master) AND
 *                var.enable_patroni_agent_policies.
 */

locals {
  patroni_agent_policy_specs = {
    "nexus-agent-pg-primary"   = { host = "pg-primary", role = "patroni" }
    "nexus-agent-pg-replica-1" = { host = "pg-replica-1", role = "patroni" }
    "nexus-agent-pg-replica-2" = { host = "pg-replica-2", role = "patroni" }
    "nexus-agent-etcd-1"       = { host = "etcd-1", role = "etcd" }
    "nexus-agent-etcd-2"       = { host = "etcd-2", role = "etcd" }
    "nexus-agent-etcd-3"       = { host = "etcd-3", role = "etcd" }
    "nexus-agent-haproxy-pg-1" = { host = "haproxy-pg-1", role = "haproxy" }
    "nexus-agent-haproxy-pg-2" = { host = "haproxy-pg-2", role = "haproxy" }
  }
}

resource "null_resource" "vault_agent_patroni_policies" {
  count = var.enable_vault_cluster && var.enable_vault_init && var.enable_patroni_agent_setup && var.enable_patroni_agent_policies ? 1 : 0

  triggers = {
    post_init_id               = null_resource.vault_post_init[0].id
    patroni_role_id            = length(null_resource.vault_pki_patroni_role) > 0 ? null_resource.vault_pki_patroni_role[0].id : "disabled"
    patroni_role_name          = var.vault_pki_patroni_role_name
    creds_seed_id              = length(null_resource.vault_patroni_cluster_creds_seed) > 0 ? null_resource.vault_patroni_cluster_creds_seed[0].id : "disabled"
    patroni_policies_overlay_v = "2" # v2 (0.G.4) = initial 8 narrow policies (3 Patroni + 3 etcd + 2 HAProxy HA pair) with role-differentiated KV grants. v1 was the abandoned single-HAProxy variant superseded mid-scaffold.
  }

  depends_on = [
    null_resource.vault_post_init,
    null_resource.vault_pki_patroni_role,
    null_resource.vault_patroni_cluster_creds_seed,
  ]

  provisioner "local-exec" {
    when        = create
    interpreter = ["pwsh", "-NoProfile", "-Command"]
    command     = <<-PWSH
      $ip          = '${local.vault_1_ip}'
      $user        = '${local.ssh_user}'
      $keysFileRaw = '${var.vault_init_keys_file}'
      $keysFile    = $ExecutionContext.InvokeCommand.ExpandString($keysFileRaw.Replace('$HOME', $env:USERPROFILE))

      if (-not (Test-Path $keysFile)) { throw "[patroni-policies] keys file $keysFile missing" }
      $rootToken = (Get-Content $keysFile | ConvertFrom-Json).root_token

      # Three policy bodies -- Patroni nodes get the full PG creds suite,
      # etcd nodes get only etcd-root + patroni-rest, HAProxy gets only
      # patroni-rest + haproxy-stats. Body assembled per-spec below.

      $patroniPolicy = @"
# Phase 0.G.4 setup -- agent policy for Patroni nodes (HOSTNAME placeholder
# substituted per-policy below). Grants PKI leaf issuance + KV reads on the
# 4 Patroni-relevant creds + token self-mgmt.
path "pki_int/issue/${var.vault_pki_patroni_role_name}" {
  capabilities = ["create", "update"]
}
path "nexus/data/oltp/patroni/etcd-root-password" {
  capabilities = ["read"]
}
path "nexus/data/oltp/patroni/patroni-rest-password" {
  capabilities = ["read"]
}
path "nexus/data/oltp/patroni/postgres-superuser-password" {
  capabilities = ["read"]
}
path "nexus/data/oltp/patroni/postgres-replication-password" {
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
# Phase 0.G.4 setup -- agent policy for etcd nodes (HOSTNAME placeholder
# substituted per-policy below). Grants PKI leaf issuance + KV reads on the
# 2 etcd-relevant creds (etcd-root + patroni-rest parity) + token self-mgmt.
path "pki_int/issue/${var.vault_pki_patroni_role_name}" {
  capabilities = ["create", "update"]
}
path "nexus/data/oltp/patroni/etcd-root-password" {
  capabilities = ["read"]
}
path "nexus/data/oltp/patroni/patroni-rest-password" {
  capabilities = ["read"]
}
path "auth/token/lookup-self" {
  capabilities = ["read"]
}
path "auth/token/renew-self" {
  capabilities = ["update"]
}
"@

      $haproxyPolicy = @"
# Phase 0.G.4 setup -- agent policy for the HAProxy LB (HOSTNAME placeholder
# substituted per-policy below). Grants PKI leaf issuance + KV reads on
# patroni-rest (operator backlink) + haproxy-stats (UI auth) + token self-mgmt.
path "pki_int/issue/${var.vault_pki_patroni_role_name}" {
  capabilities = ["create", "update"]
}
path "nexus/data/oltp/patroni/patroni-rest-password" {
  capabilities = ["read"]
}
path "nexus/data/oltp/patroni/haproxy-stats-password" {
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
%{for name, spec in local.patroni_agent_policy_specs~}
        @{ Name = '${name}'; Host = '${spec.host}'; Role = '${spec.role}' },
%{endfor~}
        $null
      ) | Where-Object { $_ -ne $null }

      foreach ($s in $specs) {
        $name = $s.Name
        $hostName = $s.Host
        $role = $s.Role
        $policyBody = switch ($role) {
          'patroni' { $patroniPolicy }
          'etcd'    { $etcdPolicy }
          'haproxy' { $haproxyPolicy }
        }
        $bodyRendered = $policyBody -replace 'HOSTNAME', $hostName

        $bodyBytes = [System.Text.UTF8Encoding]::new($false).GetBytes($bodyRendered)
        $bodyB64   = [Convert]::ToBase64String($bodyBytes)

        $remoteBash = @"
set -euo pipefail
export VAULT_TOKEN='$rootToken'
export VAULT_SKIP_VERIFY=true
export VAULT_ADDR=https://127.0.0.1:8200
echo '$bodyB64' | base64 -d | vault policy write $name - >/dev/null
echo "[patroni-policies] wrote policy $name ($role)"
"@
        $remoteBytes = [System.Text.UTF8Encoding]::new($false).GetBytes($remoteBash)
        $remoteB64   = [Convert]::ToBase64String($remoteBytes)

        Write-Host "[patroni-policies] writing $name ($role policy for $hostName)"
        $output = ssh -o ConnectTimeout=15 -o BatchMode=yes -o StrictHostKeyChecking=no $user@$ip "echo '$remoteB64' | base64 -d | bash" 2>&1 | Out-String
        if ($LASTEXITCODE -ne 0) {
          Write-Host $output.Trim()
          throw "[patroni-policies] failed writing $name (rc=$LASTEXITCODE)"
        }
        Write-Host $output.Trim()
      }

      Write-Host "[patroni-policies] all $($specs.Count) Patroni-tier policies written"
    PWSH
  }
}
