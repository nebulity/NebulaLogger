#!/usr/bin/env bash
# shellcheck disable=SC2016 # jq programs are single-quoted on purpose
# Replays `latdx test impact` over the latest upstream main commits that touch
# nebula-logger/, each checked out at the commit and compared with its first
# parent, and prints one JSON line per commit: the share of the suite LATdx
# selects by count and weighted by RunTime. No org is needed.
#
# Usage: replay-selection.sh <workspace> <count> <runtimes.json>
#   runtimes.json maps lower-cased "Class.method" to RunTime in ms, from a
#   stock RunLocalTests run (see measure.sh's baseline_tests arm).
set -uo pipefail

ws="${1:?workspace}"
count="${2:?count}"
runtimes="${3:?runtimes.json}"
source_dir="nebula-logger"

now_ms() { perl -MTime::HiRes=time -e 'printf("%d\n", time() * 1000)'; }

mapfile -t commits < <(git -C "$ws" log --format=%H -n "$count" HEAD -- "$source_dir")
for c in "${commits[@]}"; do
  git -C "$ws" checkout -q --force "$c"
  start=$(now_ms)
  impact="$(cd "$ws" && latdx test impact --base "${c}^" --head "$c" --json 2> /dev/null)"
  rc=$?
  end=$(now_ms)
  files=$(git -C "$ws" diff --name-only "${c}^" "$c" -- "$source_dir" | wc -l | tr -d ' ')
  apex=$(git -C "$ws" diff --name-only "${c}^" "$c" -- "$source_dir" | grep -cE '\.(cls|trigger)$')
  jq -cn --arg c "$c" --arg subject "$(git -C "$ws" log -1 --format=%s "$c")" \
    --argjson rc "$rc" --argjson ms "$((end - start))" --argjson files "$files" --argjson apex "$apex" \
    --slurpfile rt "$runtimes" --argjson impact "${impact:-null}" '
      $rt[0] as $m | ([$m[]] | add) as $total
      | (($impact.affected // []) | map(ascii_downcase)) as $sel
      | [$sel[] | $m[.] // empty] as $hit
      | {commit: $c, subject: $subject, impact_rc: $rc, impact_ms: $ms,
         delta_files: $files, apex_files: $apex,
         changed_classes: ($impact.changed // [] | length),
         selected_methods: ($sel | length), matched_methods: ($hit | length),
         suite_methods: ($m | length),
         share_count: (if $impact == null then null else ($hit | length) / ($m | length) end),
         share_time: (if $impact == null then null else ($hit | add // 0) / $total end),
         risk_flags: [($impact // {}) | to_entries[] | select((.key | endswith("Change")) and .value == true) | .key]}
      | . + {safe_share_time: (if (.risk_flags | length) > 0 then 1 else .share_time end)}' \
    2> /dev/null || jq -cn --arg c "$c" --argjson rc "$rc" '{commit: $c, impact_rc: $rc, error: "unparseable impact output"}'
done
