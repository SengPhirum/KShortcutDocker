#!/usr/bin/env sh
set -eu
exec 3>&2

# network.sh (POSIX sh)
#
# Purpose:
#   1) Ensure all networks declared in a Docker Compose file exist.
#   2) Recreate an existing Docker network after detaching all services and containers.
#   3) Inspect subnet usage and available IPs for Docker networks.
#
# Usage:
#   ./network.sh [ensure-options]
#   ./network.sh ensure [ensure-options]
#   ./network.sh update <network-name> [update-options]
#   ./network.sh check [network-name-or-regex] [check-options]

usage_all() {
  cat <<'EOF'
Usage:
  ./network.sh [ensure-options]
  ./network.sh ensure [ensure-options]
  ./network.sh update <network-name> [update-options]
  ./network.sh check [network-name-or-regex] [check-options]
  ./network.sh check-subnet [check-options]   # backward-compatible alias

Purpose:
  1) Check and create all networks from docker-compose if missing.
  2) Recreate an existing network after detaching all services and containers.
  3) Check subnet usage (used/available IPs) for Docker networks.

Ensure options:
  -f, --file FILE         Compose file to read (default: docker-compose.yml)
  --stack-name NAME       Stack name for non-external networks without explicit name
  -v, --verbose           Print each command before execution
  -h, --help              Show this help

Update options:
  --subnet <CIDR>         New subnet for target network
  --subnet=<CIDR>         New subnet (inline form)
  --gateway <IP>          Gateway IP for recreated network
  --gateway=<IP>          Gateway (inline form)
  --network <name>        Target network name (alternative to positional argument)
  --network=<name>        Target network name (inline form)
  --yes                   Run without interactive confirmation
  -v, --verbose           Print each command before execution
  -h, --help              Show this help

Check options:
  -n, --network <regex>   Regex filter for network names (default: .*)
  --network=<regex>       Regex filter (inline form)
  --using                 List services using each matched network
  -v, --verbose           Print each command before execution
  -h, --help              Show this help

Environment (ensure mode):
  DRIVER=overlay          Default driver when not set in compose
  ATTACHABLE=true         Default attachable when not set in compose
  DRY_RUN=1               Print actions instead of executing them
EOF
}

usage_ensure() {
  cat <<'EOF'
Usage:
  ./network.sh [ensure-options]
  ./network.sh ensure [ensure-options]

Ensure options:
  -f, --file FILE         Compose file to read (default: docker-compose.yml)
  --stack-name NAME       Stack name for non-external networks without explicit name
  -v, --verbose           Print each command before execution
  -h, --help              Show this help

Environment (ensure mode):
  DRIVER=overlay          Default driver when not set in compose
  ATTACHABLE=true         Default attachable when not set in compose
  DRY_RUN=1               Print actions instead of executing them
EOF
}

usage_update() {
  cat <<'EOF'
Usage:
  ./network.sh update <network-name> [update-options]

Update options:
  --subnet <CIDR>         New subnet for target network
  --subnet=<CIDR>         New subnet (inline form)
  --gateway <IP>          Gateway IP for recreated network
  --gateway=<IP>          Gateway (inline form)
  --network <name>        Target network name (alternative to positional argument)
  --network=<name>        Target network name (inline form)
  --yes                   Run without interactive confirmation
  -v, --verbose           Print each command before execution
  -h, --help              Show this help
EOF
}

usage_check_subnet() {
  cat <<'EOF'
Usage:
  ./network.sh check [network-name-or-regex] [check-options]
  ./network.sh check-subnet [check-options]   # backward-compatible alias

Check options:
  [network-name-or-regex] Positional network name/regex filter
  -n, --network <regex>   Regex filter for network names (default: .*)
  --network=<regex>       Regex filter (inline form)
  --using                 List services using each matched network
  -v, --verbose           Print each command before execution
  -h, --help              Show this help
EOF
}

usage() {
  usage_all
}

have() { command -v "$1" >/dev/null 2>&1; }
err() { printf 'Error: %s\n' "$*" >&2; }
info() { printf -- '-- %s\n' "$*"; }
migrate_log() { printf '[network-update] %s\n' "$*"; }

to_lower() { printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]'; }

is_true() {
  _v="$(to_lower "${1:-}")"
  [ "$_v" = "true" ] || [ "$_v" = "1" ] || [ "$_v" = "yes" ] || [ "$_v" = "y" ]
}

strip_wrapping_quotes() {
  _raw="${1:-}"
  case "$_raw" in
    \"*\") printf '%s' "$_raw" | sed 's/^"\(.*\)"$/\1/' ;;
    *) printf '%s' "$_raw" ;;
  esac
}

print_dry_run() {
  printf '[DRY RUN]'
  for _arg in "$@"; do
    printf ' %s' "$_arg"
  done
  printf '\n'
}

print_verbose_arg() {
  _arg="$1"
  case "$_arg" in
    --label=*|--opt=*|--subnet=*|--gateway=*)
      _name="${_arg%%=*}"
      _value="${_arg#*=}"
      _value_escaped="$(printf '%s' "$_value" | sed 's/\\/\\\\/g; s/"/\\"/g')"
      printf '%s="%s"' "$_name" "$_value_escaped" >&3
      ;;
    ''|*[!A-Za-z0-9_./:=@%+,-]*)
      _escaped="$(printf '%s' "$_arg" | sed "s/'/'\\\\''/g")"
      printf "'%s'" "$_escaped" >&3
      ;;
    *)
      printf '%s' "$_arg" >&3
      ;;
  esac
}

print_verbose_command() {
  printf 'docker' >&3
  for _arg in "$@"; do
    printf ' ' >&3
    print_verbose_arg "$_arg"
  done
  printf '\n' >&3
}

format_command_arg() {
  _arg="$1"
  case "$_arg" in
    --label=*|--opt=*|--subnet=*|--gateway=*)
      _name="${_arg%%=*}"
      _value="${_arg#*=}"
      _value_escaped="$(printf '%s' "$_value" | sed 's/\\/\\\\/g; s/"/\\"/g')"
      COMMAND_LOG_ARG="${_name}=\"${_value_escaped}\""
      ;;
    ''|*[!A-Za-z0-9_./:=@%+,-]*)
      _escaped="$(printf '%s' "$_arg" | sed "s/'/'\\\\''/g")"
      COMMAND_LOG_ARG="'${_escaped}'"
      ;;
    *)
      COMMAND_LOG_ARG="$_arg"
      ;;
  esac
}

log_command() {
  _command_line=""
  for _arg in "$@"; do
    format_command_arg "$_arg"
    if [ -n "$_command_line" ]; then
      _command_line="${_command_line} ${COMMAND_LOG_ARG}"
    else
      _command_line="${COMMAND_LOG_ARG}"
    fi
  done
  migrate_log "Command: $_command_line"
}

enable_verbose_trace() {
  if [ "${VERBOSE:-false}" = "true" ]; then
    info "Verbose mode enabled (Docker commands only)."
  fi
}

require_docker() {
  if ! env docker --version >/dev/null 2>&1; then
    err "docker is required but was not found in PATH"
    exit 1
  fi
}

docker() {
  if [ "${VERBOSE:-false}" = "true" ]; then
    print_verbose_command "$@"
  fi
  env docker "$@"
}

ensure_swarm_active() {
  _state="$(docker info -f '{{.Swarm.LocalNodeState}}' 2>/dev/null || true)"
  _state_lc="$(to_lower "$_state")"
  if [ "$_state_lc" != "active" ]; then
    err "Overlay networks require Docker Swarm mode (current: ${_state:-unknown})."
    err "Initialize Swarm first, e.g.: docker swarm init"
    exit 1
  fi
}

cidr_usable_hosts() {
  _cidr="$1"
  awk -v cidr="$_cidr" '
    BEGIN {
      n = split(cidr, parts, "/")
      if (n != 2 || parts[2] !~ /^[0-9]+$/) {
        print "N/A"
        exit
      }
      prefix = parts[2] + 0
      if (prefix < 0 || prefix > 32) {
        print "N/A"
        exit
      }
      if (prefix == 32) {
        print 1
        exit
      }
      if (prefix == 31) {
        print 2
        exit
      }
      total = exp(log(2) * (32 - prefix))
      printf "%.0f\n", total - 2
    }
  '
}

is_valid_cidr() {
  _cidr="$1"
  awk -v cidr="$_cidr" '
    BEGIN {
      n = split(cidr, parts, "/")
      if (n != 2) exit 1
      if (parts[2] !~ /^[0-9]+$/) exit 1
      prefix = parts[2] + 0
      if (prefix < 0 || prefix > 32) exit 1
      m = split(parts[1], oct, ".")
      if (m != 4) exit 1
      for (i = 1; i <= 4; i++) {
        if (oct[i] !~ /^[0-9]+$/) exit 1
        val = oct[i] + 0
        if (val < 0 || val > 255) exit 1
      }
      exit 0
    }
  '
}

cidr_prefix() {
  _cidr="$1"
  awk -v cidr="$_cidr" '
    BEGIN {
      n = split(cidr, parts, "/")
      if (n != 2) exit 1
      if (parts[2] !~ /^[0-9]+$/) exit 1
      prefix = parts[2] + 0
      if (prefix < 0 || prefix > 32) exit 1
      print prefix
      exit 0
    }
  ' 2>/dev/null || true
}

cidr_overlaps() {
  _cidr_a="$1"
  _cidr_b="$2"
  awk -v a="$_cidr_a" -v b="$_cidr_b" '
    function ip_to_int(ip, o) {
      split(ip, o, ".")
      return (((o[1] * 256 + o[2]) * 256 + o[3]) * 256 + o[4])
    }
    function range_from_cidr(c, out, p, n, m, ip, prefix, size, start, stop) {
      n = split(c, p, "/")
      if (n != 2) return 0
      if (p[2] !~ /^[0-9]+$/) return 0
      prefix = p[2] + 0
      if (prefix < 0 || prefix > 32) return 0
      m = split(p[1], out, ".")
      if (m != 4) return 0
      for (i = 1; i <= 4; i++) {
        if (out[i] !~ /^[0-9]+$/) return 0
        if ((out[i] + 0) < 0 || (out[i] + 0) > 255) return 0
      }
      ip = ip_to_int(p[1])
      size = 2 ^ (32 - prefix)
      start = int(ip / size) * size
      stop = start + size - 1
      out["start"] = start
      out["stop"] = stop
      return 1
    }
    BEGIN {
      if (!range_from_cidr(a, ra)) exit 2
      if (!range_from_cidr(b, rb)) exit 2
      if (ra["start"] <= rb["stop"] && rb["start"] <= ra["stop"]) exit 0
      exit 1
    }
  ' >/dev/null 2>&1
}

list_existing_subnets() {
  docker network ls -q 2>/dev/null | while IFS= read -r _nid; do
    [ -n "$_nid" ] || continue
    docker network inspect "$_nid" -f '{{range .IPAM.Config}}{{if .Subnet}}{{println .Subnet}}{{end}}{{end}}' 2>/dev/null || true
  done | sed '/^[[:space:]]*$/d' | sort -u
}

cidr_overlaps_any() {
  _candidate="$1"
  _existing_list="$2"
  for _existing in $_existing_list; do
    [ -n "$_existing" ] || continue
    if ! is_valid_cidr "$_existing"; then
      continue
    fi
    if cidr_overlaps "$_candidate" "$_existing"; then
      return 0
    fi
  done
  return 1
}

generate_subnets_in_pool() {
  _pool_cidr="$1"
  _target_prefix="$2"
  awk -v pool="$_pool_cidr" -v target_prefix="$_target_prefix" '
    function ip_to_int(ip, o) {
      split(ip, o, ".")
      return (((o[1] * 256 + o[2]) * 256 + o[3]) * 256 + o[4])
    }
    function int_to_ip(v, o1, o2, o3, o4) {
      o1 = int(v / 16777216) % 256
      o2 = int(v / 65536) % 256
      o3 = int(v / 256) % 256
      o4 = int(v) % 256
      return o1 "." o2 "." o3 "." o4
    }
    BEGIN {
      n = split(pool, p, "/")
      if (n != 2) exit
      if (p[2] !~ /^[0-9]+$/) exit
      pool_prefix = p[2] + 0
      prefix = target_prefix + 0
      if (prefix < pool_prefix || prefix > 32) exit
      pool_size = 2 ^ (32 - pool_prefix)
      block_size = 2 ^ (32 - prefix)
      pool_start = int(ip_to_int(p[1]) / pool_size) * pool_size
      last_start = pool_start + pool_size - block_size
      for (s = pool_start; s <= last_start; s += block_size) {
        print int_to_ip(s) "/" prefix
      }
    }
  '
}

first_conflicting_subnet() {
  _candidate="$1"
  _ignore_cidr="${2:-}"
  _existing="$(list_existing_subnets)"

  for _existing_cidr in $_existing; do
    [ -n "$_existing_cidr" ] || continue
    if [ -n "$_ignore_cidr" ] && [ "$_existing_cidr" = "$_ignore_cidr" ]; then
      continue
    fi
    if ! is_valid_cidr "$_existing_cidr"; then
      continue
    fi
    if cidr_overlaps "$_candidate" "$_existing_cidr"; then
      printf '%s\n' "$_existing_cidr"
      return 0
    fi
  done

  return 1
}

pick_available_temp_subnet() {
  _old_subnet="${1:-}"
  _target_subnet="${2:-}"
  _prefix="$(cidr_prefix "$_old_subnet")"
  [ -n "$_prefix" ] || _prefix="$(cidr_prefix "$_target_subnet")"
  [ -n "$_prefix" ] || _prefix="24"

  _existing_subnets="$(list_existing_subnets)"
  _avoid_list="$_existing_subnets
$_target_subnet
$_old_subnet"

  # Prefer high private ranges to avoid collisions with active cluster pools.
  for _pool in 10.255.0.0/16 10.254.0.0/16 172.31.0.0/16 172.30.0.0/16 192.168.255.0/24; do
    _candidates="$(generate_subnets_in_pool "$_pool" "$_prefix")"
    for _candidate in $_candidates; do
      [ -n "$_candidate" ] || continue
      if ! cidr_overlaps_any "$_candidate" "$_avoid_list"; then
        printf '%s\n' "$_candidate"
        return 0
      fi
    done
  done

  return 1
}

extract_network_specs() {
  if have yq; then
    # Output as pipe-delimited fields:
    # key|name|external|driver|attachable|subnet|gateway
    yq -r '
      (.networks // {})
      | to_entries[]
      | [
          .key,
          ((.value.name // "") | tostring),
          ((.value.external // "") | tostring),
          ((.value.driver // "") | tostring),
          ((.value.attachable // "") | tostring),
          ((.value.ipam.config[0].subnet // "") | tostring),
          ((.value.ipam.config[0].gateway // "") | tostring)
        ]
      | join("|")
    ' "$COMPOSE_FILE" 2>/dev/null
  else
    printf -- '-- %s\n' "yq not found; using fallback parser (best-effort)." >&2
    awk '
      BEGIN{
        in_n=0; key=""; name=""; ext=""; drv=""; att=""; subnet=""; gateway=""
      }
      function flush() {
        if (key != "") {
          print key "|" name "|" ext "|" drv "|" att "|" subnet "|" gateway
        }
      }
      /^networks:[[:space:]]*$/ {
        in_n=1
        key=""; name=""; ext=""; drv=""; att=""; subnet=""; gateway=""
        next
      }
      in_n && /^[^[:space:]]/ {
        flush()
        in_n=0
        next
      }
      in_n && /^  [A-Za-z0-9_.-]+:[[:space:]]*$/ {
        flush()
        key=$0
        sub(/^[[:space:]]+/, "", key)
        sub(/:[[:space:]]*$/, "", key)
        name=""; ext=""; drv=""; att=""; subnet=""; gateway=""
        next
      }
      in_n && /external:[[:space:]]*(true|"true")/ { ext="true"; next }
      in_n && /external:[[:space:]]*(false|"false")/ { ext="false"; next }
      in_n && /name:[[:space:]]*[^[:space:]]+/ {
        line=$0
        sub(/^.*name:[[:space:]]*/, "", line)
        sub(/[[:space:]]+#.*$/, "", line)
        gsub(/^"/, "", line)
        gsub(/"$/, "", line)
        name=line
        next
      }
      in_n && /driver:[[:space:]]*[^[:space:]]+/ {
        line=$0
        sub(/^.*driver:[[:space:]]*/, "", line)
        sub(/[[:space:]]+#.*$/, "", line)
        drv=line
        next
      }
      in_n && /attachable:[[:space:]]*(true|"true")/ { att="true"; next }
      in_n && /attachable:[[:space:]]*(false|"false")/ { att="false"; next }
      in_n && /subnet:[[:space:]]*[^[:space:]]+/ {
        line=$0
        sub(/^.*subnet:[[:space:]]*/, "", line)
        sub(/[[:space:]]+#.*$/, "", line)
        subnet=line
        next
      }
      in_n && /gateway:[[:space:]]*[^[:space:]]+/ {
        line=$0
        sub(/^.*gateway:[[:space:]]*/, "", line)
        sub(/[[:space:]]+#.*$/, "", line)
        gateway=line
        next
      }
      END {
        if (in_n) { flush() }
      }
    ' "$COMPOSE_FILE"
  fi
}

ensure_networks() {
  if [ ! -f "$COMPOSE_FILE" ]; then
    err "Compose file not found: $COMPOSE_FILE"
    exit 1
  fi

  _specs="$(extract_network_specs | sed '/^[[:space:]]*$/d')"
  if [ -z "$_specs" ]; then
    info "No networks found in $COMPOSE_FILE"
    exit 0
  fi

  _swarm_checked="false"
  while IFS='|' read -r _key _name _external _driver _attachable _subnet _gateway; do
    [ -n "$_key" ] || continue

    _key="$(strip_wrapping_quotes "$_key")"
    _name="$(strip_wrapping_quotes "$_name")"
    _external="$(strip_wrapping_quotes "$_external")"
    _driver="$(strip_wrapping_quotes "$_driver")"
    _attachable="$(strip_wrapping_quotes "$_attachable")"
    _subnet="$(strip_wrapping_quotes "$_subnet")"
    _gateway="$(strip_wrapping_quotes "$_gateway")"

    if [ -n "$_name" ]; then
      _net="$_name"
    elif [ "$(to_lower "$_external")" = "true" ]; then
      _net="$_key"
    else
      _net="${STACK_NAME}_${_key}"
    fi

    _create_driver="$_driver"
    [ -n "$_create_driver" ] || _create_driver="$DRIVER"

    _create_attachable="$_attachable"
    [ -n "$_create_attachable" ] || _create_attachable="$ATTACHABLE"

    if docker network inspect "$_net" >/dev/null 2>&1; then
      info "Network exists: $_net"
      continue
    fi

    if [ "$(to_lower "$_create_driver")" = "overlay" ] && [ "$_swarm_checked" != "true" ]; then
      ensure_swarm_active
      _swarm_checked="true"
    fi

    set -- docker network create --driver "$_create_driver"
    if is_true "$_create_attachable"; then
      set -- "$@" --attachable
    fi
    if [ -n "$_subnet" ]; then
      set -- "$@" --subnet "$_subnet"
    fi
    if [ -n "$_gateway" ]; then
      set -- "$@" --gateway "$_gateway"
    fi
    set -- "$@" "$_net"

    info "Network missing: $_net"
    if [ -n "$DRY_RUN" ]; then
      print_dry_run "$@"
    else
      "$@"
      info "Created network: $_net"
    fi
  done <<EOF
$_specs
EOF

  info "Done."
}

detach_services_from_network() {
  _remove_network="$1"
  _services="$(list_network_services "$_remove_network")"
  [ -n "$_services" ] || return 0

  while IFS='|' read -r _service_id _service_name; do
    [ -n "$_service_id" ] || continue
    [ -n "$_service_name" ] || _service_name="$_service_id"

    clear_paused_service_update "$_service_id" "$_service_name"

    migrate_log "Checking service '$_service_name' is stable before detaching network '$_remove_network'"
    if ! wait_for_service_stable "$_service_id" "$_service_name"; then
      migrate_log "Service '$_service_name' is not stable before detach."
      return 1
    fi

    migrate_log "Detaching service '$_service_name' from network '$_remove_network'"
    log_command docker service update --detach=false --network-rm "$_remove_network" "$_service_id"
    if ! docker service update --detach=false --network-rm "$_remove_network" "$_service_id"; then
      migrate_log "Failed to detach service '$_service_name' from network '$_remove_network'."
      return 1
    fi

    migrate_log "Checking service '$_service_name' is stable after detaching network '$_remove_network'"
    if ! wait_for_service_stable "$_service_id" "$_service_name"; then
      migrate_log "Service '$_service_name' did not become stable after detach."
      return 1
    fi
  done <<EOF
$_services
EOF

  return 0
}

list_network_services() {
  _network="$1"
  _network_id="$(docker network inspect "$_network" -f '{{.Id}}' 2>/dev/null | tr -d '[:space:]' || true)"
  [ -n "$_network_id" ] || return 0

  _service_ids="$(docker service ls -q 2>/dev/null || true)"
  [ -n "$_service_ids" ] || return 0

  for _service_id in $_service_ids; do
    _service_name="$(docker service inspect "$_service_id" -f '{{.Spec.Name}}' 2>/dev/null || true)"
    [ -n "$_service_name" ] || _service_name="$_service_id"
    if service_has_network_id "$_service_id" "$_network_id"; then
      printf '%s|%s\n' "$_service_id" "$_service_name"
    fi
  done
}

network_id_by_name() {
  _network="$1"
  docker network inspect "$_network" -f '{{.Id}}' 2>/dev/null | tr -d '[:space:]' || true
}

network_label_value() {
  _network="$1"
  _label_key="$2"
  docker network inspect "$_network" -f "{{index .Labels \"$_label_key\"}}" 2>/dev/null | tr -d '[:space:]' || true
}

container_label_value() {
  _container="$1"
  _label_key="$2"
  docker inspect "$_container" -f "{{index .Config.Labels \"$_label_key\"}}" 2>/dev/null | tr -d '[:space:]' || true
}

container_is_swarm_managed() {
  _container="$1"
  _service_id="$(container_label_value "$_container" "com.docker.swarm.service.id")"
  _task_id="$(container_label_value "$_container" "com.docker.swarm.task.id")"
  [ -n "$_service_id" ] || [ -n "$_task_id" ]
}

service_targets() {
  _service_id="$1"
  docker service inspect "$_service_id" -f '{{range .Spec.TaskTemplate.Networks}}{{println .Target}}{{end}}' 2>/dev/null | sed '/^[[:space:]]*$/d'
}

service_virtual_ip_targets() {
  _service_id="$1"
  docker service inspect "$_service_id" -f '{{range .Endpoint.VirtualIPs}}{{println .NetworkID}}{{end}}' 2>/dev/null | sed '/^[[:space:]]*$/d'
}

service_spec_has_network_id() {
  _service_id="$1"
  _network_id="$2"
  [ -n "$_network_id" ] || return 1
  service_targets "$_service_id" | grep -Fx "$_network_id" >/dev/null 2>&1
}

service_has_network_id() {
  _service_id="$1"
  _network_id="$2"
  [ -n "$_network_id" ] || return 1
  if service_spec_has_network_id "$_service_id" "$_network_id"; then
    return 0
  fi
  service_virtual_ip_targets "$_service_id" | grep -Fx "$_network_id" >/dev/null 2>&1
}

service_network_move_applied() {
  _service_id="$1"
  _from_network_id="$2"
  _to_network_id="$3"

  [ -n "$_to_network_id" ] || return 1
  if ! service_spec_has_network_id "$_service_id" "$_to_network_id"; then
    return 1
  fi
  if [ -n "$_from_network_id" ] && service_spec_has_network_id "$_service_id" "$_from_network_id"; then
    return 1
  fi
  if [ -n "$_from_network_id" ] && service_has_network_id "$_service_id" "$_from_network_id"; then
    return 1
  fi
  return 0
}

service_update_state() {
  _service_id="$1"
  docker service inspect "$_service_id" -f '{{if .UpdateStatus}}{{.UpdateStatus.State}}{{end}}' 2>/dev/null | tr -d '[:space:]' || true
}

service_replicated_replicas() {
  _service_id="$1"
  docker service inspect "$_service_id" -f '{{if .Spec.Mode.Replicated}}{{.Spec.Mode.Replicated.Replicas}}{{end}}' 2>/dev/null | tr -d '[:space:]' || true
}

service_running_task_summary() {
  _service_id="$1"
  docker service ps --filter desired-state=running --format '{{.CurrentState}}|{{.Error}}' "$_service_id" 2>/dev/null || true
}

service_is_stable() {
  _service_id="$1"
  _update_state="$(to_lower "$(service_update_state "$_service_id")")"
  case "$_update_state" in
    paused|updating|rollback_started|rollback_paused|rollback_in_progress)
      return 1
      ;;
  esac

  _tasks="$(service_running_task_summary "$_service_id")"
  _running_count=0
  _task_count=0

  while IFS='|' read -r _current_state _task_error; do
    [ -n "$_current_state" ] || continue
    _task_count=$((_task_count + 1))
    case "$_current_state" in
      Running* ) _running_count=$((_running_count + 1)) ;;
      * ) return 1 ;;
    esac
  done <<EOF
$_tasks
EOF

  _replicas="$(service_replicated_replicas "$_service_id")"
  case "$_replicas" in
    ''|*[!0-9]*)
      [ "$_task_count" -gt 0 ] || return 1
      ;;
    *)
      [ "$_task_count" -eq "$_replicas" ] || return 1
      ;;
  esac

  [ "$_running_count" -eq "$_task_count" ]
}

wait_for_service_stable() {
  _service_id="$1"
  _service_name="$2"
  _retries="${3:-24}"
  _i=1

  while [ "$_i" -le "$_retries" ]; do
    if service_is_stable "$_service_id"; then
      return 0
    fi
    _state="$(service_update_state "$_service_id")"
    if [ "$(to_lower "$_state")" = "paused" ]; then
      migrate_log "Service '$_service_name' update is paused; attempting recovery before retry."
      clear_paused_service_update "$_service_id" "$_service_name"
    fi
    sleep 5
    _i=$((_i + 1))
  done

  migrate_log "Service '$_service_name' is not stable yet."
  docker service ps --filter desired-state=running "$_service_id" 2>/dev/null || true
  return 1
}

wait_for_service_network_move() {
  _service_id="$1"
  _service_name="$2"
  _from_network_id="$3"
  _to_network_id="$4"
  _retries="${5:-20}"
  _i=1

  while [ "$_i" -le "$_retries" ]; do
    if service_network_move_applied "$_service_id" "$_from_network_id" "$_to_network_id"; then
      return 0
    fi
    sleep 3
    _i=$((_i + 1))
  done

  migrate_log "Service '$_service_name' still references the old network after waiting."
  return 1
}

clear_paused_service_update() {
  _service_id="$1"
  _service_name="$2"
  _state="$(docker service inspect "$_service_id" -f '{{if .UpdateStatus}}{{.UpdateStatus.State}}{{end}}' 2>/dev/null || true)"
  if [ "$(to_lower "$_state")" = "paused" ]; then
    migrate_log "Service '$_service_name' update is paused; attempting service rollback to unpause."
    docker service update --rollback "$_service_id" >/dev/null 2>&1 || true
    sleep 3
  fi
}

list_network_containers() {
  _network="$1"
  docker network inspect "$_network" -f '{{range $id, $c := .Containers}}{{printf "%s|%s\n" $id $c.Name}}{{end}}' 2>/dev/null | sed '/^[[:space:]]*$/d'
}

detach_containers_from_network() {
  _network="$1"
  _containers="$(list_network_containers "$_network")"
  [ -n "$_containers" ] || return 0

  while IFS='|' read -r _container_id _container_name; do
    [ -n "$_container_id" ] || continue

    case "$_container_name" in
      lb-*|ingress-sbox) continue ;;
    esac
    if container_is_swarm_managed "$_container_id"; then
      continue
    fi

    _label="$_container_id"
    [ -n "$_container_name" ] && _label="$_container_name"
    migrate_log "Disconnecting container '$_label' from network '$_network'"
    log_command docker network disconnect "$_network" "$_container_id"
    if ! docker network disconnect "$_network" "$_container_id" >/dev/null 2>&1; then
      migrate_log "Failed to disconnect container '$_label' from network '$_network'."
      return 1
    fi
  done <<EOF
$_containers
EOF

  return 0
}

network_name_exists() {
  _network="$1"
  docker network ls --format '{{.Name}}' 2>/dev/null | grep -Fx "$_network" >/dev/null 2>&1
}

list_network_ids_by_name() {
  _network="$1"
  docker network ls --format '{{.ID}}|{{.Name}}' 2>/dev/null | awk -F'|' -v name="$_network" '$2 == name { print $1 }'
}

remove_network_ids_by_name() {
  _network="$1"
  _ids="$(list_network_ids_by_name "$_network")"
  [ -n "$_ids" ] || return 0

  migrate_log "Removing stale network entry '$_network'."
  for _id in $_ids; do
    [ -n "$_id" ] || continue
    docker network rm "$_id" >/dev/null 2>&1 || true
  done
}

wait_for_network_name_release() {
  _network="$1"
  _retries="${2:-15}"
  _purge="${3:-false}"
  _i=1

  while [ "$_i" -le "$_retries" ]; do
    if ! network_name_exists "$_network"; then
      return 0
    fi
    if [ "$_purge" = "true" ]; then
      remove_network_ids_by_name "$_network"
    fi
    sleep 2
    _i=$((_i + 1))
  done

  return 1
}

remove_stale_network_entry() {
  _network="$1"
  if network_name_exists "$_network" && ! docker network inspect "$_network" >/dev/null 2>&1; then
    remove_network_ids_by_name "$_network"
    if ! wait_for_network_name_release "$_network" 20 true; then
      migrate_log "Warning: network name '$_network' is still reserved after stale removal attempt."
    fi
  fi
}

network_name_conflict_error() {
  printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]' | grep -F "network with name" >/dev/null 2>&1 \
    && printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]' | grep -F "already exists" >/dev/null 2>&1
}

wait_for_network_identity() {
  _network="$1"
  _retries=15
  _i=1
  NETWORK_WAIT_DRIVER=""
  NETWORK_WAIT_SCOPE=""

  while [ "$_i" -le "$_retries" ]; do
    NETWORK_WAIT_DRIVER="$(docker network inspect "$_network" -f '{{.Driver}}' 2>/dev/null | tr -d '[:space:]' || true)"
    NETWORK_WAIT_SCOPE="$(docker network inspect "$_network" -f '{{.Scope}}' 2>/dev/null | tr -d '[:space:]' || true)"
    if [ -n "$NETWORK_WAIT_DRIVER" ] && [ -n "$NETWORK_WAIT_SCOPE" ]; then
      return 0
    fi
    sleep 2
    _i=$((_i + 1))
  done

  NETWORK_WAIT_DRIVER=""
  NETWORK_WAIT_SCOPE=""
  return 1
}

capture_network_metadata() {
  _network="$1"
  NETWORK_META_DRIVER="$(docker network inspect "$_network" -f '{{.Driver}}' 2>/dev/null || true)"
  NETWORK_META_ATTACHABLE="$(docker network inspect "$_network" -f '{{.Attachable}}' 2>/dev/null || true)"
  NETWORK_META_INTERNAL="$(docker network inspect "$_network" -f '{{.Internal}}' 2>/dev/null || true)"
  NETWORK_META_LABELS="$(docker network inspect "$_network" -f '{{range $k, $v := .Labels}}{{printf "%s|%s\n" $k $v}}{{end}}' 2>/dev/null | sed '/^[[:space:]]*$/d' || true)"
  NETWORK_META_OPTIONS="$(docker network inspect "$_network" -f '{{range $k, $v := .Options}}{{printf "%s|%s\n" $k $v}}{{end}}' 2>/dev/null | sed '/^[[:space:]]*$/d' || true)"
}

create_network_with_metadata_once() {
  _name="$1"
  _subnet="${2:-}"
  _gateway="${3:-}"
  _driver="${4:-overlay}"
  _attachable="${5:-false}"
  _internal="${6:-false}"
  _labels="${7:-}"
  _options="${8:-}"

  set -- docker network create --driver "$_driver"
  if [ "$(to_lower "$_attachable")" = "true" ]; then
    set -- "$@" --attachable
  fi
  if [ "$(to_lower "$_internal")" = "true" ]; then
    set -- "$@" --internal
  fi

  while IFS='|' read -r _k _v; do
    [ -n "$_k" ] || continue
    if [ -n "$_v" ]; then
      set -- "$@" "--opt=${_k}=${_v}"
    else
      # Some options are key-only flags (for example: encrypted).
      set -- "$@" "--opt=${_k}"
    fi
  done <<EOF
$_options
EOF

  while IFS='|' read -r _k _v; do
    [ -n "$_k" ] || continue
    if [ -n "$_v" ]; then
      set -- "$@" "--label=${_k}=${_v}"
    else
      set -- "$@" "--label=${_k}"
    fi
  done <<EOF
$_labels
EOF

  if [ -n "$_subnet" ]; then
    set -- "$@" "--subnet=${_subnet}"
  fi
  if [ -n "$_gateway" ]; then
    set -- "$@" "--gateway=${_gateway}"
  fi
  set -- "$@" "$_name"
  log_command "$@"
  if CREATE_NETWORK_LAST_ERROR="$("$@" 2>&1 >/dev/null)"; then
    CREATE_NETWORK_LAST_ERROR=""
    return 0
  fi
  return 1
}

create_network_with_metadata() {
  _name="$1"
  _subnet="${2:-}"
  _gateway="${3:-}"
  _driver="${4:-overlay}"
  _attachable="${5:-false}"
  _internal="${6:-false}"
  _labels="${7:-}"
  _options="${8:-}"
  _attempt_with_options="true"
  _name_retry=1
  _name_retry_max=8
  _base_err=""

  while [ "$_name_retry" -le "$_name_retry_max" ]; do
    if [ "$_attempt_with_options" = "true" ]; then
      if create_network_with_metadata_once "$_name" "$_subnet" "$_gateway" "$_driver" "$_attachable" "$_internal" "$_labels" "$_options"; then
        return 0
      fi
    else
      if create_network_with_metadata_once "$_name" "$_subnet" "$_gateway" "$_driver" "$_attachable" "$_internal" "$_labels" ""; then
        return 0
      fi
    fi

    _base_err="${CREATE_NETWORK_LAST_ERROR:-$_base_err}"

    if [ "$_attempt_with_options" = "true" ] && [ -n "$(printf '%s' "$_options" | tr -d '[:space:]')" ] && ! network_name_conflict_error "$_base_err"; then
      migrate_log "Create network '$_name' with copied options failed; retrying without options."
      _attempt_with_options="false"
      continue
    fi

    if network_name_conflict_error "$_base_err"; then
      migrate_log "Network name '$_name' is still reserved; waiting for Docker to release it (${_name_retry}/${_name_retry_max})."
      remove_stale_network_entry "$_name"
      sleep 5
      _name_retry=$((_name_retry + 1))
      continue
    fi

    break
  done

  if [ -n "$(printf '%s' "$_labels" | tr -d '[:space:]')" ]; then
    migrate_log "Create network '$_name' failed while applying copied labels; refusing to recreate without labels."
    _base_err="${CREATE_NETWORK_LAST_ERROR:-$_base_err}"
  fi

  if [ -n "$_base_err" ]; then
    _base_err_line="$(printf '%s' "$_base_err" | tr '\n' ' ' | sed 's/[[:space:]]\+/ /g; s/^ //; s/ $//')"
    [ -n "$_base_err_line" ] && migrate_log "Create network '$_name' failed: $_base_err_line"
  fi

  return 1
}

remove_network_simple() {
  _network="$1"
  _retries="${2:-12}"
  _i=1

  while [ "$_i" -le "$_retries" ]; do
    if ! docker network inspect "$_network" >/dev/null 2>&1; then
      return 0
    fi
    log_command docker network rm "$_network"
    if docker network rm "$_network" >/dev/null 2>&1; then
      migrate_log "Removed network '$_network'."
      return 0
    fi
    migrate_log "Network '$_network' is still in use, retrying (${_i}/${_retries})..."
    sleep 5
    _i=$((_i + 1))
  done

  return 1
}

migrate_network_subnet() {
  if [ -z "$NEW_SUBNET" ]; then
    migrate_log "No --subnet provided; nothing to update. Skipping."
    return 0
  fi

  if [ -z "$OLD_NETWORK" ]; then
    migrate_log "--network (or --old-network) is required."
    exit 1
  fi

  if ! docker network inspect "$OLD_NETWORK" >/dev/null 2>&1; then
    migrate_log "Original network '$OLD_NETWORK' does not exist."
    exit 1
  fi

  _old_driver="$(docker network inspect "$OLD_NETWORK" -f '{{.Driver}}' 2>/dev/null || true)"
  _old_attachable="$(docker network inspect "$OLD_NETWORK" -f '{{.Attachable}}' 2>/dev/null || true)"
  _old_ingress="$(docker network inspect "$OLD_NETWORK" -f '{{.Ingress}}' 2>/dev/null || true)"
  _old_internal="$(docker network inspect "$OLD_NETWORK" -f '{{.Internal}}' 2>/dev/null || true)"
  _old_subnet="$(docker network inspect "$OLD_NETWORK" -f '{{with index .IPAM.Config 0}}{{.Subnet}}{{end}}' 2>/dev/null || true)"
  _old_gateway="$(docker network inspect "$OLD_NETWORK" -f '{{with index .IPAM.Config 0}}{{.Gateway}}{{end}}' 2>/dev/null || true)"
  _old_stack_namespace="$(network_label_value "$OLD_NETWORK" "com.docker.stack.namespace")"
  capture_network_metadata "$OLD_NETWORK"

  if ! is_valid_cidr "$NEW_SUBNET"; then
    migrate_log "Invalid --subnet value: '$NEW_SUBNET'"
    exit 1
  fi

  _target_conflict="$(first_conflicting_subnet "$NEW_SUBNET" "$_old_subnet" || true)"
  if [ -n "$_target_conflict" ]; then
    migrate_log "Requested subnet '$NEW_SUBNET' overlaps existing subnet '$_target_conflict'."
    migrate_log "Choose a different --subnet before starting migration."
    exit 1
  fi

  if [ "$(to_lower "$_old_ingress")" = "true" ]; then
    migrate_log "Network '$OLD_NETWORK' is an ingress network and cannot be updated."
    exit 1
  fi

  if [ "$(to_lower "$_old_driver")" = "overlay" ]; then
    _swarm_state="$(docker info -f '{{.Swarm.LocalNodeState}}' 2>/dev/null || true)"
    if [ "$(to_lower "$_swarm_state")" != "active" ]; then
      migrate_log "Docker Swarm is not active on this node. Run this on a swarm manager."
      exit 1
    fi
  fi

  _services="$(list_network_services "$OLD_NETWORK")"
  _service_count="$(printf '%s\n' "$_services" | sed '/^[[:space:]]*$/d' | wc -l | tr -d '[:space:]')"
  _container_count="$(list_network_containers "$OLD_NETWORK" | wc -l | tr -d '[:space:]')"
  [ -n "$_service_count" ] || _service_count="0"
  [ -n "$_container_count" ] || _container_count="0"

  migrate_log "Planned update:"
  migrate_log "  Source network: '$OLD_NETWORK'"
  migrate_log "  Driver: ${_old_driver:-unknown}"
  migrate_log "  Detach all services/containers from '$OLD_NETWORK'"
  migrate_log "  Remove '$OLD_NETWORK'"
  migrate_log "  Recreate '$OLD_NETWORK' with subnet '$NEW_SUBNET'"
  if [ -n "$_old_stack_namespace" ]; then
    migrate_log "  Stack namespace label: '$_old_stack_namespace'"
  fi
  if [ -n "$NEW_GATEWAY" ]; then
    migrate_log "  Use gateway '$NEW_GATEWAY'"
  fi
  migrate_log "  Attached services: $_service_count"
  migrate_log "  Attached containers/endpoints: $_container_count"
  if [ "$(to_lower "$_old_driver")" = "overlay" ]; then
    migrate_log "  Note: remote standalone containers on other swarm nodes may not be discoverable."
  fi

  if [ "$ASSUME_YES" != "true" ]; then
    printf 'Continue? [y/N] '
    read -r _answer || true
    case "$_answer" in
      y|Y|yes|YES) ;;
      *)
        migrate_log "Cancelled."
        exit 0
        ;;
    esac
  fi

  migrate_log "Step 1/3: detach services from '$OLD_NETWORK'."
  if ! detach_services_from_network "$OLD_NETWORK"; then
    migrate_log "Failed while detaching services from '$OLD_NETWORK'."
    exit 1
  fi

  migrate_log "Step 1/3: detach containers from '$OLD_NETWORK'."
  if ! detach_containers_from_network "$OLD_NETWORK"; then
    migrate_log "Failed while detaching containers from '$OLD_NETWORK'."
    exit 1
  fi

  migrate_log "Step 2/3: remove original network '$OLD_NETWORK'."
  if ! remove_network_simple "$OLD_NETWORK"; then
    migrate_log "Failed to remove original network '$OLD_NETWORK'."
    exit 1
  fi

  migrate_log "Step 3/3: recreate original network with new subnet."
  if ! create_network_with_metadata \
    "$OLD_NETWORK" \
    "$NEW_SUBNET" \
    "$NEW_GATEWAY" \
    "${_old_driver:-overlay}" \
      "${_old_attachable:-false}" \
      "${_old_internal:-false}" \
      "$NETWORK_META_LABELS" \
      "$NETWORK_META_OPTIONS"; then
    remove_stale_network_entry "$OLD_NETWORK"
    if ! create_network_with_metadata \
      "$OLD_NETWORK" \
      "$NEW_SUBNET" \
      "$NEW_GATEWAY" \
      "${_old_driver:-overlay}" \
      "${_old_attachable:-false}" \
      "${_old_internal:-false}" \
      "$NETWORK_META_LABELS" \
      "$NETWORK_META_OPTIONS"; then
      migrate_log "Failed to recreate '$OLD_NETWORK' with subnet '$NEW_SUBNET'."
      exit 1
    fi
  fi

  migrate_log "Update completed."
  migrate_log "To verify:"
  migrate_log "  ksdn check $OLD_NETWORK"
}

check_network_subnet_usage() {
  _rc=0
  printf '' | grep -E "$NETWORK_FILTER_REGEX" >/dev/null 2>&1 || _rc=$?
  if [ "$_rc" -eq 2 ]; then
    err "Invalid regex for --network: $NETWORK_FILTER_REGEX"
    exit 1
  fi

  _nets="$(docker network ls --format '{{.Name}}' | grep -E "$NETWORK_FILTER_REGEX" || true)"
  if [ -z "$_nets" ]; then
    info "No networks matched regex: $NETWORK_FILTER_REGEX"
    exit 0
  fi

  printf '%-30s %-18s %7s %10s %8s %-15s %-20s\n' "NETWORK" "SUBNET" "USED" "AVAILABLE" "TOTAL" "GATEWAY" "STACK"
  _printed=0
  for _net in $_nets; do
    _subnet="$(docker network inspect "$_net" -f '{{with index .IPAM.Config 0}}{{.Subnet}}{{end}}' 2>/dev/null || true)"
    _gateway="$(docker network inspect "$_net" -f '{{with index .IPAM.Config 0}}{{.Gateway}}{{end}}' 2>/dev/null || true)"
    _stack="$(docker network inspect "$_net" -f '{{with .Labels}}{{with index . "com.docker.stack.namespace"}}{{.}}{{end}}{{end}}' 2>/dev/null | tr -d '[:space:]')"
    [ -n "$_stack" ] || _stack="N/A"
    _status_used=""
    _status_available=""

    if [ -n "$_subnet" ]; then
      _status_used="$(docker network inspect "$_net" -f "{{if .Status}}{{with .Status.IPAM}}{{with .Subnets}}{{with index . \"$_subnet\"}}{{.IPsInUse}}{{end}}{{end}}{{end}}{{end}}" 2>/dev/null | tr -d '[:space:]')"
      _status_available="$(docker network inspect "$_net" -f "{{if .Status}}{{with .Status.IPAM}}{{with .Subnets}}{{with index . \"$_subnet\"}}{{.DynamicIPsAvailable}}{{end}}{{end}}{{end}}{{end}}" 2>/dev/null | tr -d '[:space:]')"
    fi

    if [ -z "$_subnet" ]; then
      _used="N/A"
      _usable="N/A"
      _available="N/A"
      _subnet="-"
      [ -n "$_gateway" ] || _gateway="-"
    else
      case "$_status_used" in
        ''|*[!0-9]*)
          _used="$(docker network inspect "$_net" -f '{{range .Containers}}{{println .IPv4Address}}{{end}}' 2>/dev/null | sed '/^[[:space:]]*$/d' | wc -l | tr -d '[:space:]')"
          [ -n "$_used" ] || _used="0"

          _usable="$(cidr_usable_hosts "$_subnet")"
          case "$_usable" in
            ''|*[!0-9]*)
              _available="N/A"
              ;;
            *)
              _gateway_reserved=0
              if [ -n "$_gateway" ]; then
                _gateway_reserved=1
              fi
              _available=$((_usable - _used - _gateway_reserved))
              if [ "$_available" -lt 0 ]; then
                _available=0
              fi
              ;;
          esac
          ;;
        *)
          _used="$_status_used"
          case "$_status_available" in
            ''|*[!0-9]*)
              _available="N/A"
              _usable="N/A"
              ;;
            *)
              _available="$_status_available"
              _usable=$((_used + _available))
              ;;
          esac
          ;;
      esac
      [ -n "$_gateway" ] || _gateway="-"
    fi

    # By default, skip networks without subnet allocator metrics.
    if [ "$_subnet" = "-" ] || [ "$_used" = "N/A" ] || [ "$_usable" = "N/A" ] || [ "$_available" = "N/A" ]; then
      continue
    fi

    printf '%-30s %-18s %7s %10s %8s %-15s %-20s\n' "$_net" "$_subnet" "$_used" "$_available" "$_usable" "$_gateway" "$_stack"
    _printed=$((_printed + 1))
  done

  if [ "$_printed" -eq 0 ]; then
    info "No subnet allocator metrics found for networks matching regex: $NETWORK_FILTER_REGEX"
  fi

  if [ "$CHECK_SHOW_USING" = "true" ]; then
    for _net in $_nets; do
      _services="$(list_network_services "$_net")"
      printf '\nServices using network: %s\n' "$_net"
      if [ -z "$_services" ]; then
        printf '  (none)\n'
        continue
      fi

      printf '%-18s %s\n' "SERVICE ID" "SERVICE NAME"
      while IFS='|' read -r _service_id _service_name; do
        [ -n "$_service_id" ] || continue
        printf '%-18s %s\n' "$_service_id" "${_service_name:-$_service_id}"
      done <<EOF
$_services
EOF
    done
  fi
}

parse_ensure_args() {
  while [ $# -gt 0 ]; do
    case "$1" in
      -v|--verbose)
        VERBOSE="true"
        shift
        ;;
      -f|--file)
        [ $# -ge 2 ] || { err "Missing value for $1"; usage_ensure; exit 1; }
        COMPOSE_FILE="$2"
        shift 2
        ;;
      --stack-name)
        [ $# -ge 2 ] || { err "Missing value for $1"; usage_ensure; exit 1; }
        STACK_NAME="$2"
        shift 2
        ;;
      -h|--help)
        usage_ensure
        exit 0
        ;;
      *)
        err "Unknown ensure option: $1"
        usage_ensure
        exit 1
        ;;
    esac
  done
}

parse_update_args() {
  if [ $# -gt 0 ]; then
    case "$1" in
      -*)
        ;;
      *)
        OLD_NETWORK="$1"
        shift
        ;;
    esac
  fi

  while [ $# -gt 0 ]; do
    case "$1" in
      -v|--verbose)
        VERBOSE="true"
        shift
        ;;
      --network)
        [ $# -ge 2 ] || { err "Missing value for $1"; usage_update; exit 1; }
        OLD_NETWORK="$2"
        shift 2
        ;;
      --network=*)
        OLD_NETWORK="${1#*=}"
        shift
        ;;
      --subnet|--new-subnet)
        [ $# -ge 2 ] || { err "Missing value for $1"; usage_update; exit 1; }
        NEW_SUBNET="$2"
        shift 2
        ;;
      --subnet=*|--new-subnet=*)
        NEW_SUBNET="${1#*=}"
        shift
        ;;
      --old-network)
        [ $# -ge 2 ] || { err "Missing value for $1"; usage_update; exit 1; }
        OLD_NETWORK="$2"
        shift 2
        ;;
      --old-network=*)
        OLD_NETWORK="${1#*=}"
        shift
        ;;
      --gateway)
        [ $# -ge 2 ] || { err "Missing value for $1"; usage_update; exit 1; }
        NEW_GATEWAY="$2"
        shift 2
        ;;
      --gateway=*)
        NEW_GATEWAY="${1#*=}"
        shift
        ;;
      --yes)
        ASSUME_YES="true"
        shift
        ;;
      -h|--help)
        usage_update
        exit 0
        ;;
      *)
        if [ -z "$OLD_NETWORK" ]; then
          OLD_NETWORK="$1"
          shift
        else
          err "Unknown update option: $1"
          usage_update
          exit 1
        fi
        ;;
    esac
  done
}

parse_check_subnet_args() {
  if [ $# -gt 0 ]; then
    case "$1" in
      -*)
        ;;
      *)
        NETWORK_FILTER_REGEX="$1"
        shift
        ;;
    esac
  fi

  while [ $# -gt 0 ]; do
    case "$1" in
      -v|--verbose)
        VERBOSE="true"
        shift
        ;;
      -n|--network|--name-regex)
        [ $# -ge 2 ] || { err "Missing value for $1"; usage_check_subnet; exit 1; }
        NETWORK_FILTER_REGEX="$2"
        shift 2
        ;;
      --network=*|--name-regex=*)
        NETWORK_FILTER_REGEX="${1#*=}"
        shift
        ;;
      --using)
        CHECK_SHOW_USING="true"
        shift
        ;;
      -h|--help)
        usage_check_subnet
        exit 0
        ;;
      *)
        if [ "$NETWORK_FILTER_REGEX" = ".*" ]; then
          NETWORK_FILTER_REGEX="$1"
          shift
        else
          err "Unknown check-subnet option: $1"
          usage_check_subnet
          exit 1
        fi
        ;;
    esac
  done
}

COMMAND="ensure"
VERBOSE="${VERBOSE:-false}"

while [ $# -gt 0 ]; do
  case "$1" in
    -v|--verbose)
      VERBOSE="true"
      shift
      ;;
    *)
      break
      ;;
  esac
done

if [ $# -gt 0 ]; then
  case "$1" in
    ensure)
      COMMAND="ensure"
      shift
      ;;
    update)
      COMMAND="update"
      shift
      ;;
    migrate-subnet)
      COMMAND="update"
      shift
      ;;
    check-subnet)
      COMMAND="check-subnet"
      shift
      ;;
    check)
      COMMAND="check-subnet"
      shift
      ;;
    --network|--network=*|--subnet|--subnet=*|--new-subnet|--new-subnet=*|--old-network|--old-network=*|--gateway|--gateway=*|--yes|-v|--verbose)
      # Convenience: allow update options without explicit subcommand.
      COMMAND="update"
      ;;
    -n|--name-regex|--network|--network=*|--name-regex=*|--using)
      # Convenience: allow check-subnet options without explicit subcommand.
      COMMAND="check-subnet"
      ;;
    -h|--help|help)
      usage_all
      exit 0
      ;;
    *)
      # Backward-compatible default: no subcommand means ensure mode options.
      COMMAND="ensure"
      ;;
  esac
fi

COMPOSE_FILE="docker-compose.yml"
STACK_NAME="$(basename "$(pwd)")"
DRIVER="${DRIVER:-overlay}"
ATTACHABLE="${ATTACHABLE:-true}"
DRY_RUN="${DRY_RUN:-}"

OLD_NETWORK=""
NEW_SUBNET=""
NEW_GATEWAY=""
ASSUME_YES="false"
NETWORK_FILTER_REGEX=".*"
CHECK_SHOW_USING="false"

require_docker

case "$COMMAND" in
  ensure)
    parse_ensure_args "$@"
    enable_verbose_trace
    ensure_networks
    ;;
  update)
    parse_update_args "$@"
    enable_verbose_trace
    migrate_network_subnet
    ;;
  check-subnet)
    parse_check_subnet_args "$@"
    enable_verbose_trace
    check_network_subnet_usage
    ;;
  *)
    err "Unknown command: $COMMAND"
    usage_all
    exit 1
    ;;
esac
