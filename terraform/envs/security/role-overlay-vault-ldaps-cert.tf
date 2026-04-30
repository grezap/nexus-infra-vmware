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
 * Idempotency: probe LocalMachine\My for an existing cert with
 * CN=dc-nexus.nexus.lab issued by 'NexusPlatform Intermediate CA' and
 * >30 days remaining. Skip if present + valid. Otherwise re-issue +
 * re-install + restart NTDS.
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
    ldaps_overlay_v = "2" # v2: also install issuing_ca into LocalMachine\CA so Schannel can serve the full chain (without it, AD resets the TLS handshake during LDAPS bind from Vault). v1: leaf-only into LocalMachine\My (handshake reset).
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
      # v2: probe BOTH the leaf (LocalMachine\My) AND the intermediate
      # (LocalMachine\CA). If either is missing, re-issue + re-install both
      # so Schannel always has a full chain to serve. v1 probed only the leaf
      # which let stale leaf-only installs short-circuit even after we
      # learned Schannel resets the LDAPS handshake without the intermediate
      # locally available.
      $probeRemote = @"
        `$leaf = Get-ChildItem Cert:\LocalMachine\My -ErrorAction SilentlyContinue | Where-Object {
          (`$_.Subject -match 'CN=$dcFqdn') -and
          (`$_.Issuer -match '$intCommonName') -and
          ((`$_.NotAfter - (Get-Date)).TotalDays -gt 30)
        } | Select-Object -First 1;
        `$inter = Get-ChildItem Cert:\LocalMachine\CA -ErrorAction SilentlyContinue | Where-Object {
          `$_.Subject -match 'CN=$intCommonName'
        } | Select-Object -First 1;
        if (`$leaf -and `$inter) {
          Write-Output ('CERT_OK: leaf=' + `$leaf.Subject + ' valid until ' + `$leaf.NotAfter.ToString('o') + '; intermediate=' + `$inter.Subject)
        } elseif (`$leaf -and -not `$inter) {
          Write-Output 'CERT_INCOMPLETE_NO_INTERMEDIATE'
        } else {
          Write-Output 'CERT_MISSING_OR_EXPIRING'
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

      Write-Host "[ldaps-cert] dc-nexus needs new PKI-issued LDAPS cert"

      # ─── Issue cert from Vault PKI (SSH to vault-1, run vault CLI) ─────
      Write-Host "[ldaps-cert] issuing cert via pki_int/issue/$roleName for $dcFqdn"
      $issueScript = "VAULT_TOKEN='$rootToken' VAULT_SKIP_VERIFY=true VAULT_ADDR=https://127.0.0.1:8200 vault write -format=json pki_int/issue/$roleName common_name=$dcFqdn alt_names=dc-nexus,DC-NEXUS,DC-NEXUS.nexus.lab ip_sans=$dcIp ttl=$leafTtl"
      $issueRaw = ssh -o ConnectTimeout=30 -o BatchMode=yes -o StrictHostKeyChecking=no $user@$vaultIp $issueScript 2>&1 | Out-String

      try {
        $issued = $issueRaw | ConvertFrom-Json
      } catch {
        throw "[ldaps-cert] vault write pki_int/issue returned non-JSON. Output:`n$issueRaw"
      }

      $certPem    = $issued.data.certificate
      $keyPem     = $issued.data.private_key
      $issuingCa  = $issued.data.issuing_ca
      if (-not $certPem -or -not $keyPem) {
        throw "[ldaps-cert] issued data missing certificate or private_key"
      }
      if (-not $issuingCa) {
        throw "[ldaps-cert] issued data missing issuing_ca (intermediate) -- needed for Schannel chain build"
      }
      Write-Host "[ldaps-cert] issued cert ($($certPem.Length) chars) + key ($($keyPem.Length) chars) + intermediate ($($issuingCa.Length) chars)"

      # ─── Convert PEM -> PFX on build host (.NET; required for Windows import) ──
      $tmpDir = New-Item -ItemType Directory -Force -Path (Join-Path $env:TEMP "vault-ldaps-cert-$(Get-Random)")
      $pemCertFile = Join-Path $tmpDir 'cert.pem'
      $pemKeyFile  = Join-Path $tmpDir 'key.pem'
      $pemIntFile  = Join-Path $tmpDir 'intermediate.pem'
      $pfxFile     = Join-Path $tmpDir 'dc-ldaps.pfx'
      # Random transit-only password for the PFX (used only between build host
      # PEM-to-PFX conversion and dc-nexus Import-PfxCertificate).
      $pfxPwd      = -join ((48..57) + (65..90) + (97..122) | Get-Random -Count 32 | ForEach-Object { [char]$_ })

      Set-Content -Path $pemCertFile -Value $certPem   -Encoding Ascii
      Set-Content -Path $pemKeyFile  -Value $keyPem    -Encoding Ascii
      Set-Content -Path $pemIntFile  -Value $issuingCa -Encoding Ascii

      try {
        $cert = [System.Security.Cryptography.X509Certificates.X509Certificate2]::CreateFromPemFile($pemCertFile, $pemKeyFile)
        $pfxBytes = $cert.Export([System.Security.Cryptography.X509Certificates.X509ContentType]::Pfx, $pfxPwd)
        [System.IO.File]::WriteAllBytes($pfxFile, $pfxBytes)
        Write-Host "[ldaps-cert] PEM converted to PFX (subject=$($cert.Subject))"
      } catch {
        Remove-Item -Recurse -Force $tmpDir -ErrorAction SilentlyContinue
        throw "[ldaps-cert] PEM-to-PFX conversion failed: $_"
      }

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
      # Both stores are required: My holds the LDAPS cert + private key, CA
      # holds the issuing intermediate so Schannel can build the full chain
      # to serve during the TLS handshake. Without CA, Schannel resets the
      # connection mid-handshake when a client tries to bind LDAPS.
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
      # TCP-only check is not enough -- Schannel may accept the TCP open
      # but reset the TLS handshake mid-flight if the cert chain is broken.
      # Do a real SslStream.AuthenticateAsClient + read back the server cert
      # so we know AD is actually serving LDAPS end-to-end before downstream
      # overlays (auth/ldap config, secret-engine, rotate-role) try to bind.
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
          # Skip-verify callback: this is a probe of WHAT cert AD is
          # serving, not a chain-trust check. Vault handles trust on its
          # own with the certificate=@ca-bundle field at bind time.
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
        throw "[ldaps-cert] dc-nexus LDAPS handshake on $${dcIp}:636 still failing after 8 retries (last error: $verifyError)"
      }
      Write-Host "[ldaps-cert] dc-nexus LDAPS handshake OK -- subject=$verifySubject, issuer=$verifyIssuer"
    PWSH
  }
}
