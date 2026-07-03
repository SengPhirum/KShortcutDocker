#!/bin/sh
# config.sh (POSIX compatible)
# Collect Docker Compose secrets (by file path), prompt once per unique basename,
# and write values to ./secrets/<BASENAME>.
# Does NOT modify docker-compose.yml.

set -eu

COMPOSE_FILE="docker-compose.yml"
NON_INTERACTIVE=0
SECRETS_DIR="secrets"

print_help() {
  cat <<EOF
Usage: ./config.sh [options]

Options:
  -f, --compose FILE      Path to docker-compose YAML (default: docker-compose.yml)
      --non-interactive   Read values from env vars SECRETFILE_<BASENAME>
  -h, --help              Show this help

Interactive input:
  Single-line secrets work as before.
  Armored key blocks such as .asc/.pem can be pasted directly at the prompt.
EOF
}

# Parse args
while [ $# -gt 0 ]; do
  case "$1" in
    -f|--compose) COMPOSE_FILE="$2"; shift 2;;
    --non-interactive) NON_INTERACTIVE=1; shift;;
    -h|--help) print_help; exit 0;;
    *) echo "Unknown option: $1" >&2; print_help; exit 2;;
  esac
done

[ -f "$COMPOSE_FILE" ] || { echo "Error: $COMPOSE_FILE not found" >&2; exit 2; }

# Extract unique secret files from compose (only ./secrets/* allowed, normalize)
SECRET_FILES=$(awk '
  BEGIN{ in_sects=0; in_secret=0 }
  /^secrets:[[:space:]]*$/ { in_sects=1; next }
  in_sects==1 && /^[^ ][^:]*:/ { in_sects=0; in_secret=0 }
  in_sects==1 && /^  [A-Za-z0-9_.-]+:/ { in_secret=1; next }
  in_sects==1 && in_secret==1 {
    if ($1=="file:") {
      gsub(/["'\'']/, "", $2)   # remove quotes
      if ($2 ~ /^\.\/secrets\//) {
        sub(/^\.\//, "", $2)    # strip leading ./ 
        print $2
      }
    }
  }
' "$COMPOSE_FILE" | sort -u)

[ -n "$SECRET_FILES" ] || { echo "No valid secrets found in $COMPOSE_FILE"; exit 0; }

# Deduplicate basenames
BASENAMES=$(echo "$SECRET_FILES" | xargs -n1 basename | sort -u)

mkdir -p "$SECRETS_DIR"

sanitize_to_env() {
  echo "SECRETFILE_$(echo "$1" | tr '[:lower:]' '[:upper:]' | sed 's/[^A-Z0-9]/_/g')"
}

write_secret_file() {
  dest="$1"
  value="$2"
  printf '%s\n' "$value" > "$dest"
  chmod 600 "$dest" 2>/dev/null || true
}

is_armored_block_start() {
  printf '%s\n' "$1" | grep '^-----BEGIN .\+-----$' >/dev/null 2>&1
}

armored_block_end_line() {
  printf '%s\n' "$1" | sed 's/^-----BEGIN \(.*\)-----$/-----END \1-----/'
}

read_hidden_secret_value() {
  value=""

  stty -echo
  IFS= read -r value || true

  if [ -n "$value" ] && is_armored_block_start "$value"; then
    end_line="$(armored_block_end_line "$value")"
    while IFS= read -r line; do
      value="$value
$line"
      [ "$line" = "$end_line" ] && break
    done
  fi

  stty echo
  echo >&2
  printf '%s' "$value"
}

echo "Enter secrets (hidden). Press Enter to keep existing. Paste .asc/.pem blocks directly." >&2

for base in $BASENAMES; do
  dest="$SECRETS_DIR/$base"
  if [ "$NON_INTERACTIVE" -eq 1 ]; then
    envkey=$(sanitize_to_env "$base")
    # lookup value from env
    eval val=\${$envkey:-}
    if [ -n "$val" ]; then
      write_secret_file "$dest" "$val"
    else
      [ -f "$dest" ] || { echo "Missing $envkey and no file $dest" >&2; exit 3; }
    fi
  else
    while true; do
      prompt="  $dest"
      [ -f "$dest" ] && prompt="$prompt (blank keeps existing)"
      printf "%s: " "$prompt" >&2
      val="$(read_hidden_secret_value)"
      if [ -n "$val" ]; then
        write_secret_file "$dest" "$val"
        break
      else
        [ -f "$dest" ] && break || echo "    Required (no existing file)" >&2
      fi
    done
  fi
done

echo "Done. Secrets stored in $SECRETS_DIR/"
