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
  - Dev Hub auth uses an SFDX auth URL secret (`DEV_HUB_SFDX_AUTH_URL`)
    instead of upstream's JWT connected app.
  - Upstream-only concerns are gated on `github.repository ==
'jongpie/NebulaLogger'`: Codecov uploads, the core coverage suite run,
    package version verification, and the three package-versioning jobs
    (their 2GP packages live in the upstream maintainer's Dev Hub).
  - The five feature-permutation scratch jobs (advanced, event monitoring,
    experience cloud, OmniStudio, platform cache) are also upstream-only:
    the fork's Dev Hub allows 3 active / 6 daily scratch orgs, which cannot
    fund a 6-org matrix per PR. The fork runs code quality, LWC tests, and
    the base scratch org job (one org per PR build); pushes to fork main
    skip the org job entirely.
  - `workflow_dispatch` trigger and a read-only default token
    (`permissions:` block) are added; `id-token: write` lets jobs mint the
    OIDC token used for the LATdx OSS license exchange.
- `.github/actions/latdx-test/`: composite action that installs the LATdx
  CLI, resolves a license, and runs `latdx test run` against the job's
  default org (the scratch org each job creates).
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
- Dev Hub credentials are exposed only to the `Authorize Dev Hub` step's
  environment. That step executes `npx sf` resolved from `node_modules`, so
  PRs touching `package.json` / `package-lock.json` are mirrored with the
  `held-sensitive` label and are NOT auto-built; review the manifest diff,
  then dispatch Build on the branch manually.
- Rotate/revoke the auth URL by logging the Dev Hub user out (`sf org
logout`) and re-issuing; prefer a dedicated low-privilege Dev Hub user for
  this fork.

## Secrets

| Secret                  | Required | Purpose                                                                                                                                              |
| ----------------------- | -------- | ---------------------------------------------------------------------------------------------------------------------------------------------------- |
| `DEV_HUB_SFDX_AUTH_URL` | yes      | SFDX auth URL of the Dev Hub used to create scratch orgs (`sf org auth show-sfdx-auth-url`; `sf org display` redacts it).                            |
| `LATDX_CI_LICENSE_KEY`  | no       | LATdx TEAM/CI license key. Without it the action falls back to the OSS OIDC exchange; if that path is unavailable, runs cap at 100 tests and exit 2. |

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
- The per-cycle build cap defaults to 1 (a PR build costs one scratch org
  of the 6/day allowance); raise it for a manual run with
  `gh workflow run mirror-upstream-prs.yml -f max-builds=3`.

## Timing comparison caveats

When comparing this fork's runs against upstream's runs on the same PR, the
defensible comparison is the test-execution step only. Org shape differs
(different Dev Hubs, instance pools), the fork skips the second (synchronous)
suite run and the coverage suite run, and LATdx result caching means repeat
runs of unchanged code are not equivalent to cold runs. Quote raw step
durations with these caveats, not a synthesized speedup number.
