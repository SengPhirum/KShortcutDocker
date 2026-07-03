#!/usr/bin/env sh
set -eu

TARGET_USER="deployer"

log() {
  printf '[ksd update] %s\n' "$*"
}

shell_quote() {
  printf "'%s'" "$(printf "%s" "$1" | sed "s/'/'\\\\''/g")"
}

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
PROJECT_DIR=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)
CURRENT_USER="$(id -un 2>/dev/null || whoami)"

if [ "$CURRENT_USER" = "$TARGET_USER" ]; then
  log "Updating ksd in '$PROJECT_DIR'."
  exec sh "$PROJECT_DIR/install.sh" --update
fi

if ! command -v su >/dev/null 2>&1; then
  log "Error: current user is '$CURRENT_USER' and 'su' is not available."
  exit 1
fi

project_dir_quoted="$(shell_quote "$PROJECT_DIR")"
log "Current user is '$CURRENT_USER'. Switching to '$TARGET_USER' (password required)."
exec su - "$TARGET_USER" -c "set -eu; cd $project_dir_quoted; exec sh ./install.sh --update"
