# LATdx CI Fork

This is [nebulity](https://github.com/nebulity)'s fork of
[jongpie/NebulaLogger](https://github.com/jongpie/NebulaLogger). Its purpose is
to run Nebula Logger's real-world pull requests through the
[LATdx](https://latdx.com) Apex test runner, keeping everything else about the
upstream pipeline (scratch org lifecycle, deploys, code quality checks) as
close to upstream as possible.

Every open upstream PR is mirrored here automatically and built with the
fork's CI, so each upstream contribution doubles as a live compatibility and
timing sample for LATdx. Upstream's own CI run on the same PR provides the
side-by-side baseline.

## What differs from upstream

All divergence lives in `.github/` plus this file:

- `.github/workflows/build.yml`:
  - The two `Run Apex Tests (A)synchronously` steps in each scratch-org job
    are replaced by one `Run Apex Tests with LATdx` step
    (`.github/actions/latdx-test`). The `sf project deploy validate
--test-level RunLocalTests` step is untouched, so the suite still runs
    server-side once per job as part of the deploy lifecycle.
  - Org provisioning: upstream creates a throwaway scratch org per run; the
    fork instead authorizes one long-lived org (`TARGET_ORG_SFDX_AUTH_URL`,
    see [Reserved org](#reserved-org)) and redeploys NebulaLogger onto it
    every build (idempotent). The org is created from NebulaLogger's own
    `config/scratch-orgs/base-scratch-def.json` on the LATdx Dev Hub
    (`latdx-dh`), so its shape (edition, features, settings) matches what the
    base job expects. Never substitute an sfp pool org: those carry the LATdx
    pool's scratch shape, and edition and features cannot be changed after
    creation. It carries no `Pooltag__c`, so sfp's pool prepare ignores it.
  - Upstream-only concerns are gated on `github.repository ==
'jongpie/NebulaLogger'`: Codecov uploads, the core coverage suite run,
    package version verification, and the three package-versioning jobs
    (their 2GP packages live in the upstream maintainer's Dev Hub).
  - The five feature-permutation scratch jobs (advanced, event monitoring,
    experience cloud, OmniStudio, platform cache) are upstream-only: they
    need fresh feature-specific scratch orgs the fork cannot create. The
    fork runs code quality, LWC tests, and the base scratch org job against
    the single reserved org; pushes to fork main skip the org job (dispatch
    Build on main to run it).
  - `workflow_dispatch` trigger and a read-only default token
    (`permissions:` block) are added; `id-token: write` lets jobs mint the
    OIDC token used for the LATdx OSS license exchange.
- `.github/actions/latdx-test/`: composite action that installs the LATdx
  CLI (pinned to the current stable release, `cli-version` input), resolves
  a license, and runs `latdx test run` against the job's default org (the
  reserved org).
- `.github/workflows/latdx-benchmark.yml` (dispatch only): four timed runs of
  the full suite on the reserved org (cold, cached, comment-only edit, one
  semantic edit) published as a cold-vs-cached table in the run summary.
- `.github/workflows/fork-health.yml`: daily check that fails when the
  reserved org is within 7 days of its expiry (GitHub emails a failed
  scheduled run to whoever last changed the workflow's cron; the fork has
  Issues disabled), and warns when the pinned CLI falls behind the latest
  stable release.
- `.github/workflows/mirror-upstream-prs.yml`: every 30 minutes, mirrors open
  upstream PRs into `upstream-pr-<n>` branches, opens fork PRs labeled
  `upstream-mirror`, and dispatches Build (capped per cycle to protect the
  scratch org budget). Closes mirrors whose upstream PR closed.
- `.github/workflows/sync-upstream.yml`: daily merge of upstream main into
  fork main; opens an issue on conflict.

## Test semantics

- `latdx test run` with no selection discovers org test classes with
  `NamespacePrefix = NULL`, matching `RunLocalTests` semantics (the OmniStudio
  managed package's tests stay excluded).
- Upstream runs the suite twice per job (async + sync) to cover an
  AuthSession nuance; the fork runs it once via LATdx. The async/sync
  permutation remains covered by upstream's own CI.

## Security model

Mirrored branches contain upstream-authored code, so the pipeline assumes the
code is untrusted:

- The mirror overlays `.github/` from fork main onto every mirrored branch;
  workflow or action changes from upstream PRs never execute here.
- `build.yml` runs with a read-only `GITHUB_TOKEN`, so a checkout credential
  leak cannot push or read secrets.
- The reserved org's credentials are exposed only to the org-auth and the
  `npx sf` deploy steps, which resolve `sf` from `node_modules`, so PRs
  touching `package.json` / `package-lock.json` are mirrored with the
  `held-sensitive` label and are NOT auto-built; review the manifest diff,
  then dispatch Build on the branch manually. The blast radius is one
  disposable scratch org, not a Dev Hub.
- Revoke a leaked org by deleting it on the Dev Hub and rotating
  `TARGET_ORG_SFDX_AUTH_URL` to a fresh org (see
  [Rotate the reserved org](#rotate-the-reserved-org)).

## Secrets

| Secret                     | Required | Purpose                                                                                                                                                                       |
| -------------------------- | -------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `TARGET_ORG_SFDX_AUTH_URL` | yes      | SFDX auth URL of the [reserved org](#reserved-org) the fork deploys to and tests, created from `base-scratch-def.json` on `latdx-dh`. Rotate before it expires (30 days max). |
| `LATDX_CI_LICENSE_KEY`     | no       | LATdx TEAM/CI license key. Without it the action falls back to the OSS OIDC exchange; if that path is unavailable, runs cap at 100 tests and exit 2.                          |

## Reserved org

The org behind `TARGET_ORG_SFDX_AUTH_URL`. Scratch orgs live at most 30
days, so it is rotated monthly; `fork-health.yml` reads the expiry line
below and starts failing 7 days ahead.

- Username: `test-m0xaqbghbkg7@example.com` (alias `nebula-fork-shaped`
  locally)
- Org ID: `00DAq00000I4vYv`, Dev Hub `latdx-dh`
- Created: 2026-10-21, 30-day duration (the scratch-org maximum)
- **Expires: 2026-11-20**

## Operations

- Mirrored PRs always show a parked `pull_request` run ("workflow awaiting
  approval"): GitHub requires approval for runs on PRs authored by
  first-time contributors, and `github-actions[bot]` forever stays one. Do NOT
  approve these; the mirror dispatches the real Build run, which needs no
  approval and reports on the same commit. On a `held-sensitive` PR,
  "Approve and run" would bypass the manifest-review hold.
- Mirror or sync manually: `gh workflow run mirror-upstream-prs.yml` /
  `gh workflow run sync-upstream.yml` (both also run on schedule).
- Build a held PR after review: `gh workflow run build.yml --ref
upstream-pr-<n>`.
- All fork builds and the benchmark serialize on the single reserved org via
  one `concurrency` group (`nebula-fork-shared-org`, with
  `cancel-in-progress: false`), so a second run waits rather than clashing
  on the shared org's deploy. GitHub keeps only one pending run per group:
  a third run queued while one runs and one waits cancels the waiting one.
  The mirror's
  per-cycle build cap defaults to 1; raise it for a manual run with
  `gh workflow run mirror-upstream-prs.yml -f max-builds=3` only when the
  group is idle.
- Bump the LATdx CLI: change the `cli-version` default in
  `.github/actions/latdx-test/action.yml` and `latdx-benchmark.yml` together,
  then dispatch Build and LATdx Benchmark on main.

### Rotate the reserved org

Do this when Fork Health starts failing (7 days before expiry), or any time
Build fails at "Authorize reserved org" with `RefreshTokenAuthError`.
From a checkout of this repo, with `latdx-dh` authorized locally:

```bash
# 1. Create the new org from NebulaLogger's own definition (30 days is the max).
sf org create scratch --target-dev-hub latdx-dh --no-namespace --no-track-source \
  --definition-file ./config/scratch-orgs/base-scratch-def.json \
  --duration-days 30 --alias nebula-fork-shaped-new --wait 20

# 2. Store its auth URL as the repo secret without echoing it.
sf org auth show-sfdx-auth-url -o nebula-fork-shaped-new --json \
  | jq -r '.result.sfdxAuthUrl' \
  | gh secret set TARGET_ORG_SFDX_AUTH_URL -R nebulity/NebulaLogger

# 3. Read the new username, org ID and expiry for FORK.md.
sf org display -o nebula-fork-shaped-new --json \
  | jq '.result | {username, id, expirationDate}'

# 4. Delete the old org if it still exists, then move the alias.
sf org delete scratch -o nebula-fork-shaped --no-prompt
sf alias set nebula-fork-shaped=$(sf org display -o nebula-fork-shaped-new --json | jq -r .result.username)
sf alias unset nebula-fork-shaped-new
```

Then update [Reserved org](#reserved-org) (username, org ID, created,
expires), merge that to main (the commit also keeps the scheduled workflows
from being disabled for inactivity), and dispatch both org workflows on main:
`gh workflow run build.yml --ref main` and
`gh workflow run latdx-benchmark.yml --ref main`. The first build on a fresh
org assigns `LoggerAdmin`; later re-assigns fail harmlessly.

## Known issues

- Full-suite run fails (`An unknown exception occurred`): `latdx test run`
  over NebulaLogger's full org suite (73 local Apex test classes, ~1,354
  methods) errors on every class, while stock
  `sf apex run test --test-level RunLocalTests` passes on the same org.
  Reproduced on LATdx 0.52.3 against the fresh reserved org (Build run
  [39592387700](https://github.com/nebulity/NebulaLogger/actions/runs/39592387700):
  auth, deploy and the OSS license all succeed, then
  `Error running tests: An unknown exception occurred.`, 73 classes FAIL).
  Cause, on the LATdx side: a cold-cache run submits every method as an
  explicit `tests[]` array to Salesforce's `runTestsAsynchronous`, which
  rejects arrays above roughly 550-600 methods with `UNKNOWN_EXCEPTION`
  (diagnosed in nebulity/latdx#2263, closed unmerged). The base job stays
  red until a LATdx release fixes it; the fork then bumps its CLI pin.

## Timing comparison caveats

When comparing this fork's runs against upstream's runs on the same PR, the
defensible comparison is the test-execution step only. Org shape differs
(different Dev Hubs, instance pools), the fork skips the second (synchronous)
suite run and the coverage suite run, and LATdx result caching means repeat
runs of unchanged code are not equivalent to cold runs. Quote raw step
durations with these caveats, not a synthesized speedup number.
