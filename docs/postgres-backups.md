# PostgreSQL backups and restore drill

The private k3s worker backs up `campus` daily at **04:56 UTC** (`56 4 * * *`). The application stores uploaded documents in `public.attachment_blobs`, so a single PostgreSQL snapshot captures each application and its attachment together. The systemd timer catches up once after downtime and the service retries failures every 15 minutes.

A dedicated, unversioned S3 bucket in `us-east-1` blocks public access and encrypts objects with SSE-KMS. S3 Lifecycle expires objects under `postgresql/` after **seven days**. S3 performs physical deletion asynchronously. [S3 Lifecycle expiration](https://docs.aws.amazon.com/AmazonS3/latest/userguide/lifecycle-expire-general-considerations.html)

## Install on the database worker

1. On the deployment workstation, select the existing cluster state and inputs. Review and apply the saved Terraform plan, then read the dedicated bucket output. [Learner Lab state and deployment](learner-lab.md#select-the-state-and-inputs)

   ```bash
   terraform -chdir=infra plan -state="$STATE" -var-file="$VARS" -out="$PLAN"
   terraform -chdir=infra apply -state="$STATE" "$PLAN"
   bucket=$(terraform -chdir=infra output -state="$STATE" -raw backup_bucket_name)
   aws --region us-east-1 s3api get-bucket-lifecycle-configuration --bucket "$bucket" \
     --query 'Rules[].{Status:Status,Prefix:Filter.Prefix,Days:Expiration.Days}'
   ```

2. Wait for the PostgreSQL StatefulSet to be Ready. The worker needs Bash, OpenSSL, AWS CLI v2 and the installed k3s binary. Set `DB_WORKER` to a host-key-verified SSH alias with an authorized route to the private worker. From the checkout, copy the runtime files and run the installer. Repeat this step when replacing the worker.

   ```bash
   set -euo pipefail
   tar -czf - ops/{backup,restore,postgres-backup-common,install-postgres-backup}.sh k8s/postgres/host |
     ssh -T "$DB_WORKER" 'umask 077; mkdir -p ~/pg-backup-install && tar -xzf - -C ~/pg-backup-install'
   ssh -T "$DB_WORKER" "sudo bash ~/pg-backup-install/ops/install-postgres-backup.sh '$bucket'"
   ```

3. On the worker, verify the timer and its next UTC firing time. The node's `k3s.service` starts the agent. The backup service uses its local container runtime to run PostgreSQL 17 tools in the database Pod. AWS CLI obtains temporary credentials from the worker's EC2 instance role and reaches S3 through the VPC gateway endpoint.

   ```bash
   unit=dv-ayan-kassen-1951-postgres-backup
   systemctl is-enabled "$unit.timer"
   systemctl is-active "$unit.timer"
   TZ=UTC systemctl list-timers --all "$unit.timer"
   sudo journalctl -u "$unit.service" -n 20 --no-pager
   ```

Each successful service run writes a unique object key to the journal after S3 acknowledges the SHA-256 of the custom-format archive. On the worker, select the most recent key printed by the service.

```bash
key=$(sudo journalctl -u "$unit.service" -o cat --no-pager |
  awk '/^postgresql\/campus-.*\.dump$/ { key=$0 } END { if (key) print key; else exit 1 }')
```

If the worker has been replaced, an operator with `s3:ListBucket` can also locate the latest archive from the deployment workstation.

```bash
aws --region us-east-1 s3api list-objects-v2 --bucket "$bucket" --prefix postgresql/campus- \
  --output json | jq -er '.Contents | max_by(.LastModified) | .Key'
```

The worker stages one archive in a private temporary directory and uploads it in a single S3 PUT. Keep enough space in `/var/tmp` for the dump. The PostgreSQL claim currently requests 2 GiB. A single PUT supports archives up to 5 GiB. [S3 upload limits](https://docs.aws.amazon.com/AmazonS3/latest/userguide/upload-objects.html)

## Restore and compare a scholarship application

Use an existing test application with an attachment. The following commands run in one root Bash session on the database worker. They fingerprint all fields of the chosen application, measure the attachment and calculate its SHA-256. Only the pass result is printed. Keep the test item unchanged while taking this on-demand backup.

```bash
sudo -i
set -euo pipefail
lib=/usr/local/lib/dv-ayan-kassen-1951-postgres-backup
source "$lib/postgres-backup-common.sh"
load_backup_settings
read -rp 'Test application ID: ' item
[[ $item =~ ^[1-9][0-9]*$ ]]

fingerprint() {
  k3s crictl exec "$pg_container" psql -XqAtw -v ON_ERROR_STOP=1 -U postgres -d "$1" -c "
    SELECT encode(sha256(convert_to(to_jsonb(i)::text, 'UTF8')), 'hex'),
           octet_length(b.content), encode(sha256(b.content), 'hex')
    FROM public.items AS i JOIN public.attachment_blobs AS b ON b.item_id = i.id
    WHERE i.id = $item"
}
before=$(fingerprint campus)
[[ -n $before ]]
key=$("$lib/backup.sh")
test_db=campus_restore_$(date -u +%Y%m%d_%H%M%S)
"$lib/restore.sh" "$key" "$test_db" >/dev/null
after=$(fingerprint "$test_db")
[[ $after == "$before" ]]
echo 'PASS: application fields, attachment length and SHA-256 match.'
```

For a scheduled archive, pass the object key from the journal to the same restore script. Compare against the item as it existed at backup time. The script verifies the downloaded checksum, creates an unused `campus_restore_*` database and restores in a single transaction. The fresh database admits superusers only. Cluster roles must already exist on a replacement PostgreSQL instance. [Database provisioning and roles](postgres.md)

The integration test deletes a synthetic application and its attachment after backup, restores the archive into a fresh database and compares all application fields and the attachment checksum. [Restore test](../.github/scripts/test-postgres-backup.sh)
