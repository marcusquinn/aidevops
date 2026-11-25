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

## Recovery on current main (2026-11-25)

PR #40177 was closed after conflicting with independently merged fixture
repairs. Its four implementation/report commits were recovered onto the fresh
dispatcher branch based on `a2255568bf`. Conflict resolution retains upstream:

- #40053 already isolates the command-policy interactive analyzer context.
- #40234 / PR #40240 already provides the merge-flag mock registry.
- #40232 / PR #40238 already copies the full core-layout dependency closure and
  exports both fixture installation/config paths in setup. The recovered
  per-command overrides are therefore redundant and were removed.

The only remaining test delta is manifest-index's hermetic no-node inventory.
Existing suite execution under `GITHUB_ACTIONS=true FULL_LOOP_HEADLESS=true
AIDEVOPS_WORKER_ID=fixture-parent` passes 5/5. The affected-suite comparison with
`--base origin/main --compare-base --jobs 2 --timeout 180 --retries 0` selects
one suite, omits none and reports pass. Bash syntax and whitespace checks pass.
No production guard, workflow, threshold or tool-resolution contract changes.

Replacement PR: <https://github.com/marcusquinn/aidevops/pull/40259>.

## Complete original row ownership

The following groups enumerate all **83** original regression rows exactly once.
Names omit the common `.agents/scripts/tests/test-` prefix and `.sh` suffix.
Ownership is not a claim of a fresh passing result for every suite: merged
repairs are evidence of delivery, while #40029 retains global convergence and
reassessment. #40041's residual batch was decomposed into the four named groups.

### This repair (1)

- `agent-source-manifest-index`: #40176, verified 5/5 as above.

### Setup/install/release group (20)

Owner #40232, delivered in PR #40238:

- `agent-sources-core-layout`
- `check-workflows-classifier`
- `encryption-git-roundtrip`
- `gui-codefactor-css`
- `hot-deploy-flow`
- `legacy-dashboard-launchagent-cleanup`
- `lint-resource-benchmark`
- `macos-activity-cleaner-guidance`
- `managed-temp-workspace`
- `qlty-workflow-version-pin`
- `release-publication-destination-state`
- `release-publication-workflows`
- `release-stale-runtime-recovery`
- `remove-osgrep-mcp`
- `stale-process-deploy-hardening`
- `sync-workflows-helper`
- `sync-workflows-install-missing`
- `terminal-output-contract`
- `tool-install-claudebar`
- `tool-install-serve-sim`

### GitHub/mock/gate group (19)

Owner #40233, delivered in PR #40237:

- `contributor-activity-helper-person`
- `email-receipt-forward`
- `enrich-batch-prefetch`
- `forge-event-mapping`
- `gh-signature-helper`
- `interactive-session-post-merge`
- `issue-sync-list-timeout`
- `issue-sync-pull-seeds-orphans`
- `issue-triage-gate-fail-closed`
- `maintainer-gate-approval-api-failure`
- `maintainer-gate-interactive-status-retry`
- `maintainer-gate-nmr-residue`
- `parent-prose-child-detection`
- `post-merge-verify-report`
- `pr-3885-recovery`
- `pr-review-thread-response-scanner`
- `review-bot-gate-completion-signal`
- `shared-gh-wrappers-checks-null-suites`
- `solved-label-attribution`

### Dispatch/lifecycle group (21)

Owner #40234, delivered in PR #40240:

- `cas-retry-exhaustion`
- `claim-task-id-todo-collision`
- `codegraph-worktree-init-helper`
- `deferred-job-helper`
- `define-sufficiency`
- `dispatch-claim-helper`
- `dispatch-lease-claims-private-member`
- `dispatch-override`
- `full-loop-cleanup-receipt`
- `full-loop-merge-flag-conflict`
- `full-loop-release-helper`
- `local-branch-cleanup-helper`
- `planning-commit-helper-protected-default-pr`
- `pre-push-dup-todo-guard`
- `pulse-cleanup-worker-owned-no-pr`
- `pulse-default-branch-detection`
- `repo-state-guard`
- `stats-wrapper-headless-export`
- `watchdog-stall-cap`
- `worker-output-discovery`
- `worktree-recovery-lifecycle`

### Runtime group (8)

Owner #40235, delivered in PR #40244 (command-policy identity also in #40053):

- `command-policy-helper`
- `mcp-prefix-chunk-boundary`
- `opencode-launcher-helper`
- `postflight-check-run-dedup`
- `postflight-no-source-rescan`
- `postflight-scan-scope`
- `postflight-sonarcloud-gate`
- `profile-readme-contributions-fail-closed`

### Other delivered structural/context groups (5)

- `aidevops-sh-portability`: #40053, merged fixture/context repair.
- `deploy-runtimes-bounded`: #40184 / PR #40193.
- `simplex-integration`: #40184 / PR #40193.
- `model-routing-reasoning-migration`: #40041 / PR #40236.
- `sonnet-5-5-migration`: #40041 / PR #40236.

### Residual convergence reassessment (9)

These original rows are not in those merged child scopes. They remain explicit
reassessment inputs for the still-open #40029, not assertions of repair here:

- `matterbridge-helper`
- `open-done-nonclosing-regression`
- `pulse-instance-lock-mkdir-only`
- `pulse-systemd-timeout`
- `pulse-wrapper-isrunning-shortcircuit`
- `quickfile-rest-routing`
- `session-distill-provenance`
- `tier3-simplified`
- `worker-reliability-self-heal`

For each, use the original artifact's matching log, run the current suite with
a disposable HOME via `suite-health-repro-helper.sh`, compare the current
production contract, and retain real refusal paths. Do not reopen implementation
in this narrowly scoped duplicate incident or infer success from closed sibling
issues. Any still-red row belongs in #40029's next convergence assessment.

## Convergence and notification ownership

The newer scheduled run `45529588341` failed with 77 red suites at
`391c4a389f0701092035d58105d9b4e795cdea6e`. That run predates the current merged
residual groups; it is neither verification of this replacement head nor proof
that those groups failed. #40029 stays open until a fresh assessed full run
meets its criterion. This bounded fixture repair and ownership accounting can
resolve #40176 without closing or declaring that parent green.

Duplicate-signature notification repair is independently delivered by #40178 /
PR #40179: timestamped log envelopes no longer change the error fingerprint.
Its existing signature-noise suite covers this incident's raw, three-column and
four-column payloads. No additional pulse-output workaround is needed here.
