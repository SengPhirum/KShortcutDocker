#!/usr/bin/env bash
# Install command wrappers:
#   ksdc -> config.sh
#   ksdd -> deploy.sh
#   ksds -> stop.sh
#   ksdl -> log.sh
#   ksdn -> network.sh
#   ksdu -> upgrade.sh
#
# Wrappers are generated in ./.bin (current directory by default).

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

SCRIPT_PATH="${BASH_SOURCE[0]}"
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$SCRIPT_PATH")" && pwd)
SRC_DIR="$SCRIPT_DIR/src"
BIN_DIR="$(pwd)/.bin"
LEGACY_KBL_COMPLETION_PATH="$SCRIPT_DIR/.kbl-completion.bash"
LEGACY_KBD_COMPLETION_PATH="$SCRIPT_DIR/.kbd-completion.bash"
LEGACY_KBN_COMPLETION_PATH="$SCRIPT_DIR/.kbn-completion.bash"
KSDL_COMPLETION_PATH=""
KSDD_COMPLETION_PATH=""
KSDN_COMPLETION_PATH=""
BASHRC_PATH=""
USER_SET_BASHRC=0
IS_SOURCED=0
if [[ "${BASH_SOURCE[0]}" != "$0" ]]; then
  IS_SOURCED=1
fi

print_help() {
  cat <<EOF
Usage: ./install.sh [options]

Options:
  --bin-dir DIR   Wrapper output directory (default: \$(pwd)/.bin)
  --bashrc FILE   Bash profile file (default: ~/.bashrc)
  -h, --help      Show this help
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --bin-dir)
      BIN_DIR="$2"
      shift 2
      ;;
    --bashrc)
      BASHRC_PATH="$2"
      USER_SET_BASHRC=1
      shift 2
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

KSDL_COMPLETION_PATH="$BIN_DIR/.ksdl-completion.bash"
KSDD_COMPLETION_PATH="$BIN_DIR/.ksdd-completion.bash"
KSDN_COMPLETION_PATH="$BIN_DIR/.ksdn-completion.bash"
LEGACY_BIN_KBL_COMPLETION_PATH="$BIN_DIR/.kbl-completion.bash"
LEGACY_BIN_KBD_COMPLETION_PATH="$BIN_DIR/.kbd-completion.bash"
LEGACY_BIN_KBN_COMPLETION_PATH="$BIN_DIR/.kbn-completion.bash"

detect_default_bash_profile() {
  # Use ~/.bashrc so new interactive bash terminals pick up PATH without logout/login.
  echo "$HOME/.bashrc"
}

if [ "$USER_SET_BASHRC" -eq 0 ]; then
  BASHRC_PATH="$(detect_default_bash_profile)"
fi

require_script() {
  file="$1"
  if [ ! -f "$SRC_DIR/$file" ]; then
    echo "Missing required script: $SRC_DIR/$file" >&2
    exit 1
  fi
}

require_script "config.sh"
require_script "deploy.sh"
require_script "stop.sh"
require_script "log.sh"
require_script "network.sh"
require_script "upgrade.sh"

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

write_wrapper "ksdc" "config.sh"
write_wrapper "ksdd" "deploy.sh"
write_wrapper "ksds" "stop.sh"
write_wrapper "ksdl" "log.sh"
write_wrapper "ksdn" "network.sh"
write_wrapper "ksdu" "upgrade.sh"

remove_legacy_wrapper_if_generated() {
  cmd="$1"
  target="$2"
  wrapper_path="$BIN_DIR/$cmd"

  [ -f "$wrapper_path" ] || return 0
  grep -Fq "exec sh " "$wrapper_path" || return 0
  grep -Fq "$target" "$wrapper_path" || return 0

  rm -f "$wrapper_path"
  echo "Removed legacy wrapper: $wrapper_path"
}

remove_legacy_wrappers() {
  remove_legacy_wrapper_if_generated "kbc" "config.sh"
  remove_legacy_wrapper_if_generated "kbd" "deploy.sh"
  remove_legacy_wrapper_if_generated "kbs" "stop.sh"
  remove_legacy_wrapper_if_generated "kbl" "log.sh"
  remove_legacy_wrapper_if_generated "kbn" "network.sh"
  remove_legacy_wrapper_if_generated "kbu" "upgrade.sh"
}

remove_legacy_wrappers

write_ksdl_completion() {
  cat > "$KSDL_COMPLETION_PATH" <<'EOF'
#!/usr/bin/env bash

_ksdl_list_services() {
  local stack
  stack="$(basename "$PWD")"
  [ -n "$stack" ] || return 0
  command -v docker >/dev/null 2>&1 || return 0

  docker service ls --format '{{.Name}}' 2>/dev/null \
    | awk -v prefix="${stack}_" 'index($0, prefix) == 1 { sub("^" prefix, "", $0); print }'
}

_ksdl_completion() {
  local cur cword services
  COMPREPLY=()
  cur="${COMP_WORDS[COMP_CWORD]}"
  cword="$COMP_CWORD"

  case "$cword" in
    1)
      services="$(_ksdl_list_services)"
      COMPREPLY=( $(compgen -W "$services" -- "$cur") )
      ;;
    2)
      COMPREPLY=( $(compgen -W "50 100 200 500 1000" -- "$cur") )
      ;;
  esac
}

complete -F _ksdl_completion ksdl

# Loader: if users/source files only load ksdl completion,
# also load sibling ksdd/ksdn completions automatically.
_ksdl_completion_dir="$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
if [ -f "$_ksdl_completion_dir/.ksdd-completion.bash" ]; then
  # shellcheck disable=SC1090
  source "$_ksdl_completion_dir/.ksdd-completion.bash"
fi
if [ -f "$_ksdl_completion_dir/.ksdn-completion.bash" ]; then
  # shellcheck disable=SC1090
  source "$_ksdl_completion_dir/.ksdn-completion.bash"
fi
EOF
  chmod 644 "$KSDL_COMPLETION_PATH"
}

write_ksdl_completion

write_ksdd_completion() {
  cat > "$KSDD_COMPLETION_PATH" <<'EOF'
#!/usr/bin/env bash

_ksdd_match_words() {
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

_ksdd_complete_compose_file() {
  local cur="$1" file
  COMPREPLY=()
  while IFS= read -r file; do
    case "$file" in
      *.yml|*.yaml) COMPREPLY+=("$file") ;;
    esac
  done < <(compgen -f -- "$cur")
}

_ksdd_list_first_level_stacks() {
  local dir
  for dir in "$PWD"/*; do
    [ -d "$dir" ] || continue
    if [ -f "$dir/docker-compose.yml" ] || [ -f "$dir/docker-compose-prd.yml" ] || [ -f "$dir/docker-compose-stg.yml" ]; then
      basename "$dir"
    fi
  done
}

_ksdd_complete_stack_name() {
  local cur="$1" stack
  local -a stack_names
  COMPREPLY=()
  mapfile -t stack_names < <(_ksdd_list_first_level_stacks)
  for stack in "${stack_names[@]}"; do
    case "$stack" in
      "$cur"*) COMPREPLY+=("$stack") ;;
    esac
  done
}

_ksdd_completion() {
  local cur prev
  local -a option_words

  option_words=(-f --force -c --compose-file -s --stack -a --all -h --help)
  COMPREPLY=()
  cur="${COMP_WORDS[COMP_CWORD]}"
  prev="${COMP_WORDS[COMP_CWORD-1]}"

  # Prevent falling back to generic filesystem completion except where we
  # explicitly want compose-file suggestions.
  if type compopt >/dev/null 2>&1; then
    compopt +o default +o bashdefault 2>/dev/null || true
  fi

  case "$prev" in
    -c|--compose-file)
      _ksdd_complete_compose_file "$cur"
      return 0
      ;;
    -s|--stack)
      _ksdd_complete_stack_name "$cur"
      return 0
      ;;
  esac

  case "$cur" in
    --compose-file=*)
      _ksdd_complete_compose_file "${cur#*=}"
      COMPREPLY=( "${COMPREPLY[@]/#/--compose-file=}" )
      return 0
      ;;
    --stack=*)
      _ksdd_complete_stack_name "${cur#*=}"
      COMPREPLY=( "${COMPREPLY[@]/#/--stack=}" )
      return 0
      ;;
    --*)
      _ksdd_match_words "$cur" --force --compose-file --stack --all --help
      return 0
      ;;
    -*)
      _ksdd_match_words "$cur" "${option_words[@]}"
      return 0
      ;;
    "")
      COMPREPLY=("${option_words[@]}")
      return 0
      ;;
  esac
}

complete -F _ksdd_completion ksdd
EOF
  chmod 644 "$KSDD_COMPLETION_PATH"
}

write_ksdd_completion

write_ksdn_completion() {
  cat > "$KSDN_COMPLETION_PATH" <<'EOF'
#!/usr/bin/env bash

_ksdn_list_networks() {
  command -v docker >/dev/null 2>&1 || return 0
  docker network ls --format '{{.Name}}' 2>/dev/null
}

_ksdn_match_words() {
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

_ksdn_complete_compose_file() {
  local cur="$1" file
  COMPREPLY=()
  while IFS= read -r file; do
    case "$file" in
      *.yml|*.yaml) COMPREPLY+=("$file") ;;
    esac
  done < <(compgen -f -- "$cur")
}

_ksdn_complete_networks() {
  local cur="$1" item
  local -a network_list
  COMPREPLY=()
  mapfile -t network_list < <(_ksdn_list_networks)
  for item in "${network_list[@]}"; do
    case "$item" in
      "$cur"*) COMPREPLY+=("$item") ;;
    esac
  done
}

_ksdn_complete_networks_equals() {
  local cur="$1"
  local prefix value item
  local -a network_list
  COMPREPLY=()
  prefix="${cur%%=*}="
  value="${cur#*=}"
  mapfile -t network_list < <(_ksdn_list_networks)
  for item in "${network_list[@]}"; do
    case "$item" in
      "$value"*) COMPREPLY+=("${prefix}${item}") ;;
    esac
  done
}

_ksdn_completion() {
  local cur prev mode subcommand word
  local -a subcommand_words
  local -a ensure_short_words
  local -a ensure_long_words
  local -a ensure_all_words
  local -a update_short_words
  local -a update_long_words
  local -a update_all_words
  local -a check_short_words
  local -a check_long_words
  local -a check_all_words

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
  cur="${COMP_WORDS[COMP_CWORD]}"
  prev="${COMP_WORDS[COMP_CWORD-1]}"
  subcommand=""
  for word in "${COMP_WORDS[@]:1}"; do
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

  # Prevent falling back to filesystem completion for this command.
  if type compopt >/dev/null 2>&1; then
    compopt +o default +o bashdefault 2>/dev/null || true
  fi

  if [ "$COMP_CWORD" -eq 1 ]; then
    _ksdn_match_words "$cur" -v --verbose "${subcommand_words[@]}"
    return 0
  fi

  if [ "$COMP_CWORD" -eq 2 ] && [[ "${COMP_WORDS[1]:-}" =~ ^(-v|--verbose)$ ]]; then
    _ksdn_match_words "$cur" "${subcommand_words[@]}"
    return 0
  fi

  case "$cur" in
    --network=*|--temp-network=*)
      _ksdn_complete_networks_equals "$cur"
      return 0
      ;;
  esac

  case "$prev" in
    -f|--file|--compose-file)
      _ksdn_complete_compose_file "$cur"
      return 0
      ;;
    --network|--temp-network)
      _ksdn_complete_networks "$cur"
      return 0
      ;;
    -n|--network|--name-regex)
      _ksdn_complete_networks "$cur"
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
    if [ "$COMP_CWORD" -eq 2 ] && [[ "$cur" != -* ]]; then
      _ksdn_complete_networks "$cur"
      return 0
    fi

    case "$cur" in
      --*)
        _ksdn_match_words "$cur" "${update_long_words[@]}"
        ;;
      -*)
        _ksdn_match_words "$cur" "${update_long_words[@]}"
        ;;
      "")
        COMPREPLY=("${update_all_words[@]}")
        ;;
      *)
        COMPREPLY=()
        ;;
    esac
  elif [ "$mode" = "check" ]; then
    if [ "$COMP_CWORD" -eq 2 ] && [[ "$cur" != -* ]]; then
      _ksdn_complete_networks "$cur"
      return 0
    fi

    case "$cur" in
      --*)
        _ksdn_match_words "$cur" "${check_long_words[@]}"
        ;;
      -*)
        _ksdn_match_words "$cur" "${check_short_words[@]}"
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
        _ksdn_match_words "$cur" "${ensure_long_words[@]}"
        ;;
      -*)
        _ksdn_match_words "$cur" "${ensure_short_words[@]}"
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

complete -F _ksdn_completion ksdn
EOF
  chmod 644 "$KSDN_COMPLETION_PATH"
}

write_ksdn_completion

remove_legacy_completion_files() {
  if [ -f "$LEGACY_KBL_COMPLETION_PATH" ] && [ "$LEGACY_KBL_COMPLETION_PATH" != "$KSDL_COMPLETION_PATH" ]; then
    rm -f "$LEGACY_KBL_COMPLETION_PATH"
    echo "Removed legacy completion file: $LEGACY_KBL_COMPLETION_PATH"
  fi
  if [ -f "$LEGACY_KBD_COMPLETION_PATH" ] && [ "$LEGACY_KBD_COMPLETION_PATH" != "$KSDD_COMPLETION_PATH" ]; then
    rm -f "$LEGACY_KBD_COMPLETION_PATH"
    echo "Removed legacy completion file: $LEGACY_KBD_COMPLETION_PATH"
  fi
  if [ -f "$LEGACY_KBN_COMPLETION_PATH" ] && [ "$LEGACY_KBN_COMPLETION_PATH" != "$KSDN_COMPLETION_PATH" ]; then
    rm -f "$LEGACY_KBN_COMPLETION_PATH"
    echo "Removed legacy completion file: $LEGACY_KBN_COMPLETION_PATH"
  fi
  if [ -f "$LEGACY_BIN_KBL_COMPLETION_PATH" ] && [ "$LEGACY_BIN_KBL_COMPLETION_PATH" != "$KSDL_COMPLETION_PATH" ]; then
    rm -f "$LEGACY_BIN_KBL_COMPLETION_PATH"
    echo "Removed legacy completion file: $LEGACY_BIN_KBL_COMPLETION_PATH"
  fi
  if [ -f "$LEGACY_BIN_KBD_COMPLETION_PATH" ] && [ "$LEGACY_BIN_KBD_COMPLETION_PATH" != "$KSDD_COMPLETION_PATH" ]; then
    rm -f "$LEGACY_BIN_KBD_COMPLETION_PATH"
    echo "Removed legacy completion file: $LEGACY_BIN_KBD_COMPLETION_PATH"
  fi
  if [ -f "$LEGACY_BIN_KBN_COMPLETION_PATH" ] && [ "$LEGACY_BIN_KBN_COMPLETION_PATH" != "$KSDN_COMPLETION_PATH" ]; then
    rm -f "$LEGACY_BIN_KBN_COMPLETION_PATH"
    echo "Removed legacy completion file: $LEGACY_BIN_KBN_COMPLETION_PATH"
  fi
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
    echo "# Added by scripts install.sh"
    echo "$export_line"
  } >> "$BASHRC_PATH"
  echo "PATH export added to $BASHRC_PATH"
}

ensure_bashrc_path_export

ensure_bashrc_completion_source() {
  source_line_ksdl="[ -f \"$KSDL_COMPLETION_PATH\" ] && source \"$KSDL_COMPLETION_PATH\""
  source_line_ksdd="[ -f \"$KSDD_COMPLETION_PATH\" ] && source \"$KSDD_COMPLETION_PATH\""
  source_line_ksdn="[ -f \"$KSDN_COMPLETION_PATH\" ] && source \"$KSDN_COMPLETION_PATH\""
  have_ksdl=0
  have_ksdd=0
  have_ksdn=0

  if [ -f "$BASHRC_PATH" ] && grep -Fqx "$source_line_ksdl" "$BASHRC_PATH"; then
    have_ksdl=1
  fi
  if [ -f "$BASHRC_PATH" ] && grep -Fqx "$source_line_ksdd" "$BASHRC_PATH"; then
    have_ksdd=1
  fi
  if [ -f "$BASHRC_PATH" ] && grep -Fqx "$source_line_ksdn" "$BASHRC_PATH"; then
    have_ksdn=1
  fi

  if [ "$have_ksdl" -eq 1 ] && [ "$have_ksdd" -eq 1 ] && [ "$have_ksdn" -eq 1 ]; then
    echo "ksdl/ksdd/ksdn completion sources already exist in $BASHRC_PATH"
    return 0
  fi

  {
    echo ""
    echo "# Added by scripts install.sh (ksdl/ksdd/ksdn autocomplete)"
    if [ "$have_ksdl" -eq 0 ]; then
      echo "$source_line_ksdl"
    fi
    if [ "$have_ksdd" -eq 0 ]; then
      echo "$source_line_ksdd"
    fi
    if [ "$have_ksdn" -eq 0 ]; then
      echo "$source_line_ksdn"
    fi
  } >> "$BASHRC_PATH"
  echo "ksdl/ksdd/ksdn completion source(s) added to $BASHRC_PATH"
}

ensure_bashrc_completion_source

print_completion_now_hint() {
  echo "Enable ksdl/ksdd/ksdn autocomplete in current bash shell:"
  echo "  source \"$KSDL_COMPLETION_PATH\""
  echo "  source \"$KSDD_COMPLETION_PATH\""
  echo "  source \"$KSDN_COMPLETION_PATH\""
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

  for cmd in ksdc ksdd ksds ksdl ksdn ksdu; do
    existing_cmd="$(command -v "$cmd" 2>/dev/null || true)"
    if [ -n "$existing_cmd" ] && [ "$existing_cmd" != "$BIN_DIR/$cmd" ] && [ "$existing_cmd" != "$shim_dir/$cmd" ]; then
      echo "Skipped immediate shim for '$cmd' (already resolves to $existing_cmd)" >&2
      return 1
    fi

    if [ "$shim_dir/$cmd" != "$BIN_DIR/$cmd" ]; then
      ln -sf "$BIN_DIR/$cmd" "$shim_dir/$cmd" 2>/dev/null || {
        cp "$BIN_DIR/$cmd" "$shim_dir/$cmd"
        chmod 755 "$shim_dir/$cmd"
      }
    fi
  done

  echo "$shim_dir"
}

apply_path_now() {
  if [ "$IS_SOURCED" -eq 1 ]; then
    export PATH="$BIN_DIR:$PATH"
    # Running via "source ./install.sh": this updates the caller shell.
    if [ -f "$BASHRC_PATH" ]; then
      source "$BASHRC_PATH"
    fi
    if [ -f "$KSDL_COMPLETION_PATH" ]; then
      source "$KSDL_COMPLETION_PATH"
    fi
    if [ -f "$KSDD_COMPLETION_PATH" ]; then
      source "$KSDD_COMPLETION_PATH"
    fi
    if [ -f "$KSDN_COMPLETION_PATH" ]; then
      source "$KSDN_COMPLETION_PATH"
    fi
    hash -r 2>/dev/null || true
    echo "Applied PATH in current shell (source mode). Aliases are ready: ksdc, ksdd, ksds, ksdl, ksdn, ksdu"
    echo "ksdl/ksdd/ksdn autocomplete is active in this shell."
  else
    # Running via "./install.sh": child process cannot modify parent shell env.
    if path_contains_dir "$BIN_DIR"; then
      echo "Current shell PATH already includes $BIN_DIR"
      echo "If command lookup is stale, run: hash -r"
      print_completion_now_hint
      return 0
    fi

    shim_dir="$(install_immediate_shims || true)"
    if [ -n "$shim_dir" ]; then
      echo "Installed immediate shims in $shim_dir (already on PATH)."
      echo "You can run now: ksdc, ksdd, ksds, ksdl, ksdn, ksdu"
      print_completion_now_hint
      return 0
    fi

    hash -r 2>/dev/null || true
    echo "PATH was persisted to $BASHRC_PATH"
    echo "To use wrappers in this terminal immediately (no logout/restart), run:"
    echo "  export PATH=\"$BIN_DIR:\$PATH\""
    echo "Or reload your profile:"
    echo "  source \"$BASHRC_PATH\""
    print_completion_now_hint
  fi
}

apply_path_now

echo "Installed wrappers:"
echo "  $BIN_DIR/ksdc -> $SRC_DIR/config.sh"
echo "  $BIN_DIR/ksdd -> $SRC_DIR/deploy.sh"
echo "  $BIN_DIR/ksds -> $SRC_DIR/stop.sh"
echo "  $BIN_DIR/ksdl -> $SRC_DIR/log.sh"
echo "  $BIN_DIR/ksdn -> $SRC_DIR/network.sh"
echo "  $BIN_DIR/ksdu -> $SRC_DIR/upgrade.sh"
echo "ksdl completion file:"
echo "  $KSDL_COMPLETION_PATH"
echo "ksdd completion file:"
echo "  $KSDD_COMPLETION_PATH"
echo "ksdn completion file:"
echo "  $KSDN_COMPLETION_PATH"
