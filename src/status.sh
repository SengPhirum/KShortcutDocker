#!/bin/sh
set -eu  # works in sh and bash

CURRENT_DIR="$(pwd)"
STACK_NAME="$(basename "$CURRENT_DIR")"
SERVICE=""
LOG_LINES=5

print_help() {
  cat <<EOF
Usage: ksd status [service] [options]

Shows each service of the stack in the current folder with its mode, replicas,
state and image. For services that are not fully running it also shows the task
errors (image pull, scheduling, crashes, ...) and the last log lines of the most
recent failed task. In a parent folder it checks every first-level stack folder.

Arguments:
  service              Show one service in detail, including its task history

Options:
  -n, --logs N         Log lines to show for a failed task (default: 5, 0 = none)
  -h, --help           Show this help

Exit status is 0 when every service is healthy, 1 otherwise.
EOF
}

has_compose_file() {
  [ -f "$1/docker-compose.yml" ] || [ -f "$1/docker-compose-prd.yml" ] || [ -f "$1/docker-compose-stg.yml" ]
}

# Reads "S|<service fields>", "U|<update fields>" and "T|<task fields>" lines and
# prints the service table plus details for unhealthy services (or the wanted one).
# "@@logs|<task id>|<label>" marks where to print a failed task's logs, and the
# last line is "@@unhealthy|<count>".
build_status_report() {
  awk -F '|' \
    -v stack="$1" \
    -v wanted="$2" \
    -v log_hint="$3" \
    -v log_lines="$LOG_LINES" '
    function trim(s) { sub(/^[ \t\r]+/, "", s); sub(/[ \t\r]+$/, "", s); return s }
    function fields_from(n, out, i) {
      out=$n
      for (i=n+1; i<=NF; i++) out=out "|" $i
      return out
    }
    function short_name(name) {
      if (index(name, stack "_") == 1) return substr(name, length(stack) + 2)
      return name
    }
    function cell(s) { gsub(/\t/, " ", s); return s }
    function unquote(s) {
      # Docker prints task errors wrapped in double quotes.
      if (s ~ /^".*"$/) s=substr(s, 2, length(s) - 2)
      return s
    }
    function print_table(rows, count, prefix, r, n, i, f, w, line) {
      for (r=1; r<=count; r++) {
        n=split(rows[r], f, "\t")
        for (i=1; i<n; i++) if (length(f[i]) > w[i]) w[i]=length(f[i])
      }
      for (r=1; r<=count; r++) {
        n=split(rows[r], f, "\t")
        line=prefix
        for (i=1; i<n; i++) line=line sprintf("%-" w[i] "s  ", f[i])
        line=line f[n]
        sub(/ +$/, "", line)
        print line
      }
    }
    function service_state(name, mode, replicas, running, desired, done, total, u) {
      u=update_state[name]
      if (u == "paused") return "update paused"
      if (u == "rollback_paused") return "rollback paused"
      if (u == "updating") return "updating"
      if (u == "rollback_started") return "rolling back"

      running=replicas
      sub(/\/.*/, "", running)
      desired=replicas
      sub(/^[^\/]*\//, "", desired)
      sub(/[^0-9].*$/, "", desired)

      if (mode ~ /job/) {
        # Jobs show replicas as "0/1 (1/1 completed)".
        if (match(replicas, /\([0-9]+\/[0-9]+ completed\)/)) {
          done=substr(replicas, RSTART + 1, RLENGTH - 2)
          total=done
          sub(/\/.*/, "", done)
          sub(/^[0-9]+\//, "", total)
          sub(/ .*/, "", total)
          if (total + 0 > 0 && done + 0 >= total + 0) return "completed"
        }
        return error_count[name] ? "failing" : "running"
      }
      if (desired + 0 == 0) return "scaled to 0"
      if (running + 0 < desired + 0) return error_count[name] ? "failing" : "starting"
      if (u == "rollback_completed") return "rolled back"
      return "running"
    }
    function is_healthy(state) { return state == "running" || state == "scaled to 0" || state == "completed" }
    function print_details(i, name, n, j, count, hidden, repeated, rows, seen_error, failed_task) {
      name=svc_name[i]
      print ""
      print short_name(name) ": " svc_state[i] ", replicas " svc_replicas[i]
      if (update_state[name] != "" && update_state[name] != "completed" && update_message[name] != "") {
        print "  Update: " update_message[name]
      }

      n=task_count[name]
      count=1
      hidden=0
      repeated=0
      rows[1]="TASK\tSTATE\tNODE\tERROR"
      for (j=1; j<=n; j++) {
        if (failed_task == "" && task_state[name, j] ~ /^Failed/) {
          failed_task=task_id[name, j] "|" task_name[name, j] " (" tolower(task_state[name, j]) ")"
        }
        # The overview lists current tasks and each distinct earlier error once;
        # the service view lists the whole history.
        if (wanted == "" && task_desired[name, j] != "Running") {
          if (task_error[name, j] == "") continue
          if (task_error[name, j] in seen_error) {
            repeated++
            continue
          }
        }
        if (task_error[name, j] != "") seen_error[task_error[name, j]]=1
        if (count - 1 >= task_limit) {
          hidden++
          continue
        }
        rows[++count]=cell(task_name[name, j]) "\t" cell(task_state[name, j]) "\t" cell(task_node[name, j]) "\t" cell(unquote(task_error[name, j]))
      }
      if (count > 1) {
        print_table(rows, count, "  ")
      } else {
        print "  No tasks found."
      }
      if (repeated > 0) print "  (" repeated " older task" (repeated == 1 ? "" : "s") " with the same error)"
      if (hidden > 0) print "  (" hidden " older task" (hidden == 1 ? "" : "s") " not shown)"
      if (log_lines > 0 && failed_task != "") print "@@logs|" failed_task
      print "  More: " log_hint " " short_name(name)
    }
    $1 == "S" && NF >= 6 {
      svc_count++
      svc_name[svc_count]=$3
      svc_mode[svc_count]=$4
      svc_replicas[svc_count]=$5
      svc_image[svc_count]=$6
      next
    }
    $1 == "U" && $2 != "" {
      update_state[$2]=$3
      update_message[$2]=trim(fields_from(4))
      next
    }
    $1 == "T" && NF >= 7 {
      name=$3
      sub(/^[ \t]*\\_[ \t]*/, "", name)  # history rows can be named " \_ <task>"
      service=name
      sub(/\.[^.]*$/, "", service)
      n=++task_count[service]
      task_id[service, n]=$2
      task_name[service, n]=short_name(name)
      task_node[service, n]=$4
      task_desired[service, n]=$5
      task_state[service, n]=$6
      task_error[service, n]=trim(fields_from(7))
      if (task_error[service, n] != "") error_count[service]++
      last_service=service
      next
    }
    $1 == "T" && last_service != "" {
      # Continuation of an error message that contained a newline.
      n=task_count[last_service]
      task_error[last_service, n]=trim(task_error[last_service, n] " " trim(fields_from(2)))
      next
    }
    END {
      task_limit=(wanted == "") ? 6 : 10
      row_count=1
      table[1]="SERVICE\tMODE\tREPLICAS\tSTATE\tIMAGE"
      unhealthy=0
      for (i=1; i<=svc_count; i++) {
        svc_state[i]=service_state(svc_name[i], svc_mode[i], svc_replicas[i])
        if (!is_healthy(svc_state[i])) unhealthy++
        table[++row_count]=cell(short_name(svc_name[i])) "\t" cell(svc_mode[i]) "\t" cell(svc_replicas[i]) "\t" svc_state[i] "\t" cell(svc_image[i])
      }
      print_table(table, row_count, "")

      for (i=1; i<=svc_count; i++) {
        if (wanted != "" || !is_healthy(svc_state[i])) print_details(i)
      }

      if (wanted == "") {
        print ""
        if (unhealthy == 0) {
          print (svc_count == 1 ? "The service is healthy." : "All " svc_count " services are healthy.")
        } else {
          print unhealthy " of " svc_count " service" (svc_count == 1 ? "" : "s") " need" (unhealthy == 1 ? "s" : "") " attention."
        }
      }
      print "@@unhealthy|" unhealthy
    }
  '
}

print_task_logs() {
  task_id="${1%%|*}"
  task_label="${1#*|}"

  # Bound the wait in case a node does not answer the log request.
  timeout_cmd=""
  if command -v timeout >/dev/null 2>&1; then
    timeout_cmd="timeout 15"
  fi
  logs="$($timeout_cmd docker service logs --raw --tail "$LOG_LINES" "$task_id" 2>&1 < /dev/null)" || logs=""
  [ -n "$logs" ] || return 0

  echo "  Last log lines of $task_label:"
  printf '%s\n' "$logs" | sed 's/^/    /'
}

# Returns 0 when healthy, 1 when a service needs attention, 2 on errors and
# 3 when the stack has no services.
show_stack_status() {
  stack="$1"
  wanted_service="$2"
  log_hint="$3"

  if ! services="$(docker stack services "$stack" --format '{{.ID}}|{{.Name}}|{{.Mode}}|{{.Replicas}}|{{.Image}}' 2>/dev/null)"; then
    # Run it again so Docker's own error (daemon down, not a manager, ...) is shown.
    docker stack services "$stack" > /dev/null || true
    return 2
  fi
  if [ -z "$services" ]; then
    echo "No services found for stack: $stack (not deployed?)"
    return 3
  fi

  if [ -n "$wanted_service" ]; then
    all_services="$services"
    services="$(printf '%s\n' "$all_services" | awk -F '|' -v name="${stack}_${wanted_service}" '$2 == name')"
    if [ -z "$services" ]; then
      echo "Error: service '$wanted_service' not found in stack '$stack'." >&2
      echo "Available services:" >&2
      printf '%s\n' "$all_services" | cut -d '|' -f 2 | sed "s/^${stack}_/  /" >&2
      return 2
    fi
  fi

  service_ids="$(printf '%s\n' "$services" | cut -d '|' -f 1)"
  updates="$(docker service inspect $service_ids --format '{{.Spec.Name}}|{{if .UpdateStatus}}{{.UpdateStatus.State}}|{{.UpdateStatus.Message}}{{else}}|{{end}}' 2>/dev/null || true)"
  tasks="$(docker stack ps "$stack" --no-trunc --format '{{.ID}}|{{.Name}}|{{.Node}}|{{.DesiredState}}|{{.CurrentState}}|{{.Error}}' 2>/dev/null || true)"

  report="$(
    {
      printf '%s\n' "$services" | sed 's/^/S|/'
      printf '%s\n' "$updates" | sed 's/^/U|/'
      printf '%s\n' "$tasks" | sed 's/^/T|/'
    } | build_status_report "$stack" "$wanted_service" "$log_hint"
  )"

  unhealthy=0
  while IFS= read -r line; do
    case "$line" in
      "@@logs|"*) print_task_logs "${line#@@logs|}" ;;
      "@@unhealthy|"*) unhealthy="${line#@@unhealthy|}" ;;
      *) printf '%s\n' "$line" ;;
    esac
  done <<EOF
$report
EOF

  [ "$unhealthy" -eq 0 ]
}

while [ $# -gt 0 ]; do
  case "$1" in
    -n|--logs)
      if [ $# -lt 2 ]; then
        echo "Error: $1 requires a number of lines."
        exit 2
      fi
      LOG_LINES="$2"
      shift 2
      ;;
    --logs=*)
      LOG_LINES="${1#*=}"
      shift
      ;;
    -h|--help)
      print_help
      exit 0
      ;;
    -*)
      echo "Error: Unknown option: $1"
      print_help
      exit 2
      ;;
    *)
      if [ -n "$SERVICE" ]; then
        echo "Error: unexpected argument: $1"
        print_help
        exit 2
      fi
      SERVICE="$1"
      shift
      ;;
  esac
done

case "$LOG_LINES" in
  ''|*[!0-9]*)
    echo "Error: --logs needs a number of lines, got '$LOG_LINES'."
    exit 2
    ;;
esac

if [ -n "$SERVICE" ] || has_compose_file "$CURRENT_DIR"; then
  echo "Stack: $STACK_NAME"
  show_stack_status "$STACK_NAME" "$SERVICE" "ksd log" || exit 1
  exit 0
fi

# Parent folder: check every first-level stack folder, like 'ksd deploy' batch mode.
stack_count=0
overall=0
for candidate in "$CURRENT_DIR"/*; do
  [ -d "$candidate" ] && has_compose_file "$candidate" || continue
  stack="$(basename "$candidate")"
  [ "$stack_count" -eq 0 ] || echo
  stack_count=$((stack_count + 1))

  echo "Stack: $stack"
  rc=0
  show_stack_status "$stack" "" "cd $stack && ksd log" || rc=$?
  # A folder that is not deployed is reported but does not fail the check.
  case "$rc" in
    1|2) overall=1 ;;
  esac
done

if [ "$stack_count" -eq 0 ]; then
  # No stack folders below: use the current folder name, like 'ksd log'.
  echo "Stack: $STACK_NAME"
  show_stack_status "$STACK_NAME" "" "ksd log" || exit 1
fi

exit "$overall"
