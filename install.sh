#!/usr/bin/env bash
# Install the unified "ksd" command:
#   ksd config   -> config.sh
#   ksd deploy   -> deploy.sh
#   ksd stop     -> stop.sh
#   ksd log      -> log.sh
#   ksd network  -> network.sh
#   ksd update   -> update.sh
#
# Works two ways:
#   1) Local checkout: cd into this repo and run ./install.sh
#   2) One-line remote install (no clone needed):
#        curl -fsSL https://raw.githubusercontent.com/SengPhirum/KShortcutDocker/main/install.sh | bash
#      This fetches the source into $KSD_HOME (default: ~/.ksd) and installs from there.

# When invoked as "sh install.sh", /bin/sh ignores the shebang and runs this file.
# Re-exec with bash so bash-specific features work consistently.
if [ -z "${BASH_VERSION:-}" ]; then
  if command -v bash >/dev/null 2>&1; then
    exec bash "$0" "$@"
  fi
  echo "Error: bash is required to run install.sh" >&2
  exit 1
fi

set -euo pipefail

IS_SOURCED=0
if [[ "${BASH_SOURCE[0]:-}" != "${0:-}" ]]; then
  IS_SOURCED=1
fi

KSD_HOME="${KSD_HOME:-$HOME/.ksd}"
REPO_URL="${KSD_REPO_URL:-https://github.com/SengPhirum/KShortcutDocker.git}"
REPO_TARBALL_URL="${KSD_REPO_TARBALL_URL:-https://github.com/SengPhirum/KShortcutDocker/archive/refs/heads/main.tar.gz}"

BIN_DIR=""
USER_SET_BIN_DIR=0
BASHRC_PATH=""
USER_SET_BASHRC=0
FORCE_UPDATE=0

print_help() {
  cat <<EOF
Usage: ./install.sh [options]

Options:
  --bin-dir DIR   Wrapper output directory
                  (default: \$KSD_HOME/bin for remote installs, \$(pwd)/.bin for local checkouts)
  --bashrc FILE   Bash profile file (default: ~/.bashrc)
  --update        Force-refresh the source before installing (used by 'ksd update')
  -h, --help      Show this help
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --bin-dir)
      BIN_DIR="$2"
      USER_SET_BIN_DIR=1
      shift 2
      ;;
    --bashrc)
      BASHRC_PATH="$2"
      USER_SET_BASHRC=1
      shift 2
      ;;
    --update)
      FORCE_UPDATE=1
      shift
      ;;
    -h|--help)
      print_help
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      print_help
      exit 2
      ;;
  esac
done

detect_default_bash_profile() {
  # Use ~/.bashrc so new interactive bash terminals pick up PATH without logout/login.
  echo "$HOME/.bashrc"
}

if [ "$USER_SET_BASHRC" -eq 0 ]; then
  BASHRC_PATH="$(detect_default_bash_profile)"
fi

# ---------------------------------------------------------------------------
# Resolve PROJECT_DIR: use a local checkout if install.sh is running from one
# (e.g. "./install.sh" inside a git clone). Otherwise (e.g. a one-line
# "curl ... | bash" install, or running from inside the managed $KSD_HOME
# directory) fetch/refresh the source into $KSD_HOME.
# ---------------------------------------------------------------------------

SCRIPT_PATH="${BASH_SOURCE[0]:-$0}"
LOCAL_SCRIPT_DIR=""
if [ -f "$SCRIPT_PATH" ]; then
  LOCAL_SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$SCRIPT_PATH")" && pwd)
fi

fetch_latest_source() {
  dest="$1"
  if [ -d "$dest/.git" ]; then
    echo "Updating existing checkout in $dest"
    git -C "$dest" checkout -- . 2>/dev/null || true
    git -C "$dest" pull --ff-only
    return 0
  fi

  if command -v git >/dev/null 2>&1; then
    echo "Cloning $REPO_URL to $dest"
    rm -rf "$dest"
    git clone --depth 1 "$REPO_URL" "$dest"
    return 0
  fi

  echo "git not found; downloading source tarball instead"
  mkdir -p "$dest"
  tmp_tar="$(mktemp "${TMPDIR:-/tmp}/ksd-src.XXXXXX.tar.gz")"
  if command -v curl >/dev/null 2>&1; then
    curl -fsSL "$REPO_TARBALL_URL" -o "$tmp_tar"
  elif command -v wget >/dev/null 2>&1; then
    wget -qO "$tmp_tar" "$REPO_TARBALL_URL"
  else
    echo "Error: need git, curl, or wget to install ksd" >&2
    exit 1
  fi
  find "$dest" -mindepth 1 -maxdepth 1 -exec rm -rf {} +
  tar -xzf "$tmp_tar" -C "$dest" --strip-components=1
  rm -f "$tmp_tar"
}

if [ -n "$LOCAL_SCRIPT_DIR" ] && [ "$LOCAL_SCRIPT_DIR" != "$KSD_HOME" ] && [ -f "$LOCAL_SCRIPT_DIR/src/config.sh" ]; then
  PROJECT_DIR="$LOCAL_SCRIPT_DIR"
  if [ "$FORCE_UPDATE" -eq 1 ]; then
    if [ -d "$PROJECT_DIR/.git" ]; then
      echo "Resetting tracked changes."
      git -C "$PROJECT_DIR" checkout -- .
      echo "Pulling latest changes."
      git -C "$PROJECT_DIR" pull --ff-only
    else
      echo "Note: $PROJECT_DIR is not a git checkout; skipping source update."
    fi
  fi
else
  PROJECT_DIR="$KSD_HOME"
  fetch_latest_source "$PROJECT_DIR"
fi

SRC_DIR="$PROJECT_DIR/src"

if [ "$USER_SET_BIN_DIR" -eq 0 ]; then
  if [ "$PROJECT_DIR" = "$KSD_HOME" ]; then
    BIN_DIR="$KSD_HOME/bin"
  else
    BIN_DIR="$(pwd)/.bin"
  fi
fi

KSD_COMPLETION_PATH="$BIN_DIR/.ksd-completion.bash"
LEGACY_KBL_COMPLETION_PATH="$PROJECT_DIR/.kbl-completion.bash"
LEGACY_KBD_COMPLETION_PATH="$PROJECT_DIR/.kbd-completion.bash"
LEGACY_KBN_COMPLETION_PATH="$PROJECT_DIR/.kbn-completion.bash"
LEGACY_BIN_KBL_COMPLETION_PATH="$BIN_DIR/.kbl-completion.bash"
LEGACY_BIN_KBD_COMPLETION_PATH="$BIN_DIR/.kbd-completion.bash"
LEGACY_BIN_KBN_COMPLETION_PATH="$BIN_DIR/.kbn-completion.bash"
LEGACY_BIN_KSDL_COMPLETION_PATH="$BIN_DIR/.ksdl-completion.bash"
LEGACY_BIN_KSDD_COMPLETION_PATH="$BIN_DIR/.ksdd-completion.bash"
LEGACY_BIN_KSDN_COMPLETION_PATH="$BIN_DIR/.ksdn-completion.bash"

require_script() {
  file="$1"
  if [ ! -f "$SRC_DIR/$file" ]; then
    echo "Missing required script: $SRC_DIR/$file" >&2
    exit 1
  fi
}

require_script "ksd.sh"
require_script "config.sh"
require_script "deploy.sh"
require_script "stop.sh"
require_script "log.sh"
require_script "network.sh"
require_script "update.sh"
require_script "uninstall.sh"

mkdir -p "$BIN_DIR"

write_wrapper() {
  cmd="$1"
  target="$2"
  cat > "$BIN_DIR/$cmd" <<EOF
#!/bin/sh
set -eu
exec sh "$SRC_DIR/$target" "\$@"
EOF
  chmod 755 "$BIN_DIR/$cmd"
}

write_wrapper "ksd" "ksd.sh"

remove_legacy_wrapper_if_generated() {
  dir="$1"
  cmd="$2"
  target="$3"
  wrapper_path="$dir/$cmd"

  [ -f "$wrapper_path" ] || return 0
  grep -Fq "exec sh " "$wrapper_path" || return 0
  grep -Fq "$target" "$wrapper_path" || return 0

  rm -f "$wrapper_path"
  echo "Removed legacy wrapper: $wrapper_path"
}

remove_legacy_wrappers() {
  dir="$1"
  remove_legacy_wrapper_if_generated "$dir" "kbc" "config.sh"
  remove_legacy_wrapper_if_generated "$dir" "kbd" "deploy.sh"
  remove_legacy_wrapper_if_generated "$dir" "kbs" "stop.sh"
  remove_legacy_wrapper_if_generated "$dir" "kbl" "log.sh"
  remove_legacy_wrapper_if_generated "$dir" "kbn" "network.sh"
  remove_legacy_wrapper_if_generated "$dir" "kbu" "upgrade.sh"
  remove_legacy_wrapper_if_generated "$dir" "ksdc" "config.sh"
  remove_legacy_wrapper_if_generated "$dir" "ksdd" "deploy.sh"
  remove_legacy_wrapper_if_generated "$dir" "ksds" "stop.sh"
  remove_legacy_wrapper_if_generated "$dir" "ksdl" "log.sh"
  remove_legacy_wrapper_if_generated "$dir" "ksdn" "network.sh"
  remove_legacy_wrapper_if_generated "$dir" "ksdu" "upgrade.sh"
}

remove_legacy_wrappers "$BIN_DIR"

write_ksd_completion() {
  cat > "$KSD_COMPLETION_PATH" <<'EOF'
#!/usr/bin/env bash
# ksd completion: "ksd <TAB>" lists commands; "ksd <command> <TAB>" completes
# that command's options/arguments.

_ksd_list_services() {
  local stack
  stack="$(basename "$PWD")"
  [ -n "$stack" ] || return 0
  command -v docker >/dev/null 2>&1 || return 0

  docker service ls --format '{{.Name}}' 2>/dev/null \
    | awk -v prefix="${stack}_" 'index($0, prefix) == 1 { sub("^" prefix, "", $0); print }'
}

_ksd_list_networks() {
  command -v docker >/dev/null 2>&1 || return 0
  docker network ls --format '{{.Name}}' 2>/dev/null
}

_ksd_list_first_level_stacks() {
  local dir
  for dir in "$PWD"/*; do
    [ -d "$dir" ] || continue
    if [ -f "$dir/docker-compose.yml" ] || [ -f "$dir/docker-compose-prd.yml" ] || [ -f "$dir/docker-compose-stg.yml" ]; then
      basename "$dir"
    fi
  done
}

_ksd_match_words() {
  local cur="$1"
  shift
  COMPREPLY=()
  local word
  for word in "$@"; do
    case "$word" in
      "$cur"*) COMPREPLY+=("$word") ;;
    esac
  done
}

_ksd_complete_compose_file() {
  local cur="$1" file
  COMPREPLY=()
  while IFS= read -r file; do
    case "$file" in
      *.yml|*.yaml) COMPREPLY+=("$file") ;;
    esac
  done < <(compgen -f -- "$cur")
}

_ksd_complete_stack_name() {
  local cur="$1" stack
  local -a stack_names
  COMPREPLY=()
  mapfile -t stack_names < <(_ksd_list_first_level_stacks)
  for stack in "${stack_names[@]}"; do
    case "$stack" in
      "$cur"*) COMPREPLY+=("$stack") ;;
    esac
  done
}

_ksd_complete_networks() {
  local cur="$1" item
  local -a network_list
  COMPREPLY=()
  mapfile -t network_list < <(_ksd_list_networks)
  for item in "${network_list[@]}"; do
    case "$item" in
      "$cur"*) COMPREPLY+=("$item") ;;
    esac
  done
}

_ksd_complete_networks_equals() {
  local cur="$1"
  local prefix value item
  local -a network_list
  COMPREPLY=()
  prefix="${cur%%=*}="
  value="${cur#*=}"
  mapfile -t network_list < <(_ksd_list_networks)
  for item in "${network_list[@]}"; do
    case "$item" in
      "$value"*) COMPREPLY+=("${prefix}${item}") ;;
    esac
  done
}

_ksd_deploy_completion() {
  local cur prev
  local -a option_words
  option_words=(-f --force -c --compose-file -s --stack -a --all -h --help)
  cur="${COMP_WORDS[COMP_CWORD]}"
  prev="${COMP_WORDS[COMP_CWORD-1]}"

  case "$prev" in
    -c|--compose-file)
      _ksd_complete_compose_file "$cur"
      return 0
      ;;
    -s|--stack)
      _ksd_complete_stack_name "$cur"
      return 0
      ;;
  esac

  case "$cur" in
    --compose-file=*)
      _ksd_complete_compose_file "${cur#*=}"
      COMPREPLY=( "${COMPREPLY[@]/#/--compose-file=}" )
      return 0
      ;;
    --stack=*)
      _ksd_complete_stack_name "${cur#*=}"
      COMPREPLY=( "${COMPREPLY[@]/#/--stack=}" )
      return 0
      ;;
    --*)
      _ksd_match_words "$cur" --force --compose-file --stack --all --help
      return 0
      ;;
    -*)
      _ksd_match_words "$cur" "${option_words[@]}"
      return 0
      ;;
    "")
      COMPREPLY=("${option_words[@]}")
      return 0
      ;;
  esac
}

_ksd_config_completion() {
  local cur prev
  cur="${COMP_WORDS[COMP_CWORD]}"
  prev="${COMP_WORDS[COMP_CWORD-1]}"

  case "$prev" in
    -f|--compose)
      _ksd_complete_compose_file "$cur"
      return 0
      ;;
  esac

  case "$cur" in
    --*)
      _ksd_match_words "$cur" --compose --non-interactive --help
      return 0
      ;;
    -*)
      _ksd_match_words "$cur" -f -h --compose --non-interactive --help
      return 0
      ;;
    "")
      COMPREPLY=(-f --compose --non-interactive -h --help)
      return 0
      ;;
  esac
}

_ksd_uninstall_completion() {
  local cur prev
  cur="${COMP_WORDS[COMP_CWORD]}"
  prev="${COMP_WORDS[COMP_CWORD-1]}"

  case "$prev" in
    --bashrc)
      COMPREPLY=( $(compgen -f -- "$cur") )
      return 0
      ;;
  esac

  case "$cur" in
    --*)
      _ksd_match_words "$cur" --bashrc --keep-source --yes --help
      return 0
      ;;
    -*)
      _ksd_match_words "$cur" -y -h --bashrc --keep-source --yes --help
      return 0
      ;;
    "")
      COMPREPLY=(-y --yes --bashrc --keep-source -h --help)
      return 0
      ;;
  esac
}

_ksd_log_completion() {
  local cur services
  cur="${COMP_WORDS[COMP_CWORD]}"

  case "$COMP_CWORD" in
    2)
      services="$(_ksd_list_services)"
      COMPREPLY=( $(compgen -W "$services" -- "$cur") )
      ;;
    3)
      COMPREPLY=( $(compgen -W "50 100 200 500 1000" -- "$cur") )
      ;;
  esac
}

_ksd_network_completion() {
  # Reindex so this behaves like completion for "network <args...>",
  # i.e. shift past "ksd" and treat "network" as word 0.
  local -a words=("network" "${COMP_WORDS[@]:2}")
  local cword=$(( COMP_CWORD - 1 ))
  local cur prev mode subcommand word
  local -a subcommand_words ensure_short_words ensure_long_words ensure_all_words
  local -a update_short_words update_long_words update_all_words
  local -a check_short_words check_long_words check_all_words

  subcommand_words=(ensure update check)
  ensure_short_words=(-f -v -h)
  ensure_long_words=(--file --stack-name --verbose --help)
  ensure_all_words=(-f --file --stack-name -v --verbose -h --help)
  update_short_words=(-v -h --yes)
  update_long_words=(--subnet --gateway --temp-network --network --yes --verbose --help)
  update_all_words=(--subnet --gateway --temp-network --network --yes -v --verbose -h --help)
  check_short_words=(-n -v -h)
  check_long_words=(--network --name-regex --verbose --help)
  check_all_words=(-n --network --name-regex -v --verbose -h --help)

  COMPREPLY=()
  cur="${words[$cword]:-}"
  prev="${words[$((cword-1))]:-}"
  subcommand=""
  for word in "${words[@]:1}"; do
    case "$word" in
      -v|--verbose)
        ;;
      *)
        subcommand="$word"
        break
        ;;
    esac
  done
  mode="$subcommand"

  case "$mode" in
    ensure|update|check|check-subnet|migrate-subnet)
      ;;
    *)
      mode="ensure"
      ;;
  esac

  if [ "$cword" -eq 1 ]; then
    _ksd_match_words "$cur" -v --verbose "${subcommand_words[@]}"
    return 0
  fi

  if [ "$cword" -eq 2 ] && [[ "${words[1]:-}" =~ ^(-v|--verbose)$ ]]; then
    _ksd_match_words "$cur" "${subcommand_words[@]}"
    return 0
  fi

  case "$cur" in
    --network=*|--temp-network=*)
      _ksd_complete_networks_equals "$cur"
      return 0
      ;;
  esac

  case "$prev" in
    -f|--file|--compose-file)
      _ksd_complete_compose_file "$cur"
      return 0
      ;;
    --network|--temp-network)
      _ksd_complete_networks "$cur"
      return 0
      ;;
    -n|--network|--name-regex)
      _ksd_complete_networks "$cur"
      return 0
      ;;
    --stack-name|--subnet|--gateway)
      return 0
      ;;
  esac

  if [ "$mode" = "migrate-subnet" ]; then
    mode="update"
  fi

  if [ "$mode" = "check-subnet" ]; then
    mode="check"
  fi

  if [ "$mode" = "update" ]; then
    if [ "$cword" -eq 2 ] && [[ "$cur" != -* ]]; then
      _ksd_complete_networks "$cur"
      return 0
    fi

    case "$cur" in
      --*)
        _ksd_match_words "$cur" "${update_long_words[@]}"
        ;;
      -*)
        _ksd_match_words "$cur" "${update_long_words[@]}"
        ;;
      "")
        COMPREPLY=("${update_all_words[@]}")
        ;;
      *)
        COMPREPLY=()
        ;;
    esac
  elif [ "$mode" = "check" ]; then
    if [ "$cword" -eq 2 ] && [[ "$cur" != -* ]]; then
      _ksd_complete_networks "$cur"
      return 0
    fi

    case "$cur" in
      --*)
        _ksd_match_words "$cur" "${check_long_words[@]}"
        ;;
      -*)
        _ksd_match_words "$cur" "${check_short_words[@]}"
        ;;
      "")
        COMPREPLY=("${check_all_words[@]}")
        ;;
      *)
        COMPREPLY=()
        ;;
    esac
  else
    case "$cur" in
      --*)
        _ksd_match_words "$cur" "${ensure_long_words[@]}"
        ;;
      -*)
        _ksd_match_words "$cur" "${ensure_short_words[@]}"
        ;;
      "")
        COMPREPLY=("${ensure_all_words[@]}")
        ;;
      *)
        COMPREPLY=()
        ;;
    esac
  fi
}

_ksd_completion() {
  local cur subcmd
  COMPREPLY=()
  cur="${COMP_WORDS[COMP_CWORD]}"

  # Prevent falling back to generic filesystem completion except where we
  # explicitly want file suggestions.
  if type compopt >/dev/null 2>&1; then
    compopt +o default +o bashdefault 2>/dev/null || true
  fi

  if [ "$COMP_CWORD" -eq 1 ]; then
    _ksd_match_words "$cur" config deploy stop log network update uninstall -h --help
    return 0
  fi

  subcmd="${COMP_WORDS[1]}"
  case "$subcmd" in
    deploy)
      _ksd_deploy_completion
      ;;
    config)
      _ksd_config_completion
      ;;
    log)
      _ksd_log_completion
      ;;
    network)
      _ksd_network_completion
      ;;
    uninstall)
      _ksd_uninstall_completion
      ;;
    *)
      COMPREPLY=()
      ;;
  esac
}

complete -F _ksd_completion ksd
EOF
  chmod 644 "$KSD_COMPLETION_PATH"
}

write_ksd_completion

remove_legacy_completion_files() {
  for legacy_path in \
    "$LEGACY_KBL_COMPLETION_PATH" \
    "$LEGACY_KBD_COMPLETION_PATH" \
    "$LEGACY_KBN_COMPLETION_PATH" \
    "$LEGACY_BIN_KBL_COMPLETION_PATH" \
    "$LEGACY_BIN_KBD_COMPLETION_PATH" \
    "$LEGACY_BIN_KBN_COMPLETION_PATH" \
    "$LEGACY_BIN_KSDL_COMPLETION_PATH" \
    "$LEGACY_BIN_KSDD_COMPLETION_PATH" \
    "$LEGACY_BIN_KSDN_COMPLETION_PATH"
  do
    if [ -f "$legacy_path" ] && [ "$legacy_path" != "$KSD_COMPLETION_PATH" ]; then
      rm -f "$legacy_path"
      echo "Removed legacy completion file: $legacy_path"
    fi
  done
}

remove_legacy_completion_files

ensure_bashrc_path_export() {
  export_line="export PATH=\"$BIN_DIR:\$PATH\""

  if [ -f "$BASHRC_PATH" ] && grep -Fqx "$export_line" "$BASHRC_PATH"; then
    echo "PATH export already exists in $BASHRC_PATH"
    return 0
  fi

  {
    echo ""
    echo "# Added by ksd install.sh"
    echo "$export_line"
  } >> "$BASHRC_PATH"
  echo "PATH export added to $BASHRC_PATH"
}

ensure_bashrc_path_export

ensure_bashrc_completion_source() {
  source_line_ksd="[ -f \"$KSD_COMPLETION_PATH\" ] && source \"$KSD_COMPLETION_PATH\""

  if [ -f "$BASHRC_PATH" ] && grep -Fqx "$source_line_ksd" "$BASHRC_PATH"; then
    echo "ksd completion source already exists in $BASHRC_PATH"
    return 0
  fi

  {
    echo ""
    echo "# Added by ksd install.sh (ksd autocomplete)"
    echo "$source_line_ksd"
  } >> "$BASHRC_PATH"
  echo "ksd completion source added to $BASHRC_PATH"
}

ensure_bashrc_completion_source

print_completion_now_hint() {
  echo "Enable ksd autocomplete in current bash shell:"
  echo "  source \"$KSD_COMPLETION_PATH\""
}

path_contains_dir() {
  dir="$1"
  case ":$PATH:" in
    *":$dir:"*) return 0 ;;
    *) return 1 ;;
  esac
}

find_writable_path_dir() {
  for preferred in "$HOME/.local/bin" "$HOME/bin"; do
    if path_contains_dir "$preferred"; then
      mkdir -p "$preferred" 2>/dev/null || true
      if [ -d "$preferred" ] && [ -w "$preferred" ]; then
        echo "$preferred"
        return 0
      fi
    fi
  done

  IFS=':' read -r -a path_parts <<< "$PATH"
  for dir in "${path_parts[@]}"; do
    [ -n "$dir" ] || continue
    [ -d "$dir" ] || continue
    [ -w "$dir" ] || continue
    echo "$dir"
    return 0
  done

  return 1
}

install_immediate_shims() {
  shim_dir="$(find_writable_path_dir || true)"
  if [ -z "$shim_dir" ]; then
    return 1
  fi

  existing_cmd="$(command -v ksd 2>/dev/null || true)"
  if [ -n "$existing_cmd" ] && [ "$existing_cmd" != "$BIN_DIR/ksd" ] && [ "$existing_cmd" != "$shim_dir/ksd" ]; then
    echo "Skipped immediate shim for 'ksd' (already resolves to $existing_cmd)" >&2
    return 1
  fi

  if [ "$shim_dir/ksd" != "$BIN_DIR/ksd" ]; then
    ln -sf "$BIN_DIR/ksd" "$shim_dir/ksd" 2>/dev/null || {
      cp "$BIN_DIR/ksd" "$shim_dir/ksd"
      chmod 755 "$shim_dir/ksd"
    }
  fi

  if [ "$shim_dir" != "$BIN_DIR" ]; then
    remove_legacy_wrappers "$shim_dir"
  fi

  echo "$shim_dir"
}

apply_path_now() {
  if [ "$IS_SOURCED" -eq 1 ]; then
    export PATH="$BIN_DIR:$PATH"
    # Running via "source ./install.sh": this updates the caller shell.
    if [ -f "$BASHRC_PATH" ]; then
      source "$BASHRC_PATH"
    fi
    if [ -f "$KSD_COMPLETION_PATH" ]; then
      source "$KSD_COMPLETION_PATH"
    fi
    hash -r 2>/dev/null || true
    echo "Applied PATH in current shell (source mode). Command is ready: ksd"
    echo "ksd autocomplete is active in this shell."
  else
    # Running via "./install.sh" or "curl ... | bash": child process cannot
    # modify the parent shell's environment.
    if path_contains_dir "$BIN_DIR"; then
      echo "Current shell PATH already includes $BIN_DIR"
      echo "If command lookup is stale, run: hash -r"
      print_completion_now_hint
      return 0
    fi

    shim_dir="$(install_immediate_shims || true)"
    if [ -n "$shim_dir" ]; then
      echo "Installed immediate shim in $shim_dir (already on PATH)."
      echo "You can run now: ksd"
      print_completion_now_hint
      return 0
    fi

    hash -r 2>/dev/null || true
    echo "PATH was persisted to $BASHRC_PATH"
    echo "To use ksd in this terminal immediately (no logout/restart), run:"
    echo "  export PATH=\"$BIN_DIR:\$PATH\""
    echo "Or reload your profile:"
    echo "  source \"$BASHRC_PATH\""
    print_completion_now_hint
  fi
}

apply_path_now

echo "Installed command:"
echo "  $BIN_DIR/ksd -> $SRC_DIR/ksd.sh"
echo "ksd completion file:"
echo "  $KSD_COMPLETION_PATH"
echo ""
echo "Try: ksd --help"
