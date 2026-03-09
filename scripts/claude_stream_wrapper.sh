#!/usr/bin/env bash
set -euo pipefail

log_file="$1"
shift

mkdir -p "$(dirname "$log_file")"
: >> "$log_file"

script_bin=""

if [ -x /usr/bin/script ]; then
  script_bin="/usr/bin/script"
elif command -v script >/dev/null 2>&1; then
  script_bin="$(command -v script)"
fi

if [ -n "$script_bin" ]; then
  if "$script_bin" --version 2>/dev/null | grep -qi "util-linux"; then
    quoted_command="$(printf '%q ' "$@")"
    quoted_command="${quoted_command% }"
    "$script_bin" -q -e -c "$quoted_command" "$log_file"
    exit $?
  fi

  "$script_bin" -q "$log_file" "$@"
  exit $?
fi

"$@" >>"$log_file" 2>&1
exit $?
