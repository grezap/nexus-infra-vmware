/*
 * role-overlay-windows-vault-agent.tf -- Phase 0.D.5.4 step 1/1 (foundation)
 *
 * Installs Vault Agent as a Windows service on dc-nexus + nexus-jumpbox.
 * Each Agent authenticates via its own narrow AppRole (defined in
 * security env) and renders one cred from Vault KV to a file on disk as
 * proof-of-concept. Real consumers (SQL Server config files, IIS app
 * config, scheduled tasks) come when those workloads deploy.
 *
 * Cross-env coupling: reads the AppRole creds JSON sidecars from
 * $HOME/.nexus/vault-agent-{dc-nexus,nexus-jumpbox}.json (written by
 * security env). Best-effort: WARN+skip if the JSON is absent.
 *
 * Per-host resource pattern (not a list/loop) so each host is
 * independently `-target`-able for iteration.
 *
 * Install steps (each host):
 *   1. Probe: is vault.exe already installed at expected version?
 *      If yes + agent service running + render file present: skip.
 *   2. Download vault_<version>_windows_amd64.zip from releases.hashicorp.com
 *      via nexus-gateway egress. Extract to C:\Program Files\HashiCorp\Vault\.
 *   3. Stage role-id, secret-id, CA bundle, agent config, render template
 *      to C:\ProgramData\nexus\agent\ (NTFS ACL: Administrators+SYSTEM only).
 *   4. Create Windows service `nexus-vault-agent` via sc.exe.
 *   5. Start the service.
 *   6. Verify: rendered file exists with non-empty content within 30s.
 *
 * Selective ops: enable_vault_agent_install (master) AND
 *                enable_dc_vault_agent / enable_jumpbox_vault_agent.
 *
 * Reachability invariant: Vault Agent runs as LocalSystem; binds to no
 * network ports (sink "file" only). No firewall changes. SSH/RDP from
 * build host unaffected.
 */

locals {
  # Render-target KV paths, one per host. Proof-of-concept choices:
  #   - dc-nexus: dsrm  (dc-nexus is the consumer that actually needs DSRM)
  #   - jumpbox:  nexusadmin  (jumpbox uses nexusadmin for Add-Computer
  #     when joining new machines; foundation env's existing overlay
  #     already provides this from KV, but the Agent rendering it locally
  #     is the canonical 0.E pattern)
  vault_agent_render_targets = {
    "dc-nexus" = {
      vm_ip       = local.dc_nexus_ip
      kv_path     = "${var.vault_kv_mount_path}/foundation/dc-nexus/dsrm"
      kv_field    = "password"
      render_dest = "C:/ProgramData/nexus/agent/dsrm.txt"
      creds_file  = pathexpand(var.vault_agent_dc_nexus_creds_file)
      enabled     = var.enable_vault_agent_install && var.enable_dc_vault_agent
    }
    "nexus-jumpbox" = {
      vm_ip       = local.jumpbox_ip
      kv_path     = "${var.vault_kv_mount_path}/foundation/identity/nexusadmin"
      kv_field    = "password"
      render_dest = "C:/ProgramData/nexus/agent/nexusadmin-pwd.txt"
      creds_file  = pathexpand(var.vault_agent_nexus_jumpbox_creds_file)
      enabled     = var.enable_vault_agent_install && var.enable_jumpbox_vault_agent
    }
  }
}

resource "null_resource" "dc_nexus_vault_agent" {
  count = var.enable_dc_promotion && local.vault_agent_render_targets["dc-nexus"].enabled ? 1 : 0

  triggers = {
    dc_verify_id    = null_resource.dc_nexus_verify[0].id
    vault_version   = var.vault_agent_version
    kv_path         = local.vault_agent_render_targets["dc-nexus"].kv_path
    creds_file      = local.vault_agent_render_targets["dc-nexus"].creds_file
    agent_overlay_v = "2" # v2 = New-Service instead of sc.exe (PS argv parsing eats embedded double quotes around binPath; sc.exe dumps usage help; Diagnostic 2026-05-02). v1 = sc.exe with $binPath interpolation.
  }

  depends_on = [null_resource.dc_nexus_verify]

  provisioner "local-exec" {
    when        = create
    interpreter = ["pwsh", "-NoProfile", "-Command"]
    command     = local.vault_agent_install_pwsh["dc-nexus"]
  }
}

resource "null_resource" "jumpbox_vault_agent" {
  count = var.enable_dc_promotion && var.enable_jumpbox_domain_join && local.vault_agent_render_targets["nexus-jumpbox"].enabled ? 1 : 0

  triggers = {
    jumpbox_verify_id = null_resource.jumpbox_verify[0].id
    vault_version     = var.vault_agent_version
    kv_path           = local.vault_agent_render_targets["nexus-jumpbox"].kv_path
    creds_file        = local.vault_agent_render_targets["nexus-jumpbox"].creds_file
    agent_overlay_v   = "2" # v2 = New-Service instead of sc.exe (see dc_nexus_vault_agent v2 note).
  }

  depends_on = [null_resource.jumpbox_verify]

  provisioner "local-exec" {
    when        = create
    interpreter = ["pwsh", "-NoProfile", "-Command"]
    command     = local.vault_agent_install_pwsh["nexus-jumpbox"]
  }
}

# Install pwsh script per host. Substantial PowerShell ahead -- shipped
# as a file (per memory/feedback_windows_ssh_automation.md rule #2;
# encoded base64 of this script + the 5 staged files would blow past
# cmd.exe's 8 KB command-line limit by an order of magnitude).
locals {
  vault_agent_install_pwsh = {
    for hostname, target in local.vault_agent_render_targets : hostname => <<-PWSH
      $hostname     = '${hostname}'
      $vmIp         = '${target.vm_ip}'
      $kvPath       = '${target.kv_path}'
      $kvField      = '${target.kv_field}'
      $renderDest   = '${target.render_dest}'
      $credsFile    = '${target.creds_file}'
      $vaultVersion = '${var.vault_agent_version}'
      $caBundlePath = (Resolve-Path '${pathexpand(var.vault_ca_bundle_path)}' -ErrorAction SilentlyContinue).Path
      if (-not $caBundlePath) { $caBundlePath = '${pathexpand(var.vault_ca_bundle_path)}' }

      Write-Host "[$hostname-vault-agent] starting install (Vault $vaultVersion)"

      if (-not (Test-Path $credsFile)) {
        Write-Host "[$hostname-vault-agent] WARN: AppRole creds JSON $credsFile not present (security env not yet applied?). Skipping."
        exit 0
      }
      if (-not (Test-Path $caBundlePath)) {
        Write-Host "[$hostname-vault-agent] WARN: CA bundle $caBundlePath not present. Skipping."
        exit 0
      }

      $creds = Get-Content $credsFile -Raw | ConvertFrom-Json
      if (-not $creds.role_id -or -not $creds.secret_id) {
        throw "[$hostname-vault-agent] creds file $credsFile missing role_id or secret_id"
      }

      # Build the Vault Agent config (HCL). Single template stanza for
      # the proof-of-concept render. Auto-auth via AppRole; sink to a
      # local token file (LocalSystem-readable; not exposed to other users).
      $agentConfig = @"
pid_file = "C:/ProgramData/nexus/agent/agent.pid"

vault {
  address = "https://192.168.70.121:8200"
  ca_cert = "C:/ProgramData/nexus/agent/vault-ca-bundle.crt"
}

auto_auth {
  method "approle" {
    config = {
      role_id_file_path                   = "C:/ProgramData/nexus/agent/role-id"
      secret_id_file_path                 = "C:/ProgramData/nexus/agent/secret-id"
      remove_secret_id_file_after_reading = false
    }
  }

  sink "file" {
    config = {
      path = "C:/ProgramData/nexus/agent/token"
    }
  }
}

template {
  source      = "C:/ProgramData/nexus/agent/render.tpl"
  destination = "$renderDest"
}
"@

      # Render template (consul-template / Go template syntax)
      $renderTpl = '{{ with secret "' + $kvPath + '" }}{{ .Data.data.' + $kvField + ' }}{{ end }}'

      # Build a one-shot install script that runs on the target host.
      # The script:
      #  1. Probes if vault.exe + service + render file already present at expected state -> skip.
      #  2. Downloads + extracts vault.exe to C:\Program Files\HashiCorp\Vault\.
      #  3. Stages role-id / secret-id / CA bundle / agent config / template to C:\ProgramData\nexus\agent\.
      #  4. Locks NTFS ACLs to Administrators + SYSTEM only.
      #  5. Creates + starts the nexus-vault-agent Windows service.
      #  6. Verifies the rendered file exists with non-empty content (30s poll).
      $installScript = @"
`$ErrorActionPreference = 'Stop'
`$vaultVersion = '$vaultVersion'
`$installDir   = 'C:\Program Files\HashiCorp\Vault'
`$dataDir      = 'C:\ProgramData\nexus\agent'
`$serviceName  = 'nexus-vault-agent'
`$vaultExe     = Join-Path `$installDir 'vault.exe'
`$renderDest   = '$renderDest'

# ─── Step 1: Idempotency probe ─────────────────────────────────────────
`$skip = `$false
if ((Test-Path `$vaultExe) -and (Get-Service `$serviceName -ErrorAction SilentlyContinue) -and (Test-Path `$renderDest)) {
  `$installedVer = (& `$vaultExe -version 2>&1).Trim()
  `$svcStatus = (Get-Service `$serviceName).Status
  `$rendered  = (Get-Item `$renderDest -ErrorAction SilentlyContinue)
  if (`$installedVer -match "Vault v`$vaultVersion" -and `$svcStatus -eq 'Running' -and `$rendered.Length -gt 0) {
    Write-Output ("AGENT_PRESENT: vault=" + `$installedVer + " service=" + `$svcStatus + " rendered=" + `$rendered.Length + " bytes")
    exit 0
  }
}

# ─── Step 2: Download + extract ────────────────────────────────────────
New-Item -ItemType Directory -Force -Path `$installDir | Out-Null
New-Item -ItemType Directory -Force -Path `$dataDir    | Out-Null

if (-not (Test-Path `$vaultExe) -or -not ((& `$vaultExe -version 2>&1).Trim() -match "Vault v`$vaultVersion")) {
  `$zipUrl  = "https://releases.hashicorp.com/vault/`$vaultVersion/vault_`$${vaultVersion}_windows_amd64.zip"
  `$zipPath = Join-Path `$env:TEMP "vault-`$${vaultVersion}-windows-amd64.zip"
  Write-Output ("DOWNLOADING: " + `$zipUrl)
  [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
  Invoke-WebRequest -Uri `$zipUrl -OutFile `$zipPath -UseBasicParsing
  Expand-Archive -Path `$zipPath -DestinationPath `$installDir -Force
  Remove-Item `$zipPath -Force
  Write-Output ("INSTALLED: " + (& `$vaultExe -version 2>&1).Trim())
}

# ─── Step 3: Stage agent config + creds + template ─────────────────────
# Files staged: role-id, secret-id, vault-ca-bundle.crt, agent.hcl, render.tpl
# The Set-Content -NoNewline pattern is critical for role-id / secret-id
# (Vault Agent reads the file as the bare token; trailing newline breaks
# auth with "AppRole login: invalid character ' ' in role_id").
Set-Content -Path (Join-Path `$dataDir 'role-id')   -Value 'NEXUS_PLACEHOLDER_ROLE_ID' -Encoding ASCII -NoNewline
Set-Content -Path (Join-Path `$dataDir 'secret-id') -Value 'NEXUS_PLACEHOLDER_SECRET_ID' -Encoding ASCII -NoNewline
Set-Content -Path (Join-Path `$dataDir 'vault-ca-bundle.crt') -Value @'
NEXUS_PLACEHOLDER_CA_BUNDLE
'@ -Encoding ASCII
Set-Content -Path (Join-Path `$dataDir 'agent.hcl')  -Value @'
NEXUS_PLACEHOLDER_AGENT_CONFIG
'@ -Encoding ASCII
Set-Content -Path (Join-Path `$dataDir 'render.tpl') -Value 'NEXUS_PLACEHOLDER_RENDER_TPL' -Encoding ASCII -NoNewline

# ─── Step 4: Lock NTFS ACLs (LocalSystem + Administrators only) ────────
# role-id / secret-id are sensitive; the rest can stay readable for
# diagnostic purposes but we restrict to admins+SYSTEM defensively.
foreach (`$f in @('role-id','secret-id','token','agent.pid','agent.hcl')) {
  `$p = Join-Path `$dataDir `$f
  if (Test-Path `$p) {
    icacls `$p /inheritance:r /grant:r 'NT AUTHORITY\SYSTEM:F' 'BUILTIN\Administrators:F' 2>&1 | Out-Null
  }
}

# ─── Step 5: Create + start the Windows service ────────────────────────
# New-Service (PS-native) instead of sc.exe -- PS argv parsing eats
# embedded double quotes when expanding a $binPath variable to sc.exe,
# which then dumps usage help instead of creating the service. Diagnostic
# 2026-05-02: tested manually that sc.exe works with literal quoted
# binPath but NOT when interpolated from a PS variable. New-Service's
# -BinaryPathName parameter accepts a single string + handles the
# Windows API quoting internally. LocalSystem is the default account;
# explicit -StartupType Automatic.
if (Get-Service `$serviceName -ErrorAction SilentlyContinue) {
  Stop-Service `$serviceName -Force -ErrorAction SilentlyContinue
  & sc.exe delete `$serviceName 2>&1 | Out-Null
  Start-Sleep -Seconds 2
}
`$cfgPath = Join-Path `$dataDir 'agent.hcl'
`$binPath = '"' + `$vaultExe + '" agent -config="' + `$cfgPath + '"'
New-Service -Name `$serviceName ``
  -BinaryPathName `$binPath ``
  -DisplayName 'NexusPlatform Vault Agent' ``
  -Description 'Vault Agent renders foundation creds from Vault KV to local files (Phase 0.D.5.4 sample render).' ``
  -StartupType Automatic | Out-Null
Start-Service `$serviceName

# ─── Step 6: Verify render succeeds within 30s ─────────────────────────
`$deadline = (Get-Date).AddSeconds(30)
`$rendered = `$null
while ((Get-Date) -lt `$deadline) {
  Start-Sleep -Seconds 2
  if ((Test-Path `$renderDest) -and ((Get-Item `$renderDest).Length -gt 0)) {
    `$rendered = Get-Item `$renderDest
    break
  }
}
if (-not `$rendered) {
  Write-Output ("AGENT_RENDER_TIMEOUT: " + `$renderDest + " not populated within 30s. Service status: " + (Get-Service `$serviceName).Status)
  exit 1
}
Write-Output ("AGENT_INSTALLED: " + `$serviceName + " running; rendered " + `$rendered.Length + " bytes to " + `$renderDest)
"@

      # Substitute the placeholders with actual values, base64-encode the
      # CA bundle to avoid HCL/PS escape gotchas, base64-encode the
      # config + template too.
      $caBundleContent = (Get-Content $caBundlePath -Raw).TrimEnd("`r","`n")
      $installScript = $installScript.Replace('NEXUS_PLACEHOLDER_ROLE_ID', $creds.role_id)
      $installScript = $installScript.Replace('NEXUS_PLACEHOLDER_SECRET_ID', $creds.secret_id)
      $installScript = $installScript.Replace('NEXUS_PLACEHOLDER_CA_BUNDLE', $caBundleContent)
      $installScript = $installScript.Replace('NEXUS_PLACEHOLDER_AGENT_CONFIG', $agentConfig)
      $installScript = $installScript.Replace('NEXUS_PLACEHOLDER_RENDER_TPL', $renderTpl)

      # Ship as file (per memory/feedback_windows_ssh_automation.md rule #2)
      $tmpDir          = New-Item -ItemType Directory -Force -Path (Join-Path $env:TEMP "nexus-vault-agent-$hostname-$(Get-Random)")
      $localScriptPath = Join-Path $tmpDir 'install-vault-agent.ps1'
      $remoteScriptPath = "C:/Windows/Temp/install-vault-agent-$hostname.ps1"
      $scriptWithCleanup = $installScript + "`nRemove-Item '$remoteScriptPath' -Force -ErrorAction SilentlyContinue`n"
      Set-Content -Path $localScriptPath -Value $scriptWithCleanup -Encoding UTF8

      scp -o ConnectTimeout=15 -o BatchMode=yes -o StrictHostKeyChecking=no $localScriptPath "nexusadmin@$${vmIp}:$remoteScriptPath" 2>&1 | Out-Null
      if ($LASTEXITCODE -ne 0) {
        Remove-Item -Recurse -Force $tmpDir -ErrorAction SilentlyContinue
        throw "[$hostname-vault-agent] scp of install script failed (rc=$LASTEXITCODE)"
      }

      Write-Host "[$hostname-vault-agent] dispatching install script (~$($scriptWithCleanup.Length) chars)"
      $output = ssh -o ConnectTimeout=300 -o BatchMode=yes -o StrictHostKeyChecking=no nexusadmin@$vmIp "powershell -NoProfile -ExecutionPolicy Bypass -File $remoteScriptPath" 2>&1 | Out-String
      $rc = $LASTEXITCODE
      Remove-Item -Recurse -Force $tmpDir -ErrorAction SilentlyContinue

      ssh -o ConnectTimeout=15 -o BatchMode=yes -o StrictHostKeyChecking=no nexusadmin@$vmIp "powershell -NoProfile -Command \"Remove-Item '$remoteScriptPath' -Force -ErrorAction SilentlyContinue\"" 2>&1 | Out-Null

      Write-Host "[$hostname-vault-agent] remote output:`n$($output.Trim())"

      if ($rc -ne 0 -or -not ($output -match 'AGENT_(PRESENT|INSTALLED):')) {
        throw "[$hostname-vault-agent] install failed (rc=$rc). See output above."
      }
      Write-Host "[$hostname-vault-agent] OK"
    PWSH
  }
}
