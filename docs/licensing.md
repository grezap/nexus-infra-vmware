# Licensing — implementation side

This is the nexus-infra-vmware twin of the canonical
[`nexus-platform-plan` → `docs/infra/licensing.md`](https://github.com/grezap/nexus-platform-plan/blob/main/docs/infra/licensing.md).
Decisions are locked in [ADR-0144](https://github.com/grezap/nexus-platform-plan/blob/main/docs/adr/ADR-0144-windows-licensing.md).
This doc focuses on **how the Packer + Terraform + Vault wiring actually
looks inside this repo**.

## Two build modes

Every Windows template (`packer/ws2025-core`, `packer/ws2025-desktop`,
`packer/win11ent`) accepts a single `product_source` variable:

| `product_source` | Used by | Key source | Result |
|---|---|---|---|
| `evaluation` | default, public cloners | none (eval edition in ISO) | 180 d / 90 d rearm-able VM with small desktop watermark |
| `msdn` | owner builds on host `10.0.70.101` | Vault `nexus/windows/product-keys/<template>` (or bootstrap JSON pre-Phase-0.D) | Genuine activation, no watermark, no rearm |

```bash
# Public cloner (no MSDN subscription):
packer build packer/ws2025-core                         # defaults to evaluation

# Owner (MSDN via Vault):
packer build -var product_source=msdn packer/ws2025-core
```

## Per-template variable contract

Each of `packer/{ws2025-core,ws2025-desktop,win11ent}/variables.pkr.hcl`
exposes:

```hcl
variable "product_source" {
  type        = string
  default     = "evaluation"
  description = "Activation path: 'evaluation' (public) or 'msdn' (owner)."

  validation {
    condition     = contains(["evaluation", "msdn"], var.product_source)
    error_message = "product_source must be 'evaluation' or 'msdn'."
  }
}

variable "vault_addr" {
  type        = string
  default     = "https://vault.nexus.local:8200"
  description = "Vault endpoint for MSDN key retrieval (product_source=msdn)."
}

variable "bootstrap_keys_file" {
  type        = string
  default     = "" # e.g. C:/Users/<owner>/.nexus/secrets/windows-keys.json
  description = "Pre-Phase-0.D fallback: local JSON with MSDN keys (NTFS-ACL locked)."
}
```

And a corresponding `locals` block (example for `ws2025-core`):

```hcl
locals {
  edition = var.product_source == "msdn" ? "ServerStandard" : "ServerStandardEval"

  product_key = (
    var.product_source == "evaluation"
      ? ""
      : var.bootstrap_keys_file != ""
        ? jsondecode(file(var.bootstrap_keys_file))["ws2025-core"]["key"]
        : vault("/nexus/windows/product-keys/ws2025-core", "key")
  )
}
```

The `Autounattend.xml.tpl` template consumes `{{ .product_key }}` and
`{{ .edition }}` (Packer `templatefile()` renders at build time into
`output-<template>/Autounattend.xml`). The rendered file is **gitignored at
every path** — only the `.tpl` is ever committed.

## Vault layout

```
nexus/windows/product-keys/
├── ws2025-core       { key, edition=ServerStandard,  source=msdn }
├── ws2025-desktop    { key, edition=ServerStandard,  source=msdn }
└── win11ent          { key, edition=Enterprise,      source=msdn }
```

Packer reads with the `vault` function (requires `VAULT_ADDR` + `VAULT_TOKEN`
in the shell environment). The owner's build host has a short-lived token
issued by the `packer-builder` Vault role.

## Pre-Phase-0.D bootstrap

The very first Windows template build happens **before** Vault exists
(Phase 0.B runs ahead of Phase 0.D). For that window only:

```
C:\Users\<owner>\.nexus\secrets\windows-keys.json      (NTFS ACL: owner-only)
```

```json
{
  "ws2025-core":    { "key": "XXXXX-...", "edition": "ServerStandard" },
  "ws2025-desktop": { "key": "XXXXX-...", "edition": "ServerStandard" },
  "win11ent":       { "key": "XXXXX-...", "edition": "Enterprise" }
}
```

Referenced via a gitignored `secrets.auto.pkrvars.hcl`:

```hcl
# packer/ws2025-core/secrets.auto.pkrvars.hcl   (gitignored)
product_source      = "msdn"
bootstrap_keys_file = "C:/Users/<owner>/.nexus/secrets/windows-keys.json"
```

After Phase 0.D, the bootstrap file is destroyed and `vault kv put` becomes
the canonical write path:

```bash
vault kv put nexus/windows/product-keys/ws2025-core \
  key="XXXXX-XXXXX-XXXXX-XXXXX-XXXXX" \
  edition="ServerStandard" \
  source="msdn"

Remove-Item -Force "$env:USERPROFILE\.nexus\secrets\windows-keys.json"
```

## Defense in depth (5 layers)

1. **`.gitignore`** — blocks `Autounattend.xml` at every path (only `*.tpl`
   committed), `*.pkrvars.hcl` (except `example.pkrvars.hcl`),
   `windows-keys.json`, `.nexus/`, `secrets/`, `*.pem`, `*.key`.
2. **`.gitleaks.toml`** — custom rule `microsoft-product-key` matching
   `[A-Z0-9]{5}-[A-Z0-9]{5}-[A-Z0-9]{5}-[A-Z0-9]{5}-[A-Z0-9]{5}`; placeholder
   values and `.tpl` / docs paths allow-listed.
3. **Pre-commit hook** — `scripts/check-no-product-key.ps1` scans staged
   additions and refuses the commit on match. Install locally with:

   ```powershell
   '# pre-commit' | Out-File .git/hooks/pre-commit -Encoding ASCII
   Add-Content .git/hooks/pre-commit "pwsh -NoProfile -File scripts/check-no-product-key.ps1"
   ```

4. **CI** — `.github/workflows/packer-validate.yml` runs `gitleaks detect`
   with this repo's `.gitleaks.toml` and fails the PR on any match.
5. **Packer log filtering** — builds log `product_source = msdn|evaluation`
   only; the rendered `Autounattend.xml` is emitted to `output-<template>/`
   which is gitignored and shredded after VM creation.

## Operational playbook

### Build with MSDN keys (owner)

```bash
$env:VAULT_ADDR  = "https://vault.nexus.local:8200"
$env:VAULT_TOKEN = vault login -method=oidc -token-only -role=packer-builder
packer build -var product_source=msdn packer/ws2025-core
```

### Build with Evaluation ISO (cloner)

```bash
packer build packer/ws2025-core      # product_source defaults to "evaluation"
```

### Rotate a key

1. `vault kv put nexus/windows/product-keys/<template> key=... source=msdn edition=...`
2. `make <template>`   (Packer rebuild)
3. `terraform -chdir=terraform/<env> apply -replace=module.<vm>`   (rolling replace)

### Audit activation status across the fleet

Handled by the owner-side `nexus-cli windows audit-licensing` (lives in the
`nexus-cli` repo). Reports template, source, activation status, days left
for any Evaluation VMs.

## Cross-references

- Canon: [`nexus-platform-plan/docs/infra/licensing.md`](https://github.com/grezap/nexus-platform-plan/blob/main/docs/infra/licensing.md)
- Decision: [`ADR-0144`](https://github.com/grezap/nexus-platform-plan/blob/main/docs/adr/ADR-0144-windows-licensing.md)
- Template stubs: [`packer/ws2025-core`](../packer/ws2025-core/), [`packer/ws2025-desktop`](../packer/ws2025-desktop/), [`packer/win11ent`](../packer/win11ent/)
