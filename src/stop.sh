#!/bin/sh
set -eu  # works in sh and bash

STACK_NAME=$(basename "$(pwd)")
HOSTNAME="$(hostname 2>/dev/null || true)"
COMPOSE_FILE=""
MODE_LABEL=""

# Prevent accidental deployment if stack name is "docker"
if [ "$STACK_NAME" = "docker" ]; then
  echo "Error: STACK_NAME cannot be 'docker'. Exiting."
  exit 1
fi

# Auto-pick compose file based on hostname.
case "$HOSTNAME" in
  *-PRD-*)
    if [ -f docker-compose-prd.yml ]; then
      COMPOSE_FILE="docker-compose-prd.yml"
      MODE_LABEL="PRD"
    fi
    ;;
  *-STG-*)
    if [ -f docker-compose-stg.yml ]; then
      COMPOSE_FILE="docker-compose-stg.yml"
      MODE_LABEL="STG"
    fi
    ;;
esac

# Fallback order:
# 1) docker-compose.yml
# 2) single available env compose file (prd/stg) when default file is absent
if [ -z "$COMPOSE_FILE" ]; then
  if [ -f docker-compose.yml ]; then
    COMPOSE_FILE="docker-compose.yml"
    MODE_LABEL="DEFAULT"
  elif [ -f docker-compose-prd.yml ] && [ ! -f docker-compose-stg.yml ]; then
    COMPOSE_FILE="docker-compose-prd.yml"
    MODE_LABEL="AUTO-PRD"
  elif [ -f docker-compose-stg.yml ] && [ ! -f docker-compose-prd.yml ]; then
    COMPOSE_FILE="docker-compose-stg.yml"
    MODE_LABEL="AUTO-STG"
  fi
fi

if [ -z "$COMPOSE_FILE" ] || [ ! -f "$COMPOSE_FILE" ]; then
  echo "Error: no usable compose file found in $(pwd)."
  echo "Checked: docker-compose.yml, docker-compose-prd.yml, docker-compose-stg.yml"
  exit 1
fi

echo "Mode $MODE_LABEL is stopping stack '$STACK_NAME' (compose: $COMPOSE_FILE)"
docker stack rm ${STACK_NAME}
