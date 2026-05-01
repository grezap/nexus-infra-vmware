/*
 * data-vault-kv-foundation.tf -- Phase 0.D.4 data sources reading the
 * foundation env's bootstrap creds from Vault KV at nexus/foundation/...
 *
 * All five data sources are gated on var.enable_vault_kv_creds.
 *
 *   var.enable_vault_kv_creds=false (greenfield/default during 0.D.4
 *     development): count=0; data sources don't resolve; consumer
 *     overlays use the variable default plaintext values via ternary.
 *
 *   var.enable_vault_kv_creds=true (steady state from 0.D.4 close-out
 *     onward): count=1; data sources resolve via the AppRole-authenticated
 *     vault provider; consumer overlays read from
 *     data.vault_kv_secret_v2.<name>[0].data["password"].
 *
 * KV-v2 quirk: the resource address is `nexus/foundation/...` (no
 * `data/` segment). The provider handles the KV-v2 path mapping internally;
 * `name = "foundation/dc-nexus/dsrm"` resolves to
 * `nexus/data/foundation/dc-nexus/dsrm` for the underlying API call.
 *
 * Selective ops: the master toggle short-circuits the entire layer; once
 * Vault is up and the foundation-approle creds JSON exists, individual
 * consumer overlays remain togglable independently via their own
 * existing enable_* flags. The data sources themselves are not separately
 * toggleable -- if Vault is the source of truth for bootstrap creds,
 * it's the source of truth for ALL of them, not a mix.
 */

# DSRM password -- consumed by role-overlay-dc-nexus.tf Install-ADDSForest
data "vault_kv_secret_v2" "dc_nexus_dsrm" {
  count = var.enable_vault_kv_creds ? 1 : 0
  mount = var.vault_kv_mount_path
  name  = "foundation/dc-nexus/dsrm"
}

# Local Administrator password -- consumed by role-overlay-dc-nexus.tf
# (set on the built-in Administrator before Install-ADDSForest runs)
data "vault_kv_secret_v2" "dc_nexus_local_administrator" {
  count = var.enable_vault_kv_creds ? 1 : 0
  mount = var.vault_kv_mount_path
  name  = "foundation/dc-nexus/local-administrator"
}

# nexusadmin AD user password -- consumed by:
#   - role-overlay-dc-nexus.tf (post-promotion AD reset)
#   - role-overlay-jumpbox-domainjoin.tf (Add-Computer credential)
data "vault_kv_secret_v2" "identity_nexusadmin" {
  count = var.enable_vault_kv_creds ? 1 : 0
  mount = var.vault_kv_mount_path
  name  = "foundation/identity/nexusadmin"
}

# Local helpers -- the consumer overlays do `local.foundation_creds.dsrm`
# rather than `data.vault_kv_secret_v2.dc_nexus_dsrm[0].data[...]` per call,
# which is illegible. Centralizing here also keeps the ternary logic in
# ONE place (var.enable_vault_kv_creds ? KV : plaintext-default).
locals {
  foundation_creds = {
    dsrm = var.enable_vault_kv_creds ? (
      data.vault_kv_secret_v2.dc_nexus_dsrm[0].data["password"]
    ) : var.dsrm_password

    local_administrator = var.enable_vault_kv_creds ? (
      data.vault_kv_secret_v2.dc_nexus_local_administrator[0].data["password"]
    ) : var.local_administrator_password

    nexusadmin = var.enable_vault_kv_creds ? (
      data.vault_kv_secret_v2.identity_nexusadmin[0].data["password"]
    ) : var.nexusadmin_password
  }
}
