#!/usr/bin/env bash
# shellcheck disable=SC2016 # jq programs are single-quoted on purpose
# Turns the raw arm outputs measure.sh left in OUT_DIR into one JSON record
# (stdout). Every extractor tolerates a missing or malformed file and yields
# nulls, so one broken arm never loses the others' numbers.
#
# Env: OUT_DIR, ORG_ALIAS (for the DeployRequest lookups), and the target
# fields TARGET_ID, TARGET_KIND, TARGET_TITLE, BASE_SHA, HEAD_SHA,
# DELTA_FILES, DELETED_FILES, APEX_SUBJECTS (JSON array), CLI_VERSION, RUN_URL.
set -uo pipefail

: "${OUT_DIR:?}"

# json_or_null <file> <jq filter>: the filter's result, or null.
json_or_null() {
  local out
  out="$(jq -c "$2" "$1" 2> /dev/null)" && [ -n "$out" ] && echo "$out" || echo null
}

deploy_metrics() {
  json_or_null "$OUT_DIR/$1.json" '{success: .result.success, components: .result.numberComponentsTotal, message: (if .status == 0 then null else (.message // "" | .[0:300]) end)}'
}

latdx_run_metrics() {
  local f="$OUT_DIR/$1.json" err out
  # stderr mixes plain lines with the daemon's NDJSON log records.
  err="$(sed 's/\x1b\[[0-9;]*m//g' "$OUT_DIR/$1.err" 2> /dev/null \
    | jq -Rr '(fromjson? | select(type == "object" and .lvl == "ERROR") | .msg) // (select(test("error|halt|license"; "i")))' 2> /dev/null \
    | head -n 1 | cut -c1-300)"
  out="$(jq -c --arg err "$err" '{
      tests_ran: .result.summary.testsRan, passing: .result.summary.passing,
      failing: .result.summary.failing, outcome: .result.summary.outcome,
      hits: .result.cacheReport.hits, misses: .result.cacheReport.misses,
      stale: .result.cacheReport.stale,
      error: (if (.result.summary.failing // 0) > 0 or .result == null then $err else null end)}' "$f" 2> /dev/null)"
  if [ -n "$out" ]; then echo "$out"; else jq -cn --arg err "$err" '{error: $err}'; fi
}

sf_tests_metrics() {
  json_or_null "$OUT_DIR/$1.json" '{
      tests_ran: .result.summary.testsRan, passing: .result.summary.passing,
      failing: .result.summary.failing, outcome: .result.summary.outcome,
      sum_runtime_ms: ([.result.tests[]?.RunTime] | add)}'
}

# Deploy validate: the CLI's JSON carries test counts only on success, so the
# DeployRequest record is the source for timing and counts either way.
validate_metrics() {
  local f="$OUT_DIR/$1.json" id req
  id="$(jq -r '.result.id // .data.deployId // empty' "$f" 2> /dev/null)"
  if [ -z "$id" ]; then
    json_or_null "$f" '{gate: "error", message: (.message // "" | .[0:300])}'
    return
  fi
  req="$(sf data query --use-tooling-api --target-org "$ORG_ALIAS" --json \
    --query "SELECT Status, StartDate, CompletedDate, NumberTestsCompleted, NumberTestErrors, NumberComponentErrors FROM DeployRequest WHERE Id = '$id'" 2> /dev/null \
    | jq -c '.result.records[0] // {}')"
  [ -n "$req" ] || req='{}'
  jq -c --arg id "$id" --argjson req "$req" '
      def ms(d): if d then (d | sub("\\.[0-9]+\\+0000$"; "Z") | fromdateiso8601) * 1000 else null end;
      (.message // "") as $msg
      | {deploy_id: $id, status: $req.Status,
         server_ms: (if $req.StartDate and $req.CompletedDate then ms($req.CompletedDate) - ms($req.StartDate) else null end),
         tests_completed: $req.NumberTestsCompleted, test_errors: $req.NumberTestErrors,
         component_errors: $req.NumberComponentErrors,
         gate: (if .status == 0 then "pass"
                elif ($msg | test("coverage"; "i")) then "coverage_fail"
                elif ($req.NumberTestErrors // 0) > 0 then "test_fail"
                elif ($req.NumberComponentErrors // 0) > 0 then "component_fail"
                else "error" end),
         message: (if .status == 0 then null else ($msg | .[0:500]) end)}' "$f" 2> /dev/null \
    || jq -cn --arg id "$id" '{deploy_id: $id, gate: "error"}'
}

impact_metrics() {
  json_or_null "$OUT_DIR/impact.json" '{
      changed: (.changed // []), affected_methods: (.affected // [] | length),
      affected_classes: ([.affected[]? | split(".")[0]] | unique | length),
      risk_flags: [to_entries[] | select((.key | endswith("Change")) and .value == true) | .key]}'
}

# latdx validate prints a deploy line, the test-run envelope and a coverage
# line as separate JSON documents.
latdx_validate_metrics() {
  json_or_null "$OUT_DIR/latdx_validate.json" '[inputs] as $docs | . as $first | ([$first] + $docs) as $all | {
      deployed: ([$all[] | select(.phase? == "deploy")][0].deployed),
      tests_ran: ([$all[] | select(.result?.summary?)][0].result.summary.testsRan),
      failing: ([$all[] | select(.result?.summary?)][0].result.summary.failing),
      hits: ([$all[] | select(.result?.cacheReport?)][0].result.cacheReport.hits),
      coverage_ok: ([$all[] | select(.phase? == "coverage")][0].ok),
      coverage_under: ([$all[] | select(.phase? == "coverage")][0].under),
      coverage_missing: ([$all[] | select(.phase? == "coverage")][0].missing)}'
}

# Share of the suite LATdx selects, by count and weighted by each test's
# RunTime in the baseline run (the tests LATdx keeps tend to be the slow ones).
selection_share() {
  local impact="$OUT_DIR/impact.json" base="$OUT_DIR/baseline_tests.json"
  if ! jq -e '.affected' "$impact" > /dev/null 2>&1 || ! jq -e '.result.tests' "$base" > /dev/null 2>&1; then
    echo null
    return
  fi
  jq -c -n --slurpfile i "$impact" --slurpfile b "$base" '
      ($i[0].affected | map(ascii_downcase) | map({key: ., value: true}) | from_entries) as $sel
      | [$b[0].result.tests[] | {k: ((.ApexClass.Name + "." + .MethodName) | ascii_downcase), t: (.RunTime // 0)}] as $all
      | ($all | map(.t) | add) as $total
      | ([$all[] | select($sel[.k])] ) as $hit
      | {suite_methods: ($all | length), selected_methods: ($hit | length),
         share_count: (if ($all | length) > 0 then (($hit | length) / ($all | length)) else null end),
         share_time: (if $total > 0 then (($hit | map(.t) | add // 0) / $total) else null end),
         selected_runtime_ms: ($hit | map(.t) | add // 0), suite_runtime_ms: $total,
         risk_flagged: (($i[0] | to_entries | map(select((.key | endswith("Change")) and .value == true)) | length) > 0)}
      | . + {safe_share_time: (if .risk_flagged then 1 else .share_time end)}'
}

arm_metrics() {
  case "$1" in
    deploy_base | deploy_head) deploy_metrics "$1" ;;
    latdx_prior | latdx_warm | latdx_cold) latdx_run_metrics "$1" ;;
    baseline_tests) sf_tests_metrics "$1" ;;
    validate_local | validate_selected) validate_metrics "$1" ;;
    impact) impact_metrics ;;
    latdx_validate) latdx_validate_metrics ;;
    *) echo null ;;
  esac
}

arms='{}'
while IFS= read -r line; do
  [ -z "$line" ] && continue
  name="$(jq -r '.arm' <<< "$line")"
  if jq -e '.skipped' <<< "$line" > /dev/null; then
    metrics=null
  else
    metrics="$(arm_metrics "$name")"
  fi
  arms="$(jq -c --arg n "$name" --argjson base "$line" --argjson m "${metrics:-null}" \
    '. + {($n): ($base + ($m // {}) | del(.arm))}' <<< "$arms")"
done < "$OUT_DIR/arms.ndjson"

jq -n \
  --arg id "${TARGET_ID:-}" --arg kind "${TARGET_KIND:-}" --arg title "${TARGET_TITLE:-}" \
  --arg base "${BASE_SHA:-}" --arg head "${HEAD_SHA:-}" --arg cli "${CLI_VERSION:-}" \
  --arg run_url "${RUN_URL:-}" --arg measured_at "$(date -u +%FT%TZ)" \
  --argjson delta_files "${DELTA_FILES:-null}" --argjson deleted "${DELETED_FILES:-null}" \
  --argjson apex "${APEX_SUBJECTS:-[]}" \
  --argjson arms "$arms" --argjson selection "$(selection_share)" \
  '{id: $id, kind: $kind, title: $title, base: $base, head: $head, cli_version: $cli,
    run_url: $run_url, measured_at: $measured_at, delta_files: $delta_files,
    deleted_files_not_measured: $deleted, apex_gate_subjects: $apex,
    selection: $selection, arms: $arms}'
