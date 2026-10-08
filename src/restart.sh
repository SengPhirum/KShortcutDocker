#!/bin/sh
set -eu  # works in sh and bash

STACK_NAME="$(basename "$(pwd)")"
REQUESTED_SERVICES=""

print_help() {
  cat <<EOF
Usage: ksd restart [service...] [options]

Restarts services of the stack in the current folder with
'docker service update --force': every task is replaced by a new one with the
same image and settings, following the service's update_config (one task at a
time by default). Services are restarted one after another, and each restart
waits until the service has converged.

Arguments:
  service              Service to restart (repeatable; default: every service)

Options:
  -h, --help           Show this help

Use 'ksd redeploy' instead to remove the whole stack and deploy it again.
Exit status is 0 when every restart succeeded, 1 otherwise.
EOF
}

append_requested_service() {
  if [ -n "$REQUESTED_SERVICES" ]; then
    REQUESTED_SERVICES="$REQUESTED_SERVICES
$1"
  else
    REQUESTED_SERVICES="$1"
  fi
}

while [ $# -gt 0 ]; do
  case "$1" in
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
      append_requested_service "$1"
      shift
      ;;
  esac
done

# Prevent accidental restarts if stack name is "docker"
if [ "$STACK_NAME" = "docker" ]; then
  echo "Error: STACK_NAME cannot be 'docker'. Exiting."
  exit 1
fi

if ! stack_services="$(docker stack services "$STACK_NAME" --format '{{.Name}}' 2>/dev/null)"; then
  # Run it again so Docker's own error (daemon down, not a manager, ...) is shown.
  docker stack services "$STACK_NAME" > /dev/null || true
  exit 1
fi
if [ -z "$stack_services" ]; then
  echo "No services found for stack: $STACK_NAME (not deployed?)"
  exit 1
fi
SERVICES="$(printf '%s\n' "$stack_services" | sed "s/^${STACK_NAME}_//" | sort)"

if [ -n "$REQUESTED_SERVICES" ]; then
  while IFS= read -r service; do
    if ! printf '%s\n' "$SERVICES" | grep -Fxq "$service"; then
      echo "Error: service '$service' not found in stack '$STACK_NAME'." >&2
      echo "Available services:" >&2
      printf '%s\n' "$SERVICES" | sed 's/^/  /' >&2
      exit 2
    fi
  done <<EOF
$REQUESTED_SERVICES
EOF
  # Keep the requested order, without duplicates.
  SERVICES="$(printf '%s\n' "$REQUESTED_SERVICES" | awk '!seen[$0]++')"
fi

total="$(printf '%s\n' "$SERVICES" | awk 'NF { count++ } END { print count + 0 }')"
current_index=0
restarted=0
failed=""

# Read the list on fd 3 so docker keeps the terminal on stdin.
while IFS= read -r service <&3; do
  [ -n "$service" ] || continue
  current_index=$((current_index + 1))
  echo "[$current_index/$total] Restarting service '$service' in stack '$STACK_NAME'"
  echo "Running: docker service update --force --detach=false --with-registry-auth ${STACK_NAME}_${service}"
  if docker service update \
    --force \
    --detach=false \
    --with-registry-auth \
    "${STACK_NAME}_${service}"; then
    restarted=$((restarted + 1))
  else
    failed="$failed $service"
  fi
done 3<<EOF
$SERVICES
EOF

echo
if [ -n "$failed" ]; then
  echo "Restarted $restarted of $total service(s) in stack '$STACK_NAME'. Failed:$failed"
  echo "Check with: ksd status"
  exit 1
fi
echo "Restarted $restarted service(s) in stack '$STACK_NAME'."
