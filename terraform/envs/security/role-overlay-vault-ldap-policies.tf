/*
 * role-overlay-vault-ldap-policies.tf -- Phase 0.D.3 step 1/4 (security side)
 *
 * Define the three Vault policies that LDAP group mappings reference:
 *
 *   nexus-admin    -> full sudo on all paths (`*` capabilities=create,read,
 *                     update,delete,list,sudo). Equivalent to root token in
 *                     scope; differs only in being attached via auth/ldap
 *                     (so audit logs identify the human, not "root").
 *
 *   nexus-operator -> read/write/delete/list on `nexus/*` (KV-v2 data + meta),
 *                     issue certs via `pki_int/issue/*`, list `pki_int/roles/*`.
 *                     NO sudo. NO sys/policies, sys/auth, sys/mounts changes.
 *                     The "everyday workload" policy.
 *
 *   nexus-reader   -> read+list only on `nexus/*` and `pki/cert/ca`,
 *                     `pki_int/cert/ca`. The "read-only consumer" policy.
 *
 * KV-v2 quirk: data lives at <mount>/data/<path> for reads/writes and
 * <mount>/metadata/<path> for delete/destroy/list. Both paths are covered.
 *
 * Idempotency: `vault policy write` is upsert (replaces existing). Always-
 * apply pattern; triggers re-fire when the policy text variable changes.
 *
 * Selective ops: enable_vault_ldap (master) AND enable_vault_ldap_policies.
 */

resource "null_resource" "vault_ldap_policies" {
  count = var.enable_vault_cluster && var.enable_vault_init && var.enable_vault_ldap && var.enable_vault_ldap_policies ? 1 : 0

  triggers = {
    distribute_id      = length(null_resource.vault_pki_distribute_root) > 0 ? null_resource.vault_pki_distribute_root[0].id : "disabled"
    kv_mount_path      = var.vault_kv_mount_path
    policies_overlay_v = "1"
  }

  depends_on = [null_resource.vault_pki_distribute_root, null_resource.vault_post_init]

  provisioner "local-exec" {
    when        = create
    interpreter = ["pwsh", "-NoProfile", "-Command"]
    command     = <<-PWSH
      $ip          = '${local.vault_1_ip}'
      $user        = '${local.ssh_user}'
      $kvPath      = '${var.vault_kv_mount_path}'
      $keysFileRaw = '${var.vault_init_keys_file}'
      $keysFile    = $ExecutionContext.InvokeCommand.ExpandString($keysFileRaw.Replace('$HOME', $env:USERPROFILE))

      if (-not (Test-Path $keysFile)) {
        throw "[ldap-policies] keys file $keysFile missing -- run 0.D.1 init first"
      }
      $rootToken = (Get-Content $keysFile | ConvertFrom-Json).root_token

      # Each Vault policy as a single HCL document. Inline because we want them
      # version-controlled here (not in tfstate) and sized small enough to read.
      $policyAdmin = @"
# nexus-admin policy -- full sudo, all paths.
# Mapped from AD group nexus-vault-admins via auth/ldap.
path "*" {
  capabilities = ["create", "read", "update", "delete", "list", "sudo"]
}
"@

      $policyOperator = @"
# nexus-operator policy -- everyday workload access.
# Mapped from AD group nexus-vault-operators via auth/ldap.
path "$kvPath/data/*" {
  capabilities = ["create", "read", "update", "delete", "list"]
}
path "$kvPath/metadata/*" {
  capabilities = ["read", "list", "delete"]
}
path "$kvPath/delete/*" {
  capabilities = ["update"]
}
path "$kvPath/undelete/*" {
  capabilities = ["update"]
}
path "$kvPath/destroy/*" {
  capabilities = ["update"]
}
path "pki_int/issue/*" {
  capabilities = ["create", "update"]
}
path "pki_int/roles" {
  capabilities = ["read", "list"]
}
path "pki_int/roles/*" {
  capabilities = ["read"]
}
path "pki/cert/ca" {
  capabilities = ["read"]
}
path "pki_int/cert/ca" {
  capabilities = ["read"]
}
path "auth/token/lookup-self" {
  capabilities = ["read"]
}
path "auth/token/renew-self" {
  capabilities = ["update"]
}
"@

      $policyReader = @"
# nexus-reader policy -- read-only consumer.
# Mapped from AD group nexus-vault-readers via auth/ldap.
path "$kvPath/data/*" {
  capabilities = ["read"]
}
path "$kvPath/metadata/*" {
  capabilities = ["read", "list"]
}
path "pki/cert/ca" {
  capabilities = ["read"]
}
path "pki_int/cert/ca" {
  capabilities = ["read"]
}
path "auth/token/lookup-self" {
  capabilities = ["read"]
}
path "auth/token/renew-self" {
  capabilities = ["update"]
}
"@

      # base64-encode each policy + ship to vault-1 via SSH. The remote bash
      # decodes + writes to a tmpfile + `vault policy write <name> @tmpfile`
      # (using @file syntax avoids shell-escaping the multi-line policy body).
      $policies = @{
        'nexus-admin'    = $policyAdmin
        'nexus-operator' = $policyOperator
        'nexus-reader'   = $policyReader
      }

      foreach ($name in $policies.Keys) {
        $body  = $policies[$name]
        $bytes = [System.Text.UTF8Encoding]::new($false).GetBytes($body)
        $b64   = [Convert]::ToBase64String($bytes)

        $remoteBash = @"
set -euo pipefail
export VAULT_TOKEN='$rootToken'
export VAULT_SKIP_VERIFY=true
export VAULT_ADDR=https://127.0.0.1:8200

TMP=`$(mktemp)
trap 'rm -f "`$TMP"' EXIT
echo '$b64' | base64 -d > "`$TMP"

vault policy write '$name' "`$TMP" >/dev/null
echo "[ldap-policies] wrote policy '$name' (`$(wc -c < "`$TMP") bytes)"
"@
        $bashBytes = [System.Text.UTF8Encoding]::new($false).GetBytes($remoteBash)
        $bashB64   = [Convert]::ToBase64String($bashBytes)
        $output = ssh -o ConnectTimeout=30 -o BatchMode=yes -o StrictHostKeyChecking=no $user@$ip "echo '$bashB64' | base64 -d | bash" 2>&1 | Out-String
        if ($LASTEXITCODE -ne 0) {
          throw "[ldap-policies] vault policy write '$name' failed (rc=$LASTEXITCODE). Output:`n$output"
        }
        Write-Host $output.Trim()
      }

      Write-Host "[ldap-policies] complete -- nexus-admin / nexus-operator / nexus-reader written"
    PWSH
  }
}
