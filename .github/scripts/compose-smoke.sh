#!/usr/bin/env bash
set -euo pipefail
umask 077

# Use a separate Compose project, private .env and named volumes for each run.
workdir=$(mktemp -d)
export COMPOSE_PROJECT_NAME="scholarship-ci-${GITHUB_RUN_ID:-$$}-${GITHUB_RUN_ATTEMPT:-1}"
cleanup() {
  local status=$?
  if [[ -f "$workdir/.env" ]]; then
    (cd "$workdir" && docker compose down --volumes) || status=1
  fi
  rm -rf -- "$workdir"
  exit "$status"
}
trap cleanup EXIT
cp compose.yaml "$workdir/"
grep -Ev '^(SECRET_KEY|DB_PASSWORD|MYSQL_ROOT_PASSWORD|CLICKHOUSE_PASSWORD|GRAFANA_ADMIN_PASSWORD)=' \
  .env.example > "$workdir/.env"
for name in SECRET_KEY DB_PASSWORD MYSQL_ROOT_PASSWORD CLICKHOUSE_PASSWORD GRAFANA_ADMIN_PASSWORD; do
  random=$(openssl rand -hex 32)
  printf '%s=Aa1%s\n' "$name" "$random" >> "$workdir/.env"
done
unset random
export APP_PORT=127.0.0.1:0
cd "$workdir"

start_stack() {
  docker compose up --no-build --detach --wait --wait-timeout 120 app
  base_url="http://$(docker compose port app 8000)"
  curl -fsS --max-time 10 "$base_url/readyz" |
    jq -e '.ready == true and .checks.db == true and .checks.storage == true'
  curl -fsS --max-time 10 "$base_url/info" |
    jq -e '.app == "Scholarship applications" and .db_engine == "postgresql"'
}

check_password() {
  local sample=$1 expected=$2
  jq -nc --arg sample "$sample" '{password: $sample}' |
    curl -fsS --max-time 10 --json @- "$base_url/api/admin/check-password" |
    jq -e --argjson expected "$expected" '.min_length == 16 and .require_symbol == false and .ok == $expected'
}

start_stack
echo 'Checking the HTTP password policy at 15 and 16 characters'
check_password Scholar2026Awar false
check_password Scholar2026Award true
check_password scholar2026award false

echo 'Creating a scholarship application and reading it through PostgreSQL'
application_id=$(curl -fsS --max-time 10 --json '{"title":"CI merit scholarship","description":"Persistence check"}' \
  "$base_url/api/items" | jq -er '.id | numbers')
stored_id=$(docker compose exec -T postgres psql -XqAt -v ON_ERROR_STOP=1 -U app_rw -d campus \
  -c "SELECT id FROM items WHERE title = 'CI merit scholarship' AND description = 'Persistence check'")
[[ "$stored_id" == "$application_id" ]]

echo 'Recreating both containers with their existing volumes and reading the application again'
docker compose down
start_stack
curl -fsS --max-time 10 "$base_url/api/items/$application_id" |
  jq -e --argjson id "$application_id" '.id == $id and .title == "CI merit scholarship" and .description == "Persistence check"'
