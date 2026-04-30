/*
 * role-overlay-vault-cluster.tf -- bring up the 3-node Vault Raft cluster
 * after the clones land + KV-v2 + userpass + AppRole + smoke secret.
 *
 * Phase 0.D.1 layer running on top of module.vault_1/2/3 (the bare
 * Packer-template clones). Four sequential null_resources, top-level so
 * each is independently `-target`-able for iteration:
 *
 *   1. vault_ready_probe   -- SSH echo probes to all 3 nodes + verify
 *                             vault.service is Running on each.
 *   2. vault_init_leader   -- vault-1 only: vault operator init (5 keys,
 *                             threshold 3) + unseal. Idempotent via
 *                             vault status check (initialized + sealed).
 *                             Init JSON persisted to var.vault_init_keys_file
 *                             on the build host (mode 0600).
 *   3. vault_join_followers -- vault-2 + vault-3: vault operator raft join
 *                              to vault-1, then unseal with same 3 keys.
 *                              Idempotent via raft list-peers + sealed
 *                              check.
 *   4. vault_post_init      -- enable KV-v2 at nexus/, enable userpass
 *                              auth + create operator user, enable
 *                              AppRole + create initial role, write
 *                              smoke secret at nexus/smoke/canary.
 *                              All idempotent via state probes.
 *
 * SSH transit pattern: bash scripts piped through base64 (analogous to
 * the Windows-side base64 PowerShell pattern from 0.C.2/0.C.3 -- avoids
 * shell-quoting hell when the script has nested $vars and quoting).
 *
 * VAULT_SKIP_VERIFY=true throughout (self-signed bootstrap TLS; 0.D.2
 * pivots to PKI-issued certs). Build-host operator must also set
 * VAULT_SKIP_VERIFY for direct CLI usage until 0.D.2 lands.
 *
 * Reachability invariant (memory/feedback_lab_host_reachability.md):
 *   - All operations are outbound from build host -> Vault nodes; no
 *     firewall changes; SSH/22 + 8200 reachability from 10.0.70.x stays
 *     intact (the nftables ruleset baked in the Packer template
 *     allows VMnet11 inbound on 8200).
 */

locals {
  vault_1_ip       = "192.168.70.121"
  vault_2_ip       = "192.168.70.122"
  vault_3_ip       = "192.168.70.123"
  vault_node_ips   = [local.vault_1_ip, local.vault_2_ip, local.vault_3_ip]
  vault_node_names = ["vault-1", "vault-2", "vault-3"]

  vault_leader_cluster_addr = "https://192.168.10.121:8201"
  vault_leader_api_addr     = "https://192.168.70.121:8200"

  ssh_user = var.vault_node_user
}

# ─── 1. Wait for cluster nodes ready (SSH + vault.service Running) ────────
resource "null_resource" "vault_ready_probe" {
  count = var.enable_vault_cluster && var.enable_vault_init ? 1 : 0

  triggers = {
    vault_1_id      = module.vault_1[0].vm_name
    vault_2_id      = module.vault_2[0].vm_name
    vault_3_id      = module.vault_3[0].vm_name
    ready_overlay_v = "2" # v2 = `$${ip}:` instead of `$ip:` in log messages -- PS parses `$ip:` as scope qualifier (like $env:, $script:) and errors "Variable reference is not valid". Affects 6 lines. v1 = initial implementation.
  }

  depends_on = [module.vault_1, module.vault_2, module.vault_3]

  provisioner "local-exec" {
    when        = create
    interpreter = ["pwsh", "-NoProfile", "-Command"]
    command     = <<-PWSH
      $ips     = @('${local.vault_1_ip}', '${local.vault_2_ip}', '${local.vault_3_ip}')
      $user    = '${local.ssh_user}'
      $timeout = ${var.vault_cluster_timeout_minutes}

      foreach ($ip in $ips) {
        Write-Host "[vault ready] probing SSH on $ip..."
        $bootDeadline = (Get-Date).AddMinutes($timeout)
        $sshReady = $false
        while ((Get-Date) -lt $bootDeadline) {
          $probe = (ssh -o ConnectTimeout=5 -o ConnectionAttempts=1 -o BatchMode=yes -o StrictHostKeyChecking=no $user@$ip "echo ok" 2>&1 | Out-String).Trim()
          if ($probe -eq 'ok') { $sshReady = $true; break }
          Start-Sleep -Seconds 15
        }
        if (-not $sshReady) {
          throw "[vault ready] $${ip}: ssh echo probe never succeeded after $timeout min"
        }
        Write-Host "[vault ready] $${ip}: SSH ready"

        Write-Host "[vault ready] $${ip}: probing vault.service..."
        $vaultDeadline = (Get-Date).AddMinutes($timeout)
        $vaultReady = $false
        while ((Get-Date) -lt $vaultDeadline) {
          $status = (ssh -o ConnectTimeout=5 -o BatchMode=yes -o StrictHostKeyChecking=no $user@$ip "systemctl is-active vault.service" 2>&1 | Out-String).Trim()
          if ($status -eq 'active') { $vaultReady = $true; break }
          Write-Host "[vault ready] $${ip}: vault.service status='$status', retrying..."
          Start-Sleep -Seconds 10
        }
        if (-not $vaultReady) {
          throw "[vault ready] $${ip}: vault.service never became active after $timeout min"
        }
        Write-Host "[vault ready] $${ip}: vault.service active"
      }

      Write-Host "[vault ready] all 3 nodes ready -- SSH + vault.service active"
    PWSH
  }
}

# ─── 2. Init leader (vault-1) + unseal ────────────────────────────────────
resource "null_resource" "vault_init_leader" {
  count = var.enable_vault_cluster && var.enable_vault_init ? 1 : 0

  triggers = {
    ready_id           = null_resource.vault_ready_probe[0].id
    init_keys_file     = var.vault_init_keys_file
    init_key_shares    = var.vault_init_key_shares
    init_key_threshold = var.vault_init_key_threshold
    init_overlay_v     = "1"
  }

  depends_on = [null_resource.vault_ready_probe]

  provisioner "local-exec" {
    when        = create
    interpreter = ["pwsh", "-NoProfile", "-Command"]
    command     = <<-PWSH
      $ip          = '${local.vault_1_ip}'
      $user        = '${local.ssh_user}'
      $shares      = ${var.vault_init_key_shares}
      $threshold   = ${var.vault_init_key_threshold}
      $keysFileRaw = '${var.vault_init_keys_file}'
      # Expand $HOME on the build host (we don't trust Terraform to do this in a string default)
      $keysFile    = $ExecutionContext.InvokeCommand.ExpandString($keysFileRaw.Replace('$HOME', $env:USERPROFILE))

      # ─── Step A: idempotency check -- vault status JSON ───────────────
      $statusRaw = ssh -o ConnectTimeout=15 -o BatchMode=yes -o StrictHostKeyChecking=no $user@$ip "VAULT_SKIP_VERIFY=true vault status -format=json -address=https://127.0.0.1:8200" 2>&1 | Out-String
      # vault status exits 2 when sealed but initialized, 1 when uninitialized,
      # 0 when initialized+unsealed. We parse the JSON regardless.
      $statusJson = $null
      try { $statusJson = $statusRaw | ConvertFrom-Json } catch { }

      if ($statusJson -and $statusJson.initialized -eq $true -and $statusJson.sealed -eq $false) {
        Write-Host "[vault init-leader] $ip already initialized + unsealed; checking key file..."
        if (Test-Path $keysFile) {
          Write-Host "[vault init-leader] keys file present at $keysFile -- no-op"
          exit 0
        } else {
          Write-Host "[vault init-leader] WARN: vault initialized but keys file missing at $keysFile"
          Write-Host "[vault init-leader] this means a previous init succeeded but keys weren't persisted (rare)"
          Write-Host "[vault init-leader] cluster is reachable but un-recoverable on next seal -- consider terraform destroy + apply"
          exit 0
        }
      }

      if ($statusJson -and $statusJson.initialized -eq $true -and $statusJson.sealed -eq $true) {
        Write-Host "[vault init-leader] $ip initialized but sealed; attempting unseal from $keysFile..."
        if (-not (Test-Path $keysFile)) {
          throw "[vault init-leader] $ip is sealed but keys file $keysFile is missing -- cannot unseal"
        }
        $keys = (Get-Content $keysFile | ConvertFrom-Json).unseal_keys_b64
        for ($i = 0; $i -lt $threshold; $i++) {
          $k = $keys[$i]
          ssh -o ConnectTimeout=15 -o BatchMode=yes -o StrictHostKeyChecking=no $user@$ip "VAULT_SKIP_VERIFY=true vault operator unseal -address=https://127.0.0.1:8200 $k" 2>&1 | Out-Null
        }
        Write-Host "[vault init-leader] $ip unsealed"
        exit 0
      }

      # ─── Step B: fresh init ───────────────────────────────────────────
      Write-Host "[vault init-leader] $ip uninitialized -- running vault operator init (shares=$shares threshold=$threshold)"

      $initOutput = ssh -o ConnectTimeout=30 -o BatchMode=yes -o StrictHostKeyChecking=no $user@$ip "VAULT_SKIP_VERIFY=true vault operator init -format=json -key-shares=$shares -key-threshold=$threshold -address=https://127.0.0.1:8200" 2>&1 | Out-String
      if ($LASTEXITCODE -ne 0) {
        throw "[vault init-leader] vault operator init failed (rc=$LASTEXITCODE). Output:`n$initOutput"
      }

      # Parse + persist
      try { $initJson = $initOutput | ConvertFrom-Json } catch {
        throw "[vault init-leader] vault operator init succeeded (rc=0) but output is not valid JSON. Output:`n$initOutput"
      }
      if (-not $initJson.unseal_keys_b64 -or $initJson.unseal_keys_b64.Count -lt $threshold) {
        throw "[vault init-leader] init JSON missing unseal keys (got $($initJson.unseal_keys_b64.Count); expected >=$threshold)"
      }

      # Persist to build-host file (mode 0600 equivalent on Windows: NTFS ACL
      # restricting to owner; pwsh handles this reasonably via icacls if we
      # want airtight, but for now just write + warn)
      $keysDir = Split-Path -Parent $keysFile
      New-Item -ItemType Directory -Force -Path $keysDir | Out-Null
      $initOutput.Trim() | Set-Content -Path $keysFile -Encoding UTF8

      Write-Host "[vault init-leader] init keys + root token persisted to $keysFile"
      Write-Host "[vault init-leader] CRITICAL: this file is the only copy of the unseal keys; back it up and protect it"

      # ─── Step C: unseal leader ─────────────────────────────────────────
      Write-Host "[vault init-leader] unsealing $ip..."
      $keys = $initJson.unseal_keys_b64
      for ($i = 0; $i -lt $threshold; $i++) {
        $k = $keys[$i]
        $unsealOut = ssh -o ConnectTimeout=15 -o BatchMode=yes -o StrictHostKeyChecking=no $user@$ip "VAULT_SKIP_VERIFY=true vault operator unseal -address=https://127.0.0.1:8200 $k" 2>&1 | Out-String
        if ($LASTEXITCODE -ne 0) {
          throw "[vault init-leader] unseal key $($i+1) failed (rc=$LASTEXITCODE). Output:`n$unsealOut"
        }
      }

      # Verify unsealed
      $verifyRaw = ssh -o ConnectTimeout=15 -o BatchMode=yes -o StrictHostKeyChecking=no $user@$ip "VAULT_SKIP_VERIFY=true vault status -format=json -address=https://127.0.0.1:8200" 2>&1 | Out-String
      $verifyJson = $verifyRaw | ConvertFrom-Json
      if ($verifyJson.sealed -eq $true) {
        throw "[vault init-leader] $ip still sealed after unseal -- something is wrong"
      }
      Write-Host "[vault init-leader] $ip initialized + unsealed; HA mode=$($verifyJson.ha_enabled), is_self=$($verifyJson.is_self)"
    PWSH
  }
}

# ─── 3. Join + unseal followers (vault-2, vault-3) ────────────────────────
resource "null_resource" "vault_join_followers" {
  count = var.enable_vault_cluster && var.enable_vault_init ? 1 : 0

  triggers = {
    init_id        = null_resource.vault_init_leader[0].id
    join_overlay_v = "3" # v3 = -leader-ca-cert with leader's actual cert SCP'd in. v2 used -leader-tls-skip-verify which doesn't exist in `vault operator raft join` (`flag provided but not defined`); the supported flag is -leader-ca-cert=<path>. v1 had no peer-cert handling and failed with "failed to get raft challenge".
  }

  depends_on = [null_resource.vault_init_leader]

  provisioner "local-exec" {
    when        = create
    interpreter = ["pwsh", "-NoProfile", "-Command"]
    command     = <<-PWSH
      $follower_ips    = @('${local.vault_2_ip}', '${local.vault_3_ip}')
      $user            = '${local.ssh_user}'
      $threshold       = ${var.vault_init_key_threshold}
      $keysFileRaw     = '${var.vault_init_keys_file}'
      $keysFile        = $ExecutionContext.InvokeCommand.ExpandString($keysFileRaw.Replace('$HOME', $env:USERPROFILE))
      $leaderIp        = '${local.vault_1_ip}'
      $leaderApi       = '${local.vault_leader_api_addr}'
      $leaderCluster   = '${local.vault_leader_cluster_addr}'

      if (-not (Test-Path $keysFile)) {
        throw "[vault join] keys file $keysFile missing -- run init step first"
      }
      $initJson = Get-Content $keysFile | ConvertFrom-Json
      $keys = $initJson.unseal_keys_b64

      # Fetch the leader's TLS cert ONCE -- each clone has its own self-signed
      # bootstrap cert (per-clone via vault-firstboot.sh), and `vault operator
      # raft join` needs to verify the leader's cert via -leader-ca-cert.
      # Phase 0.D.2 will issue from a shared PKI and this cert-shuffle goes
      # away. /etc/vault.d/tls/ is 0750 vault:vault so nexusadmin needs sudo
      # to read; cert itself is 644 (public) but we still need dir traversal.
      Write-Host "[vault join] fetching leader's TLS cert from vault-1..."
      $leaderCertContent = ssh -o ConnectTimeout=15 -o BatchMode=yes -o StrictHostKeyChecking=no "$${user}@$${leaderIp}" 'sudo cat /etc/vault.d/tls/vault.crt' 2>&1 | Out-String
      if ($LASTEXITCODE -ne 0 -or -not $leaderCertContent.Trim()) {
        throw "[vault join] failed to fetch leader's TLS cert. Output:`n$leaderCertContent"
      }
      Write-Host "[vault join] leader cert fetched ($($leaderCertContent.Length) bytes)"

      # Stage to a temp file on the build host so we can scp it to each
      # follower. Cleanup at the end of the resource.
      $tmpCertFile = [System.IO.Path]::GetTempFileName()
      $leaderCertContent.Trim() | Set-Content -Path $tmpCertFile -Encoding ASCII

      foreach ($ip in $follower_ips) {
        Write-Host "[vault join] processing $ip..."

        # Idempotency: check status
        $statusRaw = ssh -o ConnectTimeout=15 -o BatchMode=yes -o StrictHostKeyChecking=no $user@$ip "VAULT_SKIP_VERIFY=true vault status -format=json -address=https://127.0.0.1:8200" 2>&1 | Out-String
        $statusJson = $null
        try { $statusJson = $statusRaw | ConvertFrom-Json } catch { }

        if ($statusJson -and $statusJson.initialized -eq $true -and $statusJson.sealed -eq $false) {
          Write-Host "[vault join] $ip already initialized + unsealed (in cluster), skipping"
          continue
        }

        if (-not $statusJson -or $statusJson.initialized -ne $true) {
          # Fresh node -- copy leader's cert + run raft join with -leader-ca-cert.
          # `vault operator raft join` does NOT have a -leader-tls-skip-verify
          # flag (v2 of this overlay tried that and got "flag provided but not
          # defined"). Pre-PKI, the supported path is -leader-ca-cert pointing
          # at the leader's actual self-signed cert. We SCP'd it to the build
          # host above; now SCP it to each follower at /tmp/vault-leader.crt.
          Write-Host "[vault join] $ip: copying leader cert to /tmp/vault-leader.crt"
          scp -o ConnectTimeout=15 -o BatchMode=yes -o StrictHostKeyChecking=no $tmpCertFile "$${user}@$${ip}:/tmp/vault-leader.crt" 2>&1 | Out-Null
          if ($LASTEXITCODE -ne 0) {
            throw "[vault join] scp of leader cert to $ip failed (rc=$LASTEXITCODE)"
          }

          Write-Host "[vault join] $ip joining raft cluster at $leaderApi..."
          $joinOut = ssh -o ConnectTimeout=30 -o BatchMode=yes -o StrictHostKeyChecking=no $user@$ip "VAULT_SKIP_VERIFY=true vault operator raft join -address=https://127.0.0.1:8200 -leader-ca-cert=/tmp/vault-leader.crt $leaderApi" 2>&1 | Out-String
          if ($LASTEXITCODE -ne 0) {
            throw "[vault join] raft join on $ip failed (rc=$LASTEXITCODE). Output:`n$joinOut"
          }
          Write-Host "[vault join] $ip raft join succeeded"
          Start-Sleep -Seconds 5  # let raft handshake settle before unseal
        }

        # Unseal (whether fresh-joined or just sealed)
        Write-Host "[vault join] unsealing $ip..."
        for ($i = 0; $i -lt $threshold; $i++) {
          $k = $keys[$i]
          $unsealOut = ssh -o ConnectTimeout=15 -o BatchMode=yes -o StrictHostKeyChecking=no $user@$ip "VAULT_SKIP_VERIFY=true vault operator unseal -address=https://127.0.0.1:8200 $k" 2>&1 | Out-String
          if ($LASTEXITCODE -ne 0) {
            throw "[vault join] unseal $ip key $($i+1) failed (rc=$LASTEXITCODE). Output:`n$unsealOut"
          }
        }

        # Verify
        $verifyRaw = ssh -o ConnectTimeout=15 -o BatchMode=yes -o StrictHostKeyChecking=no $user@$ip "VAULT_SKIP_VERIFY=true vault status -format=json -address=https://127.0.0.1:8200" 2>&1 | Out-String
        $verifyJson = $verifyRaw | ConvertFrom-Json
        if ($verifyJson.sealed -eq $true) {
          throw "[vault join] $ip still sealed after unseal"
        }
        Write-Host "[vault join] $ip joined + unsealed; ha_enabled=$($verifyJson.ha_enabled)"
      }

      # Cleanup the local temp cert file
      Remove-Item -Force $tmpCertFile -ErrorAction SilentlyContinue

      # Final cluster verification: leader's raft list-peers should show 3
      Start-Sleep -Seconds 5  # raft membership settles
      $rootToken    = $initJson.root_token
      $peersRaw = ssh -o ConnectTimeout=15 -o BatchMode=yes -o StrictHostKeyChecking=no $user@$leaderIp "VAULT_TOKEN=$rootToken VAULT_SKIP_VERIFY=true vault operator raft list-peers -format=json -address=https://127.0.0.1:8200" 2>&1 | Out-String
      $peersJson = $null
      try { $peersJson = $peersRaw | ConvertFrom-Json } catch { }

      if ($peersJson -and $peersJson.data.config.servers) {
        $serverCount = $peersJson.data.config.servers.Count
        Write-Host "[vault join] cluster peer count: $serverCount"
        $peersJson.data.config.servers | ForEach-Object {
          Write-Host "[vault join]   peer: node_id=$($_.node_id) address=$($_.address) leader=$($_.leader)"
        }
        if ($serverCount -ne 3) {
          throw "[vault join] expected 3 peers, got $serverCount"
        }
      } else {
        Write-Host "[vault join] WARN: raft list-peers output unparseable. Raw:`n$peersRaw"
      }

      Write-Host "[vault join] cluster fully formed -- 3 peers, raft healthy"
    PWSH
  }
}

# ─── 4. Post-init: KV-v2 + userpass + AppRole + smoke secret ──────────────
resource "null_resource" "vault_post_init" {
  count = var.enable_vault_cluster && var.enable_vault_init ? 1 : 0

  triggers = {
    join_id             = null_resource.vault_join_followers[0].id
    kv_mount_path       = var.vault_kv_mount_path
    userpass_user       = var.vault_userpass_user
    approle_name        = var.vault_approle_name
    post_init_overlay_v = "1"
  }

  depends_on = [null_resource.vault_join_followers]

  provisioner "local-exec" {
    when        = create
    interpreter = ["pwsh", "-NoProfile", "-Command"]
    command     = <<-PWSH
      $ip            = '${local.vault_1_ip}'
      $user          = '${local.ssh_user}'
      $kvPath        = '${var.vault_kv_mount_path}'
      $userpassUser  = '${var.vault_userpass_user}'
      $userpassPwd   = '${var.vault_userpass_password}'
      $approleName   = '${var.vault_approle_name}'
      $keysFileRaw   = '${var.vault_init_keys_file}'
      $keysFile      = $ExecutionContext.InvokeCommand.ExpandString($keysFileRaw.Replace('$HOME', $env:USERPROFILE))

      if (-not (Test-Path $keysFile)) {
        throw "[vault post-init] keys file $keysFile missing"
      }
      $rootToken = (Get-Content $keysFile | ConvertFrom-Json).root_token

      # Build a single bash script, base64-transit it for clean quoting.
      # Each step is idempotent: probe state, only mutate if needed.
      $bash = @"
set -euo pipefail
export VAULT_TOKEN='$rootToken'
export VAULT_SKIP_VERIFY=true
export VAULT_ADDR=https://127.0.0.1:8200

# KV-v2 at nexus/
if vault secrets list -format=json | jq -e '."$kvPath/"' >/dev/null 2>&1; then
  echo '[post-init] KV-v2 at $kvPath/ already mounted, skipping'
else
  echo '[post-init] mounting KV-v2 at $kvPath/'
  vault secrets enable -path=$kvPath -version=2 kv
fi

# userpass auth
if vault auth list -format=json | jq -e '."userpass/"' >/dev/null 2>&1; then
  echo '[post-init] userpass auth already enabled, skipping enable'
else
  echo '[post-init] enabling userpass auth'
  vault auth enable userpass
fi

# Operator user
echo '[post-init] writing userpass user $userpassUser (idempotent overwrite)'
vault write auth/userpass/users/$userpassUser password='$userpassPwd' policies=default

# AppRole auth
if vault auth list -format=json | jq -e '."approle/"' >/dev/null 2>&1; then
  echo '[post-init] approle auth already enabled, skipping enable'
else
  echo '[post-init] enabling approle auth'
  vault auth enable approle
fi

# Initial AppRole role
echo '[post-init] writing AppRole $approleName (idempotent)'
vault write auth/approle/role/$approleName \
  token_policies=default \
  token_ttl=1h \
  token_max_ttl=4h \
  secret_id_ttl=24h

# Smoke secret -- the smoke gate's read target
echo '[post-init] writing smoke secret at $kvPath/smoke/canary'
vault kv put $kvPath/smoke/canary value=ok timestamp="`$(date -Iseconds)" phase=0.D.1

echo '[post-init] verify -- read smoke secret back'
vault kv get -format=json $kvPath/smoke/canary | jq -r '.data.data'

echo '[post-init] complete'
"@

      $bytes = [System.Text.UTF8Encoding]::new($false).GetBytes($bash)
      $b64   = [Convert]::ToBase64String($bytes)

      Write-Host "[vault post-init] dispatching post-init script to $ip via base64"
      $output = ssh -o ConnectTimeout=30 -o BatchMode=yes -o StrictHostKeyChecking=no $user@$ip "echo '$b64' | base64 -d | bash" 2>&1 | Out-String
      $rc = $LASTEXITCODE
      Write-Host $output.Trim()
      if ($rc -ne 0) {
        throw "[vault post-init] script failed (rc=$rc)"
      }

      Write-Host "[vault post-init] cluster fully bootstrapped -- KV-v2 mounted, auth methods enabled, smoke secret written"
    PWSH
  }
}
