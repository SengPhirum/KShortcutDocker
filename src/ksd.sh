#!/bin/sh
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)

print_help() {
  cat <<EOF
Usage: ksd <command> [options]

Commands:
  config    Collect Docker Compose secrets and write them to ./secrets
  deploy    Deploy a Docker Swarm stack from a compose file
  stop      Stop the Docker Swarm stack in the current directory
  log       Tail logs for a service in the current stack
  network   Ensure, update, or check Docker networks
  update    Update ksd to the latest version

Run 'ksd <command> --help' for command-specific options.
Run 'ksd <TAB>' for command completion (after enabling ksd completion).
EOF
}

[ $# -gt 0 ] || { print_help; exit 1; }

cmd="$1"
shift

case "$cmd" in
  config)
    exec sh "$SCRIPT_DIR/config.sh" "$@"
    ;;
  deploy)
    exec sh "$SCRIPT_DIR/deploy.sh" "$@"
    ;;
  stop)
    exec sh "$SCRIPT_DIR/stop.sh" "$@"
    ;;
  log)
    exec sh "$SCRIPT_DIR/log.sh" "$@"
    ;;
  network)
    exec sh "$SCRIPT_DIR/network.sh" "$@"
    ;;
  update)
    exec sh "$SCRIPT_DIR/update.sh" "$@"
    ;;
  -h|--help)
    print_help
    exit 0
    ;;
  *)
    echo "Unknown command: $cmd" >&2
    print_help
    exit 2
    ;;
esac
