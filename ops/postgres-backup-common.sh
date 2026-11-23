#!/usr/bin/env bash

backup_project=dv-ayan-kassen-1951
backup_bucket_file="/etc/$backup_project/postgres-backup-bucket"
export AWS_S3_US_EAST_1_REGIONAL_ENDPOINT=regional AWS_PAGER=

backup_fail() {
  echo "$*" >&2
  exit 1
}

validate_backup_bucket() {
  [[ $1 =~ ^dv-ayan-kassen-1951-backups-[a-z0-9-]*[a-z0-9]$ && ${#1} -le 63 ]] ||
    backup_fail 'Expected the project PostgreSQL backup bucket.'
}

load_backup_settings() {
  if [[ -z ${BACKUP_BUCKET:-} ]]; then
    [[ -r $backup_bucket_file ]] || backup_fail 'Install the backup configuration or set BACKUP_BUCKET.'
    BACKUP_BUCKET=$(<"$backup_bucket_file")
  fi
  validate_backup_bucket "$BACKUP_BUCKET"
  pg_container=$(k3s crictl ps --name '^postgres$' \
    --label "io.kubernetes.pod.namespace=$backup_project" \
    --label "io.kubernetes.pod.name=$backup_project-postgres-0" -q)
  [[ $pg_container =~ ^[0-9a-f]{12,64}$ ]] ||
    backup_fail 'Expected exactly one running scholarship PostgreSQL container on this worker.'
}

archive_checksum() {
  openssl dgst -sha256 -binary "$1" | openssl base64 -A
}
