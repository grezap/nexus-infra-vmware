# Changelog

All notable changes to this repository will be documented in this file.
The format is based on [Keep a Changelog 1.1.0](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added — Phase 0.D.5 (2026-05-02 + 2026-05-03)

- **5.1 — `MinPasswordLength=14` + KV→AD bootstrap-creds rotation overlay**
  (foundation env). Foundation env's `dc_password_min_length` default
  12 → 14; seed-mirror defaults bumped to ≥14 chars. New
  `role-overlay-dc-rotate-bootstrap-creds.tf` syncs Administrator +
  nexusadmin pwds from KV → AD whenever the trigger hash changes. DSRM
  rotation NOT in scope of this overlay (Server 2025 ntdsutil pwd
  prompt fails under SSH/redirected stdin -- console-mode read APIs;
  manual ops). New `scripts/rotate-foundation-creds.ps1` operator
  helper. New `role-overlay-dc-nexusadmin-membership.tf` idempotently
  asserts nexusadmin is in Domain Admins + Enterprise Admins (the
  original `dc_nexus_promote` v4 step's chained Add-ADGroupMember
  silently failed at promotion time; this overlay restores the intended
  state using domain Administrator credentials from KV).
  Lessons canonized: `feedback_ntdsutil_dsrm_console_mode_ssh.md`.

- **5.2 — Leaf cert TTL 1y → 90d**. `vault_pki_leaf_ttl` +
  `vault_ldaps_cert_ttl` defaults `8760h → 2160h`. The
  `vault_pki_rotate_listener` overlay v1 → v2 + the `vault_ldaps_cert`
  overlay v4 → v5 gain a 3rd idempotency condition: cert validity span
  (`notAfter - notBefore`) must be within ±10 % of the desired TTL.
  Without this, a 1y cert with 360 days remaining would skip rotation
  forever after the operator dropped TTL to 90 d.
  `scripts/smoke-0.D.2.ps1` `MinLeafTtlDays` default 300 → 30.

- **5.3 — GMSA scaffolding** (foundation env). New
  `role-overlay-dc-gmsa.tf` provisions: (a) KDS root key -- probe-only
  at this phase because `Add-KdsRootKey` on Server 2025 returns
  ERROR_NOT_SUPPORTED under SSH; manual RDP+console required; (b)
  `nexus-gmsa-consumers` AD group in `OU=Groups`; (c) sample GMSA
  `gmsa-nexus-demo$` in `OU=ServiceAccounts` with `PrincipalsAllowed-
  ToRetrieveManagedPassword` set via idempotent `Set-ADServiceAccount`
  post-create (some `New-ADServiceAccount` calls silently drop this
  field when the caller lacks Enterprise Admins). Real GMSA consumers
  (SQL Server svc account, IIS app pools) come in Phase 0.G+.
  Lesson canonized: `feedback_kds_rootkey_server2025_ssh.md`.

- **5.4 — Vault Agent on dc-nexus + nexus-jumpbox**. Two narrow Vault
  policies (`nexus-agent-dc-nexus`, `nexus-agent-nexus-jumpbox`) in
  security env's new `role-overlay-vault-agent-policies.tf`; two
  AppRoles + JSON sidecars in `role-overlay-vault-agent-approles.tf`.
  Foundation env's new `role-overlay-windows-vault-agent.tf` installs
  the `nexus-vault-agent` Windows service on each host: downloads
  vault.exe via nexus-gateway egress, stages role-id+secret-id+CA
  bundle+agent.hcl+template files (NTFS ACL: SYSTEM + Administrators
  only on sensitive files), creates the service via `New-Service`
  (NOT `sc.exe` -- PS argv parsing eats embedded double quotes around
  `binPath`), verifies render within 30 s. Render targets:
  `dc-nexus/dsrm` → `C:\ProgramData\nexus\agent\dsrm.txt` and
  `identity/nexusadmin` → `C:\ProgramData\nexus\agent\nexusadmin-pwd.txt`.

- **5.5 (code-complete; greenfield apply pending) — Transit auto-unseal**.
  New `vault-transit` single-node companion VM (192.168.70.124,
  MAC `00:50:56:3F:00:43`, own subdir `01-foundation/vault-transit/`
  per `feedback_vmware_per_vm_folders.md`). Hosts the transit secrets
  engine + key `nexus-cluster-unseal` consumed by vault-1/2/3 for
  auto-unseal. Packer template change: `vault.service` ExecStart
  points at `/etc/vault.d/` DIRECTORY (was single file) so vault server
  merges `vault.hcl` + `seal-transit.hcl` drop-in delivered post-clone
  by the new `role-overlay-vault-cluster-seal-config.tf`. New
  `role-overlay-vault-transit-bringup.tf` brings up vault-transit
  (init shamir + unseal + enable transit + create key + write policy +
  issue 720h-period token + persist 2 JSON sidecars). Cluster init
  branches on `enable_vault_transit_unseal`: shamir-mode unchanged;
  transit-mode uses `-recovery-shares`/`-recovery-threshold`. Followers
  skip manual unseal in transit-mode (auto-unseal post-raft-join).
  Greenfield bring-up (operator-driven; not yet executed): destroy +
  Packer rebuild + apply with `enable_vault_transit_unseal=true` +
  re-apply foundation env to re-seed KV-dependent state.

- **`scripts/smoke-0.D.5.ps1`** -- chained smoke gate covering all 5
  sub-deliverables (KDS root key WARN-only when missing).

- **Lessons canonized** (memory):
  - `feedback_ntdsutil_dsrm_console_mode_ssh.md`
  - `feedback_kds_rootkey_server2025_ssh.md`
  - `feedback_vmware_per_vm_folders.md`

### Added (Phase 0.D.4 — Foundation cred migration into Vault KV via AppRole — 2026-05-01)

- **`terraform/envs/security/role-overlay-vault-foundation-policy.tf`** — writes
  the `nexus-foundation-reader` Vault policy: read on
  `nexus/data/foundation/*` + `nexus/metadata/foundation/*`, write on
  `nexus/data/foundation/ad/*` only (where the bind/smoke overlays push
  generated creds at create time), token-self lookup/renew. NO sudo.
  Idempotent upsert via `vault policy write`.

- **`terraform/envs/security/role-overlay-vault-foundation-approle.tf`** —
  defines AppRole `nexus-foundation-reader` (`token_policies=
  nexus-foundation-reader`, `token_ttl=1h`, `token_max_ttl=4h`,
  `secret_id_ttl=0`, `secret_id_num_uses=0`, `bind_secret_id=true`).
  Persists role-id (stable) + freshly-generated secret-id to
  `$HOME\.nexus\vault-foundation-approle.json` on the build host (mode
  0600 via icacls). Foundation env's `provider "vault"` reads this
  sidecar at plan/apply time.

- **`terraform/envs/security/role-overlay-vault-foundation-seed.tf`** —
  one-time sticky seed of plaintext defaults + JSON migration into
  `nexus/foundation/{dc-nexus,identity,vault,ad}/*`. Six paths considered
  per apply: `dc-nexus/dsrm`, `dc-nexus/local-administrator`,
  `identity/nexusadmin`, `vault/userpass-nexusadmin`,
  `ad/svc-vault-ldap`, `ad/svc-vault-smoke`. Probe-then-write pattern;
  NEVER overwrites a populated path. Bind + smoke paths source from
  `$HOME\.nexus\vault-ad-bind.json` legacy artifact when present
  (greenfield labs without 0.D.3 yet skip those two paths cleanly).
  Plaintext seed values (dsrm / local-admin / nexusadmin / userpass)
  come from new sensitive variables in the security env's `variables.tf`
  with defaults mirroring the foundation env's defaults.

- **`terraform/envs/foundation/vault-provider.tf`** — `hashicorp/vault` ~> 4
  provider config with `auth_login` block (path `auth/approle/login`,
  parameters `{role_id, secret_id}` from the JSON sidecar via
  `pathexpand("~/...") + try(file(...), "")`). `skip_child_token=true`
  because the AppRole's policy doesn't grant `auth/token/create`. Pinned
  `~> 4.0` because v5 dropped `auth_login_approle` and changed the auth
  shape further (canonized in `feedback_terraform_vault_provider_approle.md`).

- **`terraform/envs/foundation/data-vault-kv-foundation.tf`** — three
  `vault_kv_secret_v2` data sources gated on `enable_vault_kv_creds`:
  `dc_nexus_dsrm`, `dc_nexus_local_administrator`, `identity_nexusadmin`.
  `local.foundation_creds` block centralizes the
  `enable_vault_kv_creds ? KV : variable-default` ternary so consumer
  overlays read `local.foundation_creds.dsrm` etc. instead of
  `var.dsrm_password`.

- **`scripts/smoke-0.D.4.ps1`** — chained smoke gate (0.D.3 → 0.D.2 →
  0.D.1 first, then 0.D.4 layer). Probes: AppRole creds JSON shape,
  `nexus-foundation-reader` policy paths + capabilities, AppRole role-id
  stability vs JSON cache, AppRole login → token-with-policy, six
  `kv get` probes for the seeded paths, AppRole token capability scoping
  (positive + 2 negative — token CAN read `nexus/foundation/dc-nexus/dsrm`,
  CANNOT read `nexus/smoke/canary`, CANNOT write
  `nexus/foundation/dc-nexus/dsrm`).

### Changed (Phase 0.D.4)

- **`terraform/envs/security/role-overlay-vault-ldap-auth.tf` v4 → v5** —
  bindpass now sourced from Vault KV (`nexus/foundation/ad/svc-vault-ldap`)
  with JSON-file fallback for resilience. Adds `seed_id` trigger
  reference + `depends_on null_resource.vault_foundation_seed`. Probe pattern:
  `vault kv get -format=json nexus/foundation/ad/svc-vault-ldap` first;
  fall back to `$HOME\.nexus\vault-ad-bind.json` parse if the KV path is
  empty/unparseable. After 0.D.4 close-out, the JSON file is vestigial
  and can be deleted operationally.

- **`terraform/envs/foundation/main.tf`** — `hashicorp/vault ~> 4.0`
  added to `required_providers`. Comment annotates the v5-not-v4
  pinning rationale.

- **`terraform/envs/foundation/variables.tf`** — adds
  `enable_vault_kv_creds` (default `true` after close-out flip),
  `enable_vault_kv_ad_writeback` (default `true`),
  `vault_kv_mount_path`, `vault_foundation_approle_creds_file`,
  `vault_ca_bundle_path`. Foundation-side defaults use `~/...` form
  (Terraform `pathexpand()` resolves `~`, NOT `$HOME` — security env's
  PowerShell-side defaults using `$HOME/...` resolve via
  `ExecutionContext.InvokeCommand.ExpandString` to the same physical files).

- **`terraform/envs/foundation/role-overlay-dc-nexus.tf`** — Install-ADDSForest
  now consumes `local.foundation_creds.{dsrm, local_administrator, nexusadmin}`
  instead of `var.dsrm_password` / `var.local_administrator_password` /
  `var.nexusadmin_password`.

- **`terraform/envs/foundation/role-overlay-jumpbox-domainjoin.tf`** —
  Add-Computer credential consumes `local.foundation_creds.nexusadmin`.

- **`terraform/envs/foundation/role-overlay-dc-vault-ad-bind.tf` v1 → v2** —
  KV writeback after pwd generation: when the overlay generates a fresh
  random bindpass, it writes to `nexus/foundation/ad/svc-vault-ldap`
  via SSH+`vault kv put` on vault-1 using the root token from
  `$HOME\.nexus\vault-init.json`. Best-effort: WARN+skip when
  vault-init.json is absent (security env not yet applied).

- **`terraform/envs/foundation/role-overlay-dc-vault-smoke-account.tf` v1 → v2** —
  Same KV writeback pattern for `nexus/foundation/ad/svc-vault-smoke`
  (only when the overlay actually generates a fresh pwd, NOT when
  cached pwd is preserved).

- **`scripts/security.ps1`** — `Phase` ValidateSet extended to
  `0.D.4`; default phase is now `0.D.4`. Older phases remain runnable
  explicitly.

- **`README.md`** — phase badge `0.D.3 closed → 0.D.4 closed`. Current-state
  paragraph + repo-layout block call out the new 0.D.4 deliverables
  (Vault-KV-backed bootstrap creds via AppRole; nexus-foundation-reader
  policy + AppRole + KV seed in security env; provider-driven data
  sources in foundation env). Next signal: 0.D.5 (Transit auto-unseal +
  GMSA + Vault Agent).

### Validated (Phase 0.D.4 end-to-end 2026-05-01)

- **Foundation cred migration reproducibility CONFIRMED.**
  `pwsh -File scripts\security.ps1 smoke -Phase 0.D.4` returns ALL GREEN
  through the chain: 24/24 cluster (0.D.1) + ~16 PKI (0.D.2) + ~13 LDAP
  (0.D.3) + ~14 KV-foundation (0.D.4) ≈ 67 checks. After security apply
  + `foundation apply -Vars enable_vault_kv_creds=true`, foundation plan
  reports `No changes` (steady state; data sources resolve via AppRole;
  values match seed). Acceptance criterion (`MASTER-PLAN.md` Phase 0.D
  goal): `vault kv get nexus/foundation/<path>` returns for all 6
  expected paths.

- **One new lesson canonized**:
  `feedback_terraform_vault_provider_approle.md` — `hashicorp/vault`
  provider v4.x has NO `auth_login_approle` typed block; AppRole auth
  goes through the generic `auth_login { path; parameters }` form.
  Pin `~> 4.0`; v5 changes the auth shape further. Caught when
  `terraform validate` rejected the typed block ("Blocks of type
  'auth_login_approle' are not expected here") even though the
  community-canonical shape circulates with that name.

- **Bug fix surfaced + canonized**: PowerShell `Select-String -AllMatches`
  returns null `.Matches` on multi-line strings without trailing
  newline. The AppRole role-id+secret-id parse from the remote echo
  output failed with "Cannot index into a null array" even though the
  remote bash echoed both tokens correctly. Fix: `$out -match
  '(?m)^TOKEN=(.+)$'` is the canonical PS idiom for line-anchored
  multi-line regex extraction. Per
  `feedback_diagnose_before_rewriting.md`, the diagnostic line in the
  apply error output ("Output: FOUNDATION_APPROLE_ROLE_ID=...") proved
  the regex parse was the bug, not the remote provisioning.

### Added (Phase 0.D.3 — Vault AD/LDAP integration + LDAPS pulled forward — 2026-05-01)

- **`terraform/envs/foundation/role-overlay-dc-vault-ad-bind.tf`** — creates
  `svc-vault-ldap` AD service account in `OU=ServiceAccounts`. Generates
  24-char random bindpass on the build host (not the DC — avoids leaking
  pwd via DC syslog/eventlog). Writes `{binddn, bindpass, ldap_url, ...}`
  to `$HOME\.nexus\vault-ad-bind.json` mode 0600 via icacls.
- **`terraform/envs/foundation/role-overlay-dc-vault-ad-bind-acl.tf`** —
  delegates 4 ACEs to `svc-vault-ldap` on `OU=ServiceAccounts` via
  `dsacls /I:S`: Reset Password extended right, Change Password extended
  right, RP/WP `userAccountControl`. Required for `secrets/ldap` rotate
  (without these, `vault write -force ldap/rotate-role/<name>` fails
  `LDAP Result Code 50 INSUFF_ACCESS_RIGHTS`).
- **`terraform/envs/foundation/role-overlay-dc-vault-groups.tf`** — creates
  3 AD security groups in `OU=Groups`: `nexus-vault-admins`,
  `nexus-vault-operators`, `nexus-vault-readers`. Adds `nexusadmin` to
  the admins group.
- **`terraform/envs/foundation/role-overlay-dc-vault-demo-rotated-account.tf`** —
  creates `svc-demo-rotated` (target of Vault `secrets/ldap` static
  rotate-role) with random initial pwd; Vault rotates on first apply.
- **`terraform/envs/foundation/role-overlay-dc-vault-smoke-account.tf`** —
  creates `svc-vault-smoke` for the 0.D.3 end-to-end LDAP login probe;
  enrolls in `nexus-vault-readers`. Plaintext pwd in vault-ad-bind.json
  on the build host.
- **`terraform/envs/security/role-overlay-vault-ldaps-cert.tf`** — issues
  a leaf cert from `pki_int/issue/vault-server` for
  `dc-nexus.nexus.lab`, builds PFX via openssl on vault-1, scp's to
  dc-nexus, installs in `LocalMachine\My`, restarts NTDS. Gets AD
  serving LDAPS on TCP/636.
- **`terraform/envs/security/role-overlay-vault-ldap-policies.tf`** —
  writes Vault policies: `nexus-admin` (full sudo), `nexus-operator`
  (read/write `nexus/*` + cert issuance, no sudo), `nexus-reader`
  (read-only `nexus/*`).
- **`terraform/envs/security/role-overlay-vault-ldap-auth.tf`** —
  enables `auth/ldap`, configures with LDAPS URL + binddn (from
  vault-ad-bind.json) + bindpass + userdn (`DC=nexus,DC=lab`) +
  userattr (`samAccountName`) + **`upndomain=""`** (Vault issue #27276)
  + userfilter (`(&(objectClass=user)(sAMAccountName={{.Username}}))`)
  + `certificate=@<root-CA-bundle>` for LDAPS chain validation.
  Maps AD groups to Vault policies: admins → `nexus-admin`, operators
  → `nexus-operator`, readers → `nexus-reader`.
- **`terraform/envs/security/role-overlay-vault-ldap-secret-engine.tf`** —
  enables `secrets/ldap` (`schema=ad`,
  `password_policy=nexus-ad-rotated`,
  `skip_static_role_import_rotation=true`). Replaces deprecated `ad`
  engine.
- **`terraform/envs/security/role-overlay-vault-ldap-rotate-role.tf`** —
  defines static rotate-role for `svc-demo-rotated` with
  `rotation_period=24h`. `skip_import_rotation=true` + explicit
  `vault write -force ldap/rotate-role/svc-demo-rotated` to take
  ownership without trying to bind as the target with an unknown pwd.
- **`scripts/smoke-0.D.3.ps1`** — chained smoke gate covering LDAPS
  reachability, auth/ldap config, group → policy mappings, end-to-end
  smoke login probe (svc-vault-smoke → token with `nexus-reader`),
  secrets/ldap config, static-role + static-cred reads.

### Validated (Phase 0.D.3 reproducibility 2026-05-01)

- 9 lesson commits to land 0.D.3 fully green (LDAPS forward-pull + 6
  AD-side gotchas). Final commit chain: `662ae43` → `3691f35` →
  `93695df` → `d2ed166` → `28826f1` → `a4b0ef6` → `8e1cc53` → `30df59d`
  → `d0a61a0`. Memory entries:
  `feedback_diagnose_before_rewriting.md`,
  `feedback_vault_ldap_static_role_skip_import.md`,
  `feedback_vault_ldap_ad_acl_delegation.md`,
  `feedback_vault_ldap_ad_upn_bind.md` (rewritten — original
  "always set upndomain" advice was wrong),
  `feedback_terraform_partial_apply_destroys_resources.md`,
  `feedback_systemd_link_precedence_multi_nic.md`.
- Two structural fixes committed during recovery: foundation
  `enable_vault_dhcp_reservations` default flipped false → true (commit
  `30df59d`) so partial applies don't destroy reservations;
  `vault-firstboot.sh` rewrites `10-nic0.link` with MAC-specific match
  (commit `d0a61a0`) so nic1 survives reboot.

### Added (Phase 0.D.2 — Vault PKI overlay — 2026-05-01)

- **`terraform/envs/security/role-overlay-vault-pki-mount.tf`** —
  mounts `pki/` and `pki_int/` secrets engines (idempotent via probe).
- **`terraform/envs/security/role-overlay-vault-pki-root.tf`** —
  generates internal root CA at `pki/` (`CN=NexusPlatform Root CA`,
  TTL 10 y).
- **`terraform/envs/security/role-overlay-vault-pki-intermediate.tf`** —
  generates intermediate CSR at `pki_int/`, signs via root, sets signed
  cert (`CN=NexusPlatform Intermediate CA`, TTL 5 y).
- **`terraform/envs/security/role-overlay-vault-pki-roles.tf`** —
  defines `vault-server` PKI role (`allow_ip_sans=true`,
  `allowed_domains = nexus.lab + lab + localhost`,
  `allow_subdomains=true`, leaf TTL 1 y).
- **`terraform/envs/security/role-overlay-vault-pki-rotate.tf`** —
  per-node listener cert reissue with atomic-swap into
  `/etc/vault.d/tls/` + `systemctl reload vault.service` (SIGHUP,
  zero-downtime). Idempotent via current-cert issuer + days-remaining
  probe (skips if already PKI-issued + > 30 d remaining).
- **`terraform/envs/security/role-overlay-vault-pki-distribute.tf`** —
  writes root CA bundle to build host (`$HOME\.nexus\vault-ca-bundle.crt`,
  mode 0600 via icacls) + installs on each Vault node's
  `/usr/local/share/ca-certificates/` + runs `update-ca-certificates`.
  Hash-compare idempotent.
- **`terraform/envs/security/role-overlay-vault-pki-cleanup-hack.tf`** —
  removes the per-clone `/usr/local/share/ca-certificates/vault-leader.crt`
  residue from followers (the 0.D.1 cold-start hack — distribute step
  replaces it with the shared root CA).
- **`scripts/smoke-0.D.2.ps1`** — chained PKI smoke gate (0.D.1 first,
  then PKI checks): mounts present, CA hierarchy + chain validates,
  PKI role exists, per-node listener cert (issuer + SAN coverage +
  days-remaining), build-host CA bundle hash match, build-host TLS
  validation via `VAULT_CACERT` (no skip-verify), legacy 0.D.1 trust
  shuffle cleaned up.

### Validated (Phase 0.D.2 reproducibility 2026-05-01)

- Three probe bugs surfaced in first cycle (locale-sensitive datetime
  parsing on openssl output; .NET `SslStream` custom-root TLS callback
  missing intermediate `ExtraStore` relay; sudo stderr breaking
  strict-equality probes) — all canonized in
  `feedback_smoke_gate_probe_robustness.md`.

### Validated (Phase 0.D.1 unattended end-to-end 2026-04-30)

- **3-node Vault Raft cluster reproducibility CONFIRMED**. `pwsh -File scripts\security.ps1 cycle`
  returns 24/24 smoke checks GREEN: 6 build-host reachability probes (SSH/22 +
  Vault API/8200 to all 3 nodes), 3 canonical IPs (VMnet10 backplane on nic1),
  6 vault.service health (active + initialized + unsealed × 3), 3 raft topology
  (3 peers, 1 leader, vault-1 is leader), 6 KV-v2 + auth (mount, userpass,
  user, approle, role, smoke secret), 2 cross-node read consistency from both
  followers. Wall-clock for cluster apply (post-template-build): ~5 min.

  **Iteration tax to land 0.D.1 fully green** -- counted from cluster
  scaffold through smoke green:

  | Issue | Commit | Cycle cost |
  |---|---|---|
  | hostname=vault baked at template; vmrun -cloneName doesn't propagate | `661cced` | 1 |
  | NIC enumeration order non-deterministic with two en* | `d4c2527` | 1 |
  | `$ip:` PowerShell scope-qualifier collision with TF heredoc | `98e7132` | 1 |
  | dual-NIC array splat -> hashtable splat | `f3f443a` | 1 |
  | `-leader-tls-skip-verify` flag doesn't exist | `b87970c` | 1 |
  | `-leader-ca-cert` flag doesn't propagate cleanly in 1.18 -- system trust store instead | `91b34a6` | 1 |
  | post-join unseal needs 15s settle + verify retry | `0e3e0e2` | 1 |
  | reintroduced `$threshold:` scope-qualifier bug on a new log line | `2e1bb75` | 1 |
  | Plus pre-Vault foundation regression (gateway powered off) | n/a | 1 |

  Total: ~9 cluster cycles. Memory entry `feedback_terraform_heredoc_powershell.md`
  saved to canonize the `$var:` escape rules + a mandatory pre-commit
  grep checklist so this regression doesn't keep happening.

  **Carry-forward lessons** (now memory canon -- cited inline in the
  overlay code where applied):

  - **NIC enumeration**: systemd's `OriginalName=en*` rule is non-deterministic
    with two en* interfaces. `vault-firstboot.sh` discriminates by MAC OUI
    byte 5 (`:00:` = primary, `:01:` = secondary) and remediates kernel
    naming via `ip link set <if> down; ip link set <if> name nic0` if the
    wrong NIC got renamed. Same logic applies to the secondary rename to
    nic1 -- bring DOWN before rename or it silently fails.
  - **Hostname discrimination**: `vmrun clone -cloneName=vault-1` only
    changes the VMware Workstation library display name; the guest's
    `/etc/hostname` stays at the Packer template name (`vault`).
    Discriminate clones by their DHCP-acquired VMnet11 IP (canonical via
    `dhcp-host` MAC reservation on nexus-gateway), then `hostnamectl
    set-hostname` to set the canonical name.
  - **Vault raft join across self-signed certs**: `-leader-ca-cert=<path>`
    flag empirically does NOT propagate CLI -> server reliably in
    Vault 1.18 (or our PowerShell-CRLF + heredoc transit broke it
    silently). System trust store works: SCP leader's cert to follower at
    `/usr/local/share/ca-certificates/vault-leader.crt`, run
    `update-ca-certificates`, then run `vault operator raft join` with
    NO leader-cert flags. Go's HTTPS client picks up system trust by
    default. Pre-PKI hack; 0.D.2 PKI replaces it with a shared CA.
  - **Post-raft-join propagation**: the freshly-joined follower needs
    ~15s to pull the seal config from the leader; 5s wasn't enough.
    Plus the seal-state transition after final unseal is async -- verify
    via 6× retry @ 5s each instead of single immediate check.

### Added (Phase 0.D.1 — 3-node Vault Raft cluster)

- **`packer/vault/`** — new Packer template for Vault cluster nodes. Debian 13
  base (same ISO + preseed pattern as deb13), Vault binary version-pinned via
  `var.vault_version` (default `1.18.4`), systemd units for `vault.service`
  and `vault-firstboot.service`, base config TEMPLATE rendered per-clone at
  first-boot via `vault-firstboot.sh`. Self-signed bootstrap TLS regenerated
  per-clone with the clone's actual hostname + IPs in SAN. Phase 0.D.2 will
  reissue from Vault PKI. Strips ethernet entries (`vmx_remove_ethernet_interfaces
  = true`) so Terraform's modules/vm clones with the canonical dual-NIC
  config (VMnet11 service + VMnet10 backplane).

- **`packer/vault/ansible/roles/vault_node/`** — per-template Ansible role
  installing the Vault binary (download + sha256 verify + install with
  `cap_ipc_lock=+ep`), creating vault user + group, deploying systemd units,
  installing the firstboot script. Runs after the four shared `nexus_*` roles
  (identity, network, firewall, observability) inside the vault Packer build.

- **`terraform/envs/security/`** — new env, 3 `module "vault_N"` blocks
  composed via the now-dual-NIC-capable `terraform/modules/vm/`. Per
  `nexus-platform-plan/docs/infra/vms.yaml` lines 55-57: VMnet11 IPs
  `.121/.122/.123`, VMnet10 IPs `192.168.10.121/.122/.123`, foundation tier
  directory (`H:\VMS\NexusPlatform\01-foundation\vault-N\`), MAC scheme
  `00:50:56:3F:00:40-42` (primary, VMnet11) and `00:50:56:3F:01:40-42`
  (secondary, VMnet10).

- **`terraform/envs/security/role-overlay-vault-cluster.tf`** — 4 sequential
  null_resources orchestrating cluster bring-up:
  1. `vault_ready_probe` — SSH echo probe + `vault.service` health check on
     all 3 nodes (echoes the canonical SSH transit pattern from Phase 0.C
     -- echo probe + retry loop)
  2. `vault_init_leader` — `vault operator init` on vault-1 (5 keys, threshold
     3 -- both var-overridable), persists JSON to `$HOME/.nexus/vault-init.json`
     on the build host, unseals leader. Idempotent via `vault status` JSON
     parse: skip init if already initialized + unsealed; unseal-from-keys if
     initialized + sealed; full init if uninitialized.
  3. `vault_join_followers` — vault-2 and vault-3: `vault operator raft join`
     to vault-1's API addr, then unseal with same keys. Verifies cluster has
     exactly 3 peers via `vault operator raft list-peers`.
  4. `vault_post_init` — KV-v2 mounted at `nexus/` (per MASTER-PLAN line 145),
     userpass auth enabled with `nexusadmin` operator user, AppRole auth
     enabled with `nexus-bootstrap` role, smoke secret written to
     `nexus/smoke/canary`. All idempotent via state probes (`vault secrets
     list`, `vault auth list`).

- **`terraform/envs/foundation/role-overlay-gateway-vault-reservations.tf`** —
  dnsmasq `dhcp-host` reservations on nexus-gateway pinning vault-1/2/3 MACs
  to canonical VMnet11 IPs `.121/.122/.123`. Works WITHOUT extending the
  dynamic DHCP pool (`.200-.250`) because dnsmasq honors `dhcp-host` entries
  regardless of `dhcp-range`. Toggleable via `var.enable_vault_dhcp_reservations`
  (default `false`); Vault deploys require `pwsh -File scripts\foundation.ps1
  apply -Vars enable_vault_dhcp_reservations=true` BEFORE bringing up the
  security env. Mirrors the Phase 0.C.2 `gateway-dns` overlay shape.

- **`terraform/modules/vm/` extended for dual-NIC.** Optional `var.vnet_secondary`
  + `var.mac_secondary` parameters, both default `null` (single-NIC mode --
  unchanged for foundation env's existing dc-nexus/jumpbox callers). When
  both are non-null, the post-clone `configure-vm-nic.ps1` writes ethernet1
  alongside ethernet0. README documents both modes with examples; `cpus` and
  `memory_mb` inputs remain reserved-for-future. Limitation note: dual-NIC
  mode does NOT configure the secondary NIC's IP at the OS level -- the
  consuming Packer template owns that (vault's first-boot script
  reads /etc/hostname and maps to canonical VMnet10 IP).

- **`scripts/configure-vm-nic.ps1`** updated with optional `-SecondaryVnet` /
  `-SecondaryMac` parameters. Backward compatible: existing single-NIC callers
  pass nothing and get the same single-NIC output. XOR validation ensures
  both secondary args are provided together or neither.

- **`scripts/smoke-0.D.1.ps1`** — Phase 0.D.1 smoke gate. ~24 checks:
  build-host reachability (SSH/22 + Vault API/8200 to all 3 nodes, runs
  first), canonical IPs (VMnet10 IPs configured on nic1), `vault.service`
  health (active + initialized + unsealed on all nodes), raft cluster
  topology (exactly 3 peers, exactly 1 leader, vault-1 is the leader
  post-init), KV-v2 mount + auth methods (userpass with nexusadmin user,
  approle with nexus-bootstrap role), smoke secret readability from leader
  AND both followers (cross-node consistency). Parameterized; exits non-zero
  on any failure. Requires `$HOME/.nexus/vault-init.json` for the
  root-token-required checks.

- **`scripts/security.ps1`** — pwsh-native operator wrapper for envs/security/,
  same shape as `scripts/foundation.ps1`. Six verbs: `apply`, `destroy`,
  `smoke`, `cycle` (destroy → apply → smoke), `plan`, `validate`. Forwards
  `-Vars` to terraform `-var` flags and `-SmokeArgs` to the smoke script.

- **CI matrix extension** — `packer-validate.yml` gains `vault` template +
  `envs/security` env entries + `packer/vault/ansible/` for ansible-lint.

- **Memory entries (saved 2026-04-29)** — three feedback rules canonized
  alongside this commit:
  - `feedback_master_plan_authority.md` — `nexus-platform-plan/MASTER-PLAN.md`
    + `docs/infra/vms.yaml` + ADRs are authoritative; deviations must be
    enhancements or bug fixes only, never convenience; every phase summary
    needs a Canon-mapping table citing source lines.
  - `feedback_prefer_less_memory.md` — default to the smallest RAM that
    runs the workload smoothly; build-host RAM is finite; when canon
    over-specs RAM, log deviation + update vms.yaml to match observed-
    sufficient sizing.
  - (already saved Phase 0.C.4) `feedback_lab_host_reachability.md` and
    `feedback_build_host_pwsh_native.md` continue to apply.

- **Documentation** — handbook §1g (Phase 0.D.1) covers Canon mapping,
  files, operator order (mandatory -- foundation reservations BEFORE security
  apply), selective ops, build-host reachability, initial credentials,
  operating Vault from the build host, scope-out list (0.D.2-5), and RAM
  budget arithmetic. `packer/vault/README.md` is the per-template reference
  with all Canon citations + role file map.

- **Approved deviation logged**: Vault VM RAM = 2 GB (canon vms.yaml says
  4 GB). Approved 2026-04-29 per `feedback_prefer_less_memory.md`. vms.yaml
  to be updated post-0.D.1 to match observed-sufficient sizing.

### Fixed

- **Foundation tier directory canon-compliance.** Foundation env's
  `vm_output_dir_root` default was `H:/VMS/NexusPlatform/10-core/` but
  `nexus-platform-plan/docs/infra/vms.yaml` lines 51-57 specify the canonical
  foundation tier as `01-foundation/`. Corrected the default to
  `H:/VMS/NexusPlatform/01-foundation/` and updated handbook §1c references
  (per `memory/feedback_master_plan_authority.md` -- canon is authoritative,
  deviations must be enhancements or bug fixes, not convenience).

  **Operator action required:** to migrate dc-nexus + jumpbox to the new path,
  run a destroy-then-apply cycle:
  ```powershell
  pwsh -File scripts\foundation.ps1 cycle
  ```
  This destroys the VMs at `10-core/`, re-clones at `01-foundation/`, and
  re-runs the smoke gate. ~17-18 min wall-clock.

### Added

- **Phase 0.C.4 — AD DS hardening overlays on `dc-nexus`.** Four independent
  role-overlay files under `terraform/envs/foundation/`, each with its own
  `enable_dc_*` toggle (default `true`) and independently `-target`-able per
  the selective-provisioning rule in `memory/feedback_selective_provisioning.md`:

  - `role-overlay-dc-ous.tf` — creates OU=Servers, OU=Workstations,
    OU=ServiceAccounts, OU=Groups under DC=nexus,DC=lab and moves
    `nexus-jumpbox` from CN=Computers into OU=Servers. dc-nexus stays at the
    built-in CN=Domain Controllers (Microsoft hard rule). Idempotent
    (`Get-ADOrganizationalUnit` probe per OU; jumpbox-move is a no-op when
    `enable_jumpbox_domain_join=false` or when already in OU=Servers).

  - `role-overlay-dc-password-policy.tf` — applies the Default Domain Password
    + Lockout Policy via `Set-ADDefaultDomainPasswordPolicy`. NIST
    SP 800-63B-aligned defaults: `MinPasswordLength=12`, `LockoutThreshold=5`
    (≥5 enforced via `validation` block per `memory/feedback_lab_host_reachability.md`
    so an automated probe loop can't lock out `nexusadmin` and break SSH/RDP),
    `LockoutDuration=15min`, `MaxPasswordAge=0` (never expire — modern NIST
    stance pre-Vault), `MinPasswordAge=0`, `PasswordHistoryCount=24`. Each
    field is its own variable; idempotent (compare-then-set, no-op when state
    matches).

  - `role-overlay-dc-reverse-dns.tf` — adds AD-integrated reverse DNS zone
    `70.168.192.in-addr.arpa.` (VMnet11 only, `192.168.70.0/24`) + PTR
    records for dc-nexus (.240) and nexus-jumpbox (.241). `DynamicUpdate=Secure`,
    `ReplicationScope=Domain`. VMnet10 / 10.0.70.0/24 (build-host LAN) is
    intentionally NOT included — not AD-relevant. Idempotent (`Get-DnsServerZone`
    + `Get-DnsServerResourceRecord` probes).

  - `role-overlay-dc-time.tf` — configures dc-nexus (the PDC) as authoritative
    time source for nexus.lab via `w32tm /config /reliable:YES`. Default peer
    list (`var.dc_time_external_peers`): `time.cloudflare.com,time.nist.gov,
    pool.ntp.org,time.windows.com` — four mixed-provider public NTP peers,
    each with `0x8` SpecialInterval flag per Microsoft KB 939322. Domain
    members inherit time from the PDC; no client-side configuration needed.
    Idempotent (parses `w32tm /query /configuration` for `NtpServer` + `Type`,
    reconfigures only if either differs).

  All four overlays:
  - Run AD-authenticated cmdlets **on the DC** (`192.168.70.240`), per the
    last entry in `memory/feedback_addsforest_post_promotion.md` — SSH to a
    domain member runs as the local SAM `nexusadmin` with no AD context.
  - Follow the canonical SSH transit pattern from
    `memory/feedback_windows_ssh_automation.md`: SSH echo probe + base64-encoded
    multi-token PowerShell + retry loop with stderr capture.
  - Add a corresponding `enable_dc_*` variable to `variables.tf` (with
    validation blocks where reachability is at stake), and a
    `hardening_state` block to the `domain_info` output so consumers can
    inspect which overlays are active and what values were applied.
  - Do NOT touch Windows Firewall, sshd_config, or RDP settings — preserving
    the build-host reachability invariant from
    `memory/feedback_lab_host_reachability.md` (every fleet VM stays
    SSH/22 + RDP/3389 reachable from `10.0.70.0/24`).

  Total incremental wall-clock: ~30-60 sec on top of the existing 0.C.3 cycle.

  **Deferred to later phases (mentioned for context, not built now):**
  - Second DC for replication HA → Phase 0.C.5 / Phase 0.G
  - Service accounts (`svc-postgres`, `svc-mongo`, …) → Phase 0.C.6+
  - GMSA / managed service accounts → Phase 0.D (Vault rotation)
  - Login banner GPO → cosmetic; fold in later
  - `OU=Users` → premature; no human users beyond `nexusadmin` yet
  - GPO baselines beyond Default Domain Policy (CIS, AppLocker, Defender ASR,
    Windows Firewall lockdown) → Phase 0.C.5+ with the build-host
    reachability carve-out baked in
  - `MinPasswordLength=14` tightening → Phase 0.D when Vault generates creds
  - Pivoting NTP source to gateway-as-NTP-server → separate ticket post-0.C.4

  New variables (all defaults sensible — `terraform apply` works with no
  `-var` overrides):
  - `enable_dc_ous` (bool, default true)
  - `enable_dc_password_policy` (bool, default true)
  - `dc_password_min_length` (number, default 12, validated 8-128)
  - `dc_lockout_threshold` (number, default 5, validated >=5)
  - `dc_lockout_duration_minutes` (number, default 15)
  - `dc_max_password_age_days` (number, default 0)
  - `dc_min_password_age_days` (number, default 0)
  - `dc_password_history_count` (number, default 24)
  - `enable_dc_reverse_dns` (bool, default true)
  - `enable_dc_time_authoritative` (bool, default true)
  - `dc_time_external_peers` (string, default = 4 public NTP peers)

  Documentation: new §1f in `docs/handbook.md` covers files, selective ops
  examples, smoke gate, build-host reachability verification, timing, and
  scope-out list. The `next_step` Terraform output also exposes per-overlay
  smoke commands.

- **`scripts/smoke-0.C.4.ps1` + `make foundation-smoke`** — automated smoke
  gate covering all four 0.C.4 hardening overlays (24 individual checks)
  plus the build-host reachability invariant (SSH/22 + RDP/3389 from the
  build host to dc-nexus and nexus-jumpbox). Parameterized with sensible
  defaults; exits non-zero on any failure so it can wire into CI later.
  Carry-forward sanity (DC's forest still healthy + jumpbox still
  domain-joined + Netlogon still live) is included so a hardening apply
  that regresses 0.C.2/0.C.3 surfaces in the same gate.

- **`scripts/foundation.ps1` operator wrapper** — pwsh-native equivalent of
  the bash-shaped `make foundation-*` targets, since GNU make is not
  installed on the canonical Windows pwsh build host (see
  `memory/feedback_build_host_pwsh_native.md`). Six verbs:
  `apply` / `destroy` / `smoke` / `cycle` (destroy → apply → smoke chained,
  halts on first failure) / `plan` / `validate`. Forwards `-Vars
  key=value,key=value` to terraform's `-var` flags; forwards `-SmokeArgs
  @{...}` to the smoke script. Resolves repo root from `$PSScriptRoot` so it
  works from any cwd. Validated end-to-end against the Phase 0.C.4 cycle:
  `pwsh -File scripts\foundation.ps1 cycle` reproduces the ~17-18 min
  destroy → apply → 28-check smoke flow that proved 0.C.4 reproducibility.

  Documentation: handbook §1c now leads with the pwsh wrapper as canonical;
  §1f's smoke gate also references the wrapper. Makefile gains a top-of-file
  comment + help-block notice pointing Windows operators at the wrapper. The
  Makefile targets remain functional in Linux/WSL/CI contexts.

### Changed

- **Phase 0.C.3 unattended end-to-end validated 2026-04-29** — Five iterations
  needed to peel off silent failure modes; final state validated via clean
  `terraform destroy -auto-approve` + `terraform apply -auto-approve` cycle
  in ~16 min from cold-clone to domain-joined fleet.

  - `dc_nexus_rename` `rename_overlay_v` 1→4:
    - v2: base64-encoded transit (cmd.exe quoting was mangling the rename
      command; Rename-Computer never queued, NV Hostname stayed at WIN-XXX)
    - v3: pre-flight `Test-NetConnection -Port 22` wait (vmrun start returns
      in 2 sec but Windows boot+sysprep+sshd takes 1-3 min)
    - v4: SSH **echo probe** (not Test-NetConnection) + retry loop on the
      actual rename SSH (port-22-open ≠ sshd-ready; sshd flakes for ~30-60s
      after the listening socket appears)

  - `jumpbox_domain_join` `domainjoin_v` 1→5:
    - v2: dropped inline `Restart-Service sshd` before Add-Computer (it was
      killing the SSH session running our script; Add-Computer never fired)
    - v3: hostname `nexus-admin-jumpbox` → `nexus-jumpbox` (the original
      19-char name busted the NetBIOS 15-char limit, silently rejected)
    - v4: pre-flight Test-NetConnection (same as rename v3)
    - v5: SSH echo probe + retry loop (same as rename v4)

  - `gateway_dns_forward` `dns_overlay_v` 2→7:
    - v3-v6 chased a DNSSEC theory (domain-insecure, dnssec-check-unsigned)
      that turned out to be irrelevant; v4 even broke gateway DNS by feeding
      dnsmasq a directive its build doesn't recognize
    - v7: `rebind-domain-ok=/<domain>/` was the actual fix. The gateway's
      `stop-dns-rebind` was blocking responses where our internal nexus.lab
      resolved to RFC1918 192.168.70.240 (the journal entry "possible
      DNS-rebind attack detected" was the real signal). Per-zone allowlist;
      keeps stop-dns-rebind active everywhere else.

  - `jumpbox_verify` Get-ADComputer fix: query AD from the DC instead of
    from the (now-domain-joined) jumpbox. SSH-to-jumpbox runs as the LOCAL
    nexusadmin SAM account; that session has no AD-authenticated context,
    so Get-ADComputer fails with "Unable to contact the server" even though
    the DC's ADWS is healthy. Centralizing AD queries on the DC sidesteps
    the credential-plumbing problem.

  - Hostname rename across all files: `nexus-admin-jumpbox` →
    `nexus-jumpbox` (NetBIOS limit). Affects main.tf, outputs.tf,
    variables.tf, both role-overlay files, Makefile, handbook.md.

### Added

- **`memory/feedback_windows_ssh_automation.md`** (new) — Five canonical
  structural rules for any Terraform local-exec automation that drives
  Windows VMs through OpenSSH. Lessons applicable to all future overlays
  (data env, ml env, etc. that touch Windows boxes), not just NexusPlatform's
  AD DS work.

- `memory/feedback_addsforest_post_promotion.md` (extended) — added two
  new sections: DNS-rebind blocks internal AD zones (use rebind-domain-ok),
  and Get-ADComputer requires AD-authenticated session (run from DC).

- **Phase 0.C.3 — `nexus-jumpbox` domain-join to `nexus.lab`** —
  `terraform/envs/foundation/role-overlay-jumpbox-domainjoin.tf` lays
  three sequential top-level `null_resource`s that join the jumpbox
  ws2025-desktop clone to the `nexus.lab` domain (Phase 0.C.2's forest):
  `jumpbox_domain_join` (sshd_config patch + `Add-Computer -NewName -Restart`
  in one base64-encoded SSH command) → `jumpbox_wait_rejoined` (poll
  PartOfDomain over SSH for ~3-7 min) → `jumpbox_verify` (emit
  Win32_ComputerSystem state + nltest /dsgetdc + Get-ADComputer).
  After this overlay completes, Netlogon is auto-started on the jumpbox
  and the cosmetic `nltest 1355` from §1d.6 disappears.
  New variable `enable_jumpbox_domain_join` (bool, default true);
  reuses existing `nexusadmin_password` for the join credential
  (`NEXUS\nexusadmin`).
  Implicitly depends on `enable_dc_promotion=true` via `depends_on
  null_resource.dc_nexus_verify`.
  Idempotent: skips if jumpbox is already joined to the domain.

- `outputs.tf` — new `jumpbox_info` block (enabled, hostname, fqdn, ip,
  domain_member). `next_step` HEREDOC extended with jumpbox smoke-gate
  commands.

- `docs/handbook.md` §1e (NEW) — full Phase 0.C.3 reproduce flow:
  per-step description, selective-ops cheatsheet, smoke gate, scope
  deferrals (OUs/GPOs = 0.C.4+, removing the local nexusadmin = 0.D).
  §1d.3 cleaned up (jumpbox join no longer "NOT in scope" — moved
  to 0.C.3).
  §5 directory map + §6 phase table updated to reflect 0.C.2 ✅
  and 0.C.3 🔄.

### Changed

- **Phase 0.C.2 promote step `v3` -> `v4`** — bakes four post-promotion
  remediation steps into the encoded command so fresh deploys land a
  working DC zero-touch (no manual recovery needed). Steps added (in
  order, all between Install-ADDSForest and the post-install reboot):
  (a) `Set-ADAccountPassword nexusadmin -Reset` — AD DS migrates the
      local `nexusadmin` into the AD database but blanks its password;
  (b) `Add-ADGroupMember 'Domain Admins' -Members nexusadmin` — migrated
      users land in `Domain Users` only, not Domain Admins;
  (c) Comment out `AllowUsers nexusadmin` line in `C:\ProgramData\ssh\sshd_config`
      — Win32-OpenSSH receives the username as `nexus\nexusadmin`
      post-promotion and doesn't match the bare-username AllowUsers; trust
      = pubkey + Administrators group is sufficient on a DC;
  (d) `Restart-Service sshd -Force` to load the new sshd_config.
  New variable `nexusadmin_password` (sensitive, default `NexusPackerBuild!1`,
  Vault-rotated in Phase 0.D).

- **Phase 0.C.2 gateway-dns step `dns_overlay_v` `1` -> `2`** —
  changes `systemctl reload dnsmasq` to `systemctl restart dnsmasq`.
  SIGHUP re-reads `/etc/dnsmasq.d/` files but does NOT flush the DNS
  cache; cached NXDOMAIN responses (from queries that hit the public
  upstream BEFORE the forward zone was added) survived the reload and
  kept being served. `restart` drops the cache as part of process
  restart, so the forward is live immediately.

### Added

- **`memory/feedback_addsforest_post_promotion.md`** (new entry) —
  canonical remediation pattern for any future automated AD DS
  promotion: four post-promotion steps + base64-encoded transit +
  smoke-gate guidance for workgroup peers (`nltest /dsgetdc` is
  unreliable from workgroup boxes; use Resolve-DnsName + port probes
  + DC-side nltest instead).

- **Phase 0.C.2 — AD DS role overlay on `dc-nexus`** —
  `terraform/envs/foundation/role-overlay-dc-nexus.tf` lays five
  sequential top-level `null_resource`s that promote the bare
  `ws2025-desktop` clone into a real domain controller for `nexus.lab`:
  rename → wait_renamed → promote (`Install-ADDSForest`) → wait_promoted
  → verify. Top-level (not nested in `module.dc_nexus`) so each step is
  independently `-target`-able for iteration.
  `terraform/envs/foundation/role-overlay-gateway-dns.tf` writes
  `/etc/dnsmasq.d/foundation-nexus-lab.conf` to `nexus-gateway`
  at apply-time + reloads dnsmasq, with a destroy-time provisioner
  that cleanly removes the conf. Env-scoped so the 0.B.1
  `nexus-gateway` template stays frozen.
  Toggles: `enable_dc_promotion` (bool, default true) +
  `enable_gateway_dns_forward` (bool, default true) gate the entire
  overlay surface, per `memory/feedback_selective_provisioning.md`.
  New vars: `ad_domain` (default `nexus.lab`),
  `ad_netbios` (default `NEXUS`, validated <=15 chars),
  `dsrm_password` (sensitive, default `NexusDSRM!1` pre-Phase-0.D),
  `dc_promotion_timeout_minutes` (default 15).
  All overlay steps are idempotent on re-apply.
- `outputs.tf` — new `domain_info` block (forest name, NetBIOS,
  dc_fqdn, dns_forward_active). `next_step` HEREDOC extended with
  AD DS smoke-gate commands + selective-ops examples
  (`-target=`, `-var enable_*=false`, `terraform taint`).
- `docs/handbook.md` §1d (NEW) — full Phase 0.C.2 reproduce flow:
  file inventory, selective-ops cheatsheet, smoke gate commands,
  per-step timing expectations, idempotency notes, scope deferrals
  (jumpbox domain-join, OUs/GPOs, second DC, Vault rotation).
  §1c.4 + §6 phase table updated.
  §5 directory map expanded with the new `envs/foundation/` files.

- **Phase 0.C.1 — `terraform/envs/foundation/`** — first env composing
  multiple `modules/vm/` instances. Lands two `ws2025-desktop` clones on
  VMnet11: `dc-nexus` (MAC `00:50:56:3F:00:25`) and `nexus-jumpbox`
  (MAC `00:50:56:3F:00:26`), both under tier path `H:/VMS/NexusPlatform/10-core/`.
  Shape-template for the remaining 0.C envs (`data`, `ml`, `saas`,
  `microservices`, `demo-minimal`). AD DS promotion + jumpbox tooling
  reservations are downstream role-overlay tickets.
- `Makefile` — `foundation-apply` / `foundation-destroy` targets,
  `init` / `validate` extended to cover `terraform/envs/foundation/`.
- `.github/workflows/packer-validate.yml` — `envs/foundation` added to
  the `terraform` job matrix (fmt + `init -backend=false` + validate).
- `docs/handbook.md` §1c — full reproduce flow for `envs/foundation`,
  MAC allocation table, "why an env not a smoke" rationale.
  §5 directory map + §6 phase table updated to reflect 0.B.5 / 0.B.6 ✅
  and 0.C.1 🔄.
- `docs/handbook.md` §1c.5 — **lesson #10 smoke-time gotcha**:
  pre-`dc5c588` Windows templates ship a stale `sshd_config` and reproduce
  lesson #8's connection-reset on clones — even Server SKUs that lesson #8
  said were unaffected. Discovered 2026-04-28 during 0.C.1 foundation smoke
  on `ws2025-desktop` clones (template last built `68012e8`, predates
  `dc5c588`). Hot-fix recipe (per-clone in-place sshd_config patch),
  permanent fix (rebuild affected template), and forward-implication note
  for `_shared/powershell/` discipline are documented. Affected pre-`dc5c588`
  templates flagged: `ws2025-core` (commit `42a5205`), `ws2025-desktop`
  (commit `68012e8`). win11ent (rebuilt as part of `dc5c588`) is clean.

## [0.1.1] — 2026-04-22 — "Windows licensing canon + secret-leak defenses"

Implements the nexus-infra-vmware side of
[nexus-platform-plan v0.1.3](https://github.com/grezap/nexus-platform-plan/releases/tag/v0.1.3)
and [ADR-0144](https://github.com/grezap/nexus-platform-plan/blob/main/docs/adr/ADR-0144-windows-licensing.md).

### Added

- `docs/licensing.md` — implementation-side licensing doc: `product_source`
  variable contract (`msdn` | `evaluation`), Vault layout at
  `nexus/windows/product-keys/{ws2025-core,ws2025-desktop,win11ent}`,
  pre-Phase-0.D bootstrap via NTFS-ACL'd `%USERPROFILE%\.nexus\secrets\windows-keys.json`,
  5-layer defense-in-depth, operational playbook.
- `.gitleaks.toml` — custom `microsoft-product-key` rule matching the
  5x5 alphanumeric Windows key format, with placeholder/`.tpl`/docs allow-list.
- `scripts/check-no-product-key.ps1` — pwsh pre-commit + CI guard that fails
  on any Microsoft product-key pattern outside allow-listed paths.
- `.github/workflows/packer-validate.yml` — two new jobs: `gitleaks` (full
  history scan on PRs) and `product-key-guard` (pwsh scan of every tracked
  file against the MSFT key regex).
- Per-template `## Licensing — product_source contract` sections in
  `packer/ws2025-core/README.md`, `packer/ws2025-desktop/README.md`,
  `packer/win11ent/README.md` documenting default/`msdn`/`evaluation`
  behaviour, derived `edition`, and Vault paths.

### Changed

- `.gitignore` — hardened for key-bearing artifacts: `**/Autounattend.xml`
  blocked at every path (except `*.tpl`), `*.pkrvars.hcl` blocked
  (except `example.pkrvars.hcl`), plus `windows-keys.json`, `.nexus/`,
  `secrets/`.

### Canon references

- [ADR-0144 — Windows licensing posture](https://github.com/grezap/nexus-platform-plan/blob/main/docs/adr/ADR-0144-windows-licensing.md)
- [nexus-platform-plan docs/infra/licensing.md](https://github.com/grezap/nexus-platform-plan/blob/main/docs/infra/licensing.md)

### Deferred

- Full Packer template bodies for `ws2025-core`, `ws2025-desktop`, `win11ent`
  (the licensing wiring specified in this release will be realized when
  those templates are written in Phase 0.B.4–0.B.6).
- Vault policy + AppRole for `packer-builder` (Phase 0.D).

## [0.1.0] — 2026-04-21 — "Phase 0.B scaffold + nexus-gateway build path"

Initial commit. Implements the scaffold for NexusPlatform infrastructure-as-code on VMware Workstation Pro and the full build/deploy path for **VM #0 `nexus-gateway`** (lab edge router).

### Added

- **Repo scaffold** — `packer/` with subdirs for all 6 golden templates; `terraform/gateway/` + `terraform/modules/vm/`; `docs/`; `.github/workflows/packer-validate.yml`; top-level `Makefile`.
- **`packer/nexus-gateway/`** — complete build path:
  - `nexus-gateway.pkr.hcl` — `vmware-iso` + `ansible-local` build, pinned Debian 13 netinst ISO, headless
  - `variables.pkr.hcl` — tunables (CPU, RAM, disk, ISO URL/checksum)
  - `http/preseed.cfg` — non-interactive Debian install (no GUI, sudo user, SSH, nftables/dnsmasq/chrony packages)
  - `files/nftables.conf` — ruleset (masquerade 192.168.70.0/24 → NIC0; drop VMnet10 egress)
  - `files/dnsmasq.conf` — DHCP .200-.250 + DNS forwarder (1.1.1.1/9.9.9.9) with DNSSEC
  - `files/chrony.conf` — public pool sources; serves lab on VMnet10/11 only
  - `ansible/playbook.yml` + `roles/nexus_gateway/` — persistent NIC naming via systemd .link, IP forwarding sysctl, ruleset install, services enabled, unattended security updates, SSH hardening, MOTD
- **`terraform/gateway/`** — root module:
  - `main.tf` — `vmworkstation_vm` resource + `null_resource` for NIC mapping + `null_resource` for power-on
  - `variables.tf` / `outputs.tf` / `example.tfvars`
- **`scripts/configure-gateway-nics.ps1`** — idempotent VMX rewriter: `ethernet0=bridged`, `ethernet1=VMnet11`, `ethernet2=VMnet10`, static MACs for stable NIC naming.
- **`.github/workflows/packer-validate.yml`** — CI: `packer init`/`fmt`/`validate -syntax-only`, `terraform fmt`/`validate`, `ansible-lint`, `shellcheck`.
- **`Makefile`** — `gateway`, `gateway-apply`, `gateway-destroy`, `validate`, `clean` targets. Stubs for the other 5 OS templates.
- **Docs** —
  - `README.md` — repo overview + quick start
  - `docs/architecture.md` — design rationale (toolchain, state, secrets, layering)
  - `docs/nexus-gateway.md` — VM #0 deep-dive + runbook (build, deploy, verify, rebuild)

### Canon references

- Implements [Phase 0.B.1](https://github.com/grezap/nexus-platform-plan/blob/main/MASTER-PLAN.md) of nexus-platform-plan v0.1.2.
- Honors platform constraints from nexus-platform-plan [`docs/infra/network.md`](https://github.com/grezap/nexus-platform-plan/blob/main/docs/infra/network.md): Host-Only VMnet11, `192.168.70.1` = nexus-gateway, `192.168.70.254` = host, single-NAT-slot limit.

### Deferred to later phases

- Vault PKI integration for SSH CA + TLS (Phase 0.D).
- Tier-1 HA pattern for nexus-gateway (ADR-0142).
- Templates for `deb13`, `ubuntu24`, `ws2025-core`, `ws2025-desktop`, `win11ent` (Phase 0.B.2–0.B.6).
- Reusable `terraform/modules/vm/` contents (Phase 0.C).
