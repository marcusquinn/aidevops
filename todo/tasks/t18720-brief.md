## What

Two README badge defects found while re-rendering stale badge blocks across
managed repos (follow-up to GH#35012):

1. `badges-check-helper.sh` misclassifies drift. `_classify_badges_repo` runs
   `readme-badges-helper.sh check` with only stderr suppressed, so the unified
   diff on stdout becomes the classification row. DRIFTED repos print
   `--- /dev/fd/63 <date>` as their status and the summary reports
   `0 drifted` while ~50 managed repos have drifted blocks — stale layouts
   went unnoticed.
2. `readme-badges-helper.sh` picks the repo metrics refresh caller
   (`loc-badge.yml`, calling `loc-badge-reusable.yml`) or the Star History
   caller as the "GitHub Actions" badge when it is the only workflow. The badge
   reads "Repository Metrics — generate local README data and badges |
   passing", which says nothing about the project's build health.

## How

- `.agents/scripts/badges-check-helper.sh`: discard `check` stdout and capture
  its exit code without `set -e` interference.
- `.agents/scripts/readme-badges-helper.sh` `detect_workflow_in_path`: ignore
  workflows that call `loc-badge-reusable.yml` or `star-history-reusable.yml`
  when choosing the Actions badge workflow.

### Files Scope

- `.agents/scripts/badges-check-helper.sh`
- `.agents/scripts/readme-badges-helper.sh`

## Acceptance

- `badges-check-helper.sh` reports DRIFTED (with a note) and counts drifted
  repos in the summary.
- A repo whose only workflows are the metrics/star-history callers renders no
  Actions badge.

## Verification

`shellcheck` both files; `test-readme-badges-resilience.sh`,
`test-maintenance-repo-selection.sh`; run `badges-check-helper.sh --repo` on a
drifted repo and render a repo whose only workflows are the managed callers.
