#!/bin/sh
set -eu  # works in sh and bash

HOSTNAME="$(hostname 2>/dev/null || true)"
CURRENT_DIR="$(pwd)"
RESOLVE_IMAGE=""
MANUAL_COMPOSE_FILE=""
DEPLOY_ALL=0
REQUESTED_STACKS=""
DISCOVERED_STACK_DIRS=""
SELECTED_STACK_DIRS=""
RESOLVED_COMPOSE_FILE=""
RESOLVED_MODE_LABEL=""

print_help() {
  cat <<EOF
Usage: $0 [options]

Options:
  -f, --force               Always resolve image on deploy
  -c, --compose-file FILE   Compose file to use
  -s, --stack NAME          Deploy a first-level stack by folder name (repeatable)
  -a, --all                 Deploy all first-level stacks found under current folder
  -h, --help                Show this help

Behavior:
  - In a stack folder, deploys the current folder as before.
  - In a parent folder, scans first-level child folders for docker-compose*.yml,
    lets you select stack names, then runs batch deploy sequentially.
EOF
}

append_requested_stack() {
  if [ -n "$REQUESTED_STACKS" ]; then
    REQUESTED_STACKS="$REQUESTED_STACKS
$1"
  else
    REQUESTED_STACKS="$1"
  fi
}

append_discovered_stack_dir() {
  if [ -n "$DISCOVERED_STACK_DIRS" ]; then
    DISCOVERED_STACK_DIRS="$DISCOVERED_STACK_DIRS
$1"
  else
    DISCOVERED_STACK_DIRS="$1"
  fi
}

append_selected_stack_dir() {
  if [ -n "$SELECTED_STACK_DIRS" ]; then
    SELECTED_STACK_DIRS="$SELECTED_STACK_DIRS
$1"
  else
    SELECTED_STACK_DIRS="$1"
  fi
}

add_selected_stack_dir_unique() {
  stack_dir="$1"
  case "
$SELECTED_STACK_DIRS
" in
    *"
$stack_dir
"*) return 0 ;;
  esac
  append_selected_stack_dir "$stack_dir"
}

count_stack_dirs() {
  if [ -z "$1" ]; then
    echo 0
  else
    printf '%s\n' "$1" | awk 'NF { count++ } END { print count + 0 }'
  fi
}

validate_stack_name() {
  stack_name="$1"
  if [ "$stack_name" = "docker" ]; then
    echo "Error: STACK_NAME cannot be 'docker'. Exiting."
    return 1
  fi
}

has_usable_compose() {
  target_dir="$1"
  [ -f "$target_dir/docker-compose.yml" ] \
    || [ -f "$target_dir/docker-compose-prd.yml" ] \
    || [ -f "$target_dir/docker-compose-stg.yml" ]
}

resolve_manual_compose_candidate() {
  target_dir="$1"
  case "$MANUAL_COMPOSE_FILE" in
    /*) printf '%s\n' "$MANUAL_COMPOSE_FILE" ;;
    *) printf '%s/%s\n' "$target_dir" "$MANUAL_COMPOSE_FILE" ;;
  esac
}

resolve_compose_for_dir() {
  target_dir="$1"
  RESOLVED_COMPOSE_FILE=""
  RESOLVED_MODE_LABEL=""

  if [ -n "$MANUAL_COMPOSE_FILE" ]; then
    manual_candidate="$(resolve_manual_compose_candidate "$target_dir")"
    if [ -f "$manual_candidate" ]; then
      RESOLVED_COMPOSE_FILE="$MANUAL_COMPOSE_FILE"
      RESOLVED_MODE_LABEL="MANUAL"
      return 0
    fi
    return 1
  fi

  case "$HOSTNAME" in
    *-PRD-*)
      if [ -f "$target_dir/docker-compose-prd.yml" ]; then
        RESOLVED_COMPOSE_FILE="docker-compose-prd.yml"
        RESOLVED_MODE_LABEL="PRD"
        return 0
      fi
      ;;
    *-STG-*)
      if [ -f "$target_dir/docker-compose-stg.yml" ]; then
        RESOLVED_COMPOSE_FILE="docker-compose-stg.yml"
        RESOLVED_MODE_LABEL="STG"
        return 0
      fi
      ;;
  esac

  if [ -f "$target_dir/docker-compose.yml" ]; then
    RESOLVED_COMPOSE_FILE="docker-compose.yml"
    RESOLVED_MODE_LABEL="DEFAULT"
    return 0
  fi

  if [ -f "$target_dir/docker-compose-prd.yml" ] && [ ! -f "$target_dir/docker-compose-stg.yml" ]; then
    RESOLVED_COMPOSE_FILE="docker-compose-prd.yml"
    RESOLVED_MODE_LABEL="AUTO-PRD"
    return 0
  fi

  if [ -f "$target_dir/docker-compose-stg.yml" ] && [ ! -f "$target_dir/docker-compose-prd.yml" ]; then
    RESOLVED_COMPOSE_FILE="docker-compose-stg.yml"
    RESOLVED_MODE_LABEL="AUTO-STG"
    return 0
  fi

  return 1
}

discover_first_level_stack_dirs() {
  DISCOVERED_STACK_DIRS=""
  for candidate in "$CURRENT_DIR"/*; do
    [ -d "$candidate" ] || continue
    has_usable_compose "$candidate" || continue
    append_discovered_stack_dir "$candidate"
  done
}

find_discovered_stack_dir_by_name() {
  wanted_stack="$1"
  while IFS= read -r stack_dir; do
    [ -n "$stack_dir" ] || continue
    if [ "$(basename "$stack_dir")" = "$wanted_stack" ]; then
      printf '%s\n' "$stack_dir"
      return 0
    fi
  done <<EOF
$DISCOVERED_STACK_DIRS
EOF
  return 1
}

select_all_discovered_stacks() {
  SELECTED_STACK_DIRS=""
  while IFS= read -r stack_dir; do
    [ -n "$stack_dir" ] || continue
    add_selected_stack_dir_unique "$stack_dir"
  done <<EOF
$DISCOVERED_STACK_DIRS
EOF
}

build_selected_stack_dirs_from_requests() {
  SELECTED_STACK_DIRS=""
  while IFS= read -r wanted_stack; do
    [ -n "$wanted_stack" ] || continue
    matched_stack_dir="$(find_discovered_stack_dir_by_name "$wanted_stack" || true)"
    if [ -z "$matched_stack_dir" ]; then
      echo "Error: stack '$wanted_stack' was not found in first-level folders under $CURRENT_DIR."
      exit 1
    fi
    add_selected_stack_dir_unique "$matched_stack_dir"
  done <<EOF
$REQUESTED_STACKS
EOF
}

prompt_for_stack_selection() {
  SELECTED_STACK_DIRS=""
  discovered_count=0

  echo "Detected deployable stacks in first-level folders:"
  while IFS= read -r stack_dir; do
    [ -n "$stack_dir" ] || continue
    discovered_count=$((discovered_count + 1))
    eval "DISCOVERED_STACK_$discovered_count=\$stack_dir"
    echo "  [$discovered_count] $(basename "$stack_dir")"
  done <<EOF
$DISCOVERED_STACK_DIRS
EOF

  echo "Select stacks by number or name, separated by spaces or commas."
  echo "Use 'all' to deploy everything, or 'q' to cancel."
  printf "> "
  IFS= read -r selection || exit 1
  selection="$(printf '%s' "$selection" | tr ',' ' ')"

  case "$selection" in
    [Qq]|[Qq][Uu][Ii][Tt])
      echo "Cancelled."
      exit 1
      ;;
    [Aa][Ll][Ll])
      select_all_discovered_stacks
      return 0
      ;;
    "")
      echo "Error: no stack selection provided."
      exit 1
      ;;
  esac

  for token in $selection; do
    case "$token" in
      [Aa][Ll][Ll])
        select_all_discovered_stacks
        return 0
        ;;
      *[!0-9]*)
        matched_stack_dir="$(find_discovered_stack_dir_by_name "$token" || true)"
        if [ -z "$matched_stack_dir" ]; then
          echo "Error: unknown stack '$token'."
          exit 1
        fi
        add_selected_stack_dir_unique "$matched_stack_dir"
        ;;
      *)
        eval "matched_stack_dir=\${DISCOVERED_STACK_$token:-}"
        if [ -z "$matched_stack_dir" ]; then
          echo "Error: invalid selection '$token'."
          exit 1
        fi
        add_selected_stack_dir_unique "$matched_stack_dir"
        ;;
    esac
  done
}

is_armored_block_start() {
  printf '%s\n' "$1" | grep '^-----BEGIN .\+-----$' >/dev/null 2>&1
}

armored_block_end_line() {
  printf '%s\n' "$1" | sed 's/^-----BEGIN \(.*\)-----$/-----END \1-----/'
}

use_prompt_tty() {
  [ "${KSDD_PROMPT_STDIN:-0}" != "1" ] && [ -r /dev/tty ] && [ -w /dev/tty ]
}

read_hidden_secret_value() {
  value=""
  stty_was_hidden=0

  if use_prompt_tty; then
    if stty -echo < /dev/tty 2>/dev/null; then
      stty_was_hidden=1
    fi
    IFS= read -r value < /dev/tty || true
  else
    if stty -echo 2>/dev/null; then
      stty_was_hidden=1
    fi
    IFS= read -r value || true
  fi

  if [ -n "$value" ] && is_armored_block_start "$value"; then
    end_line="$(armored_block_end_line "$value")"
    while true; do
      if use_prompt_tty; then
        IFS= read -r line < /dev/tty || break
      else
        IFS= read -r line || break
      fi
      value="$value
$line"
      [ "$line" = "$end_line" ] && break
    done
  fi

  if [ "$stty_was_hidden" -eq 1 ]; then
    if use_prompt_tty; then
      stty echo < /dev/tty 2>/dev/null || true
    else
      stty echo 2>/dev/null || true
    fi
  fi

  echo >&2
  printf '%s' "$value"
}

read_visible_resource_value() {
  value=""
  if use_prompt_tty; then
    IFS= read -r value < /dev/tty || true
  else
    IFS= read -r value || true
  fi
  printf '%s' "$value"
}

resource_label() {
  case "$1" in
    secrets) printf '%s\n' "secret" ;;
    configs) printf '%s\n' "config" ;;
    *) printf '%s\n' "$1" ;;
  esac
}

swarm_resource_command() {
  case "$1" in
    secrets) printf '%s\n' "secret" ;;
    configs) printf '%s\n' "config" ;;
    *) return 1 ;;
  esac
}

prefixed_resource_name() {
  stack_name="$1"
  resource_name="$2"

  printf '%s_%s\n' "$stack_name" "$resource_name"
}

ensure_swarm_resource() {
  resource_section="$1"
  resource_name="$2"
  external_name="$3"
  label="$(resource_label "$resource_section")"
  docker_resource="$(swarm_resource_command "$resource_section")"

  if docker "$docker_resource" inspect "$external_name" >/dev/null 2>&1; then
    echo "Docker $label exists: $external_name" >&2
    return 0
  fi

  echo "Missing Docker $label '$external_name' for compose $label '$resource_name'." >&2

  while true; do
    if [ "$resource_section" = "secrets" ]; then
      printf "  %s %s: " "$label" "$resource_name" >&2
      value="$(read_hidden_secret_value)"
    else
      printf "  %s %s: " "$label" "$resource_name" >&2
      value="$(read_visible_resource_value)"
      echo >&2
    fi

    if [ -n "$value" ]; then
      if printf '%s' "$value" | docker "$docker_resource" create "$external_name" - >/dev/null; then
        echo "Created Docker $label: $external_name" >&2
        break
      fi

      echo "Error: failed to create Docker $label '$external_name'." >&2
      return 1
    fi

    echo "    Required (Docker $label does not exist)." >&2
  done
}

collect_compose_resource_records() {
  compose_file="$1"

  awk '
    function ltrim(s) { sub(/^[ \t\r\n]+/, "", s); return s }
    function rtrim(s) { sub(/[ \t\r\n]+$/, "", s); return s }
    function trim(s) { return rtrim(ltrim(s)) }
    function indent(s, tmp) { tmp=s; sub(/[^ ].*$/, "", tmp); return length(tmp) }
    function clean_value(s) {
      s=trim(s)
      sub(/[[:space:]]+#.*$/, "", s)
      if ((s ~ /^".*"$/) || (s ~ /^'\''.*'\''$/)) {
        s=substr(s, 2, length(s) - 2)
      }
      return s
    }
    function top_key(line, s) { s=line; sub(/:.*/, "", s); return s }
    function top_rest(line, s) { s=line; sub(/^[A-Za-z0-9_.-]+:[[:space:]]*/, "", s); return trim(s) }
    function emit(section, name, attr, value) {
      name=clean_value(name)
      if (name != "") {
        print section "\t" name "\t" attr "\t" value
      }
    }
    function flush_top() {
      if (in_top && top_child_count == 0) {
        print top_section "\t__section__\tinvalid_empty\t"
      }
    }
    function enter_top(section, rest, list_text, list_count, list_index, list_items) {
      flush_top()
      in_top=1
      top_section=section
      top_name=""
      top_child_count=0
      in_services=0
      in_service_resource=0
      print section "\t__section__\tseen\t"

      if (rest != "" && rest !~ /^#/) {
        top_child_count++
        print section "\t__section__\tinvalid_inline\t" rest
        if (rest ~ /^\[/) {
          list_text=rest
          gsub(/^\[/, "", list_text)
          gsub(/\].*$/, "", list_text)
          list_count=split(list_text, list_items, ",")
          for (list_index=1; list_index<=list_count; list_index++) {
            emit(section, list_items[list_index], "invalid_sequence", "")
          }
        }
      }
    }
    function parse_service_resource_scalar(section, text, name, list_text, list_count, list_index, list_items) {
      text=clean_value(text)
      if (text == "" || text ~ /^\{/) {
        return
      }
      if (text ~ /^\[/) {
        list_text=text
        gsub(/^\[/, "", list_text)
        gsub(/\].*$/, "", list_text)
        list_count=split(list_text, list_items, ",")
        for (list_index=1; list_index<=list_count; list_index++) {
          parse_service_resource_scalar(section, list_items[list_index])
        }
        return
      }
      if (text ~ /^source:[[:space:]]*/) {
        sub(/^source:[[:space:]]*/, "", text)
        name=clean_value(text)
        emit(section, name, "referenced", "")
      } else if (text !~ /:/) {
        emit(section, text, "referenced", "")
      }
    }
    {
      raw=$0
      sub(/\r$/, "", raw)
      trimmed=trim(raw)
      if (trimmed == "" || trimmed ~ /^#/) {
        next
      }

      if (raw !~ /^[ ]/ && raw ~ /^[A-Za-z0-9_.-]+:[[:space:]]*/) {
        key=top_key(raw)
        rest=top_rest(raw)
        if (key == "secrets" || key == "configs") {
          enter_top(key, rest)
          next
        }

        flush_top()
        in_top=0
        top_section=""
        top_name=""
        top_child_count=0
        in_service_resource=0
        if (key == "services") {
          in_services=1
        } else {
          in_services=0
        }
        next
      }

      if (in_top) {
        current_indent=indent(raw)
        if (current_indent == 2 && trimmed ~ /^-/) {
          top_child_count++
          item=trimmed
          sub(/^-+[[:space:]]*/, "", item)
          if (item ~ /^source:[[:space:]]*/) {
            sub(/^source:[[:space:]]*/, "", item)
          }
          emit(top_section, item, "invalid_sequence", "")
          top_name=""
          next
        }
        if (current_indent == 2 && trimmed ~ /^[^:#][^:]*:[[:space:]]*/) {
          top_child_count++
          name=trimmed
          sub(/:.*/, "", name)
          top_name=clean_value(name)
          emit(top_section, top_name, "declared", "")
          inline=trimmed
          sub(/^[^:]+:[[:space:]]*/, "", inline)
          inline=trim(inline)
          if (inline != "" && inline !~ /^#/) {
            emit(top_section, top_name, "inline", inline)
          }
          next
        }
        if (current_indent > 2 && top_name != "") {
          field=trimmed
          if (field ~ /^file:[[:space:]]*/) {
            sub(/^file:[[:space:]]*/, "", field)
            emit(top_section, top_name, "file", clean_value(field))
            next
          }
          if (field ~ /^external:[[:space:]]*/) {
            sub(/^external:[[:space:]]*/, "", field)
            field=clean_value(field)
            if (field !~ /^(false|False|FALSE|no|0)$/) {
              emit(top_section, top_name, "external", field)
            }
            next
          }
          if (field ~ /^name:[[:space:]]*/) {
            sub(/^name:[[:space:]]*/, "", field)
            emit(top_section, top_name, "name", clean_value(field))
            next
          }
        }
        next
      }

      if (in_services) {
        current_indent=indent(raw)
        if (current_indent == 4 && trimmed ~ /^(secrets|configs):[[:space:]]*/) {
          service_section=trimmed
          sub(/:.*/, "", service_section)
          service_rest=trimmed
          sub(/^[^:]+:[[:space:]]*/, "", service_rest)
          service_rest=trim(service_rest)
          if (service_rest != "" && service_rest !~ /^#/) {
            parse_service_resource_scalar(service_section, service_rest)
            in_service_resource=0
          } else {
            in_service_resource=1
            service_resource_indent=current_indent
          }
          next
        }

        if (in_service_resource) {
          if (current_indent <= service_resource_indent && trimmed !~ /^-/) {
            in_service_resource=0
          } else {
            if (trimmed ~ /^-/) {
              item=trimmed
              sub(/^-+[[:space:]]*/, "", item)
              parse_service_resource_scalar(service_section, item)
              next
            }
            if (trimmed ~ /^source:[[:space:]]*/) {
              parse_service_resource_scalar(service_section, trimmed)
              next
            }
          }
        }
      }
    }
    END {
      flush_top()
    }
  ' "$compose_file"
}

record_has_attr() {
  records_file="$1"
  resource_section="$2"
  resource_name="$3"
  resource_attr="$4"

  awk -F '\t' \
    -v section="$resource_section" \
    -v name="$resource_name" \
    -v attr="$resource_attr" \
    '$1 == section && $2 == name && $3 == attr { found=1; exit } END { exit found ? 0 : 1 }' \
    "$records_file"
}

record_attr_value() {
  records_file="$1"
  resource_section="$2"
  resource_name="$3"
  resource_attr="$4"

  awk -F '\t' \
    -v section="$resource_section" \
    -v name="$resource_name" \
    -v attr="$resource_attr" \
    '$1 == section && $2 == name && $3 == attr { print $4; found=1; exit } END { exit found ? 0 : 1 }' \
    "$records_file"
}

strip_top_level_resource_sections() {
  compose_file="$1"

  awk '
    function trim(s) { sub(/^[ \t\r\n]+/, "", s); sub(/[ \t\r\n]+$/, "", s); return s }
    {
      raw=$0
      trimmed=trim(raw)

      if (raw !~ /^[ ]/ && raw ~ /^[A-Za-z0-9_.-]+:[[:space:]]*/) {
        key=raw
        sub(/:.*/, "", key)
        if (key == "secrets" || key == "configs") {
          skip=1
          next
        }
        skip=0
      }

      if (!skip) {
        print
      }
    }
  ' "$compose_file"
}

append_normalized_resource_sections() {
  defs_file="$1"

  for resource_section in secrets configs; do
    if awk -F '\t' -v section="$resource_section" '$1 == section { found=1; exit } END { exit found ? 0 : 1 }' "$defs_file"; then
      printf '\n%s:\n' "$resource_section"
      awk -F '\t' -v section="$resource_section" '
        $1 == section {
          print "  " $2 ":"
          if ($3 == "external") {
            print "    external: true"
            if ($4 != "") {
              print "    name: " $4
            }
          } else {
            print "    file: " $4
          }
        }
      ' "$defs_file"
    fi
  done
}

cleanup_prepared_compose() {
  if [ -n "${PREPARED_COMPOSE_TEMP_FILE:-}" ] && [ -f "$PREPARED_COMPOSE_TEMP_FILE" ]; then
    rm -f "$PREPARED_COMPOSE_TEMP_FILE"
  fi
}

prepare_compose_for_deploy() {
  compose_file="$1"
  stack_name="$2"
  PREPARED_COMPOSE_FILE="$compose_file"
  PREPARED_COMPOSE_TEMP_FILE=""

  records_dir="$(mktemp -d "${TMPDIR:-/tmp}/ksdd-deploy.XXXXXX")"
  records_file="$records_dir/resources.tsv"
  defs_file="$records_dir/defs.tsv"
  needs_prepared_compose=0

  collect_compose_resource_records "$compose_file" > "$records_file"
  : > "$defs_file"

  if awk -F '\t' '$2 == "__section__" && ($3 == "invalid_empty" || $3 == "invalid_inline" || $3 == "invalid_sequence") { found=1; exit } END { exit found ? 0 : 1 }' "$records_file"; then
    needs_prepared_compose=1
    echo "Preparing compose resource mappings before deploy." >&2
  fi

  for resource_section in secrets configs; do
    names_file="$records_dir/$resource_section.names"
    awk -F '\t' -v section="$resource_section" '$1 == section && $2 != "__section__" && !seen[$2]++ { print $2 }' "$records_file" > "$names_file"

    for resource_name in $(cat "$names_file"); do
      external_name=""
      if record_has_attr "$records_file" "$resource_section" "$resource_name" "external"; then
        external_name="$(record_attr_value "$records_file" "$resource_section" "$resource_name" "name" || true)"
        if [ -z "$external_name" ]; then
          external_value="$(record_attr_value "$records_file" "$resource_section" "$resource_name" "external" || true)"
          case "$external_value" in
            true|True|TRUE|yes|YES|1|"") ;;
            *) external_name="$external_value" ;;
          esac
        fi
        printf '%s\t%s\texternal\t%s\n' "$resource_section" "$resource_name" "$external_name" >> "$defs_file"
        continue
      fi

      resource_file="$(record_attr_value "$records_file" "$resource_section" "$resource_name" "file" || true)"
      if [ -n "$resource_file" ]; then
        printf '%s\t%s\tfile\t%s\n' "$resource_section" "$resource_name" "$resource_file" >> "$defs_file"
        continue
      fi

      if record_has_attr "$records_file" "$resource_section" "$resource_name" "referenced" \
        || record_has_attr "$records_file" "$resource_section" "$resource_name" "declared" \
        || record_has_attr "$records_file" "$resource_section" "$resource_name" "invalid_sequence"; then
        external_name="$(prefixed_resource_name "$stack_name" "$resource_name")"
        ensure_swarm_resource "$resource_section" "$resource_name" "$external_name"
        printf '%s\t%s\texternal\t%s\n' "$resource_section" "$resource_name" "$external_name" >> "$defs_file"
        needs_prepared_compose=1
      fi
    done
  done

  if [ "$needs_prepared_compose" -eq 1 ]; then
    PREPARED_COMPOSE_TEMP_FILE="$(mktemp "./.ksdd-compose.XXXXXX.yml")"
    strip_top_level_resource_sections "$compose_file" > "$PREPARED_COMPOSE_TEMP_FILE"
    append_normalized_resource_sections "$defs_file" >> "$PREPARED_COMPOSE_TEMP_FILE"
    PREPARED_COMPOSE_FILE="$PREPARED_COMPOSE_TEMP_FILE"
    echo "Using prepared compose file: $PREPARED_COMPOSE_FILE" >&2
  fi

  rm -rf "$records_dir"
}

deploy_stack_dir() {
  target_dir="$1"
  stack_name="$(basename "$target_dir")"

  validate_stack_name "$stack_name"
  if ! resolve_compose_for_dir "$target_dir"; then
    echo "Error: no usable compose file found in $target_dir."
    echo "Checked: docker-compose.yml, docker-compose-prd.yml, docker-compose-stg.yml"
    echo "Hint: pass explicit file with -c <compose-file>"
    return 1
  fi

  (
    cd "$target_dir"
    PREPARED_COMPOSE_FILE="$RESOLVED_COMPOSE_FILE"
    PREPARED_COMPOSE_TEMP_FILE=""
    trap cleanup_prepared_compose EXIT
    trap 'cleanup_prepared_compose; exit 129' HUP
    trap 'cleanup_prepared_compose; exit 130' INT
    trap 'cleanup_prepared_compose; exit 143' TERM

    echo "Mode $RESOLVED_MODE_LABEL is running stack '$stack_name' (compose: $RESOLVED_COMPOSE_FILE)"

    if [ -f .env ]; then
      # Simple export (breaks if values contain spaces/quotes)
      env_exports="$(grep -v '^#' .env | xargs 2>/dev/null || true)"
      if [ -n "$env_exports" ]; then
        export $env_exports
      fi
    fi

    prepare_compose_for_deploy "$RESOLVED_COMPOSE_FILE" "$stack_name"

    if [ -n "$RESOLVE_IMAGE" ]; then
      echo "Running: docker stack deploy -c $PREPARED_COMPOSE_FILE $stack_name --detach=false --with-registry-auth $RESOLVE_IMAGE"
      docker stack deploy \
        -c "$PREPARED_COMPOSE_FILE" \
        "$stack_name" \
        --detach=false \
        --with-registry-auth \
        "$RESOLVE_IMAGE"
    else
      echo "Running: docker stack deploy -c $PREPARED_COMPOSE_FILE $stack_name --detach=false --with-registry-auth"
      docker stack deploy \
        -c "$PREPARED_COMPOSE_FILE" \
        "$stack_name" \
        --detach=false \
        --with-registry-auth
    fi
  )
}

deploy_selected_stack_dirs() {
  total_selected="$(count_stack_dirs "$SELECTED_STACK_DIRS")"
  current_index=0

  while IFS= read -r stack_dir; do
    [ -n "$stack_dir" ] || continue
    current_index=$((current_index + 1))
    echo "[$current_index/$total_selected] Deploying stack '$(basename "$stack_dir")'"
    deploy_stack_dir "$stack_dir"
  done <<EOF
$SELECTED_STACK_DIRS
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    -f|--force)
      RESOLVE_IMAGE="--resolve-image=always"
      shift
      ;;
    -c|--compose-file)
      if [ $# -lt 2 ]; then
        echo "Error: $1 requires a file argument."
        exit 2
      fi
      MANUAL_COMPOSE_FILE="$2"
      shift 2
      ;;
    -s|--stack)
      if [ $# -lt 2 ]; then
        echo "Error: $1 requires a stack name."
        exit 2
      fi
      append_requested_stack "$2"
      shift 2
      ;;
    -a|--all)
      DEPLOY_ALL=1
      shift
      ;;
    -h|--help)
      print_help
      exit 0
      ;;
    *)
      echo "Error: Unknown option: $1"
      print_help
      exit 2
      ;;
  esac
done

if [ "$DEPLOY_ALL" -eq 1 ] && [ -n "$REQUESTED_STACKS" ]; then
  echo "Error: --all cannot be combined with --stack."
  exit 2
fi

if has_usable_compose "$CURRENT_DIR" && [ "$DEPLOY_ALL" -eq 0 ] && [ -z "$REQUESTED_STACKS" ]; then
  deploy_stack_dir "$CURRENT_DIR"
  exit 0
fi

discover_first_level_stack_dirs

if [ -z "$DISCOVERED_STACK_DIRS" ]; then
  if has_usable_compose "$CURRENT_DIR"; then
    echo "Error: no first-level stack folders found under $CURRENT_DIR."
    echo "Hint: run 'ksdd' without --stack/--all to deploy the current folder."
    exit 1
  fi

  echo "Error: no usable compose file found in $CURRENT_DIR or its first-level child folders."
  echo "Checked: docker-compose.yml, docker-compose-prd.yml, docker-compose-stg.yml"
  echo "Hint: run inside a stack folder or pass -c <compose-file>"
  exit 1
fi

if [ "$DEPLOY_ALL" -eq 1 ]; then
  select_all_discovered_stacks
elif [ -n "$REQUESTED_STACKS" ]; then
  build_selected_stack_dirs_from_requests
else
  prompt_for_stack_selection
fi

if [ -z "$SELECTED_STACK_DIRS" ]; then
  echo "Error: no stacks selected."
  exit 1
fi

deploy_selected_stack_dirs
