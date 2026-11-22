locals {
  readiness_observer = <<-BASH
    cat > /usr/local/sbin/css4003-observe <<'OBSERVER'
    #!/usr/bin/env bash
    role=$1
    console=/dev/console
    if [[ -c /dev/ttyS0 ]]; then console=/dev/ttyS0; fi
    exec > "$console" 2>/dev/null || exit 0
    unit_state() {
      local property=$1 unit=$2 value
      value=$(timeout 2s systemctl show --property="$property" --value "$unit" 2>/dev/null) || value=unknown
      [[ $value =~ ^[a-z-]{1,32}$ ]] || value=unknown
      printf '%s' "$value"
    }
    flag() { if test "$@"; then printf true; else printf false; fi; }
    deadline=$((SECONDS + 1500))
    while (( SECONDS < deadline )); do
      printf 'CSS4003_K3S UTC=%s ROLE=%s K3S=%s/%s SYNC=%s/%s BINARY=%s ARCHIVE=%s' \
        "$(date -u +%FT%TZ)" "$role" \
        "$(unit_state ActiveState k3s.service)" "$(unit_state SubState k3s.service)" \
        "$(unit_state ActiveState k3s-token-sync.service)" "$(unit_state SubState k3s-token-sync.service)" \
        "$(flag -x /usr/local/bin/k3s)" "$(flag -s /var/lib/rancher/k3s/agent/images/k3s-airgap-images-amd64.tar.zst)"
      if [[ $role == agent ]]; then
        printf ' TOKEN_PRESENT=%s\n' "$(flag -s /etc/rancher/k3s/join-token)"
      else
        printf ' TOKEN_PUBLISHED=%s\n' "$(flag -s /var/lib/k3s-bootstrap/published)"
        if rows=$(timeout 10s /usr/local/bin/k3s kubectl get nodes --request-timeout=8s --no-headers -o wide 2>/dev/null); then
          if awk -v server='${local.server_ip}' -v agent='${cidrhost(local.subnet_cidrs.private, 10)}' '
            length($1) <= 253 && $1 ~ /^[a-z0-9][a-z0-9.-]*$/ && $2 ~ /^(Ready|NotReady|Unknown)(,SchedulingDisabled)?$/ && ($6 == server || $6 == agent) {
              printf "CSS4003_K3S NODE=%s STATUS=%s INTERNAL_IP=%s\n", $1, $2, $6
              if (length($3) <= 80 && $3 ~ /^([a-z0-9,-]+|<none>)$/ && length($5) <= 64 && $5 ~ /^v[0-9]+[.][0-9]+[.][0-9]+[a-zA-Z0-9.+-]*$/) {
                details[NR] = sprintf("CSS4003_K3S NODE=%s STATUS=%s ROLES=%s VERSION=%s INTERNAL_IP=%s", $1, $2, $3, $5, $6)
              }
              if ($2 ~ /^Ready(,SchedulingDisabled)?$/ && $6 == server) s++
              if ($2 ~ /^Ready(,SchedulingDisabled)?$/ && $6 == agent) a++
            }
            END {
              if (NR != 2 || s != 1 || a != 1) exit 1
              for (i=1; i<=NR; i++) if (i in details) print details[i]
            }
          ' <<< "$rows"; then
            printf 'CSS4003_K3S RESULT=BOTH_READY\n'
            exit 0
          fi
        fi
      fi
      sleep 40
    done
    printf 'CSS4003_K3S UTC=%s ROLE=%s RESULT=OBSERVATION_ENDED\n' "$(date -u +%FT%TZ)" "$role"
    OBSERVER
    chmod 0755 /usr/local/sbin/css4003-observe
  BASH

  lab_node_user_data = {
    for role, bootstrap in local.node_user_data : role => join("\n", [
      bootstrap, local.readiness_observer,
      "systemd-run --no-block --quiet --unit=css4003-observe --property=RuntimeMaxSec=26min /usr/local/sbin/css4003-observe ${role} || true",
    ])
  }
}
