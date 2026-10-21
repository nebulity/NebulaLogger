# LATdx value dataset: Nebula Logger

Written by the `LATdx Value` workflow (`.github/workflows/latdx-value.yml` on
the fork's main). Each run appends one record per measured upstream change.

- `records.ndjson`: one JSON object per change, with every arm's numbers,
  including fields the CSV leaves out (deploy IDs, error text, the changed
  classes LATdx saw).
- `records.csv`: the same records flattened, regenerated from
  `records.ndjson` on every run.
- `selection-replay.ndjson` / `.csv`: one row per upstream commit replayed
  through `latdx test impact` alone (no org): the share of the suite LATdx
  would select for that commit, by count and by RunTime. Rows repeat across
  runs; filter by `run_url` or `cli_version` to compare like with like.
- `baseline-runtimes.json`: per-test RunTime (ms, keyed by lower-cased
  `Class.method`) from the newest stock run, the weights the replay uses.

## What one record measures

One upstream change, from `base` to `head`, on the fork's reserved scratch
org (Enterprise edition, from `config/scratch-orgs/base-scratch-def.json`):

| Arm                 | Command                                                             | Org state               |
| ------------------- | ------------------------------------------------------------------- | ----------------------- |
| `baseline_tests`    | `sf apex run test --test-level RunLocalTests`                       | head                    |
| `latdx_cold`        | `latdx test run`, empty cache                                       | head                    |
| `latdx_warm`        | `latdx test run`, cache from `latdx_prior`                          | head                    |
| `latdx_prior`       | `latdx test run` on the base commit (fills the warm cache)          | base                    |
| `impact`            | `latdx test impact --base base --head head` (no org)                | n/a                     |
| `validate_local`    | `sf project deploy validate <delta> --test-level RunLocalTests`     | base                    |
| `validate_selected` | the same with `RunSpecifiedTests` and the classes `impact` selected | base                    |
| `latdx_validate`    | `latdx validate --base base --head head --coverage-threshold 75`    | base, deploys the delta |

`<delta>` is the deployable files changed between base and head under
`nebula-logger/` (deletions are counted but not deployed). For the validate
arms the recipes' example trigger, which no test covers and upstream never has
in the org it validates on, is removed first and restored afterwards.

## Columns that need care

- `*_wall_ms` is what CI waits for, measured around the command.
  `validate_*_server_ms` is Salesforce's own start-to-finish time for the
  deploy request.
- `baseline_sum_runtime_ms` sums every test's RunTime: compute, not wall
  time. Salesforce runs a scratch org's tests in parallel, so compute saved is
  larger than wall time saved.
- `share_count` / `share_time`: the share of the suite LATdx selects, by test
  count and weighted by each test's RunTime in `baseline_tests`.
  `safe_share_time` is 1 when `risk_flags` is non-empty: those are metadata
  changes (flows, validation rules, permission sets, ...) the static reach
  graph cannot follow, so a safe pipeline runs the full suite.
- `latdx_*_hits` / `*_misses` come from LATdx's cache report; executed tests
  are `tests_ran - hits`.
- `*_gate` is `pass`, `coverage_fail`, `test_fail`, `component_fail`,
  `error`, or a skip reason.
- A non-zero `latdx_*_rc` is a LATdx failure or license halt (exit 2), kept
  as data rather than retried.

Numbers from different CLI versions (`cli_version`) are not comparable
without reading the release notes in between.
