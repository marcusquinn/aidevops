# GH#40184: stale suite assertion repair

## Incident and ownership

- Scheduled run: https://github.com/marcusquinn/aidevops/actions/runs/45408396375
- The `Run every root suite` step finished its report and failed with 83 red
  suites. This was not a workflow timeout. The incident and mixed failure causes
  are also recorded in `gh40178-shell-suite-health.md` in this directory.
- #40176 owns the command-policy, merge-flag and agent-source fixture repair unit.
- #40029 remains the workflow environment and full-health convergence tracker.
- #40178 fixed incident-signature normalization; #40184 is another rendering of
  the same scheduled failure, not evidence of a new common missing dependency.

## Reproduction and repair

Two independently reproduced stale assertions are repaired here:

1. `test-deploy-runtimes-bounded.sh` failed 1 of 10 assertions because it searched
   `setup.sh` for a direct bounded-wrapper call. Setup now sources
   `setup-execution.sh`, whose timed deployment still calls the bounded wrapper.
   Check both that source edge and the executable timed call, excluding comments.
   Existing real-wrapper timeout and child-failure checks remain intact.
2. `test-simplex-integration.sh` failed six content assertions: three domain-table
   checks still read the always-loaded guide, and three demanded old headings or
   capitalization. Check the guide's domain-index pointer and the actual routing
   targets/table in `reference/domain-index.md`. Check business-address,
   contribution and slash-command documentation as topics, including the current
   inline presentation, rather than requiring removed heading text.

No production files, security guards, workflow thresholds or suite exclusions
change. This is a residual assertion repair, not a claim that all 83 suites pass.
The health job must remain red for remaining reproducible regressions; #40029
and #40176 retain the remaining convergence work.

## Verification

- Both edited suites pass `bash -n`.
- Bounded deployment: 10 assertions pass, zero failures, including actual wrapper
  timeout and noncritical child-failure behavior.
- SimpleX: 58 assertions pass; the only two remaining failures are the existing
  ShellCheck invocations. The installed wrapper reports that it cannot find a
  real ShellCheck binary, including for `shellcheck --version`. Before this edit,
  the suite had 51 passes and eight failures. No lint skip or fake success is
  introduced. `.github/workflows/code-quality.yml` provides the CI
  `cross-platform-shellcheck` job.
- Affected-suite comparison and PR checks are recorded during PR closeout.

## Acceptance boundary

This unit fixes and accounts for the reproduced stale assertions without
duplicating the already-owned environment/fixture repairs. Full-health recovery
is not inferred from a base-comparison pass. A fresh complete health run remains
the convergence evidence required by #40029.
