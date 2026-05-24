/*
 * role-overlay-vault-pki-spark.tf -- Phase 0.L.3 setup (Spark HA mTLS)
 *
 * Defines the `spark-server` PKI role at pki_int/. Leaf-cert role for the 5
 * Spark nodes (2 masters + 3 workers). Per-host CN/SAN passed at issue time by
 * nexus-infra-lakehouse's role-overlay-spark-tls.tf.
 *
 * Certs cover: CN <hostname>.nexus.lab; SANs <hostname>, <hostname>.nexus.lab,
 * the Web UI front door spark-master.nexus.lab, localhost; IPs the service IPs +
 * the backplane IPs + 127.0.0.1. server+client EKU; 90-day TTL. Used for the
 * Spark master/worker Web UI HTTPS + the CA the Spark JVM trusts for Nessie/MinIO.
 *
 * The 3-node ZooKeeper ensemble is NOT covered -- it runs plaintext on the
 * isolated VMnet10 backplane (ADR-0035), so no ZK cert is issued.
 *
 * Selective ops: var.enable_vault_pki AND var.enable_spark_pki.
 */

resource "null_resource" "vault_pki_spark_role" {
  count = var.enable_vault_cluster && var.enable_vault_init && var.enable_vault_pki && var.enable_spark_pki ? 1 : 0

  triggers = {
    int_id               = length(null_resource.vault_pki_intermediate_ca) > 0 ? null_resource.vault_pki_intermediate_ca[0].id : "disabled"
    role_name            = var.vault_pki_spark_role_name
    leaf_ttl             = var.vault_pki_leaf_ttl
    spark_role_overlay_v = "1"
  }

  depends_on = [null_resource.vault_pki_intermediate_ca]

  provisioner "local-exec" {
    when        = create
    interpreter = ["pwsh", "-NoProfile", "-Command"]
    command     = <<-PWSH
      $ip          = '${local.vault_1_ip}'
      $user        = '${local.ssh_user}'
      $roleName    = '${var.vault_pki_spark_role_name}'
      $leafTtl     = '${var.vault_pki_leaf_ttl}'
      $keysFileRaw = '${var.vault_init_keys_file}'
      $keysFile    = $ExecutionContext.InvokeCommand.ExpandString($keysFileRaw.Replace('$HOME', $env:USERPROFILE))

      if (-not (Test-Path $keysFile)) { throw "[pki-spark] keys file $keysFile missing" }
      $rootToken = (Get-Content $keysFile | ConvertFrom-Json).root_token

      $bash = @"
set -euo pipefail
export VAULT_TOKEN='$rootToken'
export VAULT_SKIP_VERIFY=true
export VAULT_ADDR=https://127.0.0.1:8200

echo "[pki-spark] writing pki_int/roles/$roleName (idempotent overwrite)"
vault write pki_int/roles/$roleName \
  allowed_domains='nexus.lab,spark-master.nexus.lab,spark-master-1,spark-master-2,spark-worker-1,spark-worker-2,spark-worker-3,spark-master-1.nexus.lab,spark-master-2.nexus.lab,spark-worker-1.nexus.lab,spark-worker-2.nexus.lab,spark-worker-3.nexus.lab,localhost' \
  allow_subdomains=false \
  allow_bare_domains=true \
  allow_glob_domains=false \
  allow_ip_sans=true \
  enforce_hostnames=false \
  server_flag=true \
  client_flag=true \
  key_type=rsa \
  key_bits=4096 \
  ttl='$leafTtl' \
  max_ttl='$leafTtl' \
  no_store=false >/dev/null

ALLOWED=`$(vault read -format=json pki_int/roles/$roleName | jq -r '.data.allowed_domains | length')
echo "[pki-spark] role pki_int/roles/$roleName configured (allowed_domains=`$ALLOWED entries, ttl=$leafTtl, server+client EKU)"
"@

      $b64 = [Convert]::ToBase64String([System.Text.UTF8Encoding]::new($false).GetBytes($bash))
      Write-Host "[pki-spark] dispatching to $${ip} via base64"
      $output = ssh -o ConnectTimeout=30 -o BatchMode=yes -o StrictHostKeyChecking=no $user@$ip "echo '$b64' | base64 -d | bash" 2>&1 | Out-String
      $rc = $LASTEXITCODE
      Write-Host $output.Trim()
      if ($rc -ne 0) { throw "[pki-spark] script failed (rc=$rc)" }
    PWSH
  }
}
