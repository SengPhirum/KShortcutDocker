#!/usr/bin/env sh
set -eu

TARGET_USER="deployer"

log() {
  printf '[upgrade] %s\n' "$*"
}

shell_quote() {
  printf "'%s'" "$(printf "%s" "$1" | sed "s/'/'\\\\''/g")"
}

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
PROJECT_DIR=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)
CURRENT_USER="$(id -un 2>/dev/null || whoami)"

if [ "$CURRENT_USER" = "$TARGET_USER" ]; then
  cd "$PROJECT_DIR"

  if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    log "Error: '$PROJECT_DIR' is not a git repository."
    exit 1
  fi

  log "Resetting tracked changes."
  git checkout -- .

  log "Pulling latest changes."
  git pull --ff-only

  log "Running install.sh."
  exec sh "$PROJECT_DIR/install.sh"
fi

if ! command -v su >/dev/null 2>&1; then
  log "Error: current user is '$CURRENT_USER' and 'su' is not available."
  exit 1
fi

project_dir_quoted="$(shell_quote "$PROJECT_DIR")"
log "Current user is '$CURRENT_USER'. Switching to '$TARGET_USER' (password required)."
exec su - "$TARGET_USER" -c "set -eu; cd $project_dir_quoted; git checkout -- .; git pull --ff-only; exec sh ./install.sh"
