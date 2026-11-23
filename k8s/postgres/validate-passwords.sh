#!/usr/bin/env bash
set -euo pipefail

# Read one Kubernetes Secret revision so rotation cannot mix old and new keys.
directory=${DB_CREDENTIAL_DIR:-/run/scholarship-passwords}
if [[ -d "$directory/..data" ]]; then
  directory=$(readlink -f "$directory/..data")
fi
read_password() {
  local value
  value=$(cat "$directory/$1") || return 1
  if (( ${#value} < 16 )) || [[ $value != *[[:upper:]]* || $value != *[[:lower:]]* || $value != *[[:digit:]]* ]]; then
    printf '%s must have at least 16 characters, including uppercase, lowercase and a digit.\n' "$1" >&2
    return 1
  fi
  if [[ $value == [[:space:]]* || $value == *[[:space:]] || $value == *$'\n'* ]]; then
    printf '%s must be one line without surrounding whitespace for the application file reader.\n' "$1" >&2
    return 1
  fi
  printf '%s' "$value"
}
PG_ROOT_SECRET=$(read_password postgres-password)
PG_ADMIN_SECRET=$(read_password admin-password)
PG_RW_SECRET=$(read_password rw-password)
PG_RO_SECRET=$(read_password ro-password)
