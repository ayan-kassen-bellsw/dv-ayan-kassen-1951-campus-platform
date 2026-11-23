#!/usr/bin/env bash
set -euo pipefail
scripts=$(cd "$(dirname "$0")" && pwd)
source "$scripts/validate-passwords.sh"
export PG_ROOT_SECRET PG_ADMIN_SECRET PG_RW_SECRET PG_RO_SECRET
export PGHOST=/var/run/postgresql PGUSER=postgres PGCONNECT_TIMEOUT=3

# The official image uses a socket-only server during initdb. Wait for the final server.
deadline=$((SECONDS + 150))
until pg_isready -q -h 127.0.0.1 -U postgres; do
  if (( SECONDS >= deadline )); then
    echo 'PostgreSQL did not start listening on TCP.' >&2
    exit 1
  fi
  sleep 1
done
exec psql -Xqw -v ON_ERROR_STOP=1 -d postgres -f "$scripts/schema.sql"
