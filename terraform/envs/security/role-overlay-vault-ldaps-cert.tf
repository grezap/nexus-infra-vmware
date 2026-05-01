/*
 * role-overlay-vault-ldaps-cert.tf -- Phase 0.D.3 (LDAPS pulled forward)
 *
 * Issue a leaf cert from Vault's pki_int for dc-nexus.nexus.lab and
 * install it in dc-nexus's LocalMachine\My cert store. AD DS auto-
 * discovers LDAPS certs from this store on (re)start of NTDS -- once
 * installed and NTDS restarted, dc-nexus serves LDAPS on TCP/636 with
 * our PKI-issued cert.
 *
 * Why this is in security env (not foundation): the cert source is
 * Vault PKI which lives in security env. The destination is dc-nexus
 * which lives in foundation. Cross-env data flow happens via SSH from
 * the build host (which has root token + reachability to dc-nexus +
 * reachability to vault-1). Same pattern as the bind-cred JSON exchange
 * but without a state file -- the cert is install-and-forget on the DC.
 *
 * Why we need this for 0.D.3: AD has unidentified enforcement that
 * rejects ALL plain-LDAP simple binds from non-Windows clients
 * regardless of LDAPServerIntegrity registry value (tested 2/1/0; all
 * fail with "Strong Auth Required"). LDAPS sidesteps the entire
 * signing-vs-simple-bind axis -- the TLS channel encryption satisfies
 * AD's integrity requirement structurally. Originally 0.D.5 scope;
 * pulled forward to close 0.D.3 with a working live login + rotate-role.
 *
 * Trust chain on dc-nexus -- THIS IS LOAD-BEARING:
 *   - root CA   -> Cert:\LocalMachine\Root
 *   - intermediate -> Cert:\LocalMachine\CA
 *   - leaf+key  -> Cert:\LocalMachine\My
 * All three are required. Schannel walks the chain at startup and only
 * accepts a leaf cert into its "default server credential" pool if the
 * full chain builds to a trusted root *locally*. With the root missing
 * from LocalMachine\Root, X509Chain.Build returns PartialChain and
 * Schannel logs Event 36886 ("No suitable default server credential
 * exists on this system... will prevent server applications from
 * accepting SSL connections"). NTDS sees no usable LDAPS cred and
 * resets every handshake immediately ("connection forcibly closed by
 * the remote host"), even though the cert + intermediate are present
 * with a working private key. The fix is to install the root next to
 * the other two -- diagnosed via Get-WinEvent + X509Chain.Build on the
 * DC after iterations 1-3 each missed it. Memory:
 * feedback_diagnose_before_rewriting.md.
 *
 * PFX construction: done on vault-1 via `openssl pkcs12 -export`, NOT
 * via .NET X509Certificate2.CreateFromPemFile + Export(Pfx) on the
 * build host. (The .NET path is theoretically suspect -- it can yield
 * ephemeral keys -- but observed RSA accessibility on the imported
 * leaf was actually fine. The openssl path is kept because it's the
 * more correct PKCS#12 source regardless.)
 *
 * Idempotency: probe LocalMachine\Root (root) AND LocalMachine\CA
 * (intermediate) AND LocalMachine\My (leaf with private key, valid
 * >30d). Skip only if all three are present + the leaf is fresh.
 * Otherwise re-fetch root from build-host bundle, re-issue leaf via
 * openssl PFX, and re-install all three stores + restart NTDS.
 *
 * Reachability invariant: SSH/22 + RDP/3389 + Vault API/8200 unaffected.
 * NTDS restart causes ~10-30s of AD outage; LDAP/389 + LDAPS/636
 * unavailable during restart. ssh-to-DC + RDP keep working
 * (Win32-OpenSSH and tsv are independent of NTDS).
 *
 * Selective ops: enable_vault_ldap (master) AND enable_vault_ldaps_cert.
 */

resource "null_resource" "vault_ldaps_cert" {
  count = var.enable_vault_cluster && var.enable_vault_init && var.enable_vault_ldap && var.enable_vault_ldaps_cert ? 1 : 0

  triggers = {
    distribute_id   = length(null_resource.vault_pki_distribute_root) > 0 ? null_resource.vault_pki_distribute_root[0].id : "disabled"
    roles_id        = length(null_resource.vault_pki_roles) > 0 ? null_resource.vault_pki_roles[0].id : "disabled"
    int_common_name = var.vault_pki_intermediate_common_name
    leaf_ttl        = var.vault_ldaps_cert_ttl
    role_name       = var.vault_pki_role_name
    ldaps_overlay_v = "4" # v4: ALSO install root CA into Cert:\LocalMachine\Root on dc-nexus -- without it Schannel chain build returns PartialChain and AD logs Event 36886 ("No suitable default server credential"), resetting every LDAPS handshake. THIS IS THE ACTUAL FIX. v3: openssl PFX on vault-1 (kept; correct in its own right). v2: leaf+intermediate stores. v1: leaf-only.
  }

  depends_on = [null_resource.vault_pki_distribute_root, null_resource.vault_pki_roles]

  provisioner "local-exec" {
    when        = create
    interpreter = ["pwsh", "-NoProfile", "-Command"]
    command     = <<-PWSH
      $user           = '${local.ssh_user}'
      $vaultIp        = '${local.vault_1_ip}'
      $dcIp           = '192.168.70.240'
      $dcFqdn         = 'dc-nexus.nexus.lab'
      $roleName       = '${var.vault_pki_role_name}'
      $leafTtl        = '${var.vault_ldaps_cert_ttl}'
      $rootCommonName = '${var.vault_pki_root_common_name}'
      $intCommonName  = '${var.vault_pki_intermediate_common_name}'
      $keysFileRaw    = '${var.vault_init_keys_file}'
      $keysFile       = $ExecutionContext.InvokeCommand.ExpandString($keysFileRaw.Replace('$HOME', $env:USERPROFILE))
      $caBundleRaw    = '${var.vault_pki_ca_bundle_path}'
      $caBundlePath   = $ExecutionContext.InvokeCommand.ExpandString($caBundleRaw.Replace('$HOME', $env:USERPROFILE))

      if (-not (Test-Path $keysFile)) {
        throw "[ldaps-cert] vault-init.json missing at $keysFile"
      }
      if (-not (Test-Path $caBundlePath)) {
        throw "[ldaps-cert] root CA bundle missing at $caBundlePath -- run vault_pki_distribute_root first"
      }
      $rootToken = (Get-Content $keysFile | ConvertFrom-Json).root_token

      # ─── Idempotency probe: dc-nexus has the FULL chain installed? ──
      # All three tiers must be present for Schannel to qualify the leaf
      # as a default server credential. Missing any one (especially root
      # in LocalMachine\Root) causes Event 36886 + LDAPS handshake reset.
      $probeRemote = @"
        `$leaf = Get-ChildItem Cert:\LocalMachine\My -ErrorAction SilentlyContinue | Where-Object {
          (`$_.Subject -match 'CN=$dcFqdn') -and
          (`$_.Issuer -match '$intCommonName') -and
          ((`$_.NotAfter - (Get-Date)).TotalDays -gt 30) -and
          `$_.HasPrivateKey
        } | Select-Object -First 1;
        `$inter = Get-ChildItem Cert:\LocalMachine\CA -ErrorAction SilentlyContinue | Where-Object {
          `$_.Subject -match 'CN=$intCommonName'
        } | Select-Object -First 1;
        `$root = Get-ChildItem Cert:\LocalMachine\Root -ErrorAction SilentlyContinue | Where-Object {
          `$_.Subject -match 'CN=$rootCommonName'
        } | Select-Object -First 1;
        if (`$leaf -and `$inter -and `$root) {
          # Final guard: actually attempt chain build. Anything less and we
          # know Schannel will reject regardless of what's in the stores.
          `$chain = New-Object System.Security.Cryptography.X509Certificates.X509Chain;
          `$chain.ChainPolicy.RevocationMode = 'NoCheck';
          if (`$chain.Build(`$leaf)) {
            Write-Output ('CERT_OK: leaf=' + `$leaf.Subject + ' valid until ' + `$leaf.NotAfter.ToString('o') + '; intermediate=' + `$inter.Subject + '; root=' + `$root.Subject)
          } else {
            `$status = (`$chain.ChainStatus | ForEach-Object { `$_.Status }) -join ',';
            Write-Output ('CERT_INCOMPLETE_CHAIN_BUILD_FAILED: ' + `$status)
          }
        } elseif (-not `$root) {
          Write-Output 'CERT_INCOMPLETE_NO_ROOT'
        } elseif (-not `$inter) {
          Write-Output 'CERT_INCOMPLETE_NO_INTERMEDIATE'
        } else {
          Write-Output 'CERT_MISSING_OR_EXPIRING_OR_NO_PRIVKEY'
        }
"@
      $probeBytes = [System.Text.Encoding]::Unicode.GetBytes($probeRemote)
      $probeB64   = [Convert]::ToBase64String($probeBytes)
      $probeOut = ssh -o ConnectTimeout=15 -o BatchMode=yes -o StrictHostKeyChecking=no $user@$dcIp "powershell -NoProfile -EncodedCommand $probeB64" 2>&1 | Out-String

      if ($probeOut -match '\bCERT_OK:') {
        Write-Host "[ldaps-cert] dc-nexus already has valid PKI-issued cert -- skipping issue + import"
        Write-Host "  $($probeOut.Trim())"
        exit 0
      }

      Write-Host "[ldaps-cert] dc-nexus needs new PKI-issued LDAPS cert (probe: $($probeOut.Trim()))"

      # Random transit-only password for the PFX (used only between vault-1
      # PFX creation and dc-nexus Import-PfxCertificate; no persistence).
      $pfxPwd = -join ((48..57) + (65..90) + (97..122) | Get-Random -Count 32 | ForEach-Object { [char]$_ })

      # ─── Issue cert + build PFX on vault-1 via openssl ────────────────
      # We do PEM->PFX on vault-1 (Linux openssl) instead of the build host
      # (Windows .NET) because .NET's CreateFromPemFile + Export(Pfx) yields
      # a PFX whose private key, on Import-PfxCertificate, lands as ephemeral
      # / non-persisted in MachineKeys. Schannel cannot use such keys for
      # LDAPS server-side handshakes and resets every connection mid-flight.
      # openssl pkcs12 -export produces a stock PKCS#12 that imports cleanly.
      Write-Host "[ldaps-cert] dispatching issue + openssl PFX build to vault-1"
      $issueBuild = @"
set -euo pipefail
TMPDIR=`$(mktemp -d)
trap 'rm -rf "`$TMPDIR"' EXIT

ISSUED=`$(VAULT_TOKEN='$rootToken' VAULT_SKIP_VERIFY=true VAULT_ADDR=https://127.0.0.1:8200 \
  vault write -format=json pki_int/issue/$roleName \
    common_name=$dcFqdn \
    alt_names=dc-nexus,DC-NEXUS,DC-NEXUS.nexus.lab \
    ip_sans=$dcIp \
    ttl=$leafTtl)

echo "`$ISSUED" | jq -r '.data.certificate'  > "`$TMPDIR/cert.pem"
echo "`$ISSUED" | jq -r '.data.private_key' > "`$TMPDIR/key.pem"
echo "`$ISSUED" | jq -r '.data.issuing_ca'  > "`$TMPDIR/intermediate.pem"

if [ ! -s "`$TMPDIR/cert.pem" ] || [ ! -s "`$TMPDIR/key.pem" ] || [ ! -s "`$TMPDIR/intermediate.pem" ]; then
  echo "ERROR: empty cert/key/intermediate from vault" >&2
  exit 1
fi

openssl pkcs12 -export \
  -inkey "`$TMPDIR/key.pem" \
  -in    "`$TMPDIR/cert.pem" \
  -name  'dc-nexus-ldaps' \
  -passout 'pass:$pfxPwd' \
  -out   "`$TMPDIR/cert.pfx" 2>/dev/null

PFX_B64=`$(base64 -w 0 "`$TMPDIR/cert.pfx")
INT_PEM=`$(cat "`$TMPDIR/intermediate.pem")

jq -nc --arg pfx "`$PFX_B64" --arg int "`$INT_PEM" '{pfx_b64: `$pfx, intermediate_pem: `$int}'
"@
      $issueBytes = [System.Text.UTF8Encoding]::new($false).GetBytes($issueBuild)
      $issueB64   = [Convert]::ToBase64String($issueBytes)
      $issueRaw   = ssh -o ConnectTimeout=60 -o BatchMode=yes -o StrictHostKeyChecking=no $user@$vaultIp "echo '$issueB64' | base64 -d | bash" 2>&1 | Out-String

      try {
        $built = $issueRaw.Trim() | ConvertFrom-Json
      } catch {
        throw "[ldaps-cert] vault-1 issue+PFX-build did not return JSON. Output:`n$issueRaw"
      }
      if (-not $built.pfx_b64 -or -not $built.intermediate_pem) {
        throw "[ldaps-cert] vault-1 response missing pfx_b64 or intermediate_pem. Output:`n$issueRaw"
      }
      Write-Host "[ldaps-cert] received PFX ($($built.pfx_b64.Length) base64 chars) + intermediate ($($built.intermediate_pem.Length) chars)"

      # ─── Stage PFX + intermediate PEM + root PEM on build host ────────
      $tmpDir = New-Item -ItemType Directory -Force -Path (Join-Path $env:TEMP "vault-ldaps-cert-$(Get-Random)")
      $pfxFile     = Join-Path $tmpDir 'dc-ldaps.pfx'
      $pemIntFile  = Join-Path $tmpDir 'intermediate.pem'
      $pemRootFile = Join-Path $tmpDir 'root.pem'

      [System.IO.File]::WriteAllBytes($pfxFile, [Convert]::FromBase64String($built.pfx_b64))
      Set-Content -Path $pemIntFile -Value $built.intermediate_pem -Encoding Ascii
      # Root CA bundle is already on the build host (written by
      # vault_pki_distribute_root); copy it as-is for the DC.
      Copy-Item -Path $caBundlePath -Destination $pemRootFile -Force

      # ─── SCP leaf PFX + intermediate PEM + root PEM to dc-nexus ──────
      $remotePfxPath  = 'C:/Windows/Temp/dc-ldaps.pfx'
      $remoteIntPath  = 'C:/Windows/Temp/dc-ldaps-intermediate.pem'
      $remoteRootPath = 'C:/Windows/Temp/dc-ldaps-root.pem'
      Write-Host "[ldaps-cert] scp PFX + intermediate + root PEM to $${dcIp}"
      scp -o ConnectTimeout=15 -o BatchMode=yes -o StrictHostKeyChecking=no $pfxFile     "$${user}@$${dcIp}:$remotePfxPath"  2>&1 | Out-Null
      if ($LASTEXITCODE -ne 0) {
        Remove-Item -Recurse -Force $tmpDir -ErrorAction SilentlyContinue
        throw "[ldaps-cert] scp of PFX failed (rc=$LASTEXITCODE)"
      }
      scp -o ConnectTimeout=15 -o BatchMode=yes -o StrictHostKeyChecking=no $pemIntFile  "$${user}@$${dcIp}:$remoteIntPath"  2>&1 | Out-Null
      if ($LASTEXITCODE -ne 0) {
        Remove-Item -Recurse -Force $tmpDir -ErrorAction SilentlyContinue
        throw "[ldaps-cert] scp of intermediate PEM failed (rc=$LASTEXITCODE)"
      }
      scp -o ConnectTimeout=15 -o BatchMode=yes -o StrictHostKeyChecking=no $pemRootFile "$${user}@$${dcIp}:$remoteRootPath" 2>&1 | Out-Null
      if ($LASTEXITCODE -ne 0) {
        Remove-Item -Recurse -Force $tmpDir -ErrorAction SilentlyContinue
        throw "[ldaps-cert] scp of root PEM failed (rc=$LASTEXITCODE)"
      }

      # ─── Import: root -> LocalMachine\Root, intermediate -> LocalMachine\CA, leaf -> LocalMachine\My ──
      # Order matters: import root + intermediate FIRST so that when the leaf
      # lands in My and Schannel walks the chain at NTDS startup, it can build
      # leaf -> intermediate -> root locally and qualify the leaf as a default
      # server credential. Without root in LocalMachine\Root, X509Chain.Build
      # returns PartialChain and Schannel logs Event 36886, resetting every
      # LDAPS handshake regardless of how good the leaf + intermediate are.
      $importRemote = @"
        try {
          # 1. Root CA -> LocalMachine\Root (idempotent: replace by CN)
          Get-ChildItem Cert:\LocalMachine\Root -ErrorAction SilentlyContinue | Where-Object {
            `$_.Subject -match 'CN=$rootCommonName'
          } | ForEach-Object {
            Write-Output ('removing existing root: thumbprint=' + `$_.Thumbprint);
            Remove-Item `$_.PSPath -Force
          };
          `$rootImp = Import-Certificate -FilePath 'C:\Windows\Temp\dc-ldaps-root.pem' -CertStoreLocation 'Cert:\LocalMachine\Root';
          Write-Output ('imported root: thumbprint=' + `$rootImp.Thumbprint + ' subject=' + `$rootImp.Subject);

          # 2. Intermediate CA -> LocalMachine\CA (idempotent: replace by CN)
          Get-ChildItem Cert:\LocalMachine\CA -ErrorAction SilentlyContinue | Where-Object {
            `$_.Subject -match 'CN=$intCommonName'
          } | ForEach-Object {
            Write-Output ('removing existing intermediate: thumbprint=' + `$_.Thumbprint);
            Remove-Item `$_.PSPath -Force
          };
          `$intImp = Import-Certificate -FilePath 'C:\Windows\Temp\dc-ldaps-intermediate.pem' -CertStoreLocation 'Cert:\LocalMachine\CA';
          Write-Output ('imported intermediate: thumbprint=' + `$intImp.Thumbprint + ' subject=' + `$intImp.Subject);

          # 3. Leaf+key -> LocalMachine\My (idempotent: replace by subject)
          Get-ChildItem Cert:\LocalMachine\My -ErrorAction SilentlyContinue | Where-Object {
            `$_.Subject -match 'CN=$dcFqdn'
          } | ForEach-Object {
            Write-Output ('removing existing leaf cert: thumbprint=' + `$_.Thumbprint);
            Remove-Item `$_.PSPath -Force
          };
          `$pwd = ConvertTo-SecureString '$pfxPwd' -AsPlainText -Force;
          `$imp = Import-PfxCertificate -FilePath 'C:\Windows\Temp\dc-ldaps.pfx' -CertStoreLocation 'Cert:\LocalMachine\My' -Password `$pwd -Exportable;
          Write-Output ('imported leaf: thumbprint=' + `$imp.Thumbprint + ' subject=' + `$imp.Subject + ' notAfter=' + `$imp.NotAfter.ToString('o'));
          Write-Output ('imported leaf HasPrivateKey: ' + `$imp.HasPrivateKey);

          # 4. Verify chain BUILDS locally before restarting NTDS. If
          # X509Chain.Build returns false here, NTDS will reset every LDAPS
          # handshake -- so fail fast at install time with a clear message
          # instead of waiting for the handshake-verify retry loop to time out.
          `$chain = New-Object System.Security.Cryptography.X509Certificates.X509Chain;
          `$chain.ChainPolicy.RevocationMode = 'NoCheck';
          `$chainOk = `$chain.Build(`$imp);
          if (`$chainOk) {
            Write-Output ('chain build OK: ' + (`$chain.ChainElements | ForEach-Object { `$_.Certificate.Subject }) -join ' -> ');
          } else {
            `$status = (`$chain.ChainStatus | ForEach-Object { `$_.Status + ':' + `$_.StatusInformation }) -join '; ';
            Write-Output ('CHAIN_BUILD_FAILED: ' + `$status);
            exit 1;
          }

          # Cleanup transit files (PFX has a transit pwd embedded; the
          # script file itself contains that pwd literal so we delete that too).
          Remove-Item 'C:\Windows\Temp\dc-ldaps.pfx'              -Force -ErrorAction SilentlyContinue;
          Remove-Item 'C:\Windows\Temp\dc-ldaps-intermediate.pem' -Force -ErrorAction SilentlyContinue;
          Remove-Item 'C:\Windows\Temp\dc-ldaps-root.pem'         -Force -ErrorAction SilentlyContinue;
          Remove-Item 'C:\Windows\Temp\dc-ldaps-import.ps1'       -Force -ErrorAction SilentlyContinue;

          Write-Output 'restarting NTDS to pick up new LDAPS cert (~10-30s outage)...';
          Restart-Service NTDS -Force;
          Start-Sleep -Seconds 20;
          Write-Output ('NTDS service status: ' + (Get-Service NTDS).Status);
        } catch {
          Write-Output ('IMPORT_FAILED: ' + `$_);
          exit 1;
        }
"@
      # Ship the import script as a file rather than -EncodedCommand. The
      # base64 of the UTF-16 import script is ~10KB which exceeds Windows'
      # ~8KB command-line limit; cmd.exe rejects with "The command line is
      # too long." -- scp + powershell -File sidesteps the limit entirely.
      $importLocalPath  = Join-Path $tmpDir 'dc-ldaps-import.ps1'
      $remoteScriptPath = 'C:/Windows/Temp/dc-ldaps-import.ps1'
      Set-Content -Path $importLocalPath -Value $importRemote -Encoding UTF8
      scp -o ConnectTimeout=15 -o BatchMode=yes -o StrictHostKeyChecking=no $importLocalPath "$${user}@$${dcIp}:$remoteScriptPath" 2>&1 | Out-Null
      if ($LASTEXITCODE -ne 0) {
        Remove-Item -Recurse -Force $tmpDir -ErrorAction SilentlyContinue
        throw "[ldaps-cert] scp of import script failed (rc=$LASTEXITCODE)"
      }
      $importOut = ssh -o ConnectTimeout=60 -o BatchMode=yes -o StrictHostKeyChecking=no $user@$dcIp "powershell -NoProfile -ExecutionPolicy Bypass -File $remoteScriptPath" 2>&1 | Out-String

      # Cleanup build-host tmp dir regardless of success
      Remove-Item -Recurse -Force $tmpDir -ErrorAction SilentlyContinue

      if ($LASTEXITCODE -ne 0 -or $importOut -match 'IMPORT_FAILED:|CHAIN_BUILD_FAILED:') {
        throw "[ldaps-cert] dc-nexus cert install failed. Output:`n$importOut"
      }
      Write-Host "[ldaps-cert] $($importOut.Trim())"

      # ─── Verify LDAPS handshake actually completes on dc-nexus:636 ────
      Write-Host "[ldaps-cert] verifying LDAPS handshake on $${dcIp}:636..."
      Start-Sleep -Seconds 5
      $verifyOk      = $false
      $verifySubject = ''
      $verifyIssuer  = ''
      $verifyError   = ''
      for ($i = 1; $i -le 8; $i++) {
        $tcp = $null
        $ssl = $null
        try {
          $tcp = New-Object System.Net.Sockets.TcpClient
          $tcp.Connect($dcIp, 636)
          $stream = $tcp.GetStream()
          $ssl = New-Object System.Net.Security.SslStream($stream, $false, { param($s, $cert, $chain, $err) $true })
          $ssl.AuthenticateAsClient($dcFqdn)
          $verifySubject = $ssl.RemoteCertificate.Subject
          $verifyIssuer  = $ssl.RemoteCertificate.Issuer
          $verifyOk = $true
          break
        } catch {
          $verifyError = $_.Exception.Message
          Write-Host "[ldaps-cert] LDAPS handshake not ready (attempt $i/8): $verifyError -- sleeping 5s..."
          Start-Sleep -Seconds 5
        } finally {
          if ($ssl) { $ssl.Dispose() }
          if ($tcp) { $tcp.Close() }
        }
      }

      if (-not $verifyOk) {
        # ─── On failure, dump Schannel + Directory Service events from dc-nexus ──
        # so we can see exactly why AD rejected the handshake. The events are
        # written by Schannel/NTDS when the cert load or handshake fails.
        Write-Host "[ldaps-cert] handshake failed -- pulling Schannel + NTDS event diagnostics from dc-nexus"
        $diagRemote = @"
          Write-Output '=== Schannel events (System log, last 15) ===';
          Get-WinEvent -FilterHashtable @{LogName='System'; ProviderName='Schannel'} -MaxEvents 15 -ErrorAction SilentlyContinue |
            ForEach-Object { Write-Output (`$_.TimeCreated.ToString('o') + ' Id=' + `$_.Id + ' Level=' + `$_.LevelDisplayName + ' :: ' + (`$_.Message -replace '\r?\n',' | ')) };

          Write-Output '=== Directory Service events (last 8) ===';
          Get-WinEvent -LogName 'Directory Service' -MaxEvents 8 -ErrorAction SilentlyContinue |
            ForEach-Object { Write-Output (`$_.TimeCreated.ToString('o') + ' Id=' + `$_.Id + ' :: ' + ((`$_.Message -replace '\r?\n',' | ').Substring(0, [Math]::Min(280, (`$_.Message -replace '\r?\n',' | ').Length)))) };

          Write-Output '=== LDAPS cert in LocalMachine\My ===';
          Get-ChildItem Cert:\LocalMachine\My | Where-Object { `$_.Subject -match 'CN=$dcFqdn' } |
            ForEach-Object {
              Write-Output ('  Thumbprint:    ' + `$_.Thumbprint);
              Write-Output ('  Subject:       ' + `$_.Subject);
              Write-Output ('  Issuer:        ' + `$_.Issuer);
              Write-Output ('  NotAfter:      ' + `$_.NotAfter.ToString('o'));
              Write-Output ('  HasPrivateKey: ' + `$_.HasPrivateKey);
              try {
                `$rsa = [System.Security.Cryptography.X509Certificates.RSACertificateExtensions]::GetRSAPrivateKey(`$_);
                if (`$rsa) { Write-Output ('  RSA key:       accessible (' + `$rsa.KeySize + ' bits)') }
                else       { Write-Output '  RSA key:       NOT accessible (null)' }
              } catch {
                Write-Output ('  RSA key:       NOT accessible -- ' + `$_.Exception.Message)
              };
              `$ekuExt = `$_.Extensions | Where-Object { `$_.Oid.Value -eq '2.5.29.37' } | Select-Object -First 1;
              if (`$ekuExt) {
                Write-Output ('  EKU:           ' + (`$ekuExt.Format(`$false)))
              } else {
                Write-Output '  EKU:           (none -- this would block LDAPS)'
              };
              `$sanExt = `$_.Extensions | Where-Object { `$_.Oid.Value -eq '2.5.29.17' } | Select-Object -First 1;
              if (`$sanExt) {
                Write-Output ('  SAN:           ' + (`$sanExt.Format(`$false)))
              } else {
                Write-Output '  SAN:           (none)'
              }
            };
"@
        $diagBytes = [System.Text.Encoding]::Unicode.GetBytes($diagRemote)
        $diagB64   = [Convert]::ToBase64String($diagBytes)
        $diagOut   = ssh -o ConnectTimeout=30 -o BatchMode=yes -o StrictHostKeyChecking=no $user@$dcIp "powershell -NoProfile -EncodedCommand $diagB64" 2>&1 | Out-String

        throw "[ldaps-cert] dc-nexus LDAPS handshake on $${dcIp}:636 still failing after 8 retries (last error: $verifyError)`n--- DIAGNOSTICS FROM DC ---`n$($diagOut.Trim())"
      }
      Write-Host "[ldaps-cert] dc-nexus LDAPS handshake OK -- subject=$verifySubject, issuer=$verifyIssuer"
    PWSH
  }
}
