#!/bin/sh
set -eu  # works in sh and bash

STACK_NAME=$(basename "$(pwd)")

# Prevent accidental deployment if stack name is "docker"
if [ "$STACK_NAME" = "docker" ]; then
  echo "Error: STACK_NAME cannot be 'docker'. Exiting."
  exit 1
fi

list_services() {
  docker service ls --format '{{.Name}}' 2>/dev/null \
    | grep "^${STACK_NAME}_" \
    | sed "s/^${STACK_NAME}_//" || true
}

SERVICES="$(list_services)"

if [ -z "$SERVICES" ]; then
  echo "No services found for stack: $STACK_NAME"
  exit 1
fi

# If no arguments, just list services under the stack
if [ $# -lt 1 ]; then
  printf '%s\n' "$SERVICES"
  exit 0
fi

SERVICE=$1
LINES=${2:-100}  # default to 100 if not provided

if ! printf '%s\n' "$SERVICES" | grep -Fxq "$SERVICE"; then
  echo "Error: service '$SERVICE' not found in stack '$STACK_NAME'." >&2
  echo "Available services:" >&2
  printf '%s\n' "$SERVICES" >&2
  exit 1
fi

docker service logs -f "${STACK_NAME}_${SERVICE}" -n "$LINES"
