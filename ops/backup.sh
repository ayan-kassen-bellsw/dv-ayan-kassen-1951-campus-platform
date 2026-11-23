#!/usr/bin/env bash
set -euo pipefail
umask 077
source "$(dirname "$0")/postgres-backup-common.sh"
[[ $# == 0 ]] || backup_fail 'Usage: backup.sh'
load_backup_settings

work=$(mktemp -d "${TMPDIR:-/var/tmp}/campus-backup.XXXXXXXX")
trap 'rm -rf -- "$work"' EXIT
archive="$work/campus.dump"
k3s crictl exec "$pg_container" pg_dump --format=custom --no-password \
  --username=postgres --role=admin --dbname=campus > "$archive"
k3s crictl exec -i "$pg_container" pg_restore --list < "$archive" > /dev/null

key="postgresql/campus-$(date -u +%Y%m%dT%H%M%SZ)-$(cat /proc/sys/kernel/random/uuid).dump"
checksum=$(archive_checksum "$archive")
stored=$(aws --region us-east-1 s3api put-object --bucket "$BACKUP_BUCKET" --key "$key" \
  --body "$archive" --checksum-algorithm SHA256 --checksum-sha256 "$checksum" \
  --query ChecksumSHA256 --output text)
[[ $stored == "$checksum" ]] || backup_fail 'S3 did not acknowledge the archive SHA-256.'
printf '%s\n' "$key"
