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
 * PFX construction: done on vault-1 via `openssl pkcs12 -export`, NOT
 * via .NET X509Certificate2.CreateFromPemFile + Export(Pfx) on the
 * build host. The .NET path produced PFXes whose private keys imported
 * as ephemeral / non-persisted on Windows, which Schannel could not use
 * for the LDAPS server side -- AD reset every TLS handshake mid-flight
 * with "An existing connection was forcibly closed by the remote host"
 * before serving any cert. openssl produces a stock PKCS#12 that
 * Import-PfxCertificate persists into MachineKeys cleanly so Schannel
 * can sign the handshake.
 *
 * Idempotency: probe LocalMachine\My for the leaf AND LocalMachine\CA
 * for the intermediate. Skip if both present + leaf valid >30d. Otherwise
 * re-issue + re-install both stores + restart NTDS.
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
    ldaps_overlay_v = "3" # v3: openssl-built PFX on vault-1 (not .NET on build host) -- avoids ephemeral private key that Schannel could not use, plus diagnostic Schannel/NTDS event dumps on verify failure. v2: leaf+intermediate stores, .NET PFX (still failed). v1: leaf-only.
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
      $intCommonName  = '${var.vault_pki_intermediate_common_name}'
      $keysFileRaw    = '${var.vault_init_keys_file}'
      $keysFile       = $ExecutionContext.InvokeCommand.ExpandString($keysFileRaw.Replace('$HOME', $env:USERPROFILE))

      if (-not (Test-Path $keysFile)) {
        throw "[ldaps-cert] vault-init.json missing at $keysFile"
      }
      $rootToken = (Get-Content $keysFile | ConvertFrom-Json).root_token

      # ─── Idempotency probe: dc-nexus already has valid PKI-issued cert? ──
      # Probe BOTH the leaf (LocalMachine\My) AND the intermediate
      # (LocalMachine\CA). If either is missing, re-issue + re-install both
      # so Schannel always has a full chain to serve.
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
        if (`$leaf -and `$inter) {
          Write-Output ('CERT_OK: leaf=' + `$leaf.Subject + ' valid until ' + `$leaf.NotAfter.ToString('o') + '; intermediate=' + `$inter.Subject)
        } elseif (`$leaf -and -not `$inter) {
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

      # ─── Stage PFX + intermediate PEM on build host ───────────────────
      $tmpDir = New-Item -ItemType Directory -Force -Path (Join-Path $env:TEMP "vault-ldaps-cert-$(Get-Random)")
      $pfxFile    = Join-Path $tmpDir 'dc-ldaps.pfx'
      $pemIntFile = Join-Path $tmpDir 'intermediate.pem'

      [System.IO.File]::WriteAllBytes($pfxFile, [Convert]::FromBase64String($built.pfx_b64))
      Set-Content -Path $pemIntFile -Value $built.intermediate_pem -Encoding Ascii

      # ─── SCP leaf PFX + intermediate PEM to dc-nexus ─────────────────
      $remotePfxPath = 'C:/Windows/Temp/dc-ldaps.pfx'
      $remoteIntPath = 'C:/Windows/Temp/dc-ldaps-intermediate.pem'
      Write-Host "[ldaps-cert] scp PFX + intermediate PEM to $${dcIp}"
      scp -o ConnectTimeout=15 -o BatchMode=yes -o StrictHostKeyChecking=no $pfxFile     "$${user}@$${dcIp}:$remotePfxPath" 2>&1 | Out-Null
      if ($LASTEXITCODE -ne 0) {
        Remove-Item -Recurse -Force $tmpDir -ErrorAction SilentlyContinue
        throw "[ldaps-cert] scp of PFX failed (rc=$LASTEXITCODE)"
      }
      scp -o ConnectTimeout=15 -o BatchMode=yes -o StrictHostKeyChecking=no $pemIntFile  "$${user}@$${dcIp}:$remoteIntPath" 2>&1 | Out-Null
      if ($LASTEXITCODE -ne 0) {
        Remove-Item -Recurse -Force $tmpDir -ErrorAction SilentlyContinue
        throw "[ldaps-cert] scp of intermediate PEM failed (rc=$LASTEXITCODE)"
      }

      # ─── Import: leaf+key -> LocalMachine\My, intermediate -> LocalMachine\CA ──
      $importRemote = @"
        try {
          # Remove any existing leaf cert with our subject (re-issuing case)
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

          # Probe RSA key accessibility -- if Schannel can't read the private
          # key, GetRSAPrivateKey returns null even when HasPrivateKey is true.
          try {
            `$rsa = [System.Security.Cryptography.X509Certificates.RSACertificateExtensions]::GetRSAPrivateKey(`$imp);
            if (`$rsa) {
              Write-Output ('imported leaf RSA accessible: yes (size=' + `$rsa.KeySize + ')')
            } else {
              Write-Output 'imported leaf RSA accessible: NO (GetRSAPrivateKey returned null)'
            }
          } catch {
            Write-Output ('imported leaf RSA accessible: NO -- ' + `$_.Exception.Message)
          }

          # Remove any existing intermediate with our CN before re-importing
          Get-ChildItem Cert:\LocalMachine\CA -ErrorAction SilentlyContinue | Where-Object {
            `$_.Subject -match 'CN=$intCommonName'
          } | ForEach-Object {
            Write-Output ('removing existing intermediate: thumbprint=' + `$_.Thumbprint);
            Remove-Item `$_.PSPath -Force
          };

          `$intImp = Import-Certificate -FilePath 'C:\Windows\Temp\dc-ldaps-intermediate.pem' -CertStoreLocation 'Cert:\LocalMachine\CA';
          Write-Output ('imported intermediate: thumbprint=' + `$intImp.Thumbprint + ' subject=' + `$intImp.Subject);

          Remove-Item 'C:\Windows\Temp\dc-ldaps.pfx'              -Force;
          Remove-Item 'C:\Windows\Temp\dc-ldaps-intermediate.pem' -Force;

          Write-Output 'restarting NTDS to pick up new LDAPS cert (~10-30s outage)...';
          Restart-Service NTDS -Force;
          Start-Sleep -Seconds 20;
          Write-Output ('NTDS service status: ' + (Get-Service NTDS).Status);
        } catch {
          Write-Output ('IMPORT_FAILED: ' + `$_);
          exit 1;
        }
"@
      $importBytes = [System.Text.Encoding]::Unicode.GetBytes($importRemote)
      $importB64   = [Convert]::ToBase64String($importBytes)
      $importOut = ssh -o ConnectTimeout=60 -o BatchMode=yes -o StrictHostKeyChecking=no $user@$dcIp "powershell -NoProfile -EncodedCommand $importB64" 2>&1 | Out-String

      # Cleanup build-host tmp dir regardless of success
      Remove-Item -Recurse -Force $tmpDir -ErrorAction SilentlyContinue

      if ($LASTEXITCODE -ne 0 -or $importOut -match 'IMPORT_FAILED:') {
        throw "[ldaps-cert] dc-nexus PFX import failed. Output:`n$importOut"
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
