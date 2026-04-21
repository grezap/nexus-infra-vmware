# packer/ubuntu24 — Ubuntu 24.04 LTS base template (Phase 0.B.3)

**Status:** stub.

Used for VMs needing newer kernels or userspace than Debian 13 provides: MinIO (io_uring tuning), Spark workers (JVM + native libs), Jupyter servers.

Autoinstall via `cloud-init` (subiquity) rather than Debian preseed. Shared Ansible roles with `deb13/` via `packer/_shared/ansible/roles/`.

Target layout mirrors `deb13/`. Exit gate matches `deb13/` README.
