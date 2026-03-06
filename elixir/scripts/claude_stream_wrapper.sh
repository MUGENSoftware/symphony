#!/usr/bin/env bash
set -euo pipefail

log_file="$1"
shift

mkdir -p "$(dirname "$log_file")"
: >> "$log_file"

if command -v /usr/bin/script >/dev/null 2>&1; then
  /usr/bin/script -q "$log_file" "$@"
  exit $?
fi

"$@" >>"$log_file" 2>&1
exit $?
