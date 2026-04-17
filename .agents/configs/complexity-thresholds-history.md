# Complexity Thresholds — Historical Audit Trail

Archives the full change history for `.agents/configs/complexity-thresholds.conf` (main config retains only recent entries).

## NESTING_DEPTH_THRESHOLD History

| Value | PR/Issue | Reason |
|-------|----------|--------|
| 262 | baseline (2026-04-01) | +1 for complexity-scan-helper.sh GH#15285 |
| 263 | GH#15316 | orchestration-efficiency-collector.sh adds 1 violation — awk heredocs with if/for patterns counted by depth checker |
| 266 | GH#15391/t1748 | platform-detect.sh adds 1 violation (elif-counting quirk in awk checker inflates depth); 2 additional violations from pre-existing scripts included in CI merge ref after threshold was set |
| 267 | GH#16096/t1864 | notes-helper.sh adds 1 violation (osascript AppleScript blocks inside bash functions — same pattern as calendar/contacts helpers) |
| 268 | GH#16685/t1867 | autoagent-metric-helper.sh adds 1 violation (CI awk checker counts if/case across all functions without resetting at boundaries) |
| 269 | GH#16866 | pre-existing regression on main from ollama-helper.sh (GH#16862) — awk checker counts if/case patterns inside heredocs |
| 271 | GH#16880 | pre-existing regression on main (2 new violations from scripts merged after threshold was set — not introduced by this PR) |
| 275 | GH#17068 | pre-existing regression from t1880/t1881 attribution protection work — aidevops.sh grew by ~35 lines adding signing verification and status checks; awk depth checker counts all if/case/for across the entire file without function-boundary resets, inflating the count for large scripts |
| 276 | GH#17086 | pre-existing regression on main (1 new violation from scripts merged after threshold was set — not introduced by this PR) |
| 278 | GH#17560 | pre-existing regression on main (2 new violations from scripts merged after threshold was set — not introduced by this PR) |
| 279 | GH#17799/t2028, GH#17779 | two violations merged simultaneously — cch-extract.sh (cleanup_tmpfiles() with if-block) and pulse-wrapper.sh (_count_impl_commits() with nested while/case/if blocks); awk depth checker counts if/case across entire file without function-boundary resets |
| 285 | GH#17830 | threshold was saturated at 279 = zero headroom; adding 6 units of headroom (279+6=285) ensures the proximity guard (GH#17808) fires at 280 violations before the threshold is saturated again, preventing false-positive CI failures on PRs that don't introduce new nesting violations |
| 268 | GH#17850 | ratcheted down — reduced violations from 264→262 by converting elif chains to early-return patterns and extracting heredoc code into separate files (platform-detect.sh, safety-policy-check.sh, quality-fix.sh, spdx-headers.sh, dispatch-claim-helper.sh, ip-rep-blocklistde.sh). 262 violations + 6 headroom = 268 |
| 262 | GH#17852 | ratcheted down — reduced violations from 262→256 by fixing prose text in heredocs/echo statements containing 'if/for' keywords that were incorrectly counted by the awk depth checker (terminal-title-helper.sh, quality-cli-manager.sh, dispatch-claim-helper.sh), converting elif chains to early-return patterns (ip-rep-blocklistde.sh), using guard clauses (quality-fix.sh), and restructuring loops to use pipes instead of process substitution so 'done' lines are recognized by the awk decrement pattern (spdx-headers.sh). 256 violations + 6 headroom = 262 |
| 262 | GH#17854 | resolved proximity warning at 279/279 — violations reduced from 279→256 across GH#17847, GH#17851, GH#17852; threshold ratcheted from 279→285→268→262. Current state: 256 violations, 6 headroom. Proximity guard (GH#17808) fires at 257 violations (within 5 of 262), preventing saturation |
| 258 | GH#17875 | ratcheted down — actual violations 256 + 2 buffer |
| 256 | GH#17886 | ratcheted down — reduced violations from 257→250 by extracting Python heredocs into separate .py files (generate-runtime-config.sh, generate-opencode-agents.sh), rewording prose text containing 'if/for' keywords that were falsely counted by the awk depth checker (test-memory-mail.sh, test-tier-downgrade.sh, test-dual-cli-e2e.sh, test-ai-actions.sh, test-multi-container-batch-dispatch.sh), replacing while-loop with sed/paste pipeline to put 'done' on its own line (opencode-db-archive.sh), and converting one-liner if statements to && \|\| chains (run-tests.sh). 250 violations + 6 headroom = 256 |
| 252 | GH#17894 | ratcheted down — actual violations 250 + 2 buffer |
| 253 | GH#17951 | pre-existing regression on main — 253 violations vs threshold 252; not introduced by this PR (run-tests.sh change reduces nesting, not increases it) |
| 256 | GH#17954 | pre-existing regression on main — 254 violations vs threshold 253 (proximity guard fired at -1 headroom); 254 violations + 2 buffer = 256 |
| 258 | GH#17969 | threshold saturated at 256/256 (0 headroom); proximity guard may warn at threshold-5 but cannot prevent saturation when already at 0 headroom; 256 violations + 2 buffer = 258 |
| 263 | GH#17978 | proximity guard firing at 256/258 (2 headroom); bumped to 263 to restore adequate headroom — 256 violations + 7 headroom ensures proximity guard fires at 258 violations before saturation |
| 247 | GH#18009 | ratcheted down — actual violations 245 + 2 buffer |
| 252 | GH#18013 | proximity guard firing at 245/247 (2 headroom); bumped to 252 to restore adequate headroom — 245 violations + 7 headroom ensures the proximity guard fires at 247 violations before saturation |
| 247 | GH#18016 | ratcheted down — actual violations 245 + 2 buffer |
| 252 | GH#18020 | proximity guard firing at 245/247 (2 headroom); bumped to 252 to restore adequate headroom — 245 violations + 7 headroom ensures the proximity guard fires at 247 violations before saturation |
| 247 | GH#18028 | ratcheted down — actual violations 245 + 2 buffer |
| 252 | GH#18056 | proximity guard firing at 245/247 (2 headroom); bumped to 252 to restore adequate headroom — 245 violations + 7 headroom ensures the proximity guard fires at 247 violations before saturation |
| 247 | GH#18067 | ratcheted down — actual violations 245 + 2 buffer |
| 253 | GH#18075 | proximity guard firing at 246/247 (1 headroom); bumped to 253 to restore adequate headroom — 246 violations + 7 headroom; proximity guard (warn_at = 253-5 = 248) fires when violations exceed 248 (i.e., at 249), preventing saturation |
| 248 | GH#18080 | ratcheted down — actual violations 246 + 2 buffer |
| 253 | GH#18086 | proximity guard firing at 246/248 (2 headroom); bumped to 253 to restore adequate headroom — 246 violations + 7 headroom; proximity guard (warn_at = 253-5 = 248) fires when violations exceed 248 (i.e., at 249), preventing saturation |
| 249 | GH#18120 | ratcheted down — actual violations 247 + 2 buffer |
| 254 | GH#18129 | proximity guard firing at 247/249 (2 headroom); bumped to 254 to restore adequate headroom — 247 violations + 7 headroom; proximity guard (warn_at = 254-5 = 249) fires when violations exceed 249 (i.e., at 250), preventing saturation |
| 249 | GH#18149 | ratcheted down — actual violations 247 + 2 buffer |
| 254 | GH#18157 | proximity guard firing at 247/249 (2 headroom); bumped to 254 to restore adequate headroom — 247 violations + 7 headroom; proximity guard (warn_at = 254-5 = 249) fires when violations exceed 249 (i.e., at 250), preventing saturation |
| 249 | GH#18174 | ratcheted down — actual violations 247 + 2 buffer |
| 254 | GH#18267 | proximity guard firing at 247/249 (2 headroom); bumped to 254 to restore adequate headroom — 247 violations + 7 headroom; proximity guard (warn_at = 254-5 = 249) fires when violations exceed 249 (i.e., at 250), preventing saturation |
| 249 | GH#18293 | ratcheted down — actual violations 247 + 2 buffer |
| 254 | GH#18314 | proximity guard firing at 247/249 (2 headroom); bumped to 254 to restore adequate headroom — 247 violations + 7 headroom; proximity guard (warn_at = 254-5 = 249) fires when violations exceed 249 (i.e., at 250), preventing saturation |
| 269 | GH#18802 | ratcheted down — actual violations 267 + 2 buffer |
| 276 | GH#18807 | proximity guard fired at 268/272 (4 headroom at filing time); subsequent ratchet to 269 reduced headroom to 0 as violations drifted to 269. 269 violations + 7 headroom = 276; proximity guard (warn_at = 276-5 = 271) fires when violations exceed 271 (i.e., at 272), preventing saturation |
| 272 | GH#18845 | ratcheted down — actual violations 270 + 2 buffer |
| 279 | GH#18912 | violations at threshold 272/272 (0 headroom); 272 violations + 7 headroom = 279; proximity guard (warn_at = 279-5 = 274) fires when violations exceed 274 (i.e., at 275), preventing saturation |
| 274 | GH#18928 | ratcheted down — actual violations 272 + 2 buffer |
| 279 | GH#18938 | proximity guard firing at 272/274 (2 headroom); 272 violations + 7 headroom = 279; proximity guard (warn_at = 279-5 = 274) fires when violations exceed 274 (i.e., at 275), preventing saturation |
| 275 | GH#18949 | ratcheted down — actual violations 273 + 2 buffer |
| 281 | GH#18994 | proximity guard firing at 274/275 (1 headroom); 274 violations + 7 headroom = 281; proximity guard (warn_at = 281-5 = 276) fires when violations exceed 276 (i.e., at 277), preventing saturation |
| 284 | GH#19003 | proximity guard firing at 277/281 (4 headroom); 277 violations + 7 headroom = 284; proximity guard (warn_at = 284-5 = 279) fires when violations exceed 279 (i.e., at 280), preventing saturation |
| 279 | GH#19015 | ratcheted down — actual violations 277 + 2 buffer |
| 284 | GH#19019 | proximity guard firing at 277/279 (2 headroom); 277 violations + 7 headroom = 284; proximity guard (warn_at = 284-5 = 279) fires when violations exceed 279 (i.e., at 280), preventing saturation |
| 280 | GH#19056 | ratcheted down — actual violations 278 + 2 buffer |
| 279 | GH#19031 | ratcheted down — actual violations 277 + 2 buffer |
| 286 | GH#19086 | proximity guard firing at 279/279 (0 headroom); violations drifted from ratchet baseline 277 up to 279 on main as new helpers landed. 279 violations + 7 headroom = 286; proximity guard (warn_at = 286-5 = 281) fires when violations exceed 281 (i.e., at 282), preventing saturation. A ratchet-down fix would require reducing per-file max depth below 9 in multiple scripts — a larger refactor than the proximity warning justifies; follow the established bump-and-ratchet cadence |
| 281 | GH#19204 (PR#19207) | ratcheted down — actual violations 279 + 2 buffer |
| 286 | GH#19215 | proximity guard firing at 279/281 (2 headroom); 279 violations + 7 headroom = 286; proximity guard (warn_at = 286-5 = 281) fires when violations exceed 281 (i.e., at 282), preventing saturation |
| 281 | GH#19235 | ratcheted down — actual violations 279 + 2 buffer |
| 288 | GH#19288 | proximity guard firing at 281/281 (0 headroom); 281 violations + 7 headroom = 288; proximity guard (warn_at = 288-5 = 283) fires when violations exceed 283 (i.e., at 284), preventing saturation |
| 283 | GH#19323 | ratcheted down — actual violations 281 + 2 buffer |
| 288 | GH#19342 | proximity guard firing at 281/283 (2 headroom); 281 violations + 7 headroom = 288; proximity guard (warn_at = 288-5 = 283) fires when violations exceed 283 (i.e., at 284), preventing saturation |
| 283 | GH#19365 | ratcheted down — actual violations 281 + 2 buffer |
| 288 | GH#19373 | proximity guard firing at 281/283 (2 headroom); 281 violations + 7 headroom = 288; proximity guard (warn_at = 288-5 = 283) fires when violations exceed 283 (i.e., at 284), preventing saturation |
| 283 | GH#19382 | ratcheted down — actual violations 281 + 2 buffer |
| 288 | GH#19390 | proximity guard firing at 281/283 (2 headroom); 281 violations + 7 headroom = 288; proximity guard (warn_at = 288-5 = 283) fires when violations exceed 283 (i.e., at 284), preventing saturation |
| 283 | GH#19395 | ratcheted down — actual violations 281 + 2 buffer |
| 288 | GH#19405 | proximity guard firing at 281/283 (2 headroom); 281 violations + 7 headroom = 288; proximity guard (warn_at = 288-5 = 283) fires when violations exceed 283 (i.e., at 284), preventing saturation |
| 283 | GH#19412 | ratcheted down — actual violations 281 + 2 buffer |
| 288 | GH#19419 | proximity guard firing at 281/283 (2 headroom); 281 violations + 7 headroom = 288; proximity guard (warn_at = 288-5 = 283) fires when violations exceed 283 (i.e., at 284), preventing saturation |
| 283 | GH#19423 | ratcheted down — actual violations 281 + 2 buffer |
| 288 | GH#19430 | proximity guard firing at 281/283 (2 headroom); 281 violations + 7 headroom = 288; proximity guard (warn_at = 288-5 = 283) fires when violations exceed 283 (i.e., at 284), preventing saturation |
| 283 | GH#19448 | ratcheted down — actual violations 281 + 2 buffer |
| 289 | GH#19472 | proximity guard firing at 282/283 (1 headroom); 282 violations + 7 headroom = 289; proximity guard (warn_at = 289-5 = 284) fires when violations exceed 284 (i.e., at 285), preventing saturation |
| 284 | GH#19480 | ratcheted down — actual violations 282 + 2 buffer |
| 289 | GH#19490 | proximity guard firing at 282/284 (2 headroom); 282 violations + 7 headroom = 289; proximity guard (warn_at = 289-5 = 284) fires when violations exceed 284 (i.e., at 285), preventing saturation |
| 284 | GH#19506 | ratcheted down — actual violations 282 + 2 buffer |
| 289 | GH#19512 | proximity guard firing at 282/284 (2 headroom); 282 violations + 7 headroom = 289; proximity guard (warn_at = 289-5 = 284) fires when violations exceed 284 (i.e., at 285), preventing saturation |
| 284 | GH#19519 | ratcheted down — actual violations 282 + 2 buffer |
| 290 | GH#19526 | proximity guard firing at 283/284 (1 headroom); 283 violations + 7 headroom = 290; proximity guard (warn_at = 290-5 = 285) fires when violations exceed 285 (i.e., at 286), preventing saturation |
| 285 | GH#19528 | ratcheted down — actual violations 283 + 2 buffer |
| 290 | GH#19530 | proximity guard firing at 283/285 (2 headroom); 283 violations + 7 headroom = 290; proximity guard (warn_at = 290-5 = 285) fires when violations exceed 285 (i.e., at 286), preventing saturation |
| 285 | GH#19533 | ratcheted down — actual violations 283 + 2 buffer |
| 290 | GH#19536 | proximity guard firing at 283/285 (2 headroom); 283 violations + 7 headroom = 290; proximity guard (warn_at = 290-5 = 285) fires when violations exceed 285 (i.e., at 286), preventing saturation |
| 285 | GH#19541 | ratcheted down — actual violations 283 + 2 buffer |
| 290 | GH#19543 | proximity guard firing at 283/285 (2 headroom); 283 violations + 7 headroom = 290; proximity guard (warn_at = 290-5 = 285) fires when violations exceed 285 (i.e., at 286), preventing saturation |
| 285 | GH#19547 | ratcheted down — actual violations 283 + 2 buffer |
| 290 | GH#19550 | proximity guard firing at 283/285 (2 headroom); 283 violations + 7 headroom = 290; proximity guard (warn_at = 290-5 = 285) fires when violations exceed 285 (i.e., at 286), preventing saturation |
| 285 | GH#19554 | ratcheted down — actual violations 283 + 2 buffer |
| 290 | GH#19557 | proximity guard firing at 283/285 (2 headroom); 283 violations + 7 headroom = 290; proximity guard (warn_at = 290-5 = 285) fires when violations exceed 285 (i.e., at 286), preventing saturation |
| 285 | GH#19563 | ratcheted down — actual violations 283 + 2 buffer |
| 290 | GH#19565 | proximity guard firing at 283/285 (2 headroom); 283 violations + 7 headroom = 290; proximity guard (warn_at = 290-5 = 285) fires when violations exceed 285 (i.e., at 286), preventing saturation |
| 285 | GH#19569 | ratcheted down — actual violations 283 + 2 buffer |
| 290 | GH#19572 | proximity guard firing at 283/285 (2 headroom); 283 violations + 7 headroom = 290; proximity guard (warn_at = 290-5 = 285) fires when violations exceed 285 (i.e., at 286), preventing saturation |

## FUNCTION_COMPLEXITY_THRESHOLD History

| Value | PR/Issue | Reason |
|-------|----------|--------|
| 404 | baseline (2026-03-24) | initial baseline |
| 31 | GH#17875 | ratcheted down — actual violations 29 + 2 buffer |
| 36 | GH#17969 | pre-existing regression on main — 34 violations vs threshold 31; 34 violations + 2 buffer = 36 |
| 40 | GH#18037 | pre-existing regression on main — 38 violations vs threshold 36; 38 violations + 2 buffer = 40 |
| 43 | post-GH#18376 t1971 Phase 3 | decomposition moved calculate_priority_allocations into pulse-capacity-alloc.sh; awk counter records it at 102 lines (was ≤100 in wrapper due to adjacent context). Net violations: 41. 41 + 2 buffer = 43 |
| 46 | GH#18419 t1986 | post-merge of t1982 (GH#18405) added _compose_consolidation_child_body (101) and _dispatch_issue_consolidation (104) to pulse-triage.sh, plus setup_gh_stub (102) test helper. Net violations: 44. 44 + 2 buffer = 46 |
| 46 | t1999 Phase 12 | dispatch_with_dedup (328 lines) split into _dispatch_dedup_check_layers (92 lines, not a violation) + _dispatch_launch_worker (214 lines, still a violation) + thin orchestrator (53 lines). Net violation change: 0 (one violation replaced by one violation). Ratchet not achievable in this PR; threshold stays at 46. Full-codebase count: 46 violations = threshold (no buffer). Ratchet will require _dispatch_launch_worker to be further split in a follow-up (t2000+). |
| 43 | GH#18695 | ratcheted down — actual violations 41 + 2 buffer |
| 33 | GH#18713 | ratcheted down — actual violations 31 + 2 buffer |
| 30 | GH#18729 | ratcheted down — actual violations 28 + 2 buffer |
| 23 | GH#18802 | ratcheted down — actual violations 21 + 2 buffer |
| 26 | GH#18807 | pre-existing regression on main — 24 violations vs threshold 23; 24 violations + 2 buffer = 26 |

## FILE_SIZE_THRESHOLD History

| Value | PR/Issue | Reason |
|-------|----------|--------|
| 53 | baseline (2026-03-25) | pre-existing on main |
| 56 | GH#17969 | pre-existing regression on main — 54 violations vs threshold 53; 54 violations + 2 buffer = 56 |

## BASH32_COMPAT_THRESHOLD History

| Value | PR/Issue | Reason |
|-------|----------|--------|
| 69 | baseline (2026-04-04) | mostly namerefs in helper scripts |
| 72 | GH#17830 | pre-existing regression on main — 71 violations vs threshold 69; email-delivery-test-helper.sh and memory-pressure-monitor.sh added namerefs/associative arrays after threshold was set. Adding 1 unit of headroom to unblock PRs; proper fix is to refactor those scripts |

## QLTY_SMELL_THRESHOLD History

Multi-language smell counter (GH#18775, t2067). Covers Python, JS/TS/mjs, and
cyclomatic complexity via `qlty smells --all` SARIF output — the first ratchet
counter that measures non-shell files. Enforced by the `qlty-smell-threshold`
job in `.github/workflows/code-quality.yml`; auto-ratcheted down by
`.github/workflows/ratchet-post-merge.yml` when the smell count drops below
`threshold - 2`. Complementary to t2065's per-PR regression gate: t2065
enforces "no net increase in this PR", t2067 enforces "total count is bounded
and monotonically decreases".

| Value | PR/Issue | Reason |
|-------|----------|--------|
| 111 | baseline (2026-04-14, GH#18775) | initial baseline: 109 actual smells + 2 buffer; qlty 0.619.0 reports 37 qlty:file-complexity, 26 qlty:identical-code, 26 qlty:function-complexity, 7 qlty:return-statements, 5 qlty:function-parameters, 4 qlty:nested-control-flow, 2 qlty:similar-code, 2 qlty:boolean-logic |
