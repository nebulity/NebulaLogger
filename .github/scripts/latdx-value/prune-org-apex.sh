#!/usr/bin/env bash
# Deletes Apex classes and triggers (no namespace) from the reserved org that
# the given checkout's nebula-logger/ does not contain, so the org's Apex
# matches the code under test. Deploys only add and update, so a class or
# trigger from a newer upstream commit would otherwise stay in the shared org
# and run, or fire, in every later build of older code.
#
# Every custom Apex component in the reserved org comes from Nebula Logger
# deploys. As a guard against pointing this at the wrong org, it refuses to
# delete more than MAX_PRUNE components.
#
# Usage: prune-org-apex.sh <checkout> <org-alias>
set -uo pipefail

ws="${1:?checkout}"
org="${2:?org alias}"
max="${MAX_PRUNE:-25}"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

extras_for() {
  local type="$1" ext="$2"
  sf data query --target-org "$org" --json \
    --query "SELECT Name FROM ${type} WHERE NamespacePrefix = null" 2> /dev/null \
    | jq -r '.result.records[]?.Name' | sort -u > "$work/org.txt"
  find "$ws/nebula-logger" -name "*.${ext}" -exec basename {} ".${ext}" \; | sort -u > "$work/src.txt"
  comm -23 "$work/org.txt" "$work/src.txt"
}

mapfile -t classes < <(extras_for ApexClass cls)
mapfile -t triggers < <(extras_for ApexTrigger trigger)
total=$((${#classes[@]} + ${#triggers[@]}))
if [ "$total" -eq 0 ]; then
  echo "Org Apex matches the checkout; nothing to prune."
  exit 0
fi
echo "Org-only Apex: classes ${classes[*]:-none}; triggers ${triggers[*]:-none}."
if [ "$total" -gt "$max" ]; then
  echo "::warning title=Org prune skipped::${total} org-only Apex components exceed MAX_PRUNE=${max}; is this the reserved org?"
  exit 0
fi

members() {
  local name
  for name in "$@"; do printf '        <members>%s</members>\n' "$name"; done
}
api="$(jq -r '.sourceApiVersion // "62.0"' "$ws/sfdx-project.json" 2> /dev/null)"
mkdir -p "$work/pkg"
printf '<?xml version="1.0" encoding="UTF-8"?>\n<Package xmlns="http://soap.sforce.com/2006/04/metadata">\n    <version>%s</version>\n</Package>\n' "$api" > "$work/pkg/package.xml"
{
  printf '<?xml version="1.0" encoding="UTF-8"?>\n<Package xmlns="http://soap.sforce.com/2006/04/metadata">\n'
  if [ "${#classes[@]}" -gt 0 ]; then
    printf '    <types>\n'
    members "${classes[@]}"
    printf '        <name>ApexClass</name>\n    </types>\n'
  fi
  if [ "${#triggers[@]}" -gt 0 ]; then
    printf '    <types>\n'
    members "${triggers[@]}"
    printf '        <name>ApexTrigger</name>\n    </types>\n'
  fi
  printf '    <version>%s</version>\n</Package>\n' "$api"
} > "$work/pkg/destructiveChanges.xml"

if sf project deploy start --metadata-dir "$work/pkg" --target-org "$org" --wait 10 --json > "$work/result.json" 2>&1; then
  echo "Pruned ${total} org-only Apex component(s)."
else
  echo "::warning title=Org prune failed::$(jq -r '.message // "see log"' "$work/result.json" 2> /dev/null | head -c 300)"
fi
exit 0
