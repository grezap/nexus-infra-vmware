/*
 * role-overlay-vault-agent-kafka-policies.tf -- Phase 0.H.2 setup
 *
 * Six narrow Vault policies, one per kafka-node Vault Agent. Mirrors the
 * 0.E.2 `nexus-agent-swarm-*` shape, scaled to the Kafka tier:
 *
 *   nexus-agent-kafka-east-{1,2,3}  (kafka-east KRaft cluster)
 *   nexus-agent-kafka-west-{1,2,3}  (kafka-west KRaft cluster, DR)
 *
 * Permissions (minimal -- broker mTLS needs only a PKI leaf, no KV secret):
 *   - PKI issue on pki_int/issue/<kafka_role>   (all 6 -- broker TLS cert)
 *   - token self-lookup + self-renew            (all 6)
 *
 * Unlike the swarm policies there is NO KV grant: the kafka-node Vault Agent
 * renders a PEM keystore/truststore straight from the PKI leaf (Kafka 3.8's
 * ssl.keystore.type=PEM), so there is no keystore password to read from KV.
 * If a later sub-phase introduces SASL or a keystore password, add the KV
 * path here.
 *
 * Idempotency: vault policy write is upsert.
 *
 * Selective ops: var.enable_kafka_agent_setup (master) AND
 *                var.enable_kafka_agent_policies.
 */

locals {
  kafka_agent_policy_specs = {
    "nexus-agent-kafka-east-1" = { cluster = "east", host = "kafka-east-1" }
    "nexus-agent-kafka-east-2" = { cluster = "east", host = "kafka-east-2" }
    "nexus-agent-kafka-east-3" = { cluster = "east", host = "kafka-east-3" }
    "nexus-agent-kafka-west-1" = { cluster = "west", host = "kafka-west-1" }
    "nexus-agent-kafka-west-2" = { cluster = "west", host = "kafka-west-2" }
    "nexus-agent-kafka-west-3" = { cluster = "west", host = "kafka-west-3" }
  }
}

resource "null_resource" "vault_agent_kafka_policies" {
  count = var.enable_vault_cluster && var.enable_vault_init && var.enable_kafka_agent_setup && var.enable_kafka_agent_policies ? 1 : 0

  triggers = {
    post_init_id             = null_resource.vault_post_init[0].id
    kafka_role_id            = length(null_resource.vault_pki_kafka_role) > 0 ? null_resource.vault_pki_kafka_role[0].id : "disabled"
    kafka_role_name          = var.vault_pki_kafka_role_name
    kafka_policies_overlay_v = "1" # v1 = original. Minimal per-broker policy: pki_int/issue/<kafka_role> + token self-lookup/renew.
  }

  depends_on = [null_resource.vault_post_init, null_resource.vault_pki_kafka_role]

  provisioner "local-exec" {
    when        = create
    interpreter = ["pwsh", "-NoProfile", "-Command"]
    command     = <<-PWSH
      $ip          = '${local.vault_1_ip}'
      $user        = '${local.ssh_user}'
      $keysFileRaw = '${var.vault_init_keys_file}'
      $keysFile    = $ExecutionContext.InvokeCommand.ExpandString($keysFileRaw.Replace('$HOME', $env:USERPROFILE))

      if (-not (Test-Path $keysFile)) { throw "[kafka-policies] keys file $keysFile missing" }
      $rootToken = (Get-Content $keysFile | ConvertFrom-Json).root_token

      # One policy body for all 6 brokers -- they are interchangeable from
      # Vault's perspective (same PKI role, no per-host KV path). The
      # HOSTNAME placeholder is kept for symmetry with the swarm pattern +
      # so a future per-host KV grant is a one-line change.
      $brokerPolicy = @"
# Phase 0.H.2 setup -- agent policy for kafka brokers (HOSTNAME placeholder
# substituted per-policy below). Minimal: PKI leaf issuance + token self-mgmt.
path "pki_int/issue/${var.vault_pki_kafka_role_name}" {
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
%{for name, spec in local.kafka_agent_policy_specs~}
        @{ Name = '${name}'; Cluster = '${spec.cluster}'; Host = '${spec.host}' },
%{endfor~}
        $null
      ) | Where-Object { $_ -ne $null }

      foreach ($s in $specs) {
        $name = $s.Name
        $hostName = $s.Host
        $bodyRendered = $brokerPolicy -replace 'HOSTNAME', $hostName

        $bodyBytes = [System.Text.UTF8Encoding]::new($false).GetBytes($bodyRendered)
        $bodyB64   = [Convert]::ToBase64String($bodyBytes)

        $remoteBash = @"
set -euo pipefail
export VAULT_TOKEN='$rootToken'
export VAULT_SKIP_VERIFY=true
export VAULT_ADDR=https://127.0.0.1:8200
echo '$bodyB64' | base64 -d | vault policy write $name - >/dev/null
echo "[kafka-policies] wrote policy $name"
"@
        $remoteBytes = [System.Text.UTF8Encoding]::new($false).GetBytes($remoteBash)
        $remoteB64   = [Convert]::ToBase64String($remoteBytes)

        Write-Host "[kafka-policies] writing $name (broker policy for $hostName)"
        $output = ssh -o ConnectTimeout=15 -o BatchMode=yes -o StrictHostKeyChecking=no $user@$ip "echo '$remoteB64' | base64 -d | bash" 2>&1 | Out-String
        if ($LASTEXITCODE -ne 0) {
          Write-Host $output.Trim()
          throw "[kafka-policies] failed writing $name (rc=$LASTEXITCODE)"
        }
        Write-Host $output.Trim()
      }

      Write-Host "[kafka-policies] all 6 kafka-node policies written"
    PWSH
  }
}
