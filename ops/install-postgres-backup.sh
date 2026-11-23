#!/usr/bin/env bash
set -euo pipefail
source_dir=$(cd "$(dirname "$0")" && pwd)
source "$source_dir/postgres-backup-common.sh"
[[ $EUID == 0 && $# == 1 ]] || backup_fail 'Usage on the database worker: sudo bash ops/install-postgres-backup.sh <bucket>'
BACKUP_BUCKET=$1
load_backup_settings
command -v aws >/dev/null || backup_fail 'AWS CLI is required on the database worker.'
command -v openssl >/dev/null || backup_fail 'OpenSSL is required on the database worker.'

unit="$backup_project-postgres-backup"
lib="/usr/local/lib/$unit"
install -d -m 0755 "$lib" "/etc/$backup_project"
install -m 0755 "$source_dir"/{backup,restore,postgres-backup-common}.sh "$lib/"
for extension in service timer; do
  install -m 0644 "$source_dir/../k8s/postgres/host/$unit.$extension" "/etc/systemd/system/$unit.$extension"
done
config=$(mktemp "/etc/$backup_project/.postgres-backup-bucket.XXXXXXXX")
trap 'rm -f -- "$config"' EXIT
printf '%s\n' "$BACKUP_BUCKET" > "$config"
mv -f -- "$config" "$backup_bucket_file"
systemctl daemon-reload
systemctl enable --now "$unit.timer"
