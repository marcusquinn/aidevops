# GH#40176: shell-suite health investigation

## Evidence and limits

- Assigned issue: <https://github.com/marcusquinn/aidevops/issues/40176>
- Scheduled run: <https://github.com/marcusquinn/aidevops/actions/runs/45408396375>
- Tested main commit: `a591651345106fc82a91e7e23f258b063bec5cd8`
- Artifact: `suite-health`, ID `14933940266`.
- `suite-results.tsv`: 1,221 suite rows, 83 classified `regression` after
  rerunning failures. `suite-stderr.log` reports zero suites omitted by the cap
  and does not report exhaustion of the execution budget.
- The scheduled job completed normally with a failing health report, rather
  than timing out or failing to install its toolchain.

The storm bound aggregates notifications; it does not establish that every red
suite has the same cause. Do not increase the bound, suppress failed rows, or
claim that repairing one fixture makes this run green.

## First repair unit: inherited execution identity

### Command-policy interactive fixture

`test-command-policy-helper.sh` called the analyzer without worker arguments for
its interactive signing assertion, but inherited the runner's `GITHUB_ACTIONS`.
`command_policy_runtime.py` treats that variable as worker identity. Consequently
the fixture expected an interactive decision from a worker analyzer. The artifact
records `git.worker-signing-override` for this assertion.

Clear the runtime's eight worker markers only for that analyzer subprocess. No
Git command is executed by the assertion. Keep the suite's worker signing cases
and parent environment unchanged; the production signing guard is correct.

### Mocked merge-flag target

`test-full-loop-merge-flag-conflict.sh` mocked GitHub responses but did not give
`testorg/testrepo` a fixture registry role. On Actions the external-write guard
correctly classified the unknown target as contributor/read-only, so the fake
merge was never reached. All three cases failed in the artifact.

Provide an isolated registry containing only the fake target with a maintainer
role. Keep headless identity and production guards enabled. No real repository
authority or allowlist is changed.

### Verification

- Before repair: the merge-flag suite reproduced all three artifact failures on
  the worker (`rc=1`, external-write guard).
- After repair: `GITHUB_ACTIONS=true FULL_LOOP_HEADLESS=true bash
  .agents/scripts/tests/test-full-loop-merge-flag-conflict.sh` passed 3/3 cases.
- Under `GITHUB_ACTIONS=true FULL_LOOP_HEADLESS=true
  AIDEVOPS_WORKER_ID=fixture-parent`, the command-policy suite passed the repaired
  interactive assertion and every existing worker signing assertion. Its full
  result was 224 cases, 3 other failures: a hardcoded FHS `ssh-keygen` path absent
  on this runner and two approval-command expectation mismatches. These are not
  repaired or represented as passes by this unit.
- Bash syntax and `git diff --check` passed for both changed suites. The normal
  pre-commit shell ratchets passed. Standalone ShellCheck cannot start locally
  because its wrapper cannot find the binary; the PR's ShellCheck job is the
  remote verification path.
- The pre-push gate deferred TypeScript verification to CI because this
  worktree has no installed `tsc`; it did not establish a local typecheck pass.
- `affected-tests-helper.sh run --base origin/main --compare-base --jobs 2
  --timeout 180 --retries 0` completed successfully, selecting both changed
  suites with none omitted. It classified command-policy as `pre-existing`
  (`rc_head=1`, `rc_base=1`) and merge-flag as `pass` (`rc_head=0`). This is
  evidence of no introduced affected-suite regression, not a full-suite pass.

## Second repair unit: copied installation and no-node inventory

The core-layout suite exited before printing assertions because its copied
`shared-constants.sh` sources a missing `runtime-env.sh`. After supplying that
file, it reported a missing `managed-label-provisioning-lib.sh`. Match the
dependency closure already used by the manifest-index fixture, and capture
helper failures explicitly so `set -e` cannot hide their diagnostics.

The manifest suite's restricted PATH did not model a no-node host: runtime PATH
normalization appends system fallbacks, which contain Node on Actions. Its
disposable runtime wrapper now retains the real library functions, then restores
the fixture's tool inventory after initialization. Production normalization is
unchanged; no test flags or interfaces were added to production code.

Existing-suite verification: core-layout passed 9/9; manifest-index passed 5/5,
including its no-node fallback. Both use disposable installations, not a real
agent-source configuration.

## Remaining incident work

This is a partial repair. Keep GH#40176 open; do not use a closing keyword on
the first repair PR. The original artifact remains the inventory for the other
79 suites; they have not been established as fixed or unrelated by a new health
run. Examples showing that a single environment workaround is insufficient:

| Suites (under `.agents/scripts/tests/`) | Artifact evidence | Next verification |
| --- | --- | --- |
| `test-encryption-git-roundtrip.sh`, `test-dispatch-override.sh` | Missing companion script in fixture | Check current source modules before changing fixture copies |
| `test-model-routing-reasoning-migration.sh`, `test-sonnet-5-5-migration.sh`, `test-deploy-runtimes-bounded.sh` | Assertions about setup call sites fail | Compare current setup module ownership against extracted-function assertions |
| `test-maintainer-gate-approval-api-failure.sh`, `test-maintainer-gate-interactive-status-retry.sh`, `test-maintainer-gate-nmr-residue.sh` | Mocked gate jobs return nonzero | Inspect gate extraction and mocked metadata; retain fail-closed behavior |
| `test-gui-codefactor-css.sh` | Duplicate top-level selectors | Reproduce with the current CSS parser before editing UI files |
| `test-simplex-integration.sh`, `test-macos-activity-cleaner-guidance.sh`, `test-managed-temp-workspace.sh` | Documentation and setup structural assertions fail | Determine moved contract vs missing behavior; do not restore obsolete inline guidance |
| `test-gh-signature-helper.sh` | Token accounting and interactive-session expectations fail | Separate inherited identity from SQLite fixture behavior |
| `test-sync-workflows-helper.sh`, `test-sync-workflows-install-missing.sh`, `test-planning-commit-helper-protected-default-pr.sh` | Linked-worktree fixture preparation fails | Inspect fake Git identity and authority dependencies, without bypassing live guards |

Use `suite-health-repro-helper.sh` for subsequent host/fake-HOME/Linux
comparisons, and run the existing affected-suite comparison for each coherent
repair. A newer successful scheduled run, or explicit per-suite verification,
is required before reporting the aggregate incident resolved.

## Continuation checkpoint

Draft PR: <https://github.com/marcusquinn/aidevops/pull/40177>. The fixture repair
is committed and pushed; the draft is intentionally not delivery of the whole
incident. The next bounded investigation is the encryption/dispatch fixture
group in the table: inspect current sourced modules and missing companion
copies. Apply integration-scope recovery before adding target paths to the
canonical issue scope. Do not close GH#40176 or turn this first unit into a
closing PR while the aggregate criteria remain open.
