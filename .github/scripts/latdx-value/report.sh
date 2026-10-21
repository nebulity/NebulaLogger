#!/usr/bin/env bash
# shellcheck disable=SC2016 # jq programs are single-quoted on purpose
# Renders measure.sh records (one JSON object per line on stdin) as either a
# markdown table for the job summary (`report.sh md`) or CSV (`report.sh csv`,
# header included), and replay-selection.sh rows as summary statistics
# (`replay-md`) or CSV (`replay-csv`). The CSV columns are the published
# dataset's schema.
set -euo pipefail

mode="${1:?usage: report.sh md|csv|replay-md|replay-csv < records.ndjson}"

case "$mode" in
  csv)
    jq -rs '
      def a($r; $n): $r.arms[$n] // {};
      ["id", "kind", "title", "base", "head", "cli_version", "measured_at", "run_url",
       "delta_files", "deleted_files_not_measured",
       "baseline_tests_wall_ms", "baseline_tests_ran", "baseline_failing", "baseline_sum_runtime_ms",
       "latdx_cold_wall_ms", "latdx_cold_rc", "latdx_cold_tests_ran", "latdx_cold_failing", "latdx_cold_hits", "latdx_cold_misses",
       "latdx_warm_wall_ms", "latdx_warm_rc", "latdx_warm_tests_ran", "latdx_warm_failing", "latdx_warm_hits", "latdx_warm_misses",
       "latdx_prior_wall_ms", "latdx_prior_rc",
       "impact_wall_ms", "selected_methods", "suite_methods", "share_count", "share_time", "risk_flags", "safe_share_time",
       "validate_local_wall_ms", "validate_local_server_ms", "validate_local_tests", "validate_local_gate",
       "validate_selected_wall_ms", "validate_selected_server_ms", "validate_selected_tests", "validate_selected_gate",
       "latdx_validate_wall_ms", "latdx_validate_rc", "latdx_validate_tests_ran", "latdx_validate_coverage_ok",
       "deploy_head_wall_ms"],
      (.[] | . as $r | [
        .id, .kind, .title, .base, .head, .cli_version, .measured_at, .run_url,
        .delta_files, .deleted_files_not_measured,
        a($r; "baseline_tests").wall_ms, a($r; "baseline_tests").tests_ran, a($r; "baseline_tests").failing, a($r; "baseline_tests").sum_runtime_ms,
        a($r; "latdx_cold").wall_ms, a($r; "latdx_cold").rc, a($r; "latdx_cold").tests_ran, a($r; "latdx_cold").failing, a($r; "latdx_cold").hits, a($r; "latdx_cold").misses,
        a($r; "latdx_warm").wall_ms, a($r; "latdx_warm").rc, a($r; "latdx_warm").tests_ran, a($r; "latdx_warm").failing, a($r; "latdx_warm").hits, a($r; "latdx_warm").misses,
        a($r; "latdx_prior").wall_ms, a($r; "latdx_prior").rc,
        a($r; "impact").wall_ms, .selection.selected_methods, .selection.suite_methods, .selection.share_count, .selection.share_time,
        (a($r; "impact").risk_flags // [] | join(" ")), .selection.safe_share_time,
        a($r; "validate_local").wall_ms, a($r; "validate_local").server_ms, a($r; "validate_local").tests_completed, (a($r; "validate_local").gate // a($r; "validate_local").skipped),
        a($r; "validate_selected").wall_ms, a($r; "validate_selected").server_ms, a($r; "validate_selected").tests_completed, (a($r; "validate_selected").gate // a($r; "validate_selected").skipped),
        a($r; "latdx_validate").wall_ms, a($r; "latdx_validate").rc, a($r; "latdx_validate").tests_ran, a($r; "latdx_validate").coverage_ok,
        a($r; "deploy_head").wall_ms
      ]) | @csv'
    ;;
  md)
    echo "| change | delta | stock tests: wall / summed RunTime | LATdx cold | LATdx warm: wall (executed) | LATdx selection: tests / time | deploy validate RunLocalTests | deploy validate selected | latdx validate |"
    echo "|---|--:|--:|--:|--:|--:|---|---|---|"
    jq -r '
      def s($ms): if $ms == null then "-" else "\(($ms / 100 | round) / 10)s" end;
      def pct($x): if $x == null then "-" else "\(($x * 1000 | round) / 10)%" end;
      def run($a): if $a == null then "-"
        elif $a.skipped then "skipped"
        elif ($a.rc // 0) != 0 then "\(s($a.wall_ms)) rc=\($a.rc)\(if $a.error then ": " + ($a.error | .[0:60]) else "" end)"
        else s($a.wall_ms) end;
      def executed($a): if ($a.tests_ran // null) == null or ($a.rc // 0) == 1 then "" else " (\(($a.tests_ran) - ($a.hits // 0)) of \($a.tests_ran))" end;
      def gate($a): if $a == null then "-" elif $a.skipped then "skipped: \($a.skipped)"
        else "\(s($a.wall_ms)), \($a.gate // "?")\(if $a.tests_completed then ", \($a.tests_completed) tests" else "" end)" end;
      .arms as $arms
      | "| [\(.id)](\(.run_url)) \(.title | .[0:50] | gsub("\\|"; "/")) | \(.delta_files // "-") files"
        + " | \(s($arms.baseline_tests.wall_ms)) / \(s($arms.baseline_tests.sum_runtime_ms))"
        + " | \(run($arms.latdx_cold))"
        + " | \(run($arms.latdx_warm))\(executed($arms.latdx_warm))"
        + " | \(pct(.selection.share_count)) / \(pct(.selection.share_time))\(if (($arms.impact.risk_flags // []) | length) > 0 then " (risk: " + ($arms.impact.risk_flags | join(", ")) + ")" else "" end)"
        + " | \(gate($arms.validate_local))"
        + " | \(gate($arms.validate_selected))"
        + " | \(run($arms.latdx_validate))\(if $arms.latdx_validate.coverage_ok == false then ", coverage gate failed" elif $arms.latdx_validate.coverage_ok == true then ", coverage ok" else "" end) |"'
    ;;
  replay-md)
    jq -rs '
      def pct($p): sort | .[((length - 1) * $p | floor)];
      def p($x): if $x == null then "-" else "\(($x * 1000 | round) / 10)%" end;
      map(select(.share_time != null)) as $ok
      | ($ok | map(.share_time)) as $t
      | ($ok | map(.safe_share_time)) as $safe
      | "Selection replay over \($ok | length) upstream commits touching nebula-logger/ (\(length - ($ok | length)) failed):\n",
        "| | by test count | by summed RunTime | safe (risk flags run everything) |",
        "|---|--:|--:|--:|",
        "| median | \(p($ok | map(.share_count) | pct(0.5))) | \(p($t | pct(0.5))) | \(p($safe | pct(0.5))) |",
        "| p25 / p75 | \(p($ok | map(.share_count) | pct(0.25))) / \(p($ok | map(.share_count) | pct(0.75))) | \(p($t | pct(0.25))) / \(p($t | pct(0.75))) | \(p($safe | pct(0.25))) / \(p($safe | pct(0.75))) |",
        "| mean | \(p($ok | map(.share_count) | add / length)) | \(p($t | add / length)) | \(p($safe | add / length)) |",
        "",
        "\($ok | map(select(.share_time > 0.5)) | length) commits select more than half of the suite time; \($ok | map(select(.selected_methods == 0)) | length) select nothing; \($ok | map(select((.risk_flags | length) > 0)) | length) carry metadata risk flags."'
    ;;
  replay-csv)
    jq -rs '
      ["commit", "subject", "cli_version", "run_url", "delta_files", "apex_files", "changed_classes",
       "selected_methods", "suite_methods", "share_count", "share_time", "risk_flags", "safe_share_time", "impact_ms", "impact_rc"],
      (.[] | [.commit, .subject, .cli_version, .run_url, .delta_files, .apex_files, .changed_classes,
              .selected_methods, .suite_methods, .share_count, .share_time, (.risk_flags // [] | join(" ")),
              .safe_share_time, .impact_ms, .impact_rc]) | @csv'
    ;;
  *)
    echo "usage: report.sh md|csv|replay-md|replay-csv < records.ndjson" >&2
    exit 64
    ;;
esac
