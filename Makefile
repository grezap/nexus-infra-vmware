# nexus-infra-vmware — top-level make targets
# Run from a pwsh (Windows) or bash (WSL) shell. Windows targets use pwsh.

PACKER      ?= packer
TERRAFORM   ?= terraform
OUTPUT_ROOT ?= H:/VMS/NexusPlatform/_templates

.PHONY: help init validate \
        gateway gateway-apply gateway-destroy \
        deb13 ubuntu24 ws2025-core ws2025-desktop win11ent \
        all-templates clean

help:
	@echo "NexusPlatform VMware infrastructure"
	@echo ""
	@echo "  make gateway          - Build nexus-gateway .vmx (VM #0 — must be first)"
	@echo "  make gateway-apply    - Terraform apply gateway module (instantiate + power on)"
	@echo "  make gateway-destroy  - Terraform destroy gateway"
	@echo ""
	@echo "  make deb13            - Build Debian 13 base template"
	@echo "  make ubuntu24         - Build Ubuntu 24.04 LTS base template"
	@echo "  make ws2025-core      - Build Windows Server 2025 Core template"
	@echo "  make ws2025-desktop   - Build Windows Server 2025 Desktop template"
	@echo "  make win11ent         - Build Windows 11 Enterprise template"
	@echo "  make all-templates    - Build every template in order"
	@echo ""
	@echo "  make validate         - packer validate + terraform fmt/validate (all)"
	@echo "  make clean            - Remove packer output dirs + .terraform caches"

init:
	@cd packer/nexus-gateway && $(PACKER) init nexus-gateway.pkr.hcl
	@cd terraform/gateway    && $(TERRAFORM) init

validate:
	@echo "→ packer validate nexus-gateway"
	@cd packer/nexus-gateway && $(PACKER) validate .
	@echo "→ terraform fmt -check"
	@cd terraform/gateway    && $(TERRAFORM) fmt -check -recursive
	@echo "→ terraform validate"
	@cd terraform/gateway    && $(TERRAFORM) init -backend=false && $(TERRAFORM) validate

# ─── Phase 0.B.1 — nexus-gateway (VM #0) ─────────────────────────────────

gateway:
	@cd packer/nexus-gateway && $(PACKER) build \
		-var "output_directory=$(OUTPUT_ROOT)/nexus-gateway" \
		nexus-gateway.pkr.hcl

gateway-apply:
	@cd terraform/gateway && $(TERRAFORM) apply -auto-approve

gateway-destroy:
	@cd terraform/gateway && $(TERRAFORM) destroy -auto-approve

# ─── Phase 0.B.2-6 — base OS templates (stubs until implemented) ─────────

deb13:
	@cd packer/deb13          && $(PACKER) build .

ubuntu24:
	@cd packer/ubuntu24       && $(PACKER) build .

ws2025-core:
	@cd packer/ws2025-core    && $(PACKER) build .

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
