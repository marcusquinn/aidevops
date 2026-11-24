# GH#40178: duplicate shell-health incident mining

## Evidence and ownership

- Failed scheduled run: https://github.com/marcusquinn/aidevops/actions/runs/45408396375
- Run head: `a591651345106fc82a91e7e23f258b063bec5cd8`.
- Downloaded `suite-health` artifact 14933940266 contains 1,221 suite rows,
  with 83 classified as regressions. The workflow completed its report, rather
  than exhausting its execution budget.
- Issues #40176 and #40178 cite that same run and the same 83-suite error.
  Their signatures retain different step names (`Run every root suite` versus
  `UNKNOWN STEP`) and slightly different timestamps; their signal tags differ.
- #40176 owns the active fixture repair unit. Its canonical scope includes
  command-policy, merge-flag and agent-source fixtures. #40029 remains the
  convergence tracker. This PR does not change those files or close those issues.

## Root cause and repair

`extract_failure_signature` already recognizes three/four-column GitHub logs,
but passes the original row to `normalize_signature_line`. That function
previously removed only ANSI and redundant whitespace. `compute_pattern_id`
therefore hashed job/step labels and timestamps as if they were error content.
Different log renderings of the same incident could file independent issues.

Normalize only recognized timestamped log envelopes to the payload before
hashing. Preserve the error text, including a timestamp inside the payload,
and preserve trailing payload fields. Existing source-noise filtering,
infrastructure evidence, thresholds and write guards remain unchanged.
Plain lines without a recognized timestamp envelope retain their content.

Historical issues keep their original signal tags: this is not a migration or
a claim that a new hash automatically matches all previously filed issues.
Stable payloads now produce the same key across subsequent log renderings.

## Remaining health failures

The artifact does not support treating all 83 rows as one shared missing tool:

| Artifact suite | Observed failure | Ownership |
| --- | --- | --- |
| `test-agent-sources-core-layout.sh` | Fixture/source dependency failure | #40176 |
| `test-full-loop-merge-flag-conflict.sh` | Mocked merge fails before fake merge succeeds | #40176 |
| `test-simplex-integration.sh` | Stale guide/section assertions | #40029 residual triage |
| `test-deploy-runtimes-bounded.sh` | Old setup function assertion | #40029 residual triage |
| `test-opencode-launcher-helper.sh` | Launcher command expectations differ | #40029 residual triage |
| `test-enrich-batch-prefetch.sh` | REST fallback cache expectations fail | #40029 residual triage |

These are examples of baseline failure diversity, not a complete classification
or new claims of repair. No health threshold was raised, no suite was excluded,
and the health workflow remains red until its separate repairs converge.

## Verification

- `bash -n` on the miner and signature-noise suite: passed.
- `bash .agents/scripts/tests/test-gh-failure-miner-signature-noise.sh`:
  54 assertions passed, including real incident payload equivalence across raw,
  three-column and four-column rows, different timestamps, and step names.
  Review identified an ambiguous raw row with tabs and a timestamp in field 3;
  parsing the leading raw timestamp first preserves its complete error text.
  Three additional assertions cover that case and equivalent issue keys.
- `bash .agents/scripts/tests/test-gh-failure-miner-codefactor-guidance.sh`:
  33 assertions passed, including infrastructure and provider guidance contracts.
- `bash .agents/scripts/affected-tests-helper.sh run --base origin/main --compare-base`:
  all six selected suites passed, zero omitted. This includes miner signatures,
  CodeFactor guidance, SHA drift, generated issue labels, maintenance selectors
  and pulse CI failure prefetch.
- ShellCheck is unavailable locally: the runner's wrapper cannot locate a real
  binary. `.github/workflows/code-quality.yml` supplies the
  `cross-platform-shellcheck` CI job. No lint bypass or configuration change.
- Local push verification also reports missing JavaScript development tools
  (`tsc`); typecheck is deferred by the repository's own hook to CI. This
  shell-only change does not install dependencies or claim a local typecheck pass.

## Acceptance self-review

The duplicate filing defect is reproduced and covered; identical error payloads
now share a key. Error text and production guard behavior remain intact in both
existing suites. Remaining baseline health failures retain existing ownership;
this repair does not represent all 83 suites as fixed.
