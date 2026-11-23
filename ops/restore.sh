#!/usr/bin/env bash
set -euo pipefail
umask 077
source "$(dirname "$0")/postgres-backup-common.sh"
[[ $# == 2 ]] || backup_fail 'Usage: restore.sh <postgresql/archive-key> <campus_restore_name>'
key=$1
target=$2
[[ $key =~ ^postgresql/campus-[0-9]{8}T[0-9]{6}Z-[0-9a-f]{8}(-[0-9a-f]{4}){3}-[0-9a-f]{12}\.dump$ ]] ||
  backup_fail 'Expected a scholarship PostgreSQL archive key.'
[[ $target =~ ^campus_restore_[a-z0-9_]{1,40}$ ]] || backup_fail 'Expected a new campus_restore_ database name.'
load_backup_settings

work=$(mktemp -d "${TMPDIR:-/var/tmp}/campus-restore.XXXXXXXX")
created=false
cleanup() {
  if [[ $created == true ]]; then
    # CREATE succeeded for this invocation. Roll back only its fresh test database.
    k3s crictl exec "$pg_container" dropdb --no-password --username=postgres "$target" ||
      echo "Could not remove the incomplete test database $target." >&2
  fi
  rm -rf -- "$work"
}
trap cleanup EXIT
archive="$work/campus.dump"
stored=$(aws --region us-east-1 s3api get-object --bucket "$BACKUP_BUCKET" --key "$key" \
  --checksum-mode ENABLED --query ChecksumSHA256 --output text "$archive")
checksum=$(archive_checksum "$archive")
[[ $stored == "$checksum" ]] || backup_fail 'Downloaded archive failed the S3 SHA-256 check.'
k3s crictl exec -i "$pg_container" pg_restore --list < "$archive" > /dev/null

# The identifier is restricted above. A zero connection limit admits the restoring superuser only.
k3s crictl exec "$pg_container" psql -Xqw -v ON_ERROR_STOP=1 -U postgres -d postgres \
  -c "CREATE DATABASE $target TEMPLATE template0 CONNECTION LIMIT 0"
created=true
k3s crictl exec -i "$pg_container" pg_restore --no-password --exit-on-error --single-transaction \
  --username=postgres --dbname="$target" < "$archive"
created=false
printf '%s\n' "$target"
