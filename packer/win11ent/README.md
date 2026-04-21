# packer/win11ent — Windows 11 Enterprise workstation (Phase 0.B.6)

**Status:** stub.

Used for: nexus-desk integration testing, Windows-client portfolio demos (WinForms/WPF/WinUI 3 apps), developer workstations.

Automated install via `Autounattend.xml`. Post-install provisioning via WinRM + Ansible (`windows_base` shared role), plus client-specific:

- .NET 10 SDK + .NET 10 Desktop Runtime
- WinAppSDK runtime for WinUI 3
- Visual Studio Code + extensions (optional, via winget)
- Windows Terminal (default shell PowerShell 7)
- Domain-join stub
- TPM + BitLocker configured per CIS Windows 11 L1

Exit gate: fresh clone can run the nexus-desk app suite from a Harbor image tag and execute the DEMO-13 playbook.
