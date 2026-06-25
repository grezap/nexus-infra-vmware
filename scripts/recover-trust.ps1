#!/usr/bin/env pwsh
<#
.SYNOPSIS
  Re-cert an old-root cluster to the current (new) Vault root CA — the platform CA
  rollover after the v0.8.1 Vault greenfield. Sibling of recover-vault-ha.ps1.

.DESCRIPTION
  Any tier that was OFFLINE during the 2026-06-18/19 Vault greenfield kept its OLD-root
  certs + a vault-agent that can't re-authenticate (its on-node ca-bundle.crt still
  trusts the dead root, so it can't verify the new Vault → no token → can't renew certs
  or read KV). This script heals that, per node, purely over SSH (no Vault round-trip
  from the build host):

    1. push the new-root  ~/.nexus/vault-ca-bundle.crt  -> /etc/vault-agent/ca-bundle.crt
    2. push the host's Jun-19 AppRole sidecar (~/.nexus/vault-agent-<prefix><host>.json);
       extract role_id/secret_id ON-NODE -> /etc/vault-agent/{role-id,secret-id}
    3. force the pkiCert template to re-issue: cp -a + rm the rendered bundle.pem
       (pkiCert persists+reuses the leaf otherwise — the Swarm v0.8.2 lesson)
    4. systemctl restart nexus-vault-agent  -> re-auths to the new Vault -> re-renders a
       NEW-root leaf -> the split script regenerates server-cert.pem
    5. (service phase) restart/reload the tier services so they pick up the new cert
    6. verify: agent token present + the leaf re-rendered today + it chains to the new
       root (openssl verify -CAfile <new-bundle> -untrusted <node ca.pem> <leaf>)

  Certs are STAGED on every node BEFORE any service restarts (intra-tier mTLS needs a
  consistent CA — a lone restarted node can't talk to old-root peers).

  ============================== ⚠ CRITICAL WARNING ==============================
  DO NOT run the service phase of this on an HA DATA tier (Patroni/PG, Galera, etc.).
  The v0.8.1 greenfield rotated EVERY tier's Vault-KV passwords (superuser, replicator,
  rewind, operator). While the vault-agent was broken it COULD NOT re-render, so the
  on-node config kept the OLD passwords — which still matched the OLD PG roles — so the
  cluster ran fine. Healing the agent (step 4) re-renders ALL templates, pulling in the
  NEW KV passwords, which DO NOT match the running roles → replication/rewind auth fails
  → the cluster cannot form a leader → it goes DOWN. (Proven: this broke citus 2026-06-25.)
  The broken agent was effectively PROTECTING the tier.

  => For the platform CA rollover of the data tiers (citus/oltp/analytics/vitess/registry),
     the clean path is a per-tier COLD-REBUILD (its bootstrap overlays set every role from
     the CURRENT KV + issue new-root certs from scratch — exactly what swarm/obs/lakehouse
     got). This script's `-SkipServices` (stage certs only, no restart) is non-destructive
     and fine for staging; the service phase is ONLY safe for stateless components with no
     internal-credential drift. Deadline: the old-root leaves expire ~Aug/Sep 2026.
  ===============================================================================

.PARAMETER Tier
  citus | analytics-clickhouse | vitess | oltp-patroni | kafka | registry
.PARAMETER SkipServices
  Stage the new-root certs only; leave the services on their (consistent) old certs.
.EXAMPLE
  pwsh -File scripts/recover-trust.ps1 -Tier citus
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory, Position = 0)]
    [ValidateSet('citus', 'analytics-clickhouse', 'vitess', 'oltp-patroni', 'kafka', 'registry')]
    [string]$Tier,
    [switch]$SkipServices
)

$ErrorActionPreference = 'Stop'
$nexus = Join-Path $env:USERPROFILE '.nexus'
$caBundle = Join-Path $nexus 'vault-ca-bundle.crt'
$sshKey = Join-Path $env:USERPROFILE '.ssh\nexus_gateway_ed25519'
$sshUser = 'nexusadmin'
$sshOpts = @('-i', $sshKey, '-o', 'StrictHostKeyChecking=no', '-o', 'ConnectTimeout=10', '-o', 'BatchMode=yes')

if (-not (Test-Path $caBundle)) { throw "new-root CA bundle not found: $caBundle" }

# --- per-tier node + cert contract (verified live before each tier's run) ----------
# Node: Name, Ip, Tls (the pkiCert bundle dir), Svc (service unit), Act (restart|reload)
$E = '/etc/nexus-etcd/tls'                          # etcd cert dir (shared shape across tiers)
$TierSpecs = @{
    'citus' = @{
        SidecarPrefix = 'citus-'                    # build-host file = vault-agent-citus-<host>.json
        Nodes         = @(
            @{ Name = 'citus-etcd-1'; Ip = '192.168.70.202'; Tls = $E; Svc = 'nexus-etcd'; Act = 'restart' }
            @{ Name = 'citus-etcd-2'; Ip = '192.168.70.203'; Tls = $E; Svc = 'nexus-etcd'; Act = 'restart' }
            @{ Name = 'citus-etcd-3'; Ip = '192.168.70.204'; Tls = $E; Svc = 'nexus-etcd'; Act = 'restart' }
            @{ Name = 'citus-coord-1'; Ip = '192.168.70.205'; Tls = '/etc/nexus-citus/tls'; Svc = 'nexus-patroni'; Act = 'restart' }
            @{ Name = 'citus-coord-2'; Ip = '192.168.70.206'; Tls = '/etc/nexus-citus/tls'; Svc = 'nexus-patroni'; Act = 'restart' }
            @{ Name = 'citus-worker1-1'; Ip = '192.168.70.207'; Tls = '/etc/nexus-citus/tls'; Svc = 'nexus-patroni'; Act = 'restart' }
            @{ Name = 'citus-worker1-2'; Ip = '192.168.70.208'; Tls = '/etc/nexus-citus/tls'; Svc = 'nexus-patroni'; Act = 'restart' }
            @{ Name = 'citus-worker2-1'; Ip = '192.168.70.209'; Tls = '/etc/nexus-citus/tls'; Svc = 'nexus-patroni'; Act = 'restart' }
            @{ Name = 'citus-worker2-2'; Ip = '192.168.70.210'; Tls = '/etc/nexus-citus/tls'; Svc = 'nexus-patroni'; Act = 'restart' }
        )
        # service waves (ordered). Each: Match selects nodes; Unit/Act override the node's
        # Svc/Act for that wave (so one node can be hit by >1 wave — e.g. a PG node reloads
        # Patroni AND restarts its VIP keepalived). etcd restarts big-bang first (DCS), then
        # Patroni reloads (SIGHUP, no restart), then nexus-keepalived restarts so it re-probes
        # the now-new-root Patroni REST + re-claims the group VIP.
        Waves         = @(
            @{ Label = 'etcd (restart, DCS)'; Match = { $_.Svc -eq 'nexus-etcd' } }
            @{ Label = 'patroni (restart — re-init etcd client with new-root cert; reload is NOT enough on a CA-root change)'; Match = { $_.Svc -eq 'nexus-patroni' } }
            @{ Label = 'keepalived (restart, VIP re-probe)'; Match = { $_.Svc -eq 'nexus-patroni' }; Unit = 'nexus-keepalived'; Act = 'restart' }
        )
    }
}

if (-not $TierSpecs.ContainsKey($Tier)) {
    throw "tier '$Tier' has no descriptor yet. Verify its contract live, then add it to `$TierSpecs (the citus entry is the template)."
}
$spec = $TierSpecs[$Tier]

function Write-Step([string]$m) { Write-Host "`n=== $m ===" -ForegroundColor Cyan }
function Invoke-NodeSsh([string]$ip, [string]$script) {
    $b64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes(($script -replace "`r`n", "`n")))
    & ssh @sshOpts "$sshUser@$ip" "echo $b64 | base64 -d | bash" 2>&1
}

# ---------------------------------------------------------------------------------
# PHASE A — stage new-root trust + force a new-root cert re-render on every node
# ---------------------------------------------------------------------------------
Write-Step "PHASE A — stage new-root certs on all $($spec.Nodes.Count) $Tier nodes (no service disruption)"
$results = @()
foreach ($n in $spec.Nodes) {
    $sidecar = Join-Path $nexus "vault-agent-$($spec.SidecarPrefix)$($n.Name).json"
    if (-not (Test-Path $sidecar)) { Write-Host "[$($n.Name)] MISSING sidecar $sidecar" -ForegroundColor Red; $results += @{ Node = $n.Name; Ok = $false; Why = 'no sidecar' }; continue }
    & scp @sshOpts $caBundle "$($sshUser)@$($n.Ip):/tmp/nt-ca.crt"   *>$null
    & scp @sshOpts $sidecar  "$($sshUser)@$($n.Ip):/tmp/nt-sc.json" *>$null
    $bundle = "$($n.Tls)/bundle.pem"
    $leaf = "$($n.Tls)/server-cert.pem"
    $ca = "$($n.Tls)/ca.pem"
    $remote = @"
set -e
RID=`$(jq -r .role_id /tmp/nt-sc.json); SID=`$(jq -r .secret_id /tmp/nt-sc.json)
[ -n "`$RID" ] && [ "`$RID" != null ] || { echo NO_CREDS; exit 1; }
sudo install -m0644 -o root -g root /tmp/nt-ca.crt /etc/vault-agent/ca-bundle.crt
printf '%s' "`$RID" | sudo tee /etc/vault-agent/role-id   >/dev/null
printf '%s' "`$SID" | sudo tee /etc/vault-agent/secret-id >/dev/null
sudo chmod 0400 /etc/vault-agent/role-id /etc/vault-agent/secret-id
sudo test -f "$bundle" && { sudo cp -a "$bundle" "$bundle.bak"; sudo rm -f "$bundle"; }
sudo systemctl restart nexus-vault-agent
for i in `$(seq 1 30); do sudo test -f /run/nexus-vault-agent/token && break; sleep 1; done
sudo test -f /run/nexus-vault-agent/token || { echo TOKEN_ABSENT; exit 1; }
for i in `$(seq 1 25); do sudo test -f "$bundle" && break; sleep 1; done
sleep 2
ND=`$(sudo openssl x509 -in "$leaf" -noout -startdate 2>/dev/null | sed 's/notBefore=//')
VR=`$(sudo openssl verify -CAfile /etc/vault-agent/ca-bundle.crt -untrusted "$ca" "$leaf" 2>&1 | tail -1)
sudo rm -f /tmp/nt-sc.json /tmp/nt-ca.crt
echo "STAGED leaf='`$ND' verify='`$VR'"
"@
    $out = (Invoke-NodeSsh $n.Ip $remote | Out-String).Trim()
    $ok = $out -match 'STAGED' -and $out -match ': OK'
    $color = if ($ok) { 'Green' } else { 'Red' }
    Write-Host ("[{0,-16}] {1}" -f $n.Name, ($out -split "`n" | Select-Object -Last 1)) -ForegroundColor $color
    $results += @{ Node = $n.Name; Ok = $ok; Why = $out }
}
$staged = ($results | Where-Object { $_.Ok }).Count
Write-Host "`nPhase A: $staged/$($spec.Nodes.Count) nodes staged to new-root." -ForegroundColor $(if ($staged -eq $spec.Nodes.Count) { 'Green' } else { 'Yellow' })
if ($staged -ne $spec.Nodes.Count) { throw "not all nodes staged; refusing to restart services on a mixed tier. Inspect the failures above." }

# ---------------------------------------------------------------------------------
# PHASE B — restart/reload the tier services in waves (all certs are new-root now)
# ---------------------------------------------------------------------------------
if ($SkipServices) {
    Write-Host "`n-SkipServices: certs staged; services left on their old (consistent) certs. Restart at next bring-up." -ForegroundColor Yellow
    return
}
Write-Step "PHASE B — service waves (pick up the new-root certs)"
foreach ($w in $spec.Waves) {
    $wn = @($spec.Nodes | Where-Object $w.Match)
    if ($wn.Count -eq 0) { continue }
    $unitOverride = $w.Unit; $actOverride = $w.Act
    Write-Host "wave: $($w.Label) -> $($wn.Name -join ', ')"
    $wn | ForEach-Object -Parallel {
        $o = $using:sshOpts; $u = $using:sshUser
        $unit = if ($using:unitOverride) { $using:unitOverride } else { $_.Svc }
        $act = if ($using:actOverride) { $using:actOverride } else { $_.Act }
        & ssh @o "$u@$($_.Ip)" "sudo systemctl reset-failed $unit 2>/dev/null; sudo systemctl $act $unit 2>&1; echo RC=`$?" 2>&1 | Select-Object -Last 1
    } -ThrottleLimit 8 | Out-Null
    Start-Sleep -Seconds 12
}

# ---------------------------------------------------------------------------------
# PHASE C — verify every node is new-root + serving
# ---------------------------------------------------------------------------------
Write-Step "PHASE C — verify new-root + service active"
$green = 0
foreach ($n in $spec.Nodes) {
    $leaf = "$($n.Tls)/server-cert.pem"; $ca = "$($n.Tls)/ca.pem"
    $remote = @"
VR=`$(sudo openssl verify -CAfile /etc/vault-agent/ca-bundle.crt -untrusted "$ca" "$leaf" 2>&1 | tail -1)
AC=`$(systemctl is-active $($n.Svc) 2>/dev/null)
echo "verify='`$VR' svc=`$AC"
"@
    $out = (Invoke-NodeSsh $n.Ip $remote | Out-String).Trim()
    $ok = $out -match ': OK' -and $out -match 'svc=active'
    if ($ok) { $green++ }
    Write-Host ("[{0,-16}] {1}" -f $n.Name, $out) -ForegroundColor $(if ($ok) { 'Green' } else { 'Red' })
}
Write-Host "`nrecover-trust $Tier : $green/$($spec.Nodes.Count) nodes new-root + active." -ForegroundColor $(if ($green -eq $spec.Nodes.Count) { 'Green' } else { 'Yellow' })
if ($green -ne $spec.Nodes.Count) { exit 1 }
