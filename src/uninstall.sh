#!/usr/bin/env bash
# Remove everything install.sh creates:
#   - the "ksd" wrapper (and leftover wrappers from earlier versions of this
#     tool: kbc/kbd/..., ksdc/ksdd/...) from every writable PATH directory
#   - ksd's tab-completion file(s), current and legacy
#   - the PATH export / completion source lines added to your bash profile
#   - (managed installs only) the cloned source under $KSD_HOME

# Re-exec with bash if invoked via /bin/sh, same as install.sh.
if [ -z "${BASH_VERSION:-}" ]; then
  if command -v bash >/dev/null 2>&1; then
    exec bash "$0" "$@"
  fi
  echo "Error: bash is required to run uninstall" >&2
  exit 1
fi

set -euo pipefail

KSD_HOME="${KSD_HOME:-$HOME/.ksd}"
BASHRC_PATH="$HOME/.bashrc"
ASSUME_YES=0
KEEP_SOURCE=0

print_help() {
  cat <<EOF
Usage: ksd uninstall [options]

Removes the ksd command, its tab-completion, the PATH/completion lines it
added to your bash profile, and any leftover wrappers from earlier versions
of this tool (kbc/kbd/..., ksdc/ksdd/...).

Options:
  --bashrc FILE   Bash profile file to clean (default: ~/.bashrc)
  --keep-source   Keep the cloned source in \$KSD_HOME (default: ~/.ksd);
                  only remove wrappers/completion/bashrc lines
  -y, --yes       Do not prompt for confirmation
  -h, --help      Show this help
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --bashrc)
      BASHRC_PATH="$2"
      shift 2
      ;;
    --keep-source)
      KEEP_SOURCE=1
      shift
      ;;
    -y|--yes)
      ASSUME_YES=1
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

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]:-$0}")" && pwd)
PROJECT_DIR=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)

if [ "$PROJECT_DIR" = "$KSD_HOME" ]; then
  BIN_DIR="$KSD_HOME/bin"
else
  BIN_DIR="$(pwd)/.bin"
fi

REMOVE_SOURCE=0
if [ "$KEEP_SOURCE" -eq 0 ] && [ "$PROJECT_DIR" = "$KSD_HOME" ]; then
  REMOVE_SOURCE=1
fi

echo "This will remove:"
echo "  - the 'ksd' command from every PATH directory it's installed in"
echo "  - leftover wrappers from earlier versions (kbc/kbd/..., ksdc/ksdd/...)"
echo "  - ksd's tab-completion file(s)"
echo "  - PATH/completion lines ksd added to $BASHRC_PATH"
if [ "$REMOVE_SOURCE" -eq 1 ]; then
  echo "  - the cloned source in $KSD_HOME"
fi
echo ""

if [ "$ASSUME_YES" -eq 0 ]; then
  printf "Continue? [y/N] "
  read -r reply || reply=""
  case "$reply" in
    y|Y|yes|YES) ;;
    *)
      echo "Aborted."
      exit 0
      ;;
  esac
fi

WRAPPER_NAMES="ksd kbc kbd kbs kbl kbn kbu ksdc ksdd ksds ksdl ksdn ksdu"
COMPLETION_NAMES=".ksd-completion.bash .kbl-completion.bash .kbd-completion.bash .kbn-completion.bash .ksdl-completion.bash .ksdd-completion.bash .ksdn-completion.bash"

is_generated_wrapper() {
  file="$1"
  [ -f "$file" ] || return 1
  grep -Fq "exec sh " "$file" 2>/dev/null || return 1
  grep -Eq "(ksd|config|deploy|stop|log|network|update|upgrade)\.sh" "$file" 2>/dev/null || return 1
  return 0
}

collect_candidate_dirs() {
  local dir
  IFS=':' read -r -a path_parts <<< "$PATH"
  for dir in "${path_parts[@]}"; do
    [ -n "$dir" ] && echo "$dir"
  done
  echo "$HOME/.local/bin"
  echo "$HOME/bin"
  echo "$BIN_DIR"
  echo "$KSD_HOME/bin"
}

sweep_dirs() {
  local dir name target seen=""
  while IFS= read -r dir; do
    [ -n "$dir" ] || continue
    case " $seen " in
      *" $dir "*) continue ;;
    esac
    seen="$seen $dir"

    [ -d "$dir" ] || continue
    [ -w "$dir" ] || continue

    for name in $WRAPPER_NAMES; do
      target="$dir/$name"
      if is_generated_wrapper "$target"; then
        rm -f "$target"
        echo "Removed: $target"
      fi
    done
    for name in $COMPLETION_NAMES; do
      target="$dir/$name"
      if [ -f "$target" ]; then
        rm -f "$target"
        echo "Removed: $target"
      fi
    done
  done < <(collect_candidate_dirs)
}

sweep_dirs

# Legacy completion files that used to live next to the scripts themselves
# (oldest layout, before completion files moved into the bin directory).
for legacy in "$PROJECT_DIR/.kbl-completion.bash" "$PROJECT_DIR/.kbd-completion.bash" "$PROJECT_DIR/.kbn-completion.bash"; do
  if [ -f "$legacy" ]; then
    rm -f "$legacy"
    echo "Removed: $legacy"
  fi
done

clean_bashrc() {
  if [ ! -f "$BASHRC_PATH" ]; then
    echo "No bash profile found at $BASHRC_PATH (nothing to clean)"
    return 0
  fi

  local tmp_file bin_dirs dir export_line
  tmp_file="$(mktemp "${TMPDIR:-/tmp}/ksd-bashrc.XXXXXX")"

  # Directories referenced by any known ksd completion line; their PATH
  # export lines get removed too, even if they came from a past --bin-dir.
  bin_dirs="$(grep -oE '"[^"]*/\.(ksd|ksdl|ksdd|ksdn|kbl|kbd|kbn)-completion\.bash"' "$BASHRC_PATH" 2>/dev/null \
    | sed -E 's#^"(.*)/[^/]+"$#\1#' | sort -u || true)"
  bin_dirs="$(printf '%s\n%s\n' "$bin_dirs" "$BIN_DIR" | sort -u)"

  grep -vE '^# Added by (scripts|ksd) install\.sh' "$BASHRC_PATH" \
    | grep -vE '\.(ksd|ksdl|ksdd|ksdn|kbl|kbd|kbn)-completion\.bash' \
    > "$tmp_file"

  while IFS= read -r dir; do
    [ -n "$dir" ] || continue
    export_line="export PATH=\"$dir:\$PATH\""
    if grep -Fqx "$export_line" "$tmp_file"; then
      grep -Fvx "$export_line" "$tmp_file" > "${tmp_file}.next"
      mv "${tmp_file}.next" "$tmp_file"
    fi
  done <<< "$bin_dirs"

  # Collapse runs of blank lines left behind by the removals above.
  awk 'BEGIN{blank=0} /^$/{blank++; if (blank<=1) print; next} {blank=0; print}' "$tmp_file" > "${tmp_file}.collapsed"

  if ! diff -q "$BASHRC_PATH" "${tmp_file}.collapsed" >/dev/null 2>&1; then
    cp "$BASHRC_PATH" "${BASHRC_PATH}.ksd-uninstall.bak"
    mv "${tmp_file}.collapsed" "$BASHRC_PATH"
    rm -f "$tmp_file"
    echo "Cleaned ksd PATH/completion lines from $BASHRC_PATH (backup: ${BASHRC_PATH}.ksd-uninstall.bak)"
  else
    rm -f "$tmp_file" "${tmp_file}.collapsed"
    echo "No ksd lines found in $BASHRC_PATH"
  fi
}

clean_bashrc

if [ "$REMOVE_SOURCE" -eq 1 ]; then
  echo "Removing $KSD_HOME"
  ( sleep 1; rm -rf "$KSD_HOME" ) </dev/null >/dev/null 2>&1 &
  disown 2>/dev/null || true
elif [ "$KEEP_SOURCE" -eq 1 ] && [ "$PROJECT_DIR" = "$KSD_HOME" ]; then
  echo "Kept source in $KSD_HOME (--keep-source)"
fi

echo ""
echo "ksd has been uninstalled. Open a new terminal (or run 'hash -r') to clear any cached command lookup."
