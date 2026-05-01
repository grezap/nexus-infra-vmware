/*
 * vault-provider.tf -- Phase 0.D.4 vault provider config.
 *
 * Authenticates as the `nexus-foundation-reader` AppRole. Role-id +
 * secret-id are sourced from $HOME/.nexus/vault-foundation-approle.json,
 * written by the security env's role-overlay-vault-foundation-approle.tf
 * overlay.
 *
 * Lazy auth: this provider block doesn't make any Vault API call until a
 * resource/data-source actually uses it. With var.enable_vault_kv_creds=false
 * (greenfield default), all the KV data sources have count=0 -- the
 * provider stays inert and the missing/empty JSON file doesn't fail plan.
 *
 * Operator order (greenfield):
 *   1. foundation apply (enable_vault_kv_creds=false default) -- bare
 *      lab + AD plumbing using plaintext defaults.
 *   2. security apply -- brings up Vault + PKI + LDAP + writes
 *      vault-foundation-approle.json + seeds nexus/foundation/*
 *   3. foundation apply -Vars enable_vault_kv_creds=true -- consumers
 *      now read creds via Vault KV instead of variable defaults.
 *
 * Cross-ref: memory/feedback_terraform_partial_apply_destroys_resources.md
 * -- once steady state is reached, var.enable_vault_kv_creds defaults to
 * `true`. The default flips at 0.D.4 close-out.
 */

locals {
  approle_creds_path = pathexpand("${var.vault_foundation_approle_creds_file}")
  approle_creds_raw  = try(file(local.approle_creds_path), "")
  approle_creds      = local.approle_creds_raw != "" ? jsondecode(local.approle_creds_raw) : {}
  approle_role_id    = try(local.approle_creds.role_id, "00000000-0000-0000-0000-000000000000")
  approle_secret_id  = try(local.approle_creds.secret_id, "00000000-0000-0000-0000-000000000000")

  vault_addr           = "https://192.168.70.121:8200"
  vault_ca_bundle_path = pathexpand("${var.vault_ca_bundle_path}")
}

provider "vault" {
  address      = local.vault_addr
  ca_cert_file = local.vault_ca_bundle_path

  # AppRole auth -- the hashicorp/vault provider v4.x exposes AppRole login
  # via the generic `auth_login` block with path = "auth/approle/login".
  # role-id is stable across security env applies; secret-id is regenerated
  # on every security apply (operator order: security -> foundation).
  auth_login {
    path = "auth/approle/login"
    parameters = {
      role_id   = local.approle_role_id
      secret_id = local.approle_secret_id
    }
  }

  # Don't issue a child token for the provider session -- the AppRole-
  # issued token has lookup-self + renew-self only (per nexus-foundation-
  # reader policy), no token/create capability.
  skip_child_token = true
}
