#!/usr/bin/env bash
# Prints the path of the runtimes.json measure.sh wrote for the most recently
# measured upstream commit under <outputs-dir> (one sub-directory per
# downloaded latdx-value-commit-* artifact), or nothing if there is none.
set -uo pipefail

outputs="${1:?outputs dir}"
best_at=""
best=""
for dir in "$outputs"/latdx-value-commit-*/; do
  [ -f "${dir}runtimes.json" ] && [ -f "${dir}record.json" ] || continue
  at="$(jq -r '.measured_at // empty' "${dir}record.json" 2> /dev/null)"
  if [ -n "$at" ] && [[ "$at" > "$best_at" ]]; then
    best_at="$at"
    best="${dir}runtimes.json"
  fi
done
[ -n "$best" ] && echo "$best"
exit 0
