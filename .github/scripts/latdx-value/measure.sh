#!/usr/bin/env bash
# Measures one change (BASE_SHA -> HEAD_SHA) on the reserved org, comparing
# what upstream CI pays today with each LATdx arm. Writes one JSON record to
# "$OUT_DIR/record.json" plus every arm's raw output next to it.
#
# Arms, in the order they run (the order matters, see below):
#   1. deploy base       full source at BASE, the "production" state (org
#                        Apex the checkout lacks is pruned after each deploy)
#   2. latdx prior       latdx test run at BASE: the previous build, which
#                        leaves a warm cache for arm 8
#   3. validate local    sf project deploy validate <delta> RunLocalTests:
#                        upstream's deploy-time cost
#   4. impact            latdx test impact --base BASE --head HEAD (no org)
#   5. validate selected sf project deploy validate <delta> RunSpecifiedTests
#                        with the classes from arm 4, incl. its coverage gate
#   6. latdx validate    latdx validate --base BASE --head HEAD: deploys the
#                        delta (not check-only) and runs the affected tests
#   7. deploy head       full source at HEAD, so arms 8-10 test the same code
#   8. latdx warm        latdx test run at HEAD with the cache from arm 2
#   9. baseline tests    sf apex run test RunLocalTests at HEAD
#  10. latdx cold        latdx test run at HEAD with an empty cache
#
# The cache from arm 2 is snapshotted before arm 6 and restored before arm 8,
# so arm 6's own writes cannot pre-warm arm 8. The daemon is stopped before
# every checkout: its file watcher drops cached results on any .cls write,
# and a fresh CI runner has no daemon running when it checks out the head.
#
# LATdx state lives under ~/.latdx/workspaces/$LATDX_WORKSPACE_ID; the script
# pins that id so it snapshots and clears only its own workspace.
#
# Env: WS (git workspace with BASE_SHA and HEAD_SHA reachable), BASE_SHA,
# HEAD_SHA, TARGET_ID, TARGET_KIND, TARGET_TITLE, OUT_DIR, ORG_ALIAS, and
# optionally LATDX_WORKSPACE_ID.
set -uo pipefail

: "${WS:?}" "${BASE_SHA:?}" "${HEAD_SHA:?}" "${TARGET_ID:?}" "${OUT_DIR:?}" "${ORG_ALIAS:?}"
TARGET_KIND="${TARGET_KIND:-commit}"
TARGET_TITLE="${TARGET_TITLE:-}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SOURCE_DIR="nebula-logger"
mkdir -p "$OUT_DIR"
ARMS="$OUT_DIR/arms.ndjson"
: > "$ARMS"
export LATDX_WORKSPACE_ID="${LATDX_WORKSPACE_ID:-latdx-value}"
# Upstream's sfdx-project.json substitutes this into an email service's run-as
# user at deploy time and fails the conversion when it is unset.
EMAIL_SERVICE_RUN_AS_USER="$(sf org display --target-org "$ORG_ALIAS" --json 2> /dev/null | jq -r '.result.username // empty')"
export EMAIL_SERVICE_RUN_AS_USER
STATE_DIR="$HOME/.latdx/workspaces/$LATDX_WORKSPACE_ID"

now_ms() { perl -MTime::HiRes=time -e 'printf("%d\n", time() * 1000)'; }

# run_arm <name> <command...>: stdout -> <name>.json, stderr -> <name>.err,
# appends {arm, wall_ms, rc} to arms.ndjson. Never fails the script.
run_arm() {
  local name="$1"
  shift
  local start end rc
  echo "::group::${TARGET_ID} - ${name}"
  start=$(now_ms)
  (cd "$WS" && "$@") > "$OUT_DIR/${name}.json" 2> "$OUT_DIR/${name}.err"
  rc=$?
  end=$(now_ms)
  tail -n 20 "$OUT_DIR/${name}.err" || true
  echo "${name}: rc=${rc} wall=$((end - start))ms"
  echo "::endgroup::"
  jq -cn --arg arm "$name" --argjson wall "$((end - start))" --argjson rc "$rc" \
    '{arm: $arm, wall_ms: $wall, rc: $rc}' >> "$ARMS"
}

latdx_ws() { (cd "$WS" && latdx "$@"); }

stop_daemon() { latdx_ws daemon stop > /dev/null 2>&1 || true; }

clear_latdx_cache() {
  stop_daemon
  latdx_ws cache clear --quiet > /dev/null 2>&1 || true
  rm -rf "$STATE_DIR/cache"
}

skip_arm() {
  jq -cn --arg arm "$1" --arg reason "$2" '{arm: $arm, skipped: $reason}' >> "$ARMS"
  echo "${1}: skipped (${2})"
}

checkout() {
  stop_daemon
  git -C "$WS" checkout -q --force "$1"
  git -C "$WS" clean -qfd -- "$SOURCE_DIR"
}

# The reused org carries the recipes' example trigger, which no test covers;
# upstream validates on a clean org that never has it. Remove it for the
# validate arms and put it back at the end so Build sees its usual org.
remove_example_trigger() {
  sf project deploy start --metadata-dir "$SCRIPT_DIR/destructive-example-trigger" \
    --target-org "$ORG_ALIAS" --wait 10 --json > "$OUT_DIR/remove-example-trigger.json" 2>&1 || true
}

restore_example_trigger() {
  (cd "$WS" && sf project deploy start --source-dir "$SOURCE_DIR/recipes/triggers" \
    --target-org "$ORG_ALIAS" --ignore-conflicts --wait 10 --json) > "$OUT_DIR/restore-example-trigger.json" 2>&1 || true
}

# --- Delta between BASE and HEAD ------------------------------------------
git -C "$WS" diff --name-only --diff-filter=ACMRT "$BASE_SHA" "$HEAD_SHA" -- "$SOURCE_DIR" > "$OUT_DIR/delta-all.txt"
grep -v -E '(/__tests__/|/jest-mocks/|\.md$|/images/|\.ts$|/jsconfig\.json$|/\.eslintrc\.json$)' "$OUT_DIR/delta-all.txt" > "$OUT_DIR/delta.txt" || true
deleted_count=$(git -C "$WS" diff --name-only --diff-filter=D "$BASE_SHA" "$HEAD_SHA" -- "$SOURCE_DIR" | wc -l | tr -d ' ')
mapfile -t DELTA < "$OUT_DIR/delta.txt"
DELTA_ARGS=()
for f in "${DELTA[@]}"; do DELTA_ARGS+=(--source-dir "$f"); done
# Apex classes and triggers in the delta: the subjects of the per-component
# coverage gate. Test classes are exempt from that gate.
apex_subjects=()
for f in "${DELTA[@]}"; do
  case "$f" in
    *.cls | *.trigger)
      if ! grep -qi '@istest' "$WS/$f" 2> /dev/null; then
        apex_subjects+=("$(basename "${f%.*}")")
      fi
      ;;
  esac
done
echo "Delta: ${#DELTA[@]} deployable file(s), ${deleted_count} deletion(s) not measured, Apex gate subjects: ${apex_subjects[*]:-none}"

# --- 1-2: base state and the previous build's cache ------------------------
checkout "$BASE_SHA"
run_arm deploy_base sf project deploy start --source-dir "$SOURCE_DIR" --target-org "$ORG_ALIAS" --ignore-conflicts --wait 30 --json
"$SCRIPT_DIR/prune-org-apex.sh" "$WS" "$ORG_ALIAS"
clear_latdx_cache
run_arm latdx_prior latdx test run --target-org "$ORG_ALIAS" --json

# --- 3: upstream's deploy-time cost -----------------------------------------
remove_example_trigger
if [ "${#DELTA[@]}" -gt 0 ]; then
  checkout "$HEAD_SHA"
  run_arm validate_local sf project deploy validate "${DELTA_ARGS[@]}" --test-level RunLocalTests --target-org "$ORG_ALIAS" --wait 60 --json
else
  skip_arm validate_local "no deployable delta"
fi

# --- 4: selection -----------------------------------------------------------
checkout "$HEAD_SHA"
run_arm impact latdx test impact --base "$BASE_SHA" --head "$HEAD_SHA" --json
mapfile -t SELECTED < <(jq -r '[.affected[]? | split(".")[0]] | unique | .[]' "$OUT_DIR/impact.json" 2> /dev/null || true)
TEST_ARGS=()
for c in "${SELECTED[@]}"; do TEST_ARGS+=(--tests "$c"); done

# --- 5: deploy validate with the LATdx selection ----------------------------
if [ "${#DELTA[@]}" -eq 0 ]; then
  skip_arm validate_selected "no deployable delta"
elif [ "${#SELECTED[@]}" -eq 0 ]; then
  if [ "${#apex_subjects[@]}" -gt 0 ]; then
    skip_arm validate_selected "LATdx selected no tests but the delta changes Apex"
  else
    run_arm validate_selected sf project deploy validate "${DELTA_ARGS[@]}" --test-level NoTestRun --target-org "$ORG_ALIAS" --wait 60 --json
  fi
else
  run_arm validate_selected sf project deploy validate "${DELTA_ARGS[@]}" --test-level RunSpecifiedTests "${TEST_ARGS[@]}" --target-org "$ORG_ALIAS" --wait 60 --json
fi
restore_example_trigger

# --- 6: latdx validate, with the previous build's cache ---------------------
snapshot="$(mktemp -d)"
stop_daemon
if [ -d "$STATE_DIR" ]; then cp -a "$STATE_DIR" "$snapshot/state"; fi
run_arm latdx_validate latdx validate --target-org "$ORG_ALIAS" --base "$BASE_SHA" --head "$HEAD_SHA" --coverage-threshold 75 --json
stop_daemon
rm -rf "$STATE_DIR"
if [ -d "$snapshot/state" ]; then cp -a "$snapshot/state" "$STATE_DIR"; fi
rm -f "$STATE_DIR/daemon.pid" "$STATE_DIR/daemon.sock"
rm -rf "$snapshot"

# --- 7-10: same code, three ways of running its tests -----------------------
run_arm deploy_head sf project deploy start --source-dir "$SOURCE_DIR" --target-org "$ORG_ALIAS" --ignore-conflicts --wait 30 --json
"$SCRIPT_DIR/prune-org-apex.sh" "$WS" "$ORG_ALIAS"
run_arm latdx_warm latdx test run --target-org "$ORG_ALIAS" --json
run_arm baseline_tests sf apex run test --test-level RunLocalTests --target-org "$ORG_ALIAS" --wait 60 --json
clear_latdx_cache
run_arm latdx_cold latdx test run --target-org "$ORG_ALIAS" --json

# The daemon's own logs explain where a slow or failed LATdx arm spent time.
stop_daemon
if [ -d "$STATE_DIR/logs" ]; then cp -a "$STATE_DIR/logs" "$OUT_DIR/latdx-logs"; fi

# Per-test RunTime of the stock run, the weights replay-selection.sh uses.
jq -c '[.result.tests[]? | {key: ((.ApexClass.Name + "." + .MethodName) | ascii_downcase), value: (.RunTime // 0)}] | from_entries' \
  "$OUT_DIR/baseline_tests.json" > "$OUT_DIR/runtimes.json" 2> /dev/null || rm -f "$OUT_DIR/runtimes.json"

# --- Record -----------------------------------------------------------------
APEX_SUBJECTS="$(printf '%s\n' "${apex_subjects[@]}" | jq -R . | jq -sc 'map(select(length > 0))')" \
  DELTA_FILES="${#DELTA[@]}" DELETED_FILES="$deleted_count" \
  CLI_VERSION="$(latdx --version 2> /dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)" \
  RUN_URL="${GITHUB_SERVER_URL:-}/${GITHUB_REPOSITORY:-}/actions/runs/${GITHUB_RUN_ID:-}" \
  TARGET_KIND="$TARGET_KIND" TARGET_TITLE="$TARGET_TITLE" \
  "$SCRIPT_DIR/record.sh" > "$OUT_DIR/record.json"
jq . "$OUT_DIR/record.json"
