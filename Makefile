# nexus-infra-vmware — top-level make targets
# Run from a pwsh (Windows) or bash (WSL) shell. Windows targets use pwsh.

PACKER      ?= packer
TERRAFORM   ?= terraform
OUTPUT_ROOT ?= H:/VMS/NexusPlatform/_templates

.PHONY: help init validate \
        gateway gateway-apply gateway-destroy \
        deb13 deb13-smoke deb13-smoke-destroy \
        ubuntu24 ubuntu24-smoke ubuntu24-smoke-destroy \
        ws2025-core ws2025-core-msdn ws2025-core-smoke ws2025-core-smoke-destroy \
        ws2025-desktop win11ent \
        all-templates clean

help:
	@echo "NexusPlatform VMware infrastructure"
	@echo ""
	@echo "  make gateway          - Build nexus-gateway .vmx (VM #0 — must be first)"
	@echo "  make gateway-apply    - Terraform apply gateway module (instantiate + power on)"
	@echo "  make gateway-destroy  - Terraform destroy gateway"
	@echo ""
	@echo "  make deb13            - Build Debian 13 base template"
	@echo "  make deb13-smoke      - Instantiate deb13 via modules/vm (smoke test)"
	@echo "  make deb13-smoke-destroy - Tear down the smoke-test VM"
	@echo "  make ubuntu24         - Build Ubuntu 24.04 LTS base template"
	@echo "  make ubuntu24-smoke   - Instantiate ubuntu24 via modules/vm (smoke test)"
	@echo "  make ubuntu24-smoke-destroy - Tear down the ubuntu24 smoke VM"
	@echo "  make ws2025-core      - Build Windows Server 2025 Core template (evaluation ISO)"
	@echo "  make ws2025-core-msdn - Build Windows Server 2025 Core (retail/MSDN ISO + bootstrap key)"
	@echo "  make ws2025-core-smoke         - Instantiate ws2025-core via modules/vm (smoke test)"
	@echo "  make ws2025-core-smoke-destroy - Tear down the ws2025-core smoke VM"
	@echo "  make ws2025-desktop   - Build Windows Server 2025 Desktop template"
	@echo "  make win11ent         - Build Windows 11 Enterprise template"
	@echo "  make all-templates    - Build every template in order"
	@echo ""
	@echo "  make validate         - packer validate + terraform fmt/validate (all)"
	@echo "  make clean            - Remove packer output dirs + .terraform caches"

init:
	@cd packer/nexus-gateway    && $(PACKER) init nexus-gateway.pkr.hcl
	@cd packer/deb13            && $(PACKER) init deb13.pkr.hcl
	@cd packer/ubuntu24         && $(PACKER) init ubuntu24.pkr.hcl
	@cd packer/ws2025-core      && $(PACKER) init ws2025-core.pkr.hcl
	@cd terraform/gateway            && $(TERRAFORM) init
	@cd terraform/deb13-smoke        && $(TERRAFORM) init
	@cd terraform/ubuntu24-smoke     && $(TERRAFORM) init
	@cd terraform/ws2025-core-smoke  && $(TERRAFORM) init

validate:
	@echo "→ packer validate nexus-gateway"
	@cd packer/nexus-gateway && $(PACKER) validate .
	@echo "→ packer validate deb13"
	@cd packer/deb13         && $(PACKER) validate .
	@echo "→ packer validate ubuntu24"
	@cd packer/ubuntu24      && $(PACKER) validate .
	@echo "→ packer validate ws2025-core"
	@cd packer/ws2025-core   && $(PACKER) validate .
	@echo "→ terraform fmt -check (all)"
	@cd terraform                    && $(TERRAFORM) fmt -check -recursive
	@echo "→ terraform validate (gateway)"
	@cd terraform/gateway            && $(TERRAFORM) init -backend=false && $(TERRAFORM) validate
	@echo "→ terraform validate (deb13-smoke)"
	@cd terraform/deb13-smoke        && $(TERRAFORM) init -backend=false && $(TERRAFORM) validate
	@echo "→ terraform validate (ubuntu24-smoke)"
	@cd terraform/ubuntu24-smoke     && $(TERRAFORM) init -backend=false && $(TERRAFORM) validate
	@echo "→ terraform validate (ws2025-core-smoke)"
	@cd terraform/ws2025-core-smoke  && $(TERRAFORM) init -backend=false && $(TERRAFORM) validate

# ─── Phase 0.B.1 — nexus-gateway (VM #0) ─────────────────────────────────

gateway:
	@cd packer/nexus-gateway && $(PACKER) build \
		-var "output_directory=$(OUTPUT_ROOT)/nexus-gateway" \
		nexus-gateway.pkr.hcl

gateway-apply:
	@cd terraform/gateway && $(TERRAFORM) apply -auto-approve

gateway-destroy:
	@cd terraform/gateway && $(TERRAFORM) destroy -auto-approve

# ─── Phase 0.B.2 — deb13 generic base template ───────────────────────────

deb13:
	@cd packer/deb13          && $(PACKER) build .

deb13-smoke:
	@cd terraform/deb13-smoke && $(TERRAFORM) apply -auto-approve

deb13-smoke-destroy:
	@cd terraform/deb13-smoke && $(TERRAFORM) destroy -auto-approve

# ─── Phase 0.B.3 — ubuntu24 generic base template ────────────────────────

ubuntu24:
	@cd packer/ubuntu24          && $(PACKER) build .

ubuntu24-smoke:
	@cd terraform/ubuntu24-smoke && $(TERRAFORM) apply -auto-approve

ubuntu24-smoke-destroy:
	@cd terraform/ubuntu24-smoke && $(TERRAFORM) destroy -auto-approve

# ─── Phase 0.B.4 — ws2025-core Windows Server 2025 Core template ─────────

ws2025-core:
	@cd packer/ws2025-core          && $(PACKER) build .

# Owner-only: msdn/retail ISO + bootstrap JSON with product key.
# Expects C:/Users/<owner>/.nexus/secrets/windows-keys.json to exist — see
# docs/licensing.md §"Pre-Phase-0.D bootstrap".
ws2025-core-msdn:
	@cd packer/ws2025-core          && $(PACKER) build \
		-var "product_source=msdn" \
		-var "bootstrap_keys_file=$(USERPROFILE)/.nexus/secrets/windows-keys.json" .

ws2025-core-smoke:
	@cd terraform/ws2025-core-smoke && $(TERRAFORM) apply -auto-approve

ws2025-core-smoke-destroy:
	@cd terraform/ws2025-core-smoke && $(TERRAFORM) destroy -auto-approve

# ─── Phase 0.B.5-6 — remaining Windows templates (stubs until implemented) ─

ws2025-desktop:
	@cd packer/ws2025-desktop && $(PACKER) build .

win11ent:
	@cd packer/win11ent       && $(PACKER) build .

all-templates: gateway deb13 ubuntu24 ws2025-core ws2025-desktop win11ent

clean:
	@echo "Cleaning packer output + terraform caches..."
	@find packer -type d -name 'output-*' -exec rm -rf {} + 2>/dev/null || true
	@find packer -type d -name 'packer_cache' -exec rm -rf {} + 2>/dev/null || true
	@find terraform -type d -name '.terraform' -exec rm -rf {} + 2>/dev/null || true
