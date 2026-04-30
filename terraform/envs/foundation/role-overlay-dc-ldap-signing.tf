/*
 * role-overlay-dc-ldap-signing.tf -- Phase 0.D.3 (foundation side)
 *
 * Lower AD's LDAPServerIntegrity registry value from 2 (Require signing)
 * to 1 (Negotiate) on dc-nexus. Required for plain-LDAP/389 simple binds
 * from non-Windows clients (Vault's go-ldap library, OpenLDAP tools, etc.)
 * that don't auto-negotiate sign-and-seal the way Windows clients do.
 *
 * Discovered 2026-05-01 during 0.D.3 LDAP overlay first cycle. Vault's
 * auth/ldap login probe failed with the misleading wrapper error
 * "failed to bind as user". Trace-level Vault logs revealed the actual
 * underlying error:
 *
 *   ldap.(Client).getUserBindDN: bind (service) failed:
 *   LDAP Result Code 8 "Strong Auth Required"
 *
 * confirming AD's LDAPServerIntegrity=2 was rejecting Vault's BIND ACCOUNT
 * simple bind -- before Vault could even attempt the user bind. No Vault-
 * side config (upndomain, userfilter, discoverdn) can work around this;
 * the fix is on AD.
 *
 * Why this is the lab-acceptable default vs immediately landing LDAPS:
 * LDAPS requires a server cert installed on dc-nexus's Local Computer
 * Personal cert store, which is deferred to 0.D.5 (cert issuance from our
 * PKI + AD-side import). Lowering LDAPServerIntegrity to 1 unblocks 0.D.3
 * today and is documented as an approved deviation per
 * memory/feedback_master_plan_authority.md.
 *
 * Idempotency: probe current value via Get-ItemProperty; only Set + restart
 * NTDS if the value differs from desired. If already matches, no-op (NTDS
 * not restarted, no AD downtime). Re-fires only when var.dc_ldap_server_
 * integrity changes or trigger version bumps.
 *
 * Reachability invariant: NTDS restart causes ~5-30s of AD outage. SSH/22
 * + RDP/3389 from build host unaffected. AD-joined services (jumpbox,
 * future fleet) reconnect transparently after NTDS comes back. The full
 * domain-controller process (LSASS, etc.) is not restarted -- only NTDS.
 *
 * Selective ops: var.enable_dc_ldap_signing_relaxed (default false). Set
 * true via -Vars when bringing up 0.D.3 (alongside enable_vault_ad_
 * integration=true). Lifecycle: revert to 2 (or remove this overlay) in
 * 0.D.5 when LDAPS makes signing mandatory anyway.
 */

resource "null_resource" "dc_ldap_signing" {
  count = var.enable_dc_promotion && var.enable_dc_ldap_signing_relaxed ? 1 : 0

  triggers = {
    dc_verify_id      = null_resource.dc_nexus_verify[0].id
    integrity_value   = var.dc_ldap_server_integrity
    signing_overlay_v = "1"
  }

  depends_on = [null_resource.dc_nexus_verify]

  provisioner "local-exec" {
    when        = create
    interpreter = ["pwsh", "-NoProfile", "-Command"]
    command     = <<-PWSH
      $ip           = '${local.dc_nexus_ip}'
      $desiredValue = ${var.dc_ldap_server_integrity}

      Write-Host "[dc-ldap-signing] dispatching LDAPServerIntegrity tune to $ip (target value: $desiredValue)"

      $remote = @"
        `$path = 'HKLM:\SYSTEM\CurrentControlSet\Services\NTDS\Parameters';
        `$cur = (Get-ItemProperty -Path `$path -Name LDAPServerIntegrity -ErrorAction SilentlyContinue).LDAPServerIntegrity;
        if (`$null -eq `$cur) { `$curStr = '<unset>' } else { `$curStr = `$cur.ToString() };
        Write-Output ('LDAPServerIntegrity current: ' + `$curStr);
        if (`$cur -eq $desiredValue) {
          Write-Output ('LDAPServerIntegrity already matches desired value (' + $desiredValue + '), no-op');
        } else {
          Set-ItemProperty -Path `$path -Name LDAPServerIntegrity -Value $desiredValue -Type DWord;
          Write-Output ('LDAPServerIntegrity set: ' + `$curStr + ' -> ' + $desiredValue);
          Write-Output 'Restarting NTDS service to apply (brief AD outage ~5-30s)...';
          Restart-Service NTDS -Force;
          Start-Sleep -Seconds 10;
          Write-Output ('NTDS service status: ' + (Get-Service NTDS).Status);
          # Verify by re-reading
          `$verify = (Get-ItemProperty -Path `$path -Name LDAPServerIntegrity).LDAPServerIntegrity;
          Write-Output ('LDAPServerIntegrity verified: ' + `$verify);
        }
"@

      $bytes = [System.Text.Encoding]::Unicode.GetBytes($remote)
      $b64   = [Convert]::ToBase64String($bytes)
      $sshOut = ssh -o ConnectTimeout=30 -o BatchMode=yes -o StrictHostKeyChecking=no nexusadmin@$ip "powershell -NoProfile -EncodedCommand $b64" 2>&1 | Out-String
      if ($LASTEXITCODE -ne 0) {
        throw "[dc-ldap-signing] script failed (rc=$LASTEXITCODE). Output:`n$sshOut"
      }
      Write-Host "[dc-ldap-signing] $($sshOut.Trim())"
    PWSH
  }
}
