<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2026 Marcus Quinn -->

# GH#37888 quota diagnostic continuation

## Continuation at 2026-11-14

This section supersedes the earlier consumer-identity gap below, but not the
open operational acceptance criteria. New maintainer evidence on the linked
issue reports local native `gh` routine subprocesses carrying burst traffic on
the maintainer host. In its reset window ending 05:10:51Z, three minutes had
187, 389 and 446 unexplained requests; the first 15 minutes had 2003 used versus
1127 logged attempts. Composite commands and opaque pagination are reported as
an instrumentation gap. A browser's steady traffic remains a hypothesis, not
an attributed request count. These are reported owner-host observations, not
measurements reproduced on this continuation runner.

The existing `_ghqa_run_transport_attempt` exact-capture path already parses
multiple native response frames when `AIDEVOPS_GH_EXACT_QUOTA_CAPTURE=1` and
`GH_DEBUG` is unset. It is opt-in, suppresses native stderr and serializes by
credential; automatically enabling it everywhere would change command behavior.
Use a bounded affected-host reproduction rather than a guessed command-cost
table. The diagnostics reference now explains this path and its limitations.
No thresholds, credentials, processes or budget gates were changed.

Fresh local `quota-report 5400` ending at epoch 1794632302:

| Reset epoch | Sample start | Sample end | Used delta | Known local cost | Unattributed upper bound | Counter regressions |
| --- | --- | --- | --- | --- | --- | --- |
| 1794629726 | 1794626931 | 1794629562 | 235 | 103 | 132 | 0 |
| 1794630400 | 1794626903 | 1794630400 | 4862 | 3362 | 1500 | 35 |
| 1794633488 | 1794629891 | 1794632226 | 213 | 106 | 107 | 1 |
| 1794634002 | 1794630403 | 1794632302 | 2784 | 2388 | 396 | 16 |

All rows have `accounted_fraction=null`; none proves a clean full post-fix reset
window. The report contains 520 missing-metadata attempts. Reset buckets are
kept separate and residuals are not assigned to a particular consumer. Claim
evidence was not supplied to this invocation, so the hint is correctly unknown.
`api-budget` reports real REST families (60-minute attempts: issue reads 1669,
issue comments 1078, pull reads 373, unknown 365). The independent instrument
report was retained privately; its cutoff differs from the table above.

Focused verification on this runner: the instrumentation suite exits zero,
including foreign-device positive/local-only negative/missing-evidence cases;
all 73 transport-budget tests pass. The native ShellCheck binary is unavailable
(the installed wrapper reports that fact); **Code Quality Analysis / ShellCheck
(ubuntu-latest)** covers the existing changed shell files in CI. No shell or
Python production files were changed by this continuation.

`linters-local.sh --changed --base-ref 73a9e150f` exits zero. Markdown style,
secret scanning and diff-whitespace checks pass; shfmt differences on the two
pre-existing changed shell files remain advisory. Its ShellCheck summary is not
independent evidence of the native tool being available: direct invocation
reports a missing real binary, so that check remains delegated to CI.

Remaining infrastructure need: access to the affected maintainer-host routine's
bounded execution/capture and a complete post-remediation reset window with
matching dispatch logs. This runner's local counters cannot validate another
host's caller, and replaying its bulk publication is not authorized by this
brief. Recommend scoped exact capture there, then fixing the measured routine
consumer or using an operator-configured App installation profile. Do not label
the drain off-host, claim remediation, or make this checkpoint ready from these
partial local windows.

## Outcome at 2026-11-13

PR #37889 remains a diagnostic checkpoint, not a verified drain remediation.
Preserve its foreign-device hint and documentation. Do not mark it ready or
convert its non-closing issue reference until the operational criteria pass.

The endpoint-label repair is already in the branch's ancestry through
`7eda06b74` (PR #37337), in `gh_native_response.py`,
`gh-transport-governor.py`, and `gh-transport-controls.sh`. Do not duplicate it.
`pulse-diagnose-helper.sh api-budget` now reports real REST families, including
issue reads, issue comments, collaborator permissions and pull reads. Unknown
families still occur; this is not evidence that every native path is labeled.

## Fresh measurement

These are privacy-safe counts, not raw log excerpts or consumer identities.
Different credential/reset series must not be added into one user's quota.

`gh-checks-wait-helper.sh quota-report 5400`, ending at epoch `1794586194`:

| Reset epoch | Sample start | Sample end | Used delta | Known local cost | Unattributed upper bound |
| --- | --- | --- | --- | --- | --- |
| 1794583576 | 1794580796 | 1794583576 | 3924 | 662 | 3262 |
| 1794587177 | 1794583577 | 1794586190 | 4207 | 1078 | 3129 |

These two rows belong to the same credential digest. The observed local shares
are about 16.9% and 25.6%, respectively. Neither is a full post-remediation reset
window. The first has two counter regressions; the second has nine and twenty
unknown-cost attempts. `accounted_fraction` is therefore null: the ratios above
are descriptive, not proof of exact governed coverage. There are 580
missing-metadata attempts across the report. Other series have different
coverage and must not be used to declare this affected series repaired.

An independent `gh-api-instrument.sh report <private-output> 5400` snapshot at
epoch `1794586264` contains 6,858 attempts, 5,227 known quota cost and 1,163
unknown-cost attempts across all pools and credentials. Its affected series
ending at reset `1794587177` has a peak unattributed minute at `1794585420`:
202 counter drop, 31 logged local cost, 171 unexplained cost. This is an upper
bound, not an identified off-host caller's measured cost. The reports have
different cutoffs and accounting semantics; do not splice their totals.

The same snapshot's largest local callers across all pools and credentials:

| Caller | Attempts | Known quota cost |
| --- | --- | --- |
| `pulse-wrapper.sh` | 2227 | 1977 |
| `pulse-merge-routine.sh` | 1341 | 772 |
| `dispatch-dedup-helper.sh` | 652 | 632 |
| `dispatch-claim-helper.sh` | 393 | 341 |
| `headless-runtime-helper.sh` | 214 | 162 |

These instrumented callers are not evidence identifying the unexplained spend.
A fresh `gh api rate_limit` returned core used 4421/5000, remaining 579,
reset `1794587178`; GraphQL remaining was 4887/5000. This is a point sample,
not evidence of a successful full reset window.

The assigned issue's saved claim evidence contains one device for the local
self login and a different device for a different login. Comparing the self
login with the actual local device-id returns `none`, as required. This narrow
claim sample does not exclude another device elsewhere. The issue's earlier
two-device observation concerns a different login and does not identify the
current sample's consumer. A foreign claim alone never establishes quota cost.

## Verification

- ShellCheck passes for both shell files changed by this PR.
- `linters-local.sh --changed --base-ref 73a9e150f` exits zero. It reports
  advisory shfmt differences and unavailable markdownlint and native Secretlint.
  Covering CI jobs in **Code Quality Analysis** are **Markdown Lint** and
  **Secretlint (changed files)**; both passed on the starting PR head. CI must
  cover the continuation head as well.
- `python3 .agents/scripts/tests/test-gh-transport-budget.py`: 73 tests pass.
- The instrumentation regression suite passes after unsetting inherited
  `AIDEVOPS_PULSE_AUTH`, `AIDEVOPS_GITHUB_AUTH_CONSUMER` and
  `AIDEVOPS_PULSE_AUTH_ACTIVE` for that hermetic test invocation only. Without
  that isolation its copied shim fixture tries to load a production auth
  runtime that the fixture does not contain. Production auth is unchanged.
  Positive foreign-device, local-only negative and absent-evidence cases pass.
- Existing native-frame assertions verify method/class/family preservation and
  reject private request text. Runtime API-budget output independently confirms
  real families rather than only `unknown`.

## Remaining blocker and exact resumption criteria

The available evidence does not identify the unexplained consumer's caller,
host class and cost, or establish that it is outside framework reach. No
consumer-side remediation has been established, so collecting another local
window alone cannot prove the required post-fix result. This worker has no
identified foreign-device control or consumer-side logs, and must not stop
unrelated processes or change credentials based on a quota residual.

The affected login owner must map the foreign device previously observed in
the issue to its operator, provide consumer-side time-bounded counts, and stop
the duplicate consumer or isolate it with an App installation token if that
diagnosis holds. Otherwise provide the missing local/CI caller evidence before
changing a consumer. Do not raise thresholds or weaken budget gates.

After the identified consumer is fixed, capture a complete reset window with
`quota-report 5400`, the instrument report and matching pulse diagnostics.
Require local coverage at least 80% or a used-delta reduction of at least 2000
from 4999, plus no exhaustion-caused `issue_metadata_unavailable` dispatch block.
Keep these criteria open; neither passing tests nor a foreign-device hint is
a substitute for the operational evidence.
