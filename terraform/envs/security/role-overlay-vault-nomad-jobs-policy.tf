/*
 * role-overlay-vault-nomad-jobs-policy.tf -- Phase 0.E.3.3b setup
 *
 * Creates the Vault-side scaffolding for Nomad-Vault integration:
 *
 *   - Vault policy `nomad-jobs`
 *       Permissions Nomad workloads (jobs running on the cluster) inherit
 *       when they request a Vault token via the `nomad-cluster` token role.
 *       LAB-SCALE PLACEHOLDER: starts with read on `secret/data/*` (KV-v2
 *       generic secrets) -- tighten on a per-job basis at 0.E.4 / Vol00+.
 *       This is intentionally permissive at the lab tier; production-grade
 *       per-job policies arrive when actual workloads land.
 *
 *   - Vault token role `nomad-cluster`
 *       Periodic-token role that the 3 Nomad managers use via their
 *       `vault {}` agent stanza (see swarm-nomad env's role-overlay-nomad-
 *       vault.tf). Policy attachment is `nomad-jobs` only; orphan=false +
 *       period=72h means tokens issued through this role auto-renew on a
 *       3-day cadence as long as Nomad's vault token is alive.
 *
 *       Nomad's traditional integration model: the Nomad servers each hold
 *       a long-lived token tied to this role; when a job's `template{}` or
 *       `vault{}` block requests secrets, Nomad mints a child token via
 *       `vault token create -role=nomad-cluster` (which inherits the
 *       nomad-jobs policy by default), passes it to the job's allocation,
 *       and revokes it when the alloc terminates. (Nomad 1.7+ also offers
 *       Workload Identity / JWT auth as a more modern alternative; we
 *       stick with the legacy token-role flow here for symmetry with the
 *       Consul ACL pattern + because vault-jwt setup is out of scope.)
 *
 * Pre-reqs:
 *   - 0.D.1 Vault cluster init (root token sidecar exists).
 *   - 0.D.2 KV-v2 secret/* mount exists (Vault default since 1.18).
 *
 * Idempotency:
 *   - vault policy write: upsert (always succeeds with the latest body).
 *   - vault write auth/token/roles/<name>: upsert (always succeeds with
 *     the latest field set; period/orphan/allowed_policies are replaced).
 *
 * Selective ops: var.enable_nomad_vault_jobs (default true). Gated under
 *                var.enable_vault_cluster + var.enable_vault_init.
 */

resource "null_resource" "vault_nomad_jobs_policy" {
  count = var.enable_vault_cluster && var.enable_vault_init && var.enable_nomad_vault_jobs ? 1 : 0

  triggers = {
    post_init_id            = null_resource.vault_post_init[0].id
    nomad_cluster_role_name = var.vault_nomad_cluster_role_name
    nomad_jobs_policy_v     = "1" # v1 = original (nomad-jobs policy with read on secret/data/* + nomad-cluster periodic token role attaching that policy).
  }

  depends_on = [null_resource.vault_post_init]

  provisioner "local-exec" {
    when        = create
    interpreter = ["pwsh", "-NoProfile", "-Command"]
    command     = <<-PWSH
      $ip          = '${local.vault_1_ip}'
      $user        = '${local.ssh_user}'
      $roleName    = '${var.vault_nomad_cluster_role_name}'
      $keysFileRaw = '${var.vault_init_keys_file}'
      $keysFile    = $ExecutionContext.InvokeCommand.ExpandString($keysFileRaw.Replace('$HOME', $env:USERPROFILE))

      if (-not (Test-Path $keysFile)) { throw "[vault-nomad-jobs] keys file $keysFile missing" }
      $rootToken = (Get-Content $keysFile | ConvertFrom-Json).root_token

      # nomad-jobs policy body. Lab-scale permissive on secret/data/* +
      # token self-management. Tighten at workload-onboarding time.
      $policyBody = @'
# nomad-jobs -- Phase 0.E.3.3b. Inherited by Nomad workloads (job allocs)
# via the nomad-cluster token role's allowed_policies. Lab-scale placeholder;
# tighten per-job at workload-onboarding time.

path "secret/data/*" {
  capabilities = ["read", "list"]
}
path "secret/metadata/*" {
  capabilities = ["read", "list"]
}
path "auth/token/lookup-self" {
  capabilities = ["read"]
}
path "auth/token/renew-self" {
  capabilities = ["update"]
}
path "auth/token/revoke-self" {
  capabilities = ["update"]
}
'@

      $policyBytes = [System.Text.UTF8Encoding]::new($false).GetBytes($policyBody)
      $policyB64   = [Convert]::ToBase64String($policyBytes)

      $script = @"
set -euo pipefail
export VAULT_TOKEN='$rootToken'
export VAULT_SKIP_VERIFY=true
export VAULT_ADDR=https://127.0.0.1:8200

# 1. Write nomad-jobs policy (idempotent upsert).
echo '$policyB64' | base64 -d | vault policy write nomad-jobs - >/dev/null
echo '[vault-nomad-jobs] nomad-jobs policy written'

# 2. Write nomad-cluster token role (idempotent upsert). Periodic tokens
#    issued from this role auto-renew on a 3-day cadence; allowed_policies
#    constrains child tokens to inherit nomad-jobs only. orphan=false means
#    revoking the parent (Nomad's own vault token) cascades to children.
vault write auth/token/roles/$roleName \
  allowed_policies='nomad-jobs' \
  disallowed_policies='' \
  orphan=false \
  period='72h' \
  renewable=true >/dev/null
echo '[vault-nomad-jobs] nomad-cluster token role written'

# 3. Sanity-read both for visible output.
echo '--- policy read nomad-jobs ---'
vault policy read nomad-jobs | head -8
echo '--- token role read nomad-cluster ---'
vault read auth/token/roles/$roleName | head -10
"@

      $scriptBytes = [System.Text.UTF8Encoding]::new($false).GetBytes($script)
      $scriptB64   = [Convert]::ToBase64String($scriptBytes)

      Write-Host "[vault-nomad-jobs] dispatching to $${ip} via base64"
      $output = ssh -o ConnectTimeout=15 -o BatchMode=yes -o StrictHostKeyChecking=no $user@$ip "echo '$scriptB64' | base64 -d | bash" 2>&1 | Out-String
      $rc = $LASTEXITCODE
      Write-Host $output.Trim()
      if ($rc -ne 0) {
        throw "[vault-nomad-jobs] script failed (rc=$rc)"
      }
    PWSH
  }
}
