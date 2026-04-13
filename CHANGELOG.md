<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [3.7.6] - 2026-04-13

### Added

- setup.sh completion sentinel + verify-setup-log.sh + auto-update wiring (#18510)

### Changed

- Maintenance: mark t2032 complete (pr:#18502)
- Maintenance: mark t2029 complete (pr:#18506 testing:runtime-verified)
- scope simplification gate on cited line ranges, not file size alone (#18497)

### Fixed

- make sync-on-pr-merge push failure visible (t2029) (#18506)

## [3.7.5] - 2026-04-13

### Changed

- tighten pulse deterministic merge-pass close-comment wording (GH#17574) (#18502)

## [3.7.4] - 2026-04-13

### Changed

- Maintenance: add brief and TODO entry for init-routines-helper readonly collision (#18487)
- split pulse-simplification.sh state cluster below 2000 LOC gate (#18488)
- file bash 3.2 scanner hardening task (planning only) (#18490)
- fix(pulse-triage): parse JSON output + inline prompt + shape validation (#18491)
- teach /review-issue-pr to do temporal-duplicate, framing, and second-order-effects checks (#18480)
- Maintenance: mark t2018 complete (pr:#18481 testing:self-assessed)

### Fixed

- Job 3 re-runs Job 1 to refresh required CheckRun (#18481)

## [3.7.3] - 2026-04-13

### Added

- stale-recovery escalation after N consecutive cycles (t2008) (#18462)
- implement tier-label dedup via GitHub Action and dispatcher fallback (#18441)
- guard cmd_enrich body writes with sentinel+content-diff gate; add --batch mode to /new-task (#18416)
- canonical stays on main in interactive sessions, no exceptions (#18414)

### Changed

- fix(pulse-triage): surface triage failures — escalation comment + label provisioning (#18476)
- Maintenance: mark t2015 complete (pr:#18474 testing:runtime-verified)
- fix(pulse-dep-graph): parse markdown-formatted blocked-by bodies (#18474)
- cut TRIAGE_MAX_RETRIES default 3→1 to eliminate lock/unlock churn (#18472)
- docs: cross-runner coordination reference doc (#18465)
- feat: add /build-agent slash command and ubicloud hosting agent (#18407)
- Maintenance: mark t1998 complete (pr:#18438) (#18440)
- fix simplification re-eval short-circuit that left #18346 stuck forever (#18438)
- Maintenance: sync TODO.md completion markers for t1962, t1963, t1986 (#18435)
- Maintenance: mark t1981/t1983/t1984/t1985/t1995 complete (#18436)
- Tests: stub-based harness for issue-sync-lib.sh with t1983 regression (#18430)
- post-checkout hook warning when canonical goes off main (#18427)
- feat(claudecli): map OpenCode reasoning level to Claude CLI --effort flag (#18424)
- plan: post-checkout hook to auto-restore main in canonical worktree (#18422)
- parent-task dispatch guard — label survival + #parent tag + dispatch short-circuit (#18419)
- Maintenance: add TODO completion marker for merged PR #18414 (#18417)

### Fixed

- preserve trailing newline and embed OPENCODE_BIN on Linux pulse (#18477)
- add auto-dispatch to _is_protected_label exact-match list (#18469)
- dispatch-dedup audit — add combined label+assignee guard (t1996) (#18446)
- add logging to two silent skip paths in cleanup_worktrees() Pass 2 (#18442)
- sync-todo-to-issues workflow tags issues origin:interactive and assigns human pusher (#18431)
- P0 BSD awk dynamic-regex silently broke add_gh_ref_to_todo on macOS (#18423)

## [3.7.2] - 2026-04-12

### Added

- setup.sh auto-installs privacy guard in every initialized repo (#18373)
- add git pre-push privacy guard for private slug leaks (#18361)

### Changed

- fix(pulse-triage): consolidation flow never creates the promised child issue (#18405)
- chore(ci): add Complexity Analysis to required status checks on main (#18397)
- Phase 10 (FINAL) — quality-debt + ancillary-dispatch, CLEARS 2000-line gate (#18392)
- Phase 9 — extract dispatch-core + dispatch-engine (26 fns, 2,141 lines) (#18390)
- Phase 8 — extract triage cluster (10 fns, 428 lines) (#18388)
- Phase 7 — extract prefetch cluster (26 fns, 1,668 lines) (#18386)
- Phase 6 — extract simplification cluster (1,990 lines, 29 fns, largest) (#18384)
- Phase 5 — extract cleanup + issue-reconcile clusters (#18381)
- Phase 4 — extract pr-gates + merge cycle into pulse-merge.sh (#18379)
- Maintenance: bump complexity threshold 40→43 (post-#18376 Phase 3 hotfix) (#18377)
- Maintenance: mark t1970 complete (pr:#18374)
- Maintenance: mark t1969 complete (pr:#18375)
- Maintenance: mark t1968 complete (pr:#18373)
- fix interactive-claim race — auto-assign + dedup excludes closed (#18374)
- stub-based tests for privacy-guard (caught a latent cache bug) (#18375)
- Phase 3 — extract operational plumbing (capacity, logging, watchdog, capacity-alloc) (#18376)
- Phase 2 — extract 4 leaves with fan-in (queue-governor, nmr-approval, dep-graph, fast-fail) (#18368)
- Phase 1 — extract 5 leaf modules (model-routing, instance-lock, meta-parse, repo-meta, routines) (#18366)
- Phase 0 safety net — characterization tests, --self-check, --dry-run (#18362)
- Maintenance: mark t1965 complete (pr:#18361)
- Maintenance: mark t1964 complete (pr:#18360)
- Maintenance: add r005 mirror-sync routine — daily sync of private mirror repos from their upstream sources
- Maintenance: mark t1961 complete (pr:#18355)
- skip pulse dispatch for interactive-session issues (#18353)
- Maintenance: mark complete — shipped in #18351 (v3.7.1)

### Fixed

- copy all session-miner *.py modules to workspace (#18409)
- exact tNNN-prefix dedup instead of fuzzy substring search (#18396)
- remove context betas, prevent infinite 429 rotation (#18363)
- skip fake-metric update when core tracking issue already exists (#18360)

## [3.7.1] - 2026-04-12

### Changed

- Maintenance: add TODO entry and brief for 1M context window fix

### Fixed

- enable 1M context window for Claude models in opencode-aidevops plugin (#18351)

## [3.7.0] - 2026-04-12

### Changed

- Claude CLI transport proxy for OpenCode plugin (#18343)
- fix model definitions — image modality, names, attachments (#18345)

## [3.6.244] - 2026-04-12

### Added

- register anthropic and claudecli models via config-hook

### Changed

- Maintenance: changelog for 3.6.244

## [3.6.244] - 2026-04-12

### Added

- register anthropic and claudecli models via config-hook

## [3.6.243] - 2026-04-12

### Changed

- Version bump and maintenance updates


## [3.6.243] - 2026-04-12

### Fixed

- thinking

## [3.6.242] - 2026-04-11

### Added

- external PR gate — require linked issue + crypto approval (t1958) (#18339)

### Changed

- complete MCP audit — all installed MCPs in plugin registry, DEPRECATED_MCPS cleanup, fix sentry secret, update docs (#18335)
- origin:interactive implies maintainer approval — skip auto-close and gate (#18334)
- add shopify-dev-mcp to plugin registry and AGENT_MCP_TOOLS (#18331)
- register shopify-dev-mcp in generate-runtime-config.sh so setup/update installs it (#18329)
- add flock deadlock detection, self-recovery, and health alerting (#18328)
- chore: ratchet-down NESTING_DEPTH_THRESHOLD 254→249 (GH#18326) (#18327)
- add shopify-dev-mcp agent, fix MCP audit gaps, add permission-migration TODOs (#18311)

## [3.6.241] - 2026-04-11

### Changed

- harden maintainer gate — admin-only simplification, authorship exemption, origin:worker protection
- fix FD 9 inheritance — replace ineffective python3 fcntl with bash 9>&- (#18309)
- Documentation: tighten .agents/content/yt-dlp.md slash command doc (75→66 lines) (#18315)
- tighten postflight-loop.md agent doc (50→40 lines) (#18323)
- fix: add throughput check to sweep stall detection (GH#18286) (#18325)
- tighten agent doc budget-analysis.md (52 → 25 lines) (#18320)
- bump NESTING_DEPTH_THRESHOLD to 254 to restore headroom (#18321)
- tighten agent doc /security-review (52 → 50 lines) (#18322)
- tighten list-verify.md (51 → 40 lines) (#18324)
- tighten agent doc /optimize-tiers (.agents/workflows/optimize-tiers.md, 121 → 100 lines) (#18193)
- tighten seo-audit.md from 98 to 84 lines (#18228)
- tighten marketing-sales agent doc (#18235)
- tighten runners-check.md active workers comment (#18237)
- tighten .agents/workflows/remember.md (77→64 lines) (#18245)
- Documentation: tighten dashboard.md workflow doc (78→63 lines) (#18246)
- Documentation: tighten .agents/workflows/skills.md (80→70 lines) (#18248)
- Maintenance: tighten aidevops.md agent doc (92→75 lines) (#18252)
- Documentation: tighten youtube-research.md agent doc (145→138 lines) (#18253)
- tighten save-todo.md workflow doc (118→105 lines) (#18256)
- Documentation: tighten agent doc legal.md prose and structure (#18259)
- Documentation: tighten aidevops-business.md agent doc (#18261)
- Documentation: tighten automate agent doc prose (#18262)
- Documentation: tighten log-issue-aidevops.md prose (146→138 lines) (#18263)
- Documentation: tighten SEO main agent doc prose (#18265)
- Documentation: tighten autoagent.md workflow doc prose (#18266)
- tighten add-skill.md workflow doc (74→70 lines) (#18281)
- tighten research.md agent doc (74→45 lines) (#18312)
- tighten health.md — merge disclaimer, compress pre-flight, remove duplicate notice (#18305)
- tighten youtube-setup.md agent doc (101→94 lines) (#18299)
- tighten cross-review.md — remove redundant parse step, flatten usage block (#18302)
- Documentation: tighten worktree-cleanup.md — promote --delete-branch warning, inline key rules (#18304)
- ratchet-down NESTING_DEPTH_THRESHOLD 254 → 249 (#18307)
- Maintenance: ratchet down NESTING_DEPTH_THRESHOLD 254→249 (GH#18293) (#18308)
- Documentation: tighten memory-log.md workflow doc (61→52 lines) (#18301)
- tighten venv-health.md — remove redundant opening sentence, format discovery note as blockquote (#18300)
- tighten email-inbox.md — reorder security first, merge after-check prose (#18298)
- tighten email-outreach.md — merge Options+Examples, add status command (#18297)
- tighten list-todo.md — compress prose, preserve all rules (#18296)

## [3.6.238] - 2026-04-11

### Added

- claude alias with --dangerously-skip-permissions + idempotent alias block updates (#18114)

### Fixed

- setup.sh deploys slash commands to all installed runtimes (GH#18106) (#18109)

## [3.6.236] - 2026-04-11

### Added

- main-agent slash commands across 14 AI clients with aidevops- prefix (#18096)

### Changed

- Maintenance: drop t15473 TODO — scripts/commands reorg not needed (#18100)
- restore nesting threshold headroom (#18087)

### Fixed

- restrict GH#NNN auto-close to PR title and add dedup guard on closing comments (#18102)
- detect billing outage failures in gh-failure-miner (#18095)

## [3.6.229] - 2026-04-10

### Fixed

- merge custom routing table with default for complete tier coverage (#18055)

## [3.6.228] - 2026-04-10

### Fixed

- optimize model resolution for performance and Bash 3.2 compat (#18053)

## [3.6.227] - 2026-04-10

### Fixed

- resolve model tier shorthands to FQIDs at deploy time (GH#18043) (#18051)

## [3.6.224] - 2026-04-10

### Changed

- chore: ratchet-down NESTING_DEPTH_THRESHOLD 252→247 (#18029)

## [3.6.222] - 2026-04-09

### Changed

- fix npm install 630MB peer deps on every update (#18019)
- ratchet down nesting depth threshold (#18017)

## [3.6.221] - 2026-04-09

### Changed

- restore nesting threshold headroom (#18014)

### Fixed

- prevent large-file gate from blocking issues targeting non-code files (GH#17897) (#18015)

## [3.6.220] - 2026-04-09

### Changed

- remove BSD grep noise from headless runtime diagnostics (#18012)

## [3.6.218] - 2026-04-09

### Fixed

- exclude review feedback, tier escalation, and quality-debt auto-gen from consolidation filter (#17988)

## [3.6.217] - 2026-04-09

### Fixed

- exclude audit-trail/history files from simplification scanner (#17987)

## [3.6.214] - 2026-04-09

### Added

- improve simplification gate — exclude non-code files, create debt issues immediately, auto-clear stale labels (#17980)

## [3.6.213] - 2026-04-09

### Added

- add architectural protection for routines repo + port fixes from closed PRs (#17977)

## [3.6.211] - 2026-04-09

### Fixed

- centralise known bots list so workflow stays current via aidevops update (#17971)

## [3.6.210] - 2026-04-09

### Added

- generate OS-specific routine descriptions with cross-platform footnote (#17970)

## [3.6.209] - 2026-04-09

### Added

- seed core routine descriptions and tracking issues into routines repo (#17967)

### Fixed

- exclude pulse gate comments from consolidation filter (self-referential loop) (#17968)

## [3.6.207] - 2026-04-09

### Added

- add unknown bot detection workflow with auto-issue creation (#17966)

## [3.6.206] - 2026-04-09

### Fixed

- add consolidation label re-evaluation pass before early fill floor (#17964)
- bump nesting depth threshold to 256 to resolve CI proximity warning (#17963)

## [3.6.205] - 2026-04-09

### Fixed

- tighten consolidation filter to exclude operational comments + auto-clear stale labels (#17962)

## [3.6.204] - 2026-04-09

### Added

- run routines repo setup in non-interactive mode (aidevops update) (#17960)

### Changed

- convert if/else to && || chain in run-tests.sh (#17951)

### Fixed

- update dispatch comment jq patterns for ops marker compatibility (#17961)
- redirect progress echo to stderr in _check_ext_files (#17925)
- verify mergedAt before closing issues against PRs (GH#17871) (#17931)

## [3.6.202] - 2026-04-08

### Changed

- Maintenance: add bot noise and operational comment skip rules (#8c, #8d) (#17957)

## [3.6.199] - 2026-04-08

### Fixed

- quote script_path and log paths in systemd unit generation (#17948)

## [3.6.197] - 2026-04-08

### Added

- deterministic blocked-by resolution via cached dependency graph (t1935) (#17953)

### Changed

- fix: remove 2>/dev/null from framework-routing-helper call in cch-canary.sh (#17949)

### Fixed

- check-generator-rules.py argument validation and regex robustness (#17950)

## [3.6.193] - 2026-04-08

### Changed

- Maintenance: add provenance skip markers for quality-debt issues (rule #8b) (#17940)

## [3.6.192] - 2026-04-08

### Fixed

- improve readability of exit code check in test-runtime-registry.sh (#17939)
- simplify --days condition in seo-export-helper.sh for readability (#17938)
- use if blocks for format conversion clarity (#17937)

## [3.6.189] - 2026-04-08

### Changed

- Maintenance: add rule #8a to skip signature footers when reading GH threads (#17932)

## [3.6.187] - 2026-04-08

### Changed

- skip approval gate for maintainer-authored quality-debt issues (#17922)

### Fixed

- memory-pressure-monitor.sh review feedback from PR #17858 (#17926)

## [3.6.185] - 2026-04-08

### Fixed

- improve pulse throughput — reduce dedup TTL, clear dedup on crash, dispatch-first ordering (#17921)
- restore anti-pattern detail and fix routine_id fallback in AGENTS.md (#17919)

## [3.6.184] - 2026-04-08

### Added

- crash-type-aware tier escalation, issue consolidation, and large-file simplification gate (#17918)

## [3.6.182] - 2026-04-08

### Changed

- auto-set assignee on crypto approval (#17888)
- harden _detect_opencode_server curl logic and plugin symlink cleanup (#17884)

### Fixed

- Bash 3.2 compat — replace ${var^} with tr in oauth-pool-helper.sh (#17885)

## [3.6.180] - 2026-04-08

### Security

- protect needs-maintainer-review label on PRs (mirror issue protection) (#17877)

## [3.6.178] - 2026-04-08

### Changed

- remove unauthorized external code, revert unreviewed PRs, harden merge gates (#17868)

## [3.6.168] - 2026-04-08

### Changed

- reduce function complexity in oauth-pool.mjs (#17818)
- Maintenance: update simplification state registry
- feat: aidevops init-routines (#17814)

### Fixed

- _is_task_committed_to_main subject-only matching for tNNN/GH#NNN patterns (#17802)

## [3.6.158] - 2026-04-08

### Changed

- Documentation: add objective tier assignment validation to prevent mis-tagging (t1921) (#17765)
- Refactor: consolidate model tier mappings to single source of truth (#17763)
- Maintenance: update simplification state registry
- Maintenance: tighten pageindex.md agent doc (153→107 lines) (#17760)
- Maintenance: update simplification state registry

## [3.6.157] - 2026-04-07

### Changed

- add task for silent gh auth failure in approval-helper.sh (GH#17754)
- add task for resolve_api_key subshell export bug
- Maintenance: update simplification state registry
- Refactor: decompose opencode-aidevops plugin into focused modules (t1914) (#17752)

### Fixed

- restrict Closes/Fixes keywords to code fix commits only

## [3.6.156] - 2026-04-07

### Added

- add 'diagnose' command to model-accounts-pool (GH#17746) (#17756)
- add PageIndex vectorless RAG skill doc (#17753)

### Changed

- Maintenance: update simplification state registry

## [3.6.155] - 2026-04-07

### Added

- reasoning-tier enrichment for failed worker issues (#17748)

### Changed

- add triage dedup guard to prevent repeated lock/unlock cycles (#17751)
- check open PRs in dedup Layer 4 — prevent duplicate dispatch (#17749)
- Maintenance: update simplification state registry
- Refactor: decompose compute_file_metrics() into language-specific helpers (GH#17713) (#17747)
- Refactor: extract verbose output condition helper (#17745)
- Maintenance: update simplification state registry
- add qlty verification to simplification brief template and code-simplifier (#17741)
- Maintenance: update simplification state registry
- fix: Linux scheduler dual-execution and systemd migration completion (#17730)
- include PID 1 in OpenCode runtime detection (#17736)
- Performance: replace while-read loop with awk in _read_brief_what_section (#17737)
- Maintenance: update simplification state registry

### Fixed

- dedup checks commit messages, not PR bodies — closes go in commits (#17750)
- remove blocking sleep and fix gh pr view exit code in merge pass (#17744)
- add systemd install mode to routine helper (#17739)
- replace $(uname) with $OSTYPE in file_size_bytes for efficiency (#17732)
- tighten conversation-end loop scan wording (#17738)

## [3.6.152] - 2026-04-07

### Changed

- fix remaining TZ=UTC-missing date calls across 3 scripts (#17716)
- Maintenance: update simplification state registry

## [3.6.151] - 2026-04-07

### Changed

- fix _ts_to_epoch() timezone bug causing premature stale recovery (#17710)
- extend complexity scanner to Qlty-scored file types (.py/.mjs/.js/.ts) (#17708)
- remove approval gate from pulse triage dispatch (#17709)
- add briefs and plan for triage gate fix and Linux scheduler completion
- Maintenance: update simplification state registry
- Maintenance: add t1909 brief and TODO entry for install-systemd subcommand (ref:GH#17692)
- CI: add HOL skill-publish validate workflow (#17671)
- Maintenance: update simplification state registry

### Fixed

- avoid stat output pollution and suppress wal pragma output (#17685)

## [3.6.139] - 2026-04-07

### Added

- cascade tier dispatch with tier:simple/standard/reasoning (#17645)
- restore daily full codebase review via CodeRabbit (GH#17640) (#17641)

## [3.6.138] - 2026-04-07

### Changed

- fix ESCAPE clause — 4 backslashes produced 2-char string, SQLite requires 1 (#17638)

### Fixed

- remove claim guard — mismatched comment format rejected every dispatch

## [3.6.136] - 2026-04-07

### Changed

- register colormind-helper.sh in simplification state (depth already 4 ≤ 8) (#17634)

### Fixed

- pass gate immediately when review bot is rate-limited — feedback caught by daily sweeps
- skip nesting-only violations in complexity scan issue creation (GH#17632) (#17633)

## [3.6.135] - 2026-04-07

### Fixed

- reduce review-bot grace period from 4h to 30min — rate-limited bot blocked entire merge pipeline
- eliminate signature gate false positives from TUI flash (#17631)

## [3.6.134] - 2026-04-06

### Added

- claim release on worker failure + lifecycle logging

## [3.6.132] - 2026-04-06

### Fixed

- unpin opencode — root cause was SQLite contention, not version-specific

## [3.6.131] - 2026-04-06

### Added

- merge worker session DB back to shared DB after completion

### Changed

- fix full-loop-helper.sh review feedback from PR #17547 (#17625)

## [3.6.130] - 2026-04-06

### Fixed

- isolate worker SQLite DBs — shared DB with busy_timeout=0 caused silent stream death

## [3.6.129] - 2026-04-06

### Fixed

- pin opencode to 1.3.15 — 1.3.16 stalls mid-session with silent stream death

## [3.6.128] - 2026-04-06

### Fixed

- headless contract V5 — warn workers about 300s watchdog, max 240s waits

## [3.6.127] - 2026-04-06

### Fixed

- version guard runs every dispatch, not just on canary cache miss

## [3.6.126] - 2026-04-06

### Fixed

- watchdog monitors continuously — previous design exited after first activity, missing mid-session stalls

## [3.6.125] - 2026-04-06

### Fixed

- version guard reinstalls pinned opencode if drifted — unknown process keeps upgrading to 1.3.17
- move canary before dispatch claim — failure no longer triggers backoff or blocks re-dispatch

## [3.6.124] - 2026-04-06

### Changed

- broaden signature gate regex to match all footer variable patterns (#17623)

### Fixed

- canary uses sonnet (verified working) — haiku model name not in 1.3.16 registry

## [3.6.123] - 2026-04-06

### Changed

- add canary smoke test and two-phase activity watchdog (#17624)
- reduce nesting depth in cch-traffic-monitor.sh (#17619)
- tighten completion detection in JSON parsing block (#17621)

### Fixed

- update safety-policy-check to find deny rules in extracted Python file (#17622)

## [3.6.122] - 2026-04-06

### Changed

- Maintenance: bump opencode pin from 1.3.15 to 1.3.16 — bisect confirmed safe
- parse OpenCode token aggregates via pipe-delimited stats (#17612)
- Refactor: extract command defs and Python settings to reduce nesting depth (GH#17559) (#17620)
- fix now_ms fallback and add WAL cleanup trap in opencode-db-archive (#17618)
- propagate domain generator failures in orchestrator (#17614)
- use DISPATCH_COMMENT_MAX_AGE as default for STALE_ASSIGNMENT_THRESHOLD_SECONDS (#17613)
- deduplicate oauth endpoint constants in pool ops (#17617)
- use github.paginate for full comment dedup in nmr-hold-comment (#17610)
- harden tabby fix-shell YAML patching without PyYAML (#17615)
- pin opencode-ai to 1.3.15 to prevent auto-upgrade to broken 1.3.17 (#17609)

### Fixed

- restore provider delegation for CLI helpers (GH#17600) (#17611)

## [3.6.119] - 2026-04-06

### Changed

- align stale assignment TTL with dispatch comment TTL (1800s) (#17572)
- reduce nesting depth in oauth-pool-helper.sh from 109 to 3 (#17570)
- add code scaffolding requirement to plans.md Save Flow
- fix profile-readme session hours hardcoded to ~/Git/aidevops (#17568)
- Refactor: reduce nesting depth in generate-claude-commands.sh (#17569)
- decompose cmd_fix_shell() into focused helpers (#17555)

### Fixed

- track logind sessions by ID to avoid hostname matching (GH#17551) (#17566)

## [3.6.118] - 2026-04-06

### Fixed

- prevent set -e from aborting release on git ls-remote exit code 2 (#17554)

## [3.6.100] - 2026-04-05

### Fixed

- add exact close-reference verification to has_open_pr() (#17435)
- consistent persistent label, LLM stall detection, test suite, release preflight (t1890) (#17437)
- remove time_total from curl write-out to fix http_code extraction (#17439)

## [3.6.98] - 2026-04-05

### Changed

- preserve local script edits + fix OpenCode relative paths (#17421)
- Maintenance: fix version references to 3.6.97 (missed in #17425) (#17426)

### Fixed

- parse probe_provider HTTP code trailer (GH#17427) (#17430)
- improve detect_default_shell() with reliable system query (#17424)
- add zero-debt guard to _complexity_llm_sweep_due (GH#17422) (#17423)
- add PID file guard to scan mode to prevent multiple instances (GH#17415) (#17418)
- warn when deployed scripts differ from canonical source (GH#17414) (#17417)
- add PID file guard to daemon mode to prevent multiple instances (GH#17408) (#17416)

## [3.6.97] - 2026-04-05

### Fixed

- `_complexity_llm_sweep_due` in `pulse-wrapper.sh` missing zero-debt guard; when debt is zero, `0 < 0 = false` falls through to "sweep due" triggering false-positive stall issues (GH#17422)

## [3.6.94] - 2026-04-05

### Fixed

- `_install_pulse_systemd` missing PATH env var causes workers to exit 127 on Linux; add `Environment=PATH=...` to service unit matching launchd plist behaviour (GH#17405)
- `_install_pulse_systemd` timer stalls on mid-session install due to missing `OnActiveSec`; add `OnActiveSec=10s` to bootstrap first service run (GH#17405)

## [3.6.89] - 2026-04-04

### Fixed

- `aidevops update` now regenerates existing systemd service files in non-interactive mode — fixes broken service files from GH#17369 not reaching users via `aidevops update` (#17382)

## [3.5.840] - 2026-04-03

### Changed

- Tightened glm-ocr.md agent doc (79→75 lines) — moved limitations to Quick Reference, consolidated bash blocks, replaced model comparison table with decision table (#16324)

## [3.5.829] - 2026-04-03

### Changed

- Tightened hyperdrive-patterns.md agent doc (125→115 lines) — consolidated redundant SET examples in Connection Pooling section; zero information loss (#16441)

## [3.5.827] - 2026-04-03

### Changed

- Tightened git-security.md agent doc (114→108 lines) — removed redundant frontmatter defaults, out-of-scope auth examples, and redundant tool mention; zero information loss (#16442)

## [3.5.784] - 2026-04-03

### Changed

- Tightened toon.md agent doc (94→80 lines) — removed redundant Format Examples section (inline in Quick Reference), renamed section header; zero information loss (#15872)

## [3.5.694] - 2026-04-02

### Changed

- Tightened github-actions.md agent doc (79→69 lines) — removed redundant Workflow Behavior section, condensed CODACY_API_TOKEN setup steps (#15899)

## [3.5.636] - 2026-04-02

### Fixed

- Fix broken chapter links in production-video.md index — corrected 9 paths from video/NN-*.md to production-video-NN-*.md (#15684)

## [3.5.635] - 2026-04-02

### Changed

- Tightened changelog.md agent doc (66→59 lines) — compressed prose, merged redundant sections, zero content loss (#15672)

## [3.5.596] - 2026-04-02

### Changed

- plan Linux/WSL2 platform support — brief and TODO entry

### Fixed

- make changelog entries self-explanatory by resolving task IDs (#15392)

## [3.5.555] - 2026-04-01

### Changed

- Maintenance: claim t1734
- Maintenance: claim t1733

### Fixed

- resilient token rotation — wait instead of crashing on exhaustion (#15183)

## [3.5.554] - 2026-04-01

### Changed

- Maintenance: claim t1732
- Maintenance: claim t1731

### Fixed

- bypass broken select subprocess for model selection (#15181)

## [3.5.553] - 2026-04-01

### Changed

- Maintenance: claim t1730
- Maintenance: claim t1729
- Maintenance: claim t1728
- Maintenance: claim t1727
- Maintenance: claim t1726
- Maintenance: claim t1725
- Maintenance: claim t1724
- Maintenance: claim t1723
- Maintenance: claim t1722
- Maintenance: claim t1721
- Maintenance: claim t1720
- Maintenance: claim t1719
- Maintenance: claim t1718
- Maintenance: claim t1717
- Maintenance: claim t1716
- Maintenance: claim t1715

### Fixed

- isolate supervisor backoff from worker dispatch (#15167)

## [3.5.552] - 2026-04-01

### Fixed

- activity watchdog exit code race condition (#15120)

## [3.5.551] - 2026-04-01

### Fixed

- isolate headless worker auth via XDG_DATA_HOME (#15114)

## [3.5.550] - 2026-04-01

### Fixed

- stop false provider backoff from local/worker failures (#15108)

## [3.5.549] - 2026-04-01

### Fixed

- stop headless workers from rotating shared OAuth token (#15099)

## [3.5.548] - 2026-04-01

### Fixed

- normalize expired cooldowns in MJS inject functions (#15098)

## [3.5.547] - 2026-04-01

### Fixed

- pre-dispatch backoff check — don't launch workers on dead providers (#15097)
- align output format fields with mission-orchestrator expectations (#14863)

## [3.5.546] - 2026-04-01

### Fixed

- detect and kill stalled workers on rate-limited providers (#15086)

## [3.5.545] - 2026-04-01

### Added

- deterministic merge pass — auto-merge ready PRs every cycle (#15080)

## [3.5.544] - 2026-04-01

### Changed

- Maintenance: claim t1714
- Documentation: tighten wrangler-patterns.md — remove duplication with sibling files (#13672)
- Documentation: tighten cloudron-server-ops-skill.md (142→118 lines, GH#13704) (#13716)
- Documentation: tighten revenuecat.md agent doc (158 → 152 lines) (#13748)
- Documentation: tighten concurrency.md agent doc (221 -> 169 lines) (#13749)
- Documentation: tighten feature-slicing migration.md (159→148 lines, regression fix) (#13761)
- Documentation: tighten drizzle.md (132→122 lines) (#13770)
- Documentation: tighten cro-chapter-25.md — remove structural noise and redundant prose (#13863)
- Documentation: tighten meta-ads-foundations-algorithm.md — remove structural noise (#13898)
- Documentation: tighten CRO chapter 02 — compress prose, preserve all knowledge (#13966)
- Documentation: tighten video-higgsfield-ui.md (188→158 lines) — remove redundant CLI Options table, compress prompt tips and prose (#14049)
- Documentation: tighten hexagonal.md 181→160 lines — flatten mermaid nesting, compress code blocks, remove redundant path comments (GH#14040) (#14061)
- Documentation: tighten playwright-emulation.md (175→153 lines) — merge config blocks, consolidate touch into options, remove redundant multi-device recipe (#14062)
- Documentation: tighten security.md (106→80 lines, 25% reduction) (#14086)
- Documentation: tighten agent-browser.md (170→161 lines) — merge Sessions+Wait sections, fold iOS env vars into code block, move License to Quick Reference (#14115)
- Documentation: tighten hashline-edit-format.md (139→135 lines, zero knowledge loss) (#14127)
- Documentation: tighten research.md (113→106 lines) — clarify section semantics, compact sufficiency test (#14159)
- Documentation: tighten sandbox-patterns.md — remove structural noise, preserve all knowledge (#14161)
- Documentation: tighten serper.md (114→101 lines) — DRY curl headers, reorder by importance (#14188)
- Documentation: tighten turborepo.md (137→122 lines) (#14205)
- Maintenance: tighten bash-compat.md agent doc (105→77 lines) (#14221)
- Documentation: tighten axe-cli.md (114→102 lines) — merge buttons into keyboard section, compress code comments, remove redundant Quick Reference lines (#14266)
- Documentation: tighten smart-placement.md (90→79 lines) and deduplicate gotchas (87→72 lines) (#14301)
- Documentation: tighten hyperdrive-patterns.md — remove structural noise, preserve all knowledge (#14376)
- Documentation: tighten r2-gotchas.md — remove structural noise, merge common errors into sections (94→82 lines) (#14377)
- Documentation: tighten budget-analysis.md — remove structural noise, compress prose (63→50 lines) (#14396)
- Documentation: tighten pages-functions.md — compress prose, fix See Also links (57→49 lines) (#14432)
- Refactor: split _install_pulse_launchd into focused subfunctions (#14493)
- Documentation: tighten extraction-workflow.md prose without knowledge loss (#14506)
- Documentation: tighten es2016-es2017.md reference doc (#14508)
- Documentation: tighten Stagehand benchmark scripts agent doc (#14537)
- Documentation: tighten Amazon SES provider guide (GH#14007) (#14540)
- Documentation: tighten model-routing.md (135→111 lines, zero info loss) (#14555)
- Documentation: tighten services.md prose (7.6% byte reduction, zero knowledge loss) (#14556)
- Documentation: tighten app-dev-testing.md agent doc (131→115 lines) (#14563)
- Documentation: tighten ahrefs integration quick reference (#14568)
- Documentation: tighten email sequences framework agent doc (#14569)
- Documentation: tighten toon.md - remove redundant description line (#14583)
- Documentation: tighten durable-objects.md and fix broken internal links (#14584)
- Maintenance: tighten agent doc legal.md (128→86 lines) (#14597)
- Maintenance: merge cheatsheet-queries.md into queries.md, remove duplicate (#14600)
- Documentation: tighten LinkedIn Content Subagent agent doc (#14640)
- Documentation: tighten api-shield-patterns.md (127→101 lines) (#14641)
- Documentation: tighten browser-benchmark.md (125 → 86 lines) (#14667)
- Maintenance: tighten agent sources doc (#14684)
- Maintenance: tighten conversation starter prompt flow (#14689)
- Documentation: tighten mutations cheatsheet (65→56 lines) (#14691)
- Maintenance: tighten campaign launch checklist (#14699)

### Fixed

- add session-level account affinity to prevent cross-session token overwrites (t1714) (#15079)
- address PR #14278 review feedback on maintainer-gate.yml (#14443)
- handle missing paths during setup backup rotation (#14632)

## [3.5.543] - 2026-04-01

### Changed

- Maintenance: bump version to 3.5.542
- Maintenance: tighten content/editor.md agent doc (GH#14243) (#15064)

## [3.5.541] - 2026-04-01

### Changed

- Maintenance: add Claude CLI alignment comments to oauth-pool-helper.sh (#15063)

## [3.5.540] - 2026-04-01

### Changed

- Maintenance: update simplification state

### Fixed

- break orphaned-assignment deadlock and fix silent prefetch failures (GH#15060) (#15058)

## [3.5.539] - 2026-04-01

### Changed

- Maintenance: claim t1713
- Documentation: tighten agent doc Git Worktree Workflow (#14816)
- Maintenance: claim t1712
- Documentation: tighten security-deps command doc (GH#14991)
- Documentation: tighten memory-audit.md command doc (52→32 lines)
- Documentation: tighten email-design-test.md (110 → 53 lines)
- Documentation: tighten glm-ocr.md agent doc (GH#14181)
- Maintenance: tighten Cloudflare Zaraz agent doc (110→102 lines)
- Documentation: tighten xcodebuild-mcp.md agent doc
- Documentation: tighten cold-outreach.md agent doc
- Documentation: tighten feature.md agent doc (112->80 lines, 11% byte reduction)
- Documentation: tighten self-improvement.md agent doc (GH#14450)
- Documentation: tighten landing page structure framework (GH#14845)
- Documentation: tighten GEO strategy guidance (GH#14842)
- Documentation: clarify skill-scanner security override (GH#14833)
- Documentation: tighten skill-scanner agent doc (GH#14833)
- Documentation: tighten api-integrations.md — fix broken links, consolidate redundant columns
- Documentation: tighten ddos-gotchas.md (116 -> 94 lines, 8% byte reduction)
- Documentation: tighten dspyground.md agent doc (116 → 105 lines)
- Documentation: tighten workers-ai.md (116 -> 15 lines, 87% reduction)
- Documentation: tighten youtube-script.md command doc (61→49 lines)
- Maintenance: record Playwright doc simplification state
- Documentation: tighten playwright.md quick reference
- Maintenance: track GH#14295 simplification state
- Documentation: align email sequence pattern references
- Documentation: tighten api-key-management.md (122 → 54 lines, 56% reduction)
- Documentation: improve email sequence chapter navigation
- Documentation: tighten bot-management-patterns guidance
- Documentation: tighten and restructure Agents SDK gotchas (recheck)
- Documentation: tighten ranking-opportunities.md (123→91 lines)
- Documentation: tighten email-campaign.md (123→105 lines)
- Maintenance: tighten instantly.md agent doc (71→61 lines) (#14678)

### Fixed

- resolve broken aidevops CLI symlink and add to non-interactive setup (#15057)
- redirect _install_beads_node_tools() output to stderr

## [3.5.538] - 2026-03-31

### Changed

- Documentation: tighten model-specific subagent routing guide (#15012)

## [3.5.537] - 2026-03-31

### Changed

- Documentation: tighten cro-chapter-24.md from 123 to 54 lines (#14712)

## [3.5.536] - 2026-03-31

### Added

- clarify chromium debug routing handoffs (#15006)
- add chromium-debug-use skill and local CDP helper (#15007)

## [3.5.535] - 2026-03-31

### Added

- add chromium-debug-use skill and local CDP helper (#15007)

## [3.5.534] - 2026-03-31

### Changed

- Version bump and maintenance updates

## [3.5.532] - 2026-03-31

### Changed

- Documentation: tighten SRO Grounding agent doc (GH#14210) (#14919)
- Maintenance: claim t1711

## [3.5.531] - 2026-03-31

### Changed

- Documentation: tighten encryption stack overview (#14526)

## [3.5.530] - 2026-03-31

### Changed

- Version bump and maintenance updates


## [3.5.529] - 2026-03-31

### Changed

- Version bump and maintenance updates


## [3.5.528] - 2026-03-31

### Fixed

- count headless worker wrappers in pulse (#14955)

## [3.5.527] - 2026-03-31

### Changed

- Documentation: tighten LeadsForge agent doc (105→83 lines) (#14920)
- Maintenance: add chromium-debug-use follow-up planning

## [3.5.526] - 2026-03-31

### Changed

- Version bump and maintenance updates


## [3.5.525] - 2026-03-31

### Changed

- Maintenance: claim t1710
- Maintenance: claim t1709
- Maintenance: claim t1708
- Maintenance: claim t1707
- Maintenance: claim t1706

## [3.5.524] - 2026-03-31

### Changed

- Documentation: tighten Hyperdrive agent doc (GH#14399) (#14900)
- Documentation: tighten Socket MCP agent doc (#14882)
- Documentation: tighten fallback-chains.md agent doc (GH#14190) (#14878)

### Fixed

- harden deterministic pulse fill floor counts (#14840)

## [3.5.523] - 2026-03-31

### Changed

- Documentation: tighten Hyperdrive agent doc (GH#14399) (#14900)
- Documentation: tighten Socket MCP agent doc (#14882)
- Documentation: tighten fallback-chains.md agent doc (GH#14190) (#14878)

### Fixed

- harden deterministic pulse fill floor counts (#14840)

## [3.5.522] - 2026-03-31

### Changed

- Version bump and maintenance updates


## [3.5.521] - 2026-03-31

### Fixed

- backfill simplification state before complexity scan (GH#14841) (#14846)

## [3.5.520] - 2026-03-31

### Changed

- Version bump and maintenance updates


## [3.5.519] - 2026-03-31

### Changed

- Documentation: tighten worker-efficiency protocol prompt (GH#14810) (#14821)

## [3.5.518] - 2026-03-31

### Changed

- Documentation: tighten datasets.md agent doc wording (#14819)
- Documentation: tighten worker-efficiency-protocol.md (122→120 lines, 12% byte reduction) (#14723)
- Maintenance: tighten orbstack.md agent doc (121→75 lines) (#14746)
- Documentation: tighten datasets.md agent doc (121→101 lines) (#14754)
- Documentation: tighten email-verification.md agent doc (121 -> 95 lines) (#14757)
- Maintenance: tighten pre-edit.md agent doc (118 -> 80 lines) (#14778)
- Maintenance: tighten git-security.md agent doc (118 -> 95 lines) (#14780)
- Documentation: tighten skill-scanner.md (118 -> 98 lines) (#14784)
- Documentation: tighten geo-strategy.md agent doc (118 -> 106 lines) (#14785)
- Documentation: tighten heygen-skill.md index — remove verbose sections, use tables (#14786)
- Documentation: tighten list-todo.md (117 -> 62 lines) (#14793)
- Documentation: tighten landing-page-structure agent doc (117 -> 103 lines) (#14795)

## [3.5.517] - 2026-03-31

### Changed

- Documentation: tighten api-shield-gotchas.md (51 -> 46 lines) (#14776)

## [3.5.516] - 2026-03-31

### Changed

- Version bump and maintenance updates


## [3.5.515] - 2026-03-31

### Changed

- Version bump and maintenance updates


## [3.5.514] - 2026-03-31

### Changed

- Version bump and maintenance updates


## [3.5.513] - 2026-03-31

### Changed

- Documentation: tighten chore branch workflow guidance (#14722)
- Documentation: tighten workers-patterns.md — add context, deduplicate deployment commands (#14724)

## [3.5.512] - 2026-03-31

### Changed

- Version bump and maintenance updates


## [3.5.511] - 2026-03-31

### Changed

- Version bump and maintenance updates


## [3.5.510] - 2026-03-31

### Changed

- Version bump and maintenance updates


## [3.5.509] - 2026-03-31

### Changed

- Documentation: tighten bot-management-patterns.md (125→113 lines) (#14698)

## [3.5.508] - 2026-03-31

### Changed

- Version bump and maintenance updates


## [3.5.507] - 2026-03-31

### Changed

- Version bump and maintenance updates


## [3.5.506] - 2026-03-31

### Changed

- Maintenance: tighten Claude-Flow comparison doc (#14688)

## [3.5.504] - 2026-03-31

### Changed

- Maintenance: tighten aidevops-opencode plugin architecture doc (#14682)

## [3.5.503] - 2026-03-31

### Fixed

- restore Tabby profile sync on Python 3.9 (#14680)

## [3.5.502] - 2026-03-31

### Changed

- Maintenance: tighten jujutsu.md agent doc (125→90 lines) (#14665)

## [3.5.501] - 2026-03-31

### Changed

- Version bump and maintenance updates


## [3.5.500] - 2026-03-31

### Changed

- Version bump and maintenance updates


## [3.5.499] - 2026-03-31

### Changed

- Version bump and maintenance updates


## [3.5.498] - 2026-03-31

### Changed

- Version bump and maintenance updates


## [3.5.497] - 2026-03-31

### Changed

- Version bump and maintenance updates


## [3.5.496] - 2026-03-31

### Changed

- Version bump and maintenance updates


## [3.5.495] - 2026-03-31

### Changed

- Version bump and maintenance updates


## [3.5.494] - 2026-03-31

### Changed

- Version bump and maintenance updates


## [3.5.493] - 2026-03-31

### Changed

- Version bump and maintenance updates


## [3.5.492] - 2026-03-31

### Changed

- Version bump and maintenance updates


## [3.5.491] - 2026-03-31

### Changed

- Version bump and maintenance updates


## [3.5.490] - 2026-03-31

### Changed

- Version bump and maintenance updates


## [3.5.489] - 2026-03-31

### Changed

- Version bump and maintenance updates


## [3.5.488] - 2026-03-31

### Changed

- Version bump and maintenance updates


## [3.5.487] - 2026-03-31

### Changed

- Version bump and maintenance updates


## [3.5.486] - 2026-03-31

### Changed

- Version bump and maintenance updates


## [3.5.485] - 2026-03-31

### Changed

- Version bump and maintenance updates


## [3.5.484] - 2026-03-31

### Changed

- Version bump and maintenance updates


## [3.5.483] - 2026-03-31

### Changed

- Version bump and maintenance updates


## [3.5.482] - 2026-03-31

### Changed

- Version bump and maintenance updates


## [3.5.481] - 2026-03-31

### Changed

- Version bump and maintenance updates


## [3.5.480] - 2026-03-31

### Changed

- Version bump and maintenance updates


## [3.5.479] - 2026-03-31

### Changed

- Version bump and maintenance updates


## [3.5.478] - 2026-03-31

### Changed

- Version bump and maintenance updates


## [3.5.477] - 2026-03-31

### Changed

- Version bump and maintenance updates


## [3.5.476] - 2026-03-31

### Changed

- Documentation: tighten workerd.md — merge intro sections, compress to table, fix See Also links (52→34 lines) (#14538)
- Documentation: tighten workerd.md — merge intro sections, compress to table, fix See Also links (52→34 lines) (#14538)

### Fixed

- refill underfilled pulse slots during active monitoring (#14498)

## [3.5.475] - 2026-03-31

### Changed

- Version bump and maintenance updates


## [3.5.474] - 2026-03-31

### Changed

- Version bump and maintenance updates


## [3.5.473] - 2026-03-31

### Changed

- Version bump and maintenance updates


## [3.5.472] - 2026-03-31

### Changed

- Version bump and maintenance updates


## [3.5.471] - 2026-03-31

### Changed

- Documentation: restore explanatory intros in es2016-es2017.md (#14504)

## [3.5.470] - 2026-03-31

### Changed

- Version bump and maintenance updates


## [3.5.469] - 2026-03-31

### Changed

- Documentation: tighten AEO/GEO content pattern wording (#14496)

## [3.5.468] - 2026-03-31

### Changed

- Version bump and maintenance updates


## [3.5.467] - 2026-03-31

### Changed

- Maintenance: tighten aeo-geo-patterns.md headings and MD031 compliance (#14488)

## [3.5.466] - 2026-03-31

### Changed

- Version bump and maintenance updates


## [3.5.465] - 2026-03-31

### Changed

- Version bump and maintenance updates


## [3.5.464] - 2026-03-30

### Changed

- Documentation: tighten SKILL-SCAN-RESULTS.md — collapse duplicate scan rows, compress prose (68→37 lines) (#14417)

### Fixed

- address PR #14352 review feedback on agents-sdk-gotchas (#14461)

## [3.5.463] - 2026-03-30

### Changed

- Documentation: tighten mac.md — merge sections, remove structural noise (93→50 lines) (#14375)
- Documentation: tighten score-responses.md command doc (#14364)
- Documentation: tighten infraforge outreach agent guidance (#14353)
- Documentation: tighten Agent SDK gotchas guidance (#14352)
- Documentation: tighten sandbox.md — merge architecture into header, fix broken links (GH#14293) (#14299)
- Documentation: tighten workerd-patterns.md — add context line, fix broken link (#13991)
- Documentation: tighten meta-ads-creative-frameworks.md headings and structure (GH#13965) (#13997)
- Documentation: tighten CQRS & Domain Events agent doc (191→183 lines) (#14000)
- Documentation: tighten campaign launch checklist (175→144 lines) (#14004)

### Fixed

- clear expired cooldowns during pool reads (#14341)
- preserve multiline health dashboard sections (#11001) (#14328)
- reduce secret scan and npm audit noise (#14255)
- add null-safety for missing .mcp key in migrations.sh (GH#14220) (#14237)

## [3.5.462] - 2026-03-30

### Fixed

- tolerate missing mcp object in jq migration (#14244)

## [3.5.461] - 2026-03-30

### Fixed

- guard legacy overwrite helper usage (#14236)

## [3.5.460] - 2026-03-30

### Changed

- Version bump and maintenance updates


## [3.5.459] - 2026-03-30

### Fixed

- harden unattended worker progress under provider limits (#14219)

## [3.5.458] - 2026-03-30

### Changed

- Documentation: tighten langflow.md (162→153 lines) — DRY install steps, merge API sections, proper autolinks (#14187)

## [3.5.457] - 2026-03-30

### Changed

- Documentation: tighten onboarding wizard guide for GH#13999 (#14141)

## [3.5.456] - 2026-03-30

### Added

- seed mission-control init and improve self-activity triage (#14126)

### Changed

- Documentation: tighten sales emails analysis language (#14139)
- Documentation: tighten ahrefs.md (114→109 lines) — DRY auth headers, reorder by importance (#14140)
- Documentation: tighten postgres-drizzle-skill.md (160→88 lines, 45% reduction) (#14113)
- Maintenance: claim t1705

## [3.5.455] - 2026-03-30

### Changed

- Documentation: tighten voice-ai-models.md (154→147 lines) — compress Pick lines, collapse GPU table, remove formatting noise (#14038)
- Documentation: tighten hexagonal.md 183→181 lines, zero information loss (GH#13970) (#13986)
- Documentation: tighten pages-functions-patterns.md (173→171 lines) (#13990)
- Documentation: tighten playwright-emulation.md prose and structure (#13987)
- Documentation: tighten Higgsfield UI Automator agent doc (#13988)
- Documentation: add star history chart to README
- Maintenance: release v3.5.454
- Documentation: tighten hexagonal.md 186→183 lines, zero information loss (GH#13933) (#13957)
- Maintenance: tighten workerd-patterns.md, remove redundant prose (#13960)
- Documentation: tighten playwright-emulation.md (GH#13935) (#13952)

### Fixed

- restore automatic OpenCode session title sync (#14074)

## [3.5.443] - 2026-03-30

### Changed

- Maintenance: update marketplace.json for v3.5.442
- Maintenance: release v3.5.442
- Maintenance: bump version to 3.5.442
- Documentation: tighten pages-functions-patterns.md (182→178 lines) (#13929)

## [3.5.438] - 2026-03-30

### Changed

- Version bump and maintenance updates


## [3.5.410] - 2026-03-30

### Changed

- Maintenance: bump version to 3.5.407
- Documentation: tighten mission-orchestrator.md — merge duplicate dispatch blocks, normalize unicode, compress prose (#13841)
- Documentation: tighten email-composition.md — remove structural noise and redundancy (158 → 144 lines) (#13837)

## [3.5.373] - 2026-03-30

### Changed

- Maintenance: bump version to 3.5.372
- Documentation: GH#13581: tighten pages-patterns.md, remove redundant prose (#13595)

## [3.5.369] - 2026-03-30

### Changed

- Documentation: tighten pdf/overview.md (149→74 lines, remove redundant prose/examples) (#13510)
- Maintenance: bump version to 3.5.368
- Documentation: tighten email-providers.md (165→157 lines) (#13570)
- Documentation: tighten fly-io.md agent doc (GH#13579, 140→135 lines) (#13596)

## [3.5.366] - 2026-03-30

### Changed

- Maintenance: release v3.5.365
- Maintenance: update simplification state registry
- Maintenance: release v3.5.364
- Documentation: tighten fly-io.md agent doc (GH#13556, 151→140 lines) (#13563)
- Documentation: tighten services.md prose — compress verbose phrasing, preserve all content (#13529)
- Documentation: tighten sql-migrations.md (205 → 197 lines, add no-tx convention) (#13485)
- Documentation: tighten production-audio.md (151→139 lines, remove redundant pipeline block/checklist) (#13490)
- Maintenance: tighten humanise.md - compress YAML description and remove redundant inline example (#13522)
- Documentation: tighten management.md Quality Management Specification (GH#13060) (#13528)
- Maintenance: GH#12987 tighten bing-webmaster-tools.md (163→108 lines) (#13537)
- Maintenance: release v3.5.363
- Maintenance: update simplification state registry
- Documentation: tighten aidevops-opencode plugin architecture doc (165→109 lines) (#13553)
- Maintenance: update simplification state registry
- Maintenance: bump version to 3.5.361
- Maintenance: release v3.5.360
- Maintenance: GH#12978 tighten dns-providers.md agent doc (164→141 lines) (#13548)
- Maintenance: GH#12981 tighten wiki-update workflow doc (#13541)
- Documentation: tighten smime-setup.md agent doc (GH#12979) (#13546)
- Documentation: GH#12989: tighten Advantage+ Campaigns agent doc (#13535)
- Maintenance: release v3.5.356
- Maintenance: release v3.5.355
- Maintenance: release v3.5.354
- Documentation: tighten email-health-check.md (149→133 lines) (#13487)
- Documentation: tighten browser-automation.md — merge intro lines, remove misplaced setup ref (140→136 lines) (#13488)
- Documentation: tighten email-testing.md (149→128 lines) — merge CSS/engine tables, drop redundant tool comparison (#13491)
- Documentation: tighten pages-patterns.md (149→132 lines, flatten Best Practices subsections) (#13492)
- Maintenance: release v3.5.353
- Documentation: tighten autogen.md (148→140 lines) (#13493)
- Maintenance: release v3.5.352
- Documentation: tighten production-audio.md (151→139 lines, remove redundant pipeline block/checklist) (#13478)
- Documentation: tighten security-analysis.md — merge MCP section into Integrations (151→142 lines) (#13467)
- Documentation: tighten imessage.md (155→148 lines) (#13468)
- Documentation: tighten migration.md (197→165 lines, remove redundant phase table/mapping dupes) (#13466)
- Maintenance: update simplification state registry
- Maintenance: tighten cro-chapters.md index (GH#13398) (#13457)

## [3.5.362] - 2026-03-30

### Changed

- Maintenance: update simplification state registry
- Maintenance: bump version to 3.5.361

## [3.5.358] - 2026-03-30

### Changed

- Documentation: GH#12989: tighten Advantage+ Campaigns agent doc (#13535)

## [3.5.357] - 2026-03-30

### Changed

- Maintenance: release v3.5.356

## [3.5.353] - 2026-03-30

### Changed

- Documentation: tighten flowcharts.md (161→134 lines, -17%, GH#13174) (#13523)

## [3.5.344] - 2026-03-30

### Changed

- Documentation: tighten architecture.md prose (157→124 lines, zero knowledge loss) (#13445)
- Documentation: tighten session-manager.md (135→105 lines, GH#13438) (#13443)
- Documentation: tighten ai-writing-detection.md prose (GH#13423) (#13444)
- Documentation: tighten security-analysis.md agent doc (164→151 lines) (#13442)

## [3.5.339] - 2026-03-30

### Changed

- Maintenance: release v3.5.338

## [3.5.335] - 2026-03-30

### Changed

- Documentation: tighten image-seo.md — collapse duplicate batch workflow (151→133 lines) (#13424)
- Documentation: tighten cloudron-app-publishing-skill.md (150→111 lines, 26% reduction) (#13426)
- Maintenance: tighten content/optimization.md agent doc (148→135 lines) (#13425)
- Documentation: GH#13128: tighten session-manager.md (156→135 lines) (#13412)
- Documentation: tighten autogen.md — remove redundant prose, trim verbose comments (#13417)
- Maintenance: tighten agent-testing.md (151→138 lines) (#13416)

## [3.5.332] - 2026-03-30

### Changed

- Documentation: tighten architecture.md prose (164→157 lines, zero knowledge loss) (#13407)

## [3.5.319] - 2026-03-29

### Changed

- Documentation: tighten Favicon Debugger agent doc prose (#13302)
- Maintenance: release v3.5.318
- Documentation: tighten programmatic-seo.md prose (GH#13239) (#13301)
- Documentation: GH#13240 tighten cro-chapter-01.md prose (145→117 lines, all knowledge preserved) (#13294)

### Fixed

- add signature footer gate to plugin quality hooks (GH#12805) (#13303)

## [3.5.318] - 2026-03-29

### Fixed

- add signature footer gate to plugin quality hooks (GH#12805) (#13303)

## [3.5.314] - 2026-03-29

### Changed

- Documentation: GH#13238 tighten app-dev-backend.md prose (145→113 lines) (#13293)
- Documentation: tighten ios-simulator-mcp.md prose (142→121 lines, GH#13264) (#13299)
- Documentation: GH#13246 tighten d1-patterns.md prose (#13296)
- Documentation: GH#13245: tighten context-builder.md prose (144→130 lines) (#13297)
- Documentation: tighten workers-for-platforms-gotchas.md prose (141→115 lines) (#13291)
- Documentation: tighten email-design-test.md prose (GH#13272) (#13292)

### Fixed

- preserve aidevops plugin registration in opencode.json (#13298)

## [3.5.312] - 2026-03-29

### Changed

- Refactor: separate universal prompt rules from aidevops-specific guidance (#13228)
- Maintenance: update simplification state registry

## [3.5.311] - 2026-03-29

### Changed

- Maintenance: update simplification state registry

### Fixed

- use atomic JSON writes to prevent config truncation on crash (#13181)

## [3.5.297] - 2026-03-29

### Changed

- Documentation: tighten architecture.md prose without knowledge loss (#13116)

### Fixed

- show elapsed time and 0 tokens for pulse bash routine (GH#13099) (#13117)

## [3.5.281] - 2026-03-29

### Changed

- Documentation: tighten image-understanding.md — merge redundant model tables, fold Gemini note into comment (#13068)

## [3.5.277] - 2026-03-29

### Fixed

- reject non-project dirs, add --no-session for standalone callers (GH#13046) (#13058)

## [3.5.274] - 2026-03-29

### Changed

- Maintenance: release v3.5.273
- Documentation: tighten code-simplifier.md agent doc (200→198 lines) (#13033)

### Fixed

- Linux compat — remove PPID gate, broaden session detection, robust version (GH#13012) (#13021)

## [3.5.270] - 2026-03-29

### Changed

- Documentation: tighten compare-models.md (189→172 lines, GH#12852) (#13017)
- Documentation: GH#12688: tighten ad-creative-chapter-09.md (#13015)

## [3.5.147] - 2026-03-29

### Changed

- Maintenance: update simplification state registry

### Fixed

- add zero-agent guard to prevent OpenCode crash (#12615)

## [3.5.1] - 2026-03-28

### Fixed

- detect stale Homebrew install during aidevops update (GH#11470) (#12106)

## [3.5.0] - 2026-03-28

### Changed

- Refactor: flatten remaining nested dirs in tools/ (#12107)

## [3.4.193] - 2026-03-28

### Changed

- Refactor: flatten remaining nested dirs in tools/ (#12107)

## [3.4.0] - 2026-03-28

### Changed

- Refactor: merge Social-Media into Content, Sales+Marketing into Marketing-Sales (#11372)
- Maintenance: update simplification state registry

## [3.3.0] - 2026-03-28

### Changed

- Refactor: merge Video into Content, Accounts into Business (#11347)
- Documentation: tighten opencode-github.md from 328 to 192 lines (41% reduction) (#11349)
- Refactor: merge Video into Content, Accounts into Business

## [3.2.9] - 2026-03-28

### Changed

- Refactor: complete .agents/ structure cleanup (#11304)
- Documentation: simplify UGC & Video Scripts agent doc (439→350 lines) (#11297)
- Maintenance: update simplification state registry

## [3.2.7] - 2026-03-28

### Fixed

- always clean stale files during agent deployment (#11288)

## [3.2.0] - 2026-03-28

### Changed

- Version bump and maintenance updates


## [3.1.442] - 2026-03-28

### Changed

- Maintenance: raise simplification open-issue cap from 100 to 500 (#11272)
- Refactor: reorganise .agents/ structure for scalability (#11127)
- Maintenance: raise simplification scan rate from 5 to 200 issues per run (#11126)
- Documentation: codify .agents/ architecture conventions for scalability (#11124)

### Fixed

- run complexity scan every pulse cycle (15 min) instead of daily (#11271)

## [3.1.439] - 2026-03-28

### Fixed

- wire cross-machine claim lock into deterministic dedup guard (GH#11086) (#11121)

## [3.1.315] - 2026-03-27

### Fixed

- remove 500-line size gate from md simplification scan (t1679) (#6879)

## [3.1.310] - 2026-03-27

### Changed

- Refactor: terse pass on build.txt and AGENTS.md — compress prose without losing rules (#6868)

## [3.1.289] - 2026-03-27

### Added

- add Tabby terminal profile generator from repos.json (#6786)

## [3.1.154] - 2026-03-25

### Changed

- Version bump and maintenance updates


## [3.1.106] - 2026-03-25

### Added

- extend complexity scan to .md agent docs, daily interval, longest-first (#5693)

### Fixed

- clarify advisory output string concatenation (PR #5689 follow-up) (#5691)
- key commands shows 'aidevops security' not 'aidevops security scan'

## [3.1.104] - 2026-03-25

### Changed

- Documentation: add asc-cli dependency check and update web apps section (#5690)

## [3.1.94] - 2026-03-24

### Changed

- Refactor: reduce function complexity in oauth-pool-helper.sh (GH#5643) (#5654)

## [3.1.89] - 2026-03-24

### Changed

- Refactor: disable proactive refresh, keep as commented-out option (#5613)

## [3.1.88] - 2026-03-24

### Fixed

- handle 401/403 (server-side token revocation) in OAuth pool with auto-refresh (#5612)

## [3.1.80] - 2026-03-23

### Changed

- Maintenance: add OpenCode to NPM_TOOLS with bun/npm auto-detection (#5570)

### Fixed

- add cooldown check to oauth-pool fallback account selection (#5552) (#5567)

## [3.1.79] - 2026-03-23

### Fixed

- inject OAuth tokens via env vars — works on all OpenCode versions (#5561)

## [3.1.78] - 2026-03-23

### Added

- add aidevops opencode-sandbox command for isolated version testing (#5548)

## [3.1.77] - 2026-03-23

### Changed

- Maintenance: pin OpenCode to 1.2.27 — versions >1.2.27 break OAuth (#5547)

## [3.1.76] - 2026-03-23

### Fixed

- Homebrew wrapper prefers git repo aidevops.sh over installed snapshot (#5545)

## [3.1.75] - 2026-03-23

### Fixed

- correct OAuth setup docs — opencode auth login is API key only (#5544)

## [3.1.74] - 2026-03-23

### Fixed

- npm wrapper prefers git repo aidevops.sh over bundled copy (#5543)

## [3.1.73] - 2026-03-23

### Changed

- Maintenance: remove opencode-antigravity-auth plugin on update (#5542)

## [3.1.72] - 2026-03-23

### Fixed

- pool injection idle status + headless dispatch timing race (#5541)
- restore cmd_rotate (auth.json), cmd_status, cmd_assign_pending lost in PR #5535 merge (#5536)

## [3.1.71] - 2026-03-23

### Changed

- Documentation: mention @auth-troubleshooting agent and free model fallback in README (#5539)

## [3.1.70] - 2026-03-23

### Changed

- Refactor: move auth troubleshooting to subagent, pointer in AGENTS.md (#5538)

## [3.1.69] - 2026-03-23

### Added

- add status/assign-pending commands and auth troubleshooting docs (#5537)

## [3.1.68] - 2026-03-23

### Added

- add aidevops model-accounts-pool CLI command with rotate and reset-cooldowns (#5535)

## [3.1.63] - 2026-03-22

### Added

- add process-approved command to draft-response-helper

### Changed

- Maintenance: claim t1556

### Fixed

- use post-action timestamp for self-consumption loop guard (#5518)
- capture gh api error output in draft-response subscription warning (GH#5511) (#5514)
- simplify draft_responses feature flag to default-true pattern (GH#5508) (#5513)
- simplify draft_responses feature flag check per Gemini review (GH#5492) (#5500)
- remove unused print_error stub from test-migrate-orphaned-supervisor.sh (#5501)

## [3.1.56] - 2026-03-22

### Changed

- Documentation: update browser-use doc to v0.12.x API (Tools, CLI, Cloud, ChatBrowserUse) (#5463)

### Fixed

- skip launchd plist reload when content unchanged to preserve StartInterval timers (#5464)

## [3.1.55] - 2026-03-22

### Fixed

- detect default branch for profile repo push instead of hardcoding main (#5462)

## [3.1.43] - 2026-03-21

### Changed

- Performance: hoist statusOrder constant to module scope in provider-auth (#5435)
- Refactor: simplify open_browser() with for-loop over browser commands (#5410)

### Fixed

- re-enable auth hook as single object (not array) (#5444)
- store claudebar release URL in variable for maintainability (#5434)

## [3.1.42] - 2026-03-21

### Added

- add ClaudeBar to setup and upstream watch (#5420)

### Changed

- Maintenance: fix spelling optimisation→optimization in social-media.md (#5414)

### Fixed

- sync TOON plan status/phase with human-readable Completed headers (#5421)
- use jq // empty and remove 2>/dev/null on repos.json reads (#5417)
- harden unknown status sorting and remove dead constants in provider-auth (#5412)
- robust Status-line lookup in sync_plans_status (GH#5392) (#5411)
- use // empty in jq to eliminate null string check (GH#5385) (#5419)

## [3.1.41] - 2026-03-21

### Fixed

- install profile update job whenever gh is available, not only when profile repo exists (#5409)

## [3.1.40] - 2026-03-21

### Added

- auto-configure opencode-cursor-oauth plugin in setup (#5408)

### Fixed

- use conventional FIXME tag for disabled auth hook workaround (#5400)

## [3.1.38] - 2026-03-21

### Added

- add Cursor support to oauth-pool-helper.sh and /models-pool-check (#5384)

### Changed

- Documentation: add routing rules and provider-explicit examples to models-pool-check (#5379)

### Fixed

- address remaining CodeRabbit findings from PR #5375 (#5377)

## [3.1.37] - 2026-03-21

### Changed

- Documentation: rewrite /models-pool-check for zero-knowledge UX (#5376)

## [3.1.36] - 2026-03-21

### Added

- shell-based OAuth pool management and stale provider name fix (#5375)

## [3.1.35] - 2026-03-21

### Changed

- Version bump and maintenance updates


## [3.1.34] - 2026-03-21

### Added

- /models-pool-check command, fix pool model names, post-auth guidance (#5373)

## [3.1.33] - 2026-03-21

### Added

- add Cursor CLI to setup and tool version checks (#5361)

### Changed

- Maintenance: mark t1549 and t1550 as completed (PRs #5367, #5369 merged)
- Documentation: add model tier and auto-dispatch default guidance to Planning section (#5368)

### Fixed

- dynamic OAuth User-Agent detection and curl-based token endpoints (#5371)
- make profile update self-healing when repos.json entry is missing (#5372)
- remove job name field so check name matches branch protection (GH#5365) (#5366)

## [3.1.32] - 2026-03-21

### Changed

- Maintenance: add #auto-dispatch to t1549 and t1550 for pulse pickup
- Maintenance: add model tiers to t1549 (opus) and t1550 (sonnet)
- Maintenance: add Cursor OAuth pool and model routing tasks (t1549, t1550)

### Fixed

- show clean placeholder when profile stats have no local data (#5360)

## [3.1.30] - 2026-03-21

### Changed

- Maintenance: archive completed plans from PLANS.md and add cleanup helper (#5355)

### Fixed

- make profile README init resilient to missing repos and stale entries (#5358)
- revert plans-cleanup, add maintainer gate, label protection, and PLANS.md auto-sync (#5357)

## [3.1.28] - 2026-03-20

### Changed

- Refactor: relocate browser-extension-dev and mobile-app-dev out of agents root (#5353)

## [3.1.27] - 2026-03-20

### Fixed

- add role identity to 8 primary agents to prevent task declination (#5352)

## [3.1.26] - 2026-03-20

### Fixed

- add role identity to Social-Media agent to prevent task declination (#5351)
- deduplicate OpenCode plugin registration block in mcp-setup.sh (#5349)
- address CodeRabbit and Gemini review findings in oauth-pool.mjs (#5341)
- align opencode anthropic auth docs with versioned guidance (#5332) (#5343)
- use jq for version parsing instead of grep (#5338)
- harden oauth callback error handling (#5342)
- mcp-setup.sh version parsing and comparison efficiency (#5339)

## [3.1.25] - 2026-03-20

### Fixed

- OAuth pool unknown email handling — pending token flow and provider visibility (#5337)

## [3.1.24] - 2026-03-20

### Changed

- Maintenance: mark t1548 complete (pr:#5324 completed:2026-03-20) [skip ci]

### Fixed

- add local callback server for OpenAI OAuth redirect (#5325)

## [3.1.23] - 2026-03-20

### Changed

- Maintenance: reopen t1548 — worker PR broke auth with array, needs single-hook fix

### Fixed

- add dummy models to pool providers so they appear in Ctrl+A

## [3.1.22] - 2026-03-20

### Fixed

- use single auth hook — OpenCode 1.2.27 crashes on auth arrays

## [3.1.20] - 2026-03-20

### Changed

- Maintenance: add t1548 — OpenAI Pro multi-account pool rotation (ref:GH#5318)
- Maintenance: claim t1548

### Fixed

- derive session count threshold from system RAM instead of hardcoded 5

## [3.1.19] - 2026-03-20

### Added

- re-implement anthropic provider auth independent of bundled plugin

## [3.1.18] - 2026-03-20

### Added

- deploy primary-agent slash commands with Claude/OpenCode parity (#5316)

### Changed

- Refactor: OAuth pool injects tokens into built-in provider instead of custom fetch
- Maintenance: mark t1546 complete (pr:#5315 completed:2026-03-20) [skip ci]
- Maintenance: mark t1547 complete (pr:#5316 completed:2026-03-20) [skip ci]

## [3.1.17] - 2026-03-20

### Changed

- Documentation: fix cross-repo task creation workflow to prevent duplicate issues
- Maintenance: add issue refs for t1546 (GH#5311), t1547 (GH#5314)
- Maintenance: add t1546, t1547 — runtime parity tasks for Claude Code CLI + OAuth pool setup
- Maintenance: claim t1547
- Maintenance: claim t1546

## [3.1.16] - 2026-03-20

### Changed

- Tests: add regression for non-interactive Homebrew guard (#5307)

### Fixed

- clarify pulse scope decision heading (#5306)

## [3.1.0] - 2026-03-18

### Added

- pattern-driven model tier downgrade using historical success data (GH#5148) (#5156)
- add local email address verifier with RCPT TO probing and disposable domain detection (#5133) (#5135)
- add email address verification tasks (t1538, t1539)

### Changed

- Refactor: simplify dispatch example variable assignment (#5201) (#5207)
- Refactor: simplify off-peak guard in run_daily_quality_sweep (#5188)
- Maintenance: simplify redundant two-grep pipeline in loop-common.sh (#5183)
- Refactor: centralize CSV quoting in printf for email-export-helper (#5178)
- Maintenance: mark t1542 complete (pr:#5157 completed:2026-03-17) [skip ci]
- Maintenance: add t1542 TODO entry for GH#5155 orphaned archived scripts
- Maintenance: claim t1542
- Maintenance: claim t1541
- Maintenance: mark t1540 complete (pr:#5139 completed:2026-03-17) [skip ci]
- Maintenance: add t1540 TODO entry and brief for GH#5138 (workflow scope fix)
- Maintenance: claim t1540
- Maintenance: mark t1539 complete (pr:#5135 completed:2026-03-17) [skip ci]
- Maintenance: mark t1538 complete (pr:#5134 completed:2026-03-17) [skip ci]
- Documentation: t1538 research findings — Outscraper email_validation API coverage verified (#5134)
- Maintenance: claim t1539
- Maintenance: claim t1538

### Fixed

- quote default value in AGENTS_DIR parameter expansion (#5208)
- wp-helper.sh SSH commands silently failing due to argument concatenation (#5199)
- add fallback default for paths.agents_dir in dispatch example (#5196)
- extract last digit sequence from branch name for issue number (#5191) (#5194)
- address PR #5116 review feedback (#5187)
- simplify trailing newline check in ensure_trailing_newline() (#5186)
- use silent _has_crontab check in cmd_status to avoid redundant stderr (#5185)
- use exact label matching for status:blocked check in pulse-wrapper (#5184)
- expand tilde in HELPER variable assignment to prevent literal ~ in paths (#5182)
- comment out fullPage: true example in playwriter.md (#5181)
- use --argjson instead of printf pipe in backfill-closure-labels.sh (#5180)
- use precise 90-day window instead of ambiguous 'last quarter' (#5177)
- remove blanket 2>/dev/null suppression in migrate_orphaned_supervisor (GH#5159) (#5175)
- remove redundant empty-string check from is_framework_task() (#5174)
- add 14 orphaned archived scripts to cleanup_deprecated_paths() (#5157)
- add framework-issue-helper.sh to enforce self-improvement repo routing (GH#5149) (#5154)
- add structural enforcement for self-improvement repo routing (t1541) (#5152)
- extend screenshot size guardrails to all Playwright paths (GH#5143) (#5144)
- add terminal blocker detection to pulse dispatch logic (GH#5141) (#5142)
- add workflow scope to gh auth flow and pre-push detection (t1540) (#5139)
- use neutral PULSE_DIR to prevent session accumulation on pulse:false repos (#5137)

## [3.0.12] - 2026-03-16

### Changed

- Performance: gate daily quality sweep to off-peak hours (18:00-23:59 local) (#5131)
- Refactor: extract ensure_trailing_newline() to reduce duplication in aidevops.sh (#5120)

### Fixed

- scope /runners to specified items only, remove /pulse spec duplication (#5129)
- use aidevops config get paths.agents_dir in HELPER= dispatch examples (#5125)
- use dynamic agents_dir path for headless-runtime-helper.sh dispatch examples (#5124)
- replace hardcoded year with [year] placeholder in query-fanout-research.md (#5126)
- address PR #5087 review feedback (#5123)
- RFC 4180 quote all CSV fields in attachment manifest (GH#5114) (#5122)
- align -> arrows in tool stack summaries for readability (#5121)
- address PR #5014 review feedback on google-workspace.md (#5116)
- correct WPackagist acquisition year from 2026 to 2024 (#5118)
- use secretlint exit code instead of fragile regex in patch preflight (#5117)
- tighten awk regex patterns in list_active_worker_processes to reduce false positives (#5119)
- route /runners dispatch through headless-runtime-helper.sh (GH#5096) (#5099)
- backfill script — skip completed issues to avoid unnecessary API calls (#5097)

## [3.0.10] - 2026-03-16

### Added

- add Google Workspace CLI (gws) to setup and auto-update (#5083)

### Changed

- Documentation: add task briefs for t1534, t1535 Linux scheduler bugs
- Maintenance: add t1534, t1535 Linux scheduler bugs to TODO.md
- Maintenance: claim t1535
- Maintenance: claim t1534

## [3.0.9] - 2026-03-16

### Changed

- Documentation: add WP Composer as preferred alternative to WPackagist in wp-dev.md (#5078)

### Fixed

- patch release preflight scans only changed files instead of entire repo (#5082)
- ensure trailing newline in .gitignore before appending entries (#5080)

## [3.0.1] - 2026-03-15

### Changed

- Maintenance: mark t1491 complete (pr:#4931 completed:2026-03-15) [skip ci]
- Maintenance: add t1491 — Bash 3.2 config_get fix (GH#4929)
- Maintenance: claim t1491

### Fixed

- add sqlite3 to setup.sh required dependencies (#4935)
- replace Bash 4.0+ indirect expansion with eval for 3.2 compat (#4931)

## [3.0.0] - 2026-03-15

### Added

- model-level backoff in headless-runtime-helper.sh (#4927)
- bridge daily quality sweep to code-simplifier pipeline (t1490)

### Changed

- Maintenance: mark t1485 complete (pr:#4923 completed:2026-03-15) [skip ci]
- Documentation: add Knowledge Graph Routing pattern to agent design patterns
- Documentation: add TOON token-efficient serialisation to agent design patterns
- Documentation: refine founder tagline wording
- Documentation: add Open-Source to founder tagline
- Documentation: use 'Founded' instead of 'Created' for ongoing project
- Documentation: add creation date and author attribution to README
- Documentation: remove Windows Terminal from supported terminals list
- Maintenance: mark t1489 complete (pr:#4918 completed:2026-03-15) [skip ci]
- Documentation: audit README — update stale counts, add OpenCode+Claude positioning (#4922)
- Maintenance: mark t1488 complete (pr:#4919 completed:2026-03-15) [skip ci]
- Refactor: split seo-content-analyzer.py into focused modules (t1488) (#4919)
- Maintenance: mark t1487 complete (pr:#4914 completed:2026-03-15) [skip ci]
- Maintenance: mark t1486 complete (pr:#4915 completed:2026-03-15) [skip ci]
- Performance: tune worker RAM allocation — 512MB per worker, 6GB reserve (was 1GB/8GB)
- Maintenance: claim t1490
- Maintenance: add Codacy quality gate adjustment task (t1489)
- Maintenance: claim t1489
- Maintenance: claim t1488
- Maintenance: add module-split tasks for top 4 file-complexity smells (t1485-t1488)
- Maintenance: claim t1487
- Maintenance: claim t1486
- Maintenance: claim t1485
- Refactor: reduce Qlty smells in playwright-automator.mjs (batch 3c)
- Refactor: reduce Qlty maintainability smells (batch3c)
- Maintenance: claim t1484
- Refactor: reduce Qlty maintainability smells in OpenCode TS files (batch 3b)
- Refactor: reduce Qlty maintainability smells in Python scripts (batch 3a)
- Refactor: reduce Qlty maintainability smells in Python/JS scripts (batch 3a)

### Fixed

- correct tmux to cmux in supported terminals list
- add blank line between tagline quote and subtitle (#4924)
- tagline paragraph break and website badge globe icon (#4921)
- make pulse-wrapper.sh source-safe in zsh/supervisor sessions (GH#4904) (#4920)
- auto-assign issues on creation to prevent duplicate dispatch
- ensure simplification-debt labels exist before issue creation
- add comma thousands separators to token counts (e.g., 10,425.3M) (#4911)
- split footer text into separate paragraphs for readability (#4909)

## [2.173.0] - 2026-03-14

### Added

- add ripgrep (rg) to required dependencies in setup (#4892)

### Changed

- Documentation: add pulse model constraint to model-routing.md — sonnet only, openai unreliable for orchestration
- Documentation: note pulse supervisor requires Anthropic sonnet, OpenAI unreliable for orchestration

### Fixed

- remove ssh from required deps in setup-modules/core.sh (#4899)

## [2.172.29] - 2026-03-14

### Fixed

- add wrapper-level forced recycle when pulse LLM exits early while underfilled (#4620)
- remove 2>/dev/null from source to expose syntax errors (#4613)
- use install -d -m 700 for ~/.ssh directory creation (#4612)
- address quality-debt review feedback for vector-search.md (#4611)
- skip approval-only reviews in scan-merged to prevent false-positive issues (#4609)
- add explicit return 0 to get_domain() in eeat-score-helper.sh (#4608)
- make AI lock checks atomic (#4607)
- replace bash 4.0+ features with portable alternatives in 2 scripts (#4603)
- address PR #2326 review feedback on model-routing.md (#4598)
- resolve gemini review feedback on auto-verify logic (#4605)
- address PR #2255 review feedback on t1327-brief.md (#4594)

## [2.172.28] - 2026-03-14

### Fixed

- replace bash 4.0+ features with portable alternatives in 5 scripts (#4601)

## [2.172.27] - 2026-03-14

### Added

- enforce finding-to-task conversion for all multi-finding reports (#4593)

### Changed

- Maintenance: mark t1481 complete (pr:#4596 completed:2026-03-14) [skip ci]

### Fixed

- replace bash 4.2+ associative arrays with portable grep in worktree cleanup (#4592)
- use idiomatic parse_pr_url guard in state transition check (#4591)

## [2.172.22] - 2026-03-13

### Changed

- Maintenance: claim t1477
- Maintenance: address PR #353 review feedback (t3777) (#4437)

## [2.172.21] - 2026-03-13

### Changed

- Tests: guard worktree-first pre-edit guidance in release preflight (#2208)
- Maintenance: claim t1476
- Maintenance: claim t1475

## [2.172.20] - 2026-03-13

### Changed

- Maintenance: claim t1474

### Fixed

- align headless pre-edit wording with worktree guidance (#3193)

## [2.172.19] - 2026-03-13

### Changed

- Maintenance: claim t1473
- Maintenance: remove redundant jq identity pipe in cmd_usage (#4403)
- Maintenance: remove redundant env-var prefix in shell command examples (#4407)
- Refactor: deduplicate script version update path for release bumps (#4356)

### Fixed

- enforce worktree-first guidance in guardrails (#4443)
- address PR #163 review feedback on browser automation docs (#4439)
- address PR #364 gemini review — batch script guard + relative paths (#4438)
- two-layer dispatch dedup + earlier thrash detection (GH#4400) (#4441)
- address PR #352 review feedback — atomic DELETEs and env-var path (GH#3776) (#4440)
- use empty-string check for cert expiry date parse failure (GH#4275) (#4434)
- use .param set for FTS5 MATCH to prevent SQL injection (GH#3155)
- replace curl|sh with safer download-review-execute pattern (GH#3107)
- address GH#3147 quality-debt — regex injection hardening + remove 2>/dev/null suppressions
- use mktemp for secure temp file in build-mcp key injection example (GH#4267)
- use explicit uname check for stat mtime (GH#3513) (#4422)
- add PPID guard to emergency kill loop to protect interactive sessions (GH#3453) (#4421)
- group local declarations in auto-batch block (t3491) (#4426)
- clean up temp dispatch scripts after execution (GH#3497) (#4428)
- use mktemp instead of hardcoded /tmp path in build-mcp key injection example (#4417)
- remove non-existent status fields from chrome-webstore-release docs (GH#3693) (#4418)
- align crft-lookup.md commands and schema with tech-stack-helper.sh (#4423)
- use type -P for Continue.dev detection to avoid bash builtin false positive (GH#3452) (#4419)
- add EXIT trap for robust temp file cleanup on abrupt termination (GH#3560) (#4425)
- restore explicit phase list in ai-search-readiness description (GH#4266) (#4416)
- count all PRs (open+merged+closed) for daily cap (GH#4412) (#4415)
- restore phpdoc formatting in wordpress guide examples (#4414)
- address PR #4393 inline review suggestions in wappalyzer.md (#4408)
- use += to append to cleanup file registry (#4406)
- remove spaces in process substitution per gemini-code-assist review (#4405)
- add input/output label to opus cost pricing format (#4404)
- add parameterized SQLite queries to prevent SQL injection (GH#3527) (#4402)
- address PR #1955 review feedback (t3638) (#4401)
- add eval checkpoint cleanup to Phase 1c and Phase 4b (GH#3637) (#4398)
- elevate API key security note to blockquote (GH#3554) (#4397)
- address high-severity PR #1184 review findings (#4396)
- correct function counts and flag eval style violations in t316.1 (#4394)
- clarify opus cost multiplier with explicit pricing basis (GH#3569) (#4391)
- suppress SC1091 info in voice-helper.sh, verify tempfile security fixes (GH#3557) (#4379)
- add default case for invalid mode in coderabbit-cli.sh (GH#3520) (#4376)
- correct Grok model name to Grok Imagine in UI-only comment (#4377)
- add error handling for tty write and close operations (#4378)
- guard empty array expansions for Bash < 4.4 compat (GH#3544) (#4380)
- add error handling for TTY write and close failures (#4381)
- remove tautological 'SEO optimization' in accessibility.md (#4382)
- use process substitution for find loops (GH#3516) (#4383)
- harden against shell injection and prompt injection (#4388)
- correct misleading barge-in comment to accurately describe AEC limitation (#4385)
- document docker guard rationale, verify all HIGH findings from GH#3553 (#4386)
- replace eval with bash array in merge_task_pr (GH#3565) (#4389)
- separate preflight execution from output parsing (#4390)
- remove unused server_port param from generate_bot_template (#4375)
- filter unresolved threads by AI reviewer and surface API errors (GH#3585) (#4371)
- warn on insecure sshpass password file permissions (GH#3574) (#4372)
- add set -euo pipefail to routine-scheduler.sh (GH#3664) (#4373)
- guard jq failures to prevent skill-sources.json data loss (#4335)
- resolve critical quality-debt in email-health-check-helper.sh (#4336)
- document npm package unavailability and add setup instructions (#4337)
- add setup-modules/ to npm package files manifest (GH#3594) (#4339)
- use || true instead of || echo "" for grep guard in pulse.sh (GH#3679) (#4340)
- clarify SIGKILL/SIGTERM exit code mapping in portable_timeout (GH#3610) (#4341)
- improve health issue title command error handling (#4358)
- consolidate jq parsing in skill URL flow test (#4355)

## [2.172.18] - 2026-03-13

### Changed

- Maintenance: claim t1472

### Fixed

- recycle stale workers during severe pulse underfill (#4353)

## [2.172.17] - 2026-03-13

### Changed

- Maintenance: claim t1471

### Fixed

- adapt pulse cold-start timeout to underfill severity (#4352)

## [2.172.16] - 2026-03-13

### Changed

- Maintenance: claim t1470

### Fixed

- trim pulse prefetch issue payload to avoid cold-start stalls (#4350)

## [2.172.15] - 2026-03-13

### Fixed

- adapt stale pulse recovery timeout to underfill severity (#4348)

## [2.172.14] - 2026-03-13

### Changed

- Maintenance: claim t1469

### Fixed

- auto-generate release changelog when unreleased is empty

## [2.172.13] - 2026-03-13

### Changed

- Version bump and maintenance updates


## [2.172.12] - 2026-03-13

### Fixed

- normalize active issue assignment in pulse (#4345)
- preserve manual profile README sections during stats updates

## [2.172.11] - 2026-03-13

### Fixed

- resolve critical quality-debt in tech-stack.md (GH#3686) (#4331)
- replace PID file deletion with IDLE sentinel to close dedup race window (GH#4324) (#4332)
- add explicit return 0 to all success paths in wappalyzer-helper.sh (#4333)
- resolve critical quality-debt in wp-helper.sh (GH#3629) (#4334)
- add trap-guarded helper for mktemp in test-pr-task-check.sh (#4329)
- correct BigQuery HTTP Archive query to use UNNEST for technologies array (#4328)
- address PR #1497 review feedback in todo-sync.sh (GH#3695) (#4327)
- recycle stale pulse process when underfilled (#4326)

## [2.172.10] - 2026-03-13

### Changed

- Refactor: extract failure message helper in test-worker-sandbox-helper.sh (#4291)

### Fixed

- add file existence checks in session-miner to reduce file_not_found failures (#4321)
- harden JSON extraction in run_single_evaluator against braces in details (#4320)
- deploy from current worktree path instead of canonical main checkout (#4319)
- tighten pulse cold-start timeout when underfilled (#4323)
- replace echo pipe with herestring in email-delivery-test-helper.sh
- address CHANGES_REQUESTED review feedback on PR #4174
- address review feedback — grep -c accuracy, font-size threshold, ANSI stripping, backslash pattern
- prevent silent failure in secret-helper get_secret_value
- docs consistency, portability, and minor code improvements
- remove dead code, error suppression, and improve reliability
- base64-encode jq values to prevent shell injection in declare (#4316)
- replace grep|cut with while IFS= read loop for task_id parsing (#4289)
- allow dots in routine names per coderabbit suggestion (#4292)
- enforce browser QA vision size guardrails (#4310)
- verify and document GH#4271 quality-debt findings in stats-wrapper.sh (#4288)

## [2.172.9] - 2026-03-13

### Fixed

- avoid false pulse idle kills during cold start (#4312)

## [2.172.8] - 2026-03-13

### Changed

- Documentation: add turn-end claim discipline gate (#4306)
- Documentation: add unreleased notes for t1459 release

### Fixed

- auto-run contribution-watch backfill on low cadence
- add backfill safety-net mode to contribution-watch

## [2.172.7] - 2026-03-12

### Fixed

- reduce contribution-watch noise with notification filtering

## [2.172.6] - 2026-03-12

### Changed

- Version bump and maintenance updates


## [2.172.5] - 2026-03-12

### Changed

- Documentation: add remote MCP consumer configuration guide to build-mcp.md (#4247)
- Performance: consolidate multiple jq calls into single invocations (#4249)
- Refactor: extract run_freshness_checks(), replace silent || true with error logging

### Fixed

- correct phase count in ai-search-readiness.md description (#4246)
- add pipefail to codacy-collector SQL pipeline subshell (#4248)
- address quality-debt review feedback (#4221, #4222, #4224) (#4253)
- pass state file path instead of content to avoid Linux E2BIG (#4258)
- make safety policy check work without ripgrep
- enforce secret-safe worker command pipeline
- address quality-debt review feedback (#4225, #4226, #4224) (#4244)
- auto-block zero-commit worker thrashing (#4208)
- harden ai-research.ts OAuth token management
- detect unparseable certificate expiry dates in email-test-suite
- remove redundant null check in eval_dataset score guard
- apply Gemini review suggestions — contextual error logging for title view/edit (GH#3153)
- harden evaluator JSON extraction and simplify score guard
- parse open_prs_json once before loop to avoid O(n) re-parsing (GH#3153)
- remove blanket stderr suppression from gh calls in health issue update (GH#3153)
- address critical review feedback on ai-judgment-helper.sh (GH#3179)
- include install path in branch-switch error log
- clean working tree before branch-switch recovery
- auto-update recovery for dirty tree, diverged branch, and API rate limits

## [2.172.3] - 2026-03-12

### Fixed

- validate fallback secret input values
- clarify secret set terminal-only flow
- make qlty/codacy install fail-open in CI (GH#4216) (#4238)

## [2.172.2] - 2026-03-12

### Fixed

- count full-loop PR workers in pulse occupancy

## [2.172.1] - 2026-03-12

### Fixed

- add adaptive pulse queue-governor signals
- use Path.as_posix for thread index links (#4181)
- consolidate fail-closed scanner skip handling (#4210)
- correct NeuronWriter endpoint guidance (#4211)

## [2.172.0] - 2026-03-12

### Added

- add AI-search GEO/SRO specialist workflows

### Fixed

- address review feedback in AI-search docs
- narrow pulse worker matching to real issue runs

## [2.171.11] - 2026-03-12

### Fixed

- enforce pulse worker launch validation guidance
- add runtime auth failure fallback retry
- retry worker launches with same-cycle provider fallback
- reallocate pulse slots when product repos are capped

## [2.171.10] - 2026-03-11

### Fixed

- resolve SC2016 in stats GraphQL queries
- prevent GraphQL injection and add slug validation in stats-functions.sh
- test harness early exit and security posture stderr suppression
- propagate assert_contains failure exit code in recovery test
- remove stray "text" from code fence closing in build-agent.md

## [2.171.9] - 2026-03-11

### Fixed

- make pulse dispatch intelligence-first by default

## [2.171.8] - 2026-03-11

### Fixed

- scan explicit targets in secretlint preflight
- stream secretlint output in patch preflight
- auto-select working secretlint runtime for preflight
- fail closed on secretlint runtime errors in preflight

## [2.171.7] - 2026-03-11

### Changed

- Documentation: add unreleased notes for pulse dispatch fallback

### Fixed

- keep pulse productive when labels lag
- align conventional commit prefixes across loop docs (GH#3800)

## [2.171.6] - 2026-03-11

### Changed

- Documentation: add unreleased patch release changelog entries

### Fixed

- make patch preflight trap cleanup shellcheck-safe
- unblock patch release preflight from historical debt
- clarify pulse wrapper fallback warning
- improve pulse wrapper fallback observability
- harden aidevops update when brew or auth refresh fails
- keep pulse status and worker cap reporting aligned
- use GitHub API fallback for gh version check when brew unavailable

## [2.171.5] - 2026-03-11

### Fixed

- simplify session context JSON fallback handling
- address final session review feedback
- resolve remaining session review feedback
- align session context helper flags and fallbacks
- harden session review security summaries

## [2.171.0] - 2026-03-10

### Added

- add DNS exfiltration detection patterns (t1428.1, GH#4023) (#4045)
- add MCP tool description runtime scanning for prompt injection detection (#4031)

### Changed

- Documentation: add t1428 Grith-inspired security enhancements plan and brief
- Refactor: standardize on pre-increment ((++var)) across all shell scripts (#3972)
- Documentation: add t1426 task brief

### Fixed

- make skills-helper.sh discover symlinked skills in custom/skills/ (#4092)
- validate auto-detected PR number and harden sql_escape against newlines (GH#3706) (#4069)
- eliminate SQL injection vulnerabilities in sonarcloud-collector-helper.sh (GH#3710) (#4068)
- address critical quality-debt in codacy-collector-helper.sh (GH#3711) (#4067)
- address SQL injection, data corruption, and command injection in audit-task-creator-helper.sh (#4065)
- validate numeric inputs before SQL interpolation and preserve triage_result in migration (GH#3716) (#4062)
- harden SQL queries against injection in quality sweep scripts (GH#3719) (#4064)
- harden resolve_rebase_conflicts against indirect prompt injection (GH#3721) (#4059)
- refactor normalise_email_sections to fix quality-debt findings (#3701) (#4060)
- resolve quality-debt findings in email-thread-reconstruction.py (#4061)
- address quality-debt in real-video-enhancer-helper.sh (GH#3729) (#4058)
- remove stray :1 suffix and fix path style in enhancor.md (#4057)
- add robustness guards to Node.js version string parsing (#4056)
- harden todo-sync.sh against injection vulnerabilities (GH#3727) (#4055)
- namespace plugin template subagent name to avoid collisions (GH#3741) (#4054)
- address critical quality-debt in enhancor-helper.sh (GH#3731) (#4053)
- add prompt injection mitigations to OCR receipt extraction prompts (#4051)
- use canonical PyPI package name for extract-thinker (GH#3742) (#4049)
- add task_id input validation to prevent command injection (GH#3734) (#4050)
- correct broken code block fences and add PATH note in Playwriter docs (#4047)
- use backticks for code elements in graduated-learnings.md (#4048)
- resubmit 5 quality-debt fixes from closed batch PRs (#3974)
- address security findings in quickfile-helper.sh (GH#3736) (#4046)
- address quality-debt in memory-audit-pulse, test-memory-mail, route.md (GH#3983, GH#3771, GH#3765) (#4043)
- address quality-debt in compare-models.md, schema-validator-helper, marketing.md (GH#3764, GH#3760, GH#3753) (#4044)
- clarify dashboard.md output format inconsistencies (#4037)
- replace echo|bc pipes with bc here-strings in OCR test script (#4039)
- address PR #4020 review bot suggestions (#4022)
- make CI workflows resilient to fork PR permission limitations (#4017)
- make worker-lifecycle-common.sh set -e safe (GH#4010) (#4018)

## [2.170.2] - 2026-03-09

### Fixed

- revert incorrect anomalyco removal, add explicit marcusquinn/aidevops slug (#4014)
- address set -e incompatible error handling and blanket stderr suppression in worker-watchdog.sh (#4013)
- address 5 quality-debt findings from closed batch PRs (batch 3) (#3976)
- address 5 quality-debt findings (batch 4) (#3977)
- address 4 quality-debt findings in plugin-loader-helper.sh (#3978)
- remove blanket error suppression in OCR test pipeline (#3979)
- detect and redeploy stale agents in update pipeline (#4001)
- tool-version-check falls back to package.json for MCP servers that block on --version (#3973)
- resubmit 5 quality-debt fixes from closed batch PRs (batch 2) (#3975)
- remove anomalyco org name from system prompt and active code to prevent slug hallucination (#3999)

## [2.170.1] - 2026-03-09

### Changed

- Documentation: add changelog entry for screen time fallback fix

### Fixed

- screen time shows 0h when launchd job lacks Knowledge DB access (#3997)
- add top-level permissions to code-review-monitoring workflow (GH#3848) (#3850)
- validate $limit as positive integer to prevent SQL injection in quality-sweep-helper.sh (#3968)

## [2.168.1] - 2026-03-09

### Added

- add contribution-watch to monitor external issues/PRs for new comments (#3933) (#3943)

### Changed

- Documentation: add changelog entry for profile README review fixes

### Fixed

- address Gemini code review feedback on profile README generation (#3963)
- move SONAR_TOKEN to job-level env so if: conditions evaluate correctly (#3958)

## [2.168.0] - 2026-03-09

### Added

- generate rich profile READMEs with badges, repos, and contributions (#3962)

### Changed

- Documentation: add changelog entry for rich profile README feature

## [2.167.2] - 2026-03-09

### Changed

- Version bump and maintenance updates


## [2.167.1] - 2026-03-09

### Fixed

- improve worker session classification to reduce inflated interactive counts (#3957)
- security hardening — path traversal, injection, jq filter bug (batch 3) (#3877)
- HIGH quality-debt batch — logic bugs, exit codes, path typo, arg guards (#3947)

## [2.167.0] - 2026-03-09

### Added

- auto-create profile README for new users on setup (#3954)
- add cache savings column to AI model usage table (#3953)

## [2.166.0] - 2026-03-09

### Added

- add top apps by screen time percentage table to profile README (#3952)

## [2.159.0] - 2026-03-08

### Added

- add session time tracking to health dashboard (#3920)

### Changed

- Documentation: add changelog entry for session time tracking

## [2.156.0] - 2026-03-08

### Added

- add hygiene layer — stash cleanup, orphan worktree detection, stale PR triage (#3895)

## [2.154.5] - 2026-03-08

### Fixed

- expand version history for opencode-anthropic-auth changelog clarity (GH#3808) (#3825)
- pin sst/opencode/github action to v1.2.21 SHA for supply chain security (#3824)
- add daily PR creation cap to prevent CodeRabbit quota exhaustion (GH#3821) (#3822)
- escape all SQL-interpolated values in cache_get/cache_put (SQL injection) (#3676)
- address critical quality-debt from PR #152 review feedback (#3506)

## [2.154.4] - 2026-03-07

### Added

- add URL-based skill import to add-skill-helper.sh (#3139)
- add URL-based update checking for non-GitHub skills (t1415.2) (#3141)

### Changed

- Documentation: add changelog for shellcheck wrapper staleness fix (#3163)
- Documentation: add Convos encrypted messaging agent (t1414.1) (#3140)

### Fixed

- capture Tier 2 classifier stderr in cmd_classify_deep (#3144)
- update stale shellcheck wrapper during setup (#3163)
- prevent command injection in worker sandbox env generation (GH#3119) (#3123)
- address PR #3081 review feedback in sandbox-exec-helper.sh (#3129)
- prevent command injection in sandbox cleanup and add consistent error logging (#3130)
- remove silent error suppression in content-classifier-helper.sh (#3137)
- address quality-debt in network-tier-helper.sh from PR #3081 review (#3138)

## [2.154.3] - 2026-03-07

### Changed

- Documentation: add changelog for shellcheck auto-parallel (#3142)
- Performance: auto-detect CPU count for shellcheck concurrency limit (#3142)

## [2.154.2] - 2026-03-07

### Changed

- Documentation: add changelog for shellcheck resource management (#3136)
- Performance: add shellcheck concurrency limiter, debounce, and orphan reaper (#3136)

## [2.154.1] - 2026-03-07

### Changed

- Documentation: add changelog entries for shellcheck wrapper hotfix (GH#2915)

### Fixed

- replace shellcheck binary with wrapper to prevent memory explosions (GH#2915) (#3125)

## [2.154.0] - 2026-03-07

### Added

- add security-audit-sweep.sh and run cross-repo security audit (t1412.13) (#3100)
- add command logger helper for worker command auditing (t1412.5) (#3102)
- add network domain tiering for worker sandboxing (t1412.3) (#3081)
- add startup security posture check (t1412.6) (#3089)
- add worker sandbox for credential isolation (t1412.1) (#3080)
- enhance task-decompose-helper with context-aware classification and improved LLM prompts (#3091)
- add per-repo security posture checks to aidevops init (#3093)
- add scoped short-lived GitHub tokens for worker agents (t1412.2) (#3094)

### Changed

- Documentation: add MCP server install security warnings across all MCP docs and install flows (#3090)
- Documentation: recommend @stackone/defender for product-side injection defense (#3097)
- Documentation: t1412.13 includes per-repo AGENTS.md security section updates
- Documentation: add t1412.13 security audit sweep across managed repos
- Documentation: add StackOne Defender learnings to t1412 — framework + product-side
- Documentation: add t1412.11 per-repo security posture in aidevops init
- Documentation: expand t1412 with intelligence-layer scan, tamper-evident logging, CI/CD guidance, MCP warnings
- Documentation: add user-action requirements and startup security posture check (Phase 6) to t1412
- Documentation: add t1412 worker sandboxing task — credential isolation, network tiering, content trust boundaries

### Fixed

- pin all GitHub Actions to SHA and fix github.event injection risks (#3103)
- suppress SC2030 for intentional PATH modification in test subshells (#3051)
- bash 3.2 compatibility for dataset-helper.sh and align bench --dataset with dataset convention (#3079)
- address ShellCheck dead code warnings (SC2034, SC2317, SC2329) (#3077)
- correct t1412 brief to reference OpenCode throughout
- restore accurate Claude Code references in t1412 brief
- correct runtime identity references in t1412 brief (OpenCode, not Claude Code)
- align task-decompose-helper.sh invocations with actual API contract (#3042)
- use $path/TODO.md in pulse lineage examples instead of bare TODO.md (#3044)
- remove blanket stderr suppression and fix stream mixing in review-bot-gate-helper (#3039)
- correct documentation link paths in orchestration.md (#3036)
- resolve canonical model names in routing tiers output (#3032)
- add request-retry to review-bot-gate-helper for rate-limited bots (#3017)
- memory recall uses per-token quoting instead of phrase matching (#3064)
- move orphaned table rows back into Decision Table in headless-dispatch.md (#3065)

## [2.153.0] - 2026-03-07

### Added

- pulse CI failure pattern detection — identify systemic workflow bugs (#2979)

### Fixed

- replace ls -lh with stat-based human_filesize helper (SC2012) (#3059)
- resolve SC2034 unused variable warnings in test and agent scripts (#3060)
- add per-file SC2329 shellcheck disable directives with justification (#3061)
- replace sed with parameter expansion in email-signature-parser-helper.sh (#3055)
- remove unreachable return guard in generate-claude-commands.sh (SC2317) (#3054)
- export platform/repo constants to prevent recurring SC2034 (#3045) (#3046)
- remove incorrect format-lineage helper reference from headless-dispatch docs (#3043)
- pass title as positional arg to classify in new-task.md (#3041)
- remove 2>/dev/null from task decomposition bash examples (#3040)
- address high-severity quality-debt in batch-strategy-helper.sh (#3033)
- group consecutive redirects with { } >> file (SC2129) in setup-modules (#3015)
- remove unused PLATFORM_LINUX and annotate cross-file SC2034 variables (#3012)
- replace SC2015 A&&B||C antipatterns with if-then-else in mcp-setup.sh (#3011)
- review-bot-gate falls back to SUCCESS status checks when bots are rate-limited (#3006)

## [2.152.0] - 2026-03-06

### Added

- wire task decomposition into dispatch pipeline (t1408.2) (#2997)
- t1408.4 add batch execution strategies for task decomposition dispatch (#3000)
- t1407 check contributing guidelines before filing on external repos (#3001)
- t1408 recursive task decomposition for dispatch — plan, brief, and TODO entry
- add CI self-healing to pulse — re-run stale checks after workflow fixes merge (#2981)
- add CI failure pattern detection to pulse — detect systemic workflow bugs (#2976)

### Changed

- Refactor: extract session flag paths to script-level constants in pulse-wrapper.sh (#2978)
- Refactor: t1409 classify processes as app vs tool in memory-pressure-monitor (#2998)

### Fixed

- install memory pressure monitor via setup.sh for reboot survival (#2965)
- prevent orphaned processes from timeout_sec pipe to head in test_smtp (#2970)
- avoid orphaned processes from timeout_sec pipe to head on macOS (#2971)
- use character class grep pattern and escape dots in pulse-session-helper (#2977)
- pulse watchdog — add progress inspection, raise timeouts, reorder main() (#2991)
- remove blanket stderr suppression in cleanup_worktrees() (#3004)
- remove stderr suppression from jq calls in config-helper.sh (#3002)
- replace blanket 2>/dev/null with explicit file checks in shell-env.sh (#3003)
- calculate LLM cost from tokens — OpenCode does not provide msg.cost (#2972)
- review-bot-gate distinguishes rate-limit notices from real reviews (#2980) (#2982)
- resolve CI check failures on all PRs — regex false positive + concurrency (#2974)

## [2.151.6] - 2026-03-06

### Changed

- Version bump and maintenance updates

## [2.151.2] - 2026-03-05

### Added

- add session-based pulse control (aidevops pulse start/stop/status) (#2935)

### Fixed

- disable SC1091 globally and remove source-path=SCRIPTDIR from .shellcheckrc (#2939)
- require explicit consent for supervisor pulse installation (GH#2926) (#2936)

## [2.151.1] - 2026-03-05

### Fixed

- write SHELLCHECK_PATH to .zshenv for non-interactive shell coverage (#2937)
- config-helper.sh _jsonc_get discards false/0 values due to jq // empty (#2931)
- add timeout and hung-process detection to get_installed_version (#2932)

## [2.151.0] - 2026-03-05

### Fixed

- address 5 review findings on memory-pressure-monitor.sh from PR #2884 (#2930)
- sanitize process names in log output to prevent log injection (t1402) (#2908)
- harden ShellCheck fallback path — process group kill + missing warning (#2923)
- address quality-debt review feedback on pulse-wrapper.sh (t2892) (#2913)

## [2.150.0] - 2026-03-05

### Added

- add session count awareness to warn on excessive concurrent sessions (t1398.4) (#2883)
- add process-focused memory pressure monitor (t1398.5) (#2884)

### Changed

- Refactor: deduplicate CodeRabbit trigger logic in quality sweep (t1401) (#2887)
- Refactor: use array for trigger_reasons construction in pulse-wrapper.sh (t2856) (#2886)
- Refactor: collapse redundant jq severity elif/else branches (#2824)

### Fixed

- replace grep-based downgrade test with functional test (GH#2867) (#2889)
- remove stderr suppression from write_proof_log calls (t2865) (#2888)
- add process resource guard to pulse-wrapper.sh (t1398.1) (#2881)
- add pulse self-watchdog idle detection (t1398.3) (#2882)
- harden ShellCheck invocation to prevent exponential expansion (t1398.2) (#2885)
- replace kill -0 with ps -p and remove redundant 2>/dev/null in pulse-wrapper.sh (#2879)
- remove 2>/dev/null from db() calls in todo-sync.sh to preserve diagnostic stderr (#2880)
- remove blanket stderr suppression from db() call in todo-sync.sh (#2872)
- address critical quality-debt in sanity-check.sh (GH#2866) (#2870)
- add first-run guard and remove over-sensitive condition in CodeRabbit sweep trigger (#2852)
- add watchdog timeout to pulse-wrapper run_pulse() (t1397) (#2853)
- suppress auto-pickup in pulse --batch mode to prevent phantom batches (#2837) (#2843)
- skip batch tasks in Phase 0.6 reconcile-queue to prevent premature cancellation (#2844)
- prevent Phase 0.9 sanity check from resetting completed tasks to queued (t2838) (#2845)
- skip delta-based CodeRabbit triggers on first sweep run (t1392) (#2835)
- improve actionability of conversational memory lookup guidance (t1391) (#2830)
- use full URL with {slug} placeholder in wiki clone example (#2831)
- add busy_timeout to sqliteExec() preventing database locked errors (#2828)
- replace 2>/dev/null with --silent on gh api label POST calls (#2829)
- remove 2>/dev/null from gh pr view in check_external_contributor_pr (#2825)
- move external-contributor idempotency guard from prompt to shell function (t1391) (#2810)
- make CodeRabbit sweep conditional on quality gate changes (t1390) (#2808)
- rewrite pulse external-contributor idempotency guard to fail closed on API errors (#2803)
- use jq any() for robust pulse idempotency guard label check (#2801)

## [2.147.3] - 2026-03-01

### Added

- add Step 3.7 to pulse.md — act on quality review findings (#2638)

## [2.147.2] - 2026-03-01

### Fixed

- grep -c with || echo produces multiline output breaking arithmetic (#2637)
- replace Python 3.10+ union type syntax with Optional for 3.9 compat (#2635)

## [2.147.1] - 2026-03-01

### Added

- add Qlty CLI to setup.sh tool installation (#2633)

## [2.147.0] - 2026-03-01

### Added

- add daily multi-tool code quality sweep across all repos (#2631)

## [2.146.4] - 2026-03-01

### Changed

- Documentation: align git workflow docs with assignment and worktree conventions (#2630)

## [2.146.3] - 2026-03-01

### Fixed

- make dispatch dedup resilient to worker crashes across machines (#2629)

## [2.146.2] - 2026-03-01

### Fixed

- self-assign issues on dispatch, correct title pluralization (#2628)

## [2.146.1] - 2026-03-01

### Fixed

- health issue shows assigned count and unpins stale closed issues (#2626)

## [2.146.0] - 2026-03-01

### Added

- add pinned health issue dashboard per repo per runner (#2624)
- add orphaned PR scanner to supervisor pulse (t216) (#2622)
- enforce Task tool parallelism for independent subtasks in worker dispatch prompt (#2621)

### Fixed

- harden ampcode-cli.sh with array whitelists and safe arg handling (t105) (#2623)

## [2.145.1] - 2026-02-28

### Added

- cross-repo worktree cleanup with squash-merge detection (#2616)

## [2.145.0] - 2026-02-28

### Added

- wire parallel model verification into pipeline (t1364.3) (#2598)
- wire bundle config into dispatch, quality gates, and agent routing (t1364.6) (#2596)
- wire parallel model verification into pipeline (t1364.3) (#2580)
- add cross-provider verification agent and helper script (t1364.2) (#2576)
- define high-stakes operation taxonomy and verification triggers (t1364.1) (#2572)
- add /security-audit command for external repo security auditing (#2567)
- add automatic worktree cleanup for merged PRs (#2551)
- add mission email helper for 3rd-party communication (t1360) (#2553)
- add procurement agent for autonomous mission purchases (t1358) (#2550)
- replace hardcoded thresholds with AI judgment (t1363.6) (#2547)
- add entity memory architecture doc and integration tests (t1363.7) (#2545)

### Changed

- Documentation: add entity memory architecture doc, update memory README, add integration tests (t1363.7) (#2548)

### Fixed

- stop pulse from creating spam summary issues and duplicate task issues (#2615)
- add PATH normalisation to pulse for MCP shell compatibility (#2614)
- change shebang to #!/bin/bash in issue-sync scripts for headless PATH compatibility (#2611)
- replace dirname with parameter expansion in session-miner-pulse.sh (#2609)
- replace dirname with pure-bash parameter expansion in issue-sync scripts (#2603)
- prevent framework from leaving uncommitted changes in project repos (#2574)
- pass --interactive flag to aidevops-update-check.sh in AGENTS.md greeting (#2557)
- derive repo name from git remote URL instead of basename in cmd_init (#2549)

## [2.144.0] - 2026-02-28

### Added

- replace hardcoded thresholds with AI judgment (t1363.6) (#2539)
- add self-evolution loop for capability gap detection (t1363.4) (#2538)
- add mission-aware browser QA for milestone validation (t1359) (#2541)
- integrate entity system into Matrix bot (t1363.5) (#2537)

### Changed

- Refactor: replace .agents symlink with real directory scaffold in aidevops init (#2544)

## [2.142.1] - 2026-02-27

### Added

- add CI guard to auto-reopen issues with persistent label (#2489)

### Changed

- Performance: parallelise skill scanning and stub generation to fix update timeout (#2493)

### Fixed

- skip .gitignore modification for repos with tracked .agents/ directory (#2491)

## [2.142.0] - 2026-02-27

### Added

- add CI check for PR-issue linkage via closing keywords (#2486)

### Fixed

- scope TTSR read-before-edit rule to existing files only (#2487) (#2488)
- handle bare array format in pulse-repos.json migration (#2485)
- guard Rosetta detection against missing file command (t1354) (#2484)

## [2.141.0] - 2026-02-27

### Changed

- Documentation: add v2.141.0 changelog entries for release
- Documentation: add cross-repo task creation guidance to AGENTS.md and build.txt (#2483)
- Documentation: add Next.js stale lock file knowledge to local-hosting.md (#2482)

### Fixed

- remove state-diff gate from pulse wrapper (#2481)

## [2.140.0] - 2026-02-27

### Changed

- Documentation: add v2.140.0 changelog entries for release
- Documentation: add duplicate issue detection guidance to pulse agent (#2480)

## [2.139.1] - 2026-02-27

### Changed

- Documentation: add v2.140.0 changelog entries [skip ci]

### Fixed

- add Python >= 3.10 pre-check before cisco-ai-skill-scanner install (t1351) (#2472)

## [2.139.0] - 2026-02-27

### Added

- pre-fetch all repo state before pulse to prevent single-repo tunnel vision (#2471)

### Changed

- Documentation: move changelog entries to [Unreleased] for release script [skip ci]
- Documentation: add v2.139.0 changelog entries for pulse seed state [skip ci]
- Refactor: strengthen 'Intelligence Over Determinism' as core harness principle (#2467)
- Refactor: simplify pulse.md — 622 to 127 lines, trust intelligence over deterministic rules (#2465)

### Fixed

- replace arbitrary 5-minute time budget with 'run until done, then exit' (#2466)
- use full path scripts/commands/pulse.md in all agent references (#2459)
- add mandatory OPEN state check before dispatching workers (#2455)
- pulse should close open issues labelled status:done (#2456)
- add broader dedup search before fallback issue creation (#2447) (#2454)
- add local dev routing to Build+ Domain Expertise Check table (#2453)

## [2.138.0] - 2026-02-27

### Added

- add cross-repo TODO-to-issue sync in supervisor pulse (#2451)

### Changed

- Documentation: add Intelligence Over Scripts to system prompt and PR issue-linkage guidance (#2446)

### Fixed

- prevent worker issue hijacking and require cross-repo TODO commit+push (#2450)

## [2.137.0] - 2026-02-27

### Added

- add longform talking-head video pipeline with MiniMax TTS, VEED Fabric, and InfiniteTalk (#2445)

### Changed

- Refactor: merge pulse-repos.json into repos.json with slug field (#2448)

### Fixed

- add local_only field and support nested repo paths (#2449)
- strengthen webfetch error prevention guidance based on 46.8% failure rate analysis (#2444)
- always regenerate pulse plist on setup.sh upgrades (#2442)

## [2.135.1] - 2026-02-27

### Changed

- Version bump and maintenance updates

## [2.134.1] - 2026-02-27

### Changed

- Documentation: update model files from aidevops (t1133)

## [2.134.0] - 2026-02-26

### Added

- add install/serve/pull aliases and update subcommand to local-model-helper.sh (t1338.4) (#2395)
- finalize local-models subagent — integrate session nudge, fix stale markers (#2391)
- add advisory stuck detection for supervisor workers (t1332) (#2393)
- align local tier fallback to haiku and add local to routing table (t1338.1) (#2385)

### Changed

- Documentation: update model files from aidevops (t1133)
- Documentation: add Tier 3 scripts audit report (t1337.1) (#2397)
- Documentation: update model files from aidevops (t1133)
- Documentation: update model files from aidevops (t1133)

### Fixed

- skip update check in headless/non-interactive sessions (#2400)
- use jq -sr (raw output) in _count_usage_in_window to prevent JSON-quoted pipe-delimited output (#2389)
- use Linux-first stat format in matterbridge test permissions check (t1328) (#2387)

## [2.133.11] - 2026-02-26

### Changed

- Documentation: changelog for pulse scheduler setup guide
- Documentation: add pulse scheduler setup guide to runners.md — plist creation, reboot behavior, RunAtLoad (#2383)

### Fixed

- add blocker-chain validation, worker time budgets, and dependency chain ordering (#2382)

## [2.133.10] - 2026-02-26

### Changed

- Documentation: changelog for intelligence-driven worker assessment

### Fixed

- replace deterministic kill thresholds with intelligence-driven worker assessment (#2381)

## [2.133.9] - 2026-02-26

### Changed

- Documentation: changelog for tool check timeout fix

### Fixed

- add timeouts to npm/brew/pip queries to prevent update hangs (#2286) (#2380)

## [2.133.8] - 2026-02-26

### Added

- pulse auto-resolves blocked issues — checks blockers, unblocks when resolved, comments why (#2379)

### Changed

- Documentation: changelog for blocked issue resolution

## [2.133.7] - 2026-02-26

### Changed

- Documentation: changelog for headless greeting fix

### Fixed

- skip greeting/question in headless command sessions (pulse, full-loop) (#2377)

## [2.133.6] - 2026-02-26

### Added

- add prompt-guard-helper.sh for chat input injection defense (t1327.8) (#2374)
- add outbound leak detection at bot send boundary (t1327.9) (#2373)

### Changed

- Documentation: changelog for pulse autonomy v2 fix

### Fixed

- stronger autonomous execution enforcement in pulse — prevent report-and-stop pattern (#2376)

## [2.133.5] - 2026-02-26

### Added

- t1338.5 usage logging and disk management for local models (#2340)

### Changed

- Documentation: changelog for pulse autonomy fix and housekeeping

### Fixed

- enforce autonomous execution in pulse — never ask user for confirmation (#2368)
- add prevention rules for top 5 recurring error patterns (#2367)
- migrate repo-sync-helper.sh launchd label to sh.aidevops convention (#2365)

## [2.133.4] - 2026-02-26

### Changed

- Documentation: add changelog for pulse-repos.json and plist fix

### Fixed

- pulse.md reads repos from pulse-repos.json instead of hardcoding (#2361)

## [2.133.3] - 2026-02-26

### Added

- add usage logging and disk management for local models (#2358)

### Changed

- Documentation: add changelog entry for dispatch CLI fix

### Fixed

- enforce opencode run for headless dispatch — never use claude CLI (#2359)

## [2.133.2] - 2026-02-26

### Changed

- Documentation: add changelog entry for dedup script archival

## [2.133.1] - 2026-02-26

### Changed

- Documentation: add changelog entry for supervisor pulse guidance improvements

### Fixed

- Improve supervisor pulse guidance — dedup, blocked issues, stuck workers (#2350)

## [2.133.0] - 2026-02-26

### Added

- Add design principles checklist to UI verification workflow (#2349)

### Changed

- Documentation: add changelog entry for design principles

## [2.132.0] - 2026-02-26

### Added

- add agent-driven issue label lifecycle to full-loop and pulse (#2347)
- add UI verification workflow for design/layout tasks (#2346)
- auto-update TODO.md proof-log on PR merge (#2338)
- t1338.4 create local-model-helper.sh for llama.cpp inference management (#2334)
- add opus strategic review phase to supervisor pulse (t1340) (#2333)
- PR-merge triggered issue-sync for closing hygiene (t1339)

### Changed

- Documentation: recommend subscription plans over API billing for regular use (#2345)

### Fixed

- strategic review — add root cause analysis with dedup against existing work (#2339)
- strategic review — cross-repo discovery, action/TODO split, concurrency awareness (#2336)
- add --repo flag to gh CLI calls in PR-merge sync jobs

## [2.131.0] - 2026-02-25

### Added

- add structural thinking, scientific reasoning, and reasoning responsibility to build.txt (#2315)
- session miner — daily self-improvement pulse from session data (#2313)

### Changed

- Documentation: add launchd/cron naming convention to AGENTS.md (#2319)
- Documentation: t1306 mark stream hooks upstream PR complete with brief (#2318)
- Documentation: add build-agent routing instruction for all primary agents (#2314)
- Documentation: t1311 post-migration review of swarm DAG research (#2306)

### Fixed

- t1327.2 address PR review feedback on SimpleX subagent docs (#2317)
- add dispatch dedup helper with normalized title matching (#2310) (#2312)
- distinguish advisory vs critical failures in postflight workflow (#2308)

## [2.130.0] - 2026-02-25

### Added

- add mandatory closing comment gate to full-loop workers (#2297)

### Changed

- Documentation: add task briefs for t1335-t1337 — archive and simplify redundant orchestration scripts

### Fixed

- mark t1314 complete — batch concurrency bypass resolved by PR #2236 and obsoleted by supervisor refactor #2291
- scrub private repo names from public issue tracker and add automated sanitization (#2303)
- add cross-repo routing rule to prevent wrong-repo task creation (#2302)
- exclude currency/pricing patterns from shell-local-params rule false-positives (#2296)

## [2.129.0] - 2026-02-25

### Added

- add self-improvement principle and agent routing to pulse system (#2295)
- t1331 — standalone circuit breaker for AI pulse supervisor (#2294)
- t1327.6 Matterbridge integration for SimpleX-Matrix bridging
- add SimpleX Chat bot API research report (t1327.1) (#2258)
- t1328 matterbridge agent + t1329 cross-review judge pipeline (#2267)

### Changed

- Refactor: replace 37K-line bash supervisor with 123-line AI pulse system (#2291)
- Documentation: rebase and consolidate SimpleX Chat subagent documentation (t1327.2) (#2266)
- Documentation: update model files from aidevops (t1133)
- Documentation: update model files from aidevops (t1133)
- Documentation: update model files from aidevops (t1133)
- Documentation: update model files from aidevops (t1133)
- Documentation: update model files from aidevops (t1133)
- Documentation: update model files from aidevops (t1133)
- Documentation: update model files from aidevops (t1133)
- Documentation: update model files from aidevops (t1133)

### Fixed

- make cmd_update() resilient to dirty tree, diverged history, and detached HEAD (#2289)
- prevent aidevops update from dirtying git working tree (#2286) (#2287)
- add CI failure debugging guidance to worker protocol (#2283)
- sanity-check grep -c arithmetic errors from whitespace in output (#2280)

## [2.127.1] - 2026-02-25

### Fixed

- gather_task_state query references non-existent worker_pid column — Phase 3 completely broken (#2275)

## [2.127.0] - 2026-02-25

### Added

- cross-repo issue/PR visibility in supervisor AI context + concurrency underutilisation alerting (#2272)

### Changed

- Documentation: update model files from aidevops (t1133)

### Fixed

- unpin stale supervisor health issues when closing or replacing them (#2270)

## [2.126.0] - 2026-02-25

### Added

- support .aidevops.json project config in claim-task-id.sh (t1322) (#2237)
- increase AI timeouts to 30s and add deferred re-evaluation queue (t1325) (#2242)
- AI-based issue duplicate detection and auto-dispatch assessment (t1324) (#2241)
- align repo-sync-helper.sh with auto-update-helper.sh patterns (t1264.2) (#2200)

### Changed

- Documentation: add SimpleX (t1327) and Matterbridge (t1328) planning artifacts (#2255)
- Documentation: update model files from aidevops (t1133)
- Documentation: update model files from aidevops (t1133)
- Refactor: t1160.3 — align runner-helper.sh CLI resolution with dual-CLI architecture (#2231)
- Documentation: update model files from aidevops (t1133)
- Documentation: update model files from aidevops (t1133)
- Documentation: update model files from aidevops (t1133)
- Documentation: update model files from aidevops (t1133)
- Documentation: update model files from aidevops (t1133)
- Documentation: t1321 integration test results — final t1311 migration audit (#2229)
- Refactor: t1318-t1320 migrate check_task_staleness() to AI, document mechanical modules (#2226)
- Documentation: update model files from aidevops (t1133)
- Refactor: t1315 migrate pulse.sh get_task_timeout() to AI classification (#2225)
- Refactor: t1313 migrate dispatch.sh decision logic to AI (#2224)
- Refactor: t1312 remove dead code stubs + retire evaluate_worker heuristic tree (#2221)
- Refactor: migrate should_run_routine() from case-statement to AI scheduling (t1317) (#2220)
- Documentation: update model files from aidevops (t1133)
- Documentation: update model files from aidevops (t1133)
- Documentation: update model files from aidevops (t1133)
- Documentation: update model files from aidevops (t1133)
- Refactor: replace deterministic supervisor lifecycle with AI-first decision engine (#2206)
- Documentation: update model files from aidevops (t1133)
- Documentation: update model files from aidevops (t1133)
- Documentation: update model files from aidevops (t1133)
- Documentation: update model files from aidevops (t1133)
- Documentation: update model files from aidevops (t1133)
- Documentation: update model files from aidevops (t1133)
- Documentation: update model files from aidevops (t1133)
- Documentation: update model files from aidevops (t1133)
- Documentation: update t1305 issue draft with current upstream status (t1305) (#2201)

### Fixed

- resolve bare tier names to full model strings before DB storage (#2256)
- resolve merge conflict markers in TODO.md (t1305/t1306, t1107)
- exclude currency patterns from shell-local-params rule (t1323) (#2238)
- prevent duplicate supervisor health issues via label-based lookup and dedup guard (#2243)
- register blocked tasks in DB during auto-pickup instead of skipping (#2239)
- blocked-by parser matches backtick-quoted code in task descriptions (#2232)
- bash 3.2 compatibility for routine-scheduler cache (#2222)
- add Phase 3d to merge open PRs for verified tasks and adopt orphan PRs (#2205)

## [2.125.1] - 2026-02-24

### Changed

- Documentation: update model files from aidevops (t1133)
- Documentation: update model files from aidevops (t1133)
- Documentation: update model files from aidevops (t1133)
- Documentation: update model files from aidevops (t1133)
- Documentation: update model files from aidevops (t1133)
- Documentation: update model files from aidevops (t1133)
- Documentation: update model files from aidevops (t1133)
- Documentation: update model files from aidevops (t1133)
- Documentation: update model files from aidevops (t1133)
- Documentation: update model files from aidevops (t1133)
- Documentation: update model files from aidevops (t1133)
- Documentation: update model files from aidevops (t1133)
- Documentation: update model files from aidevops (t1133)
- Documentation: update model files from aidevops (t1133)
- Documentation: update model files from aidevops (t1133)
- Documentation: update model files from aidevops (t1133)
- Documentation: update model files from aidevops (t1133)
- Documentation: update model files from aidevops (t1133)
- Documentation: update model files from aidevops (t1133)
- Documentation: update model files from aidevops (t1133)
- Documentation: update model files from aidevops (t1133)

### Fixed

- prevent TTSR messagesTransformHook infinite correction loop (#2203)
- cron.sh script_path resolves to wrong directory (GH#2160), unblock t1311, add t1314 for batch concurrency fix (GH#2163) (#2193)
- prevent undefined content in memory store (t1302) (#2125)
- pass task_line to find_closing_pr in audit — fixes false no_pr_linkage for auto-reaped tasks (t1158) (#2197)
- add sequential dependency enforcement for t1120 subtask chain (t1257) (#2195)

## [2.125.0] - 2026-02-23

### Added

- add executable verify blocks for task briefs (t1313) (#2187)
- add container pool manager for supervisor (t1165.2) (#2184)
- link task IDs to GitHub issues in health dashboard alerts (#2171)

### Changed

- Documentation: update model files from aidevops (t1133)
- Documentation: update model files from aidevops (t1133)
- Documentation: update model files from aidevops (t1133)

### Fixed

- clear dedup guard state on task reset to prevent false cancellations (#2189)
- ensure task briefs are copied into worktrees at dispatch time (#2188)
- guard MEMORY_DB with default empty to prevent unbound variable crash (#2186)
- resolve three supervisor pulse-blocking bugs (#2185)
- align OAuth routing tests with PR #2173 (opencode is sole worker CLI) (#2180)
- correct repo slug anomalyco/aidevops to marcusquinn/aidevops (#2181)
- force opencode as sole worker CLI, remove OAuth routing to claude CLI (#2173)
- bash 3.2 compatibility and readonly variable conflicts (#2172)

## [2.124.2] - 2026-02-22

### Changed

- Documentation: update model files from aidevops (t1133)

### Fixed

- kill running osgrep processes before cleanup to prevent index rebuilds (#2170)

## [2.123.5] - 2026-02-22

### Added

- add intent tracing to OpenCode plugin tool call logging (t1309) (#2153)

### Changed

- Documentation: add hashline edit format reference (t1310) (#2151)

### Fixed

- safe empty array expansion in _run_generator under set -u

## [2.123.4] - 2026-02-22

### Changed

- Documentation: add changelog entry for v2.123.4
- Documentation: update model files from aidevops (t1133)

### Fixed

- add npm fallback for OpenCode version detection (#2165)

## [2.123.4] - 2026-02-22

### Fixed

- Add npm fallback for OpenCode version detection when CLI not in PATH during session init (#2165)

## [2.123.3] - 2026-02-22

### Added

- mandatory task briefs with session provenance and conversation context (#2116)

### Changed

- Documentation: add changelog entry for v2.123.3
- Documentation: update TODOs t1305, t1306, t1309 with OpenCode v1.2.x release notes

### Fixed

- detect OpenCode version via CLI instead of hardcoded bun package.json path (#2164)

## [2.123.3] - 2026-02-22

### Fixed

- Detect OpenCode version via CLI instead of hardcoded bun package.json path (#2164)

## [2.123.2] - 2026-02-22

### Added

- add quick tool staleness check to aidevops update (#2161)

### Changed

- Documentation: add changelog entry for v2.123.2

## [2.123.2] - 2026-02-22

### Added

- Quick tool staleness check in `aidevops update` — checks key tools (opencode, gh) and offers to run full update (#2161)

## [2.123.1] - 2026-02-22

### Changed

- Documentation: add changelog entries for v2.123.0 and v2.123.1

### Fixed

- use npm for tool updates and capture positional params as locals (#2158)

## [2.123.1] - 2026-02-22

### Fixed

- Use npm (not bun) for all tool update commands in tool-version-check.sh — bun not guaranteed installed (#2158)
- Fix OpenCode package name from `opencode` to `opencode-ai` in tool registry (#2158)
- Capture positional params as locals in run_with_spinner after shift (#2158)

## [2.123.0] - 2026-02-22

### Added

- NetBird self-hosted mesh VPN agent with multi-platform support

## [2.122.5] - 2026-02-22

### Added

- expand supervisor health issue with per-task detail and typed attention breakdown (#2156)

### Changed

- Documentation: add changelog entry for v2.122.5

### Fixed

- suppress Homebrew auto-update globally in run_with_spinner for all brew commands (#2157)

## [2.122.5] - 2026-02-22

### Fixed

- Suppress Homebrew auto-update globally in run_with_spinner for all 10 brew install call sites (#2157)

## [2.122.4] - 2026-02-22

### Changed

- Documentation: add changelog entry for v2.122.4
- Documentation: update model files from aidevops (t1133)

### Fixed

- export HOMEBREW_NO_AUTO_UPDATE so it propagates to backgrounded brew install (#2155)

## [2.122.4] - 2026-02-22

### Fixed

- HOMEBREW_NO_AUTO_UPDATE not propagating to backgrounded brew install, causing duplicate 50MB index download (#2155)

## [2.122.3] - 2026-02-22

### Added

- add spinner to brew/apt/dnf/yum/pacman/apk installs during setup (#2154)

### Changed

- Documentation: add changelog entry for v2.122.3

## [2.122.3] - 2026-02-22

### Added

- Spinner feedback for package manager installs during setup (brew, apt, dnf, yum, pacman, apk) (#2154)

## [2.122.2] - 2026-02-22

### Changed

- Documentation: add changelog entry for SETUP_MODULES_DIR hotfix

### Fixed

- curl install dies at SETUP_MODULES_DIR under set -e on fresh machines (#2149)

## [2.122.1] - 2026-02-22

### Changed

- Documentation: add changelog entry for curl install fix

### Fixed

- curl install silently exits — bootstrap guard before source lines (#2148)

## [2.122.0] - 2026-02-22

### Added

- add idle-gated tool auto-update to keep all installed tools fresh (#2145)
- worker-count concurrency model and parallel sibling dispatch (#2146)
- add fix_ci action to supervisor AI lifecycle for automatic CI repair (#2144)

### Changed

- Documentation: add changelog entries for v2.122.0
- Documentation: update model files from aidevops (t1133)
- Documentation: update model files from aidevops (t1133)
- Documentation: update model files from aidevops (t1133)
- Documentation: update model files from aidevops (t1133)
- Documentation: update model files from aidevops (t1133)
- Documentation: update model files from aidevops (t1133)
- Documentation: update model files from aidevops (t1133)
- Documentation: update model files from aidevops (t1133)
- Documentation: update model files from aidevops (t1133)
- Documentation: update model files from aidevops (t1133)

### Fixed

- disable Phase 4e PPID=1 orphan kill sweep in pulse.sh (#2143)

## [2.121.0] - 2026-02-21

### Changed

- Refactor: eliminate evaluating state race condition in supervisor pulse (#2056)
- Refactor: add build_cli_cmd() abstraction to replace duplicated CLI branches (t1160.1) (#2053)
- Documentation: update model files from aidevops (t1133)
- Documentation: update model files from aidevops (t1133)

### Fixed

- add ai-chat-sidebar to subagent-index.toon (t1267) (#2049)
- wire -needed blocker tags into cron auto-pickup and add park_task AI action (t1287) (#2052)

## [2.120.0] - 2026-02-21

### Added

- extend skills discovery with skills.sh registry search (t1280) (#2035)
- harden Gitea API adapter with error checking, label caching, pagination, and search (t1120.2) (#2031)

### Changed

- Documentation: update model files from aidevops (t1133)
- Documentation: update model files from aidevops (t1133)
- Documentation: update model files from aidevops (t1133)
- Documentation: update model files from aidevops (t1133)
- Documentation: update model files from aidevops (t1133)
- Documentation: update model files from aidevops (t1133)
- Documentation: add Repo Sync section to AGENTS.md (t1264.4) (#2023)

### Fixed

- resolve BSD sed regex, dedup suppression, and add adaptive AI pulsing (t1285) (#2043)
- create one GitHub issue per ID in claim-task-id.sh --count N batch allocation (#2045)
- extend create_improvement dedup window + add recent fixes context (t1284) (#2040)
- wp-helper.sh run_wp_command() CONFIG_FILE not propagated from get_site_config subshell (t1279) (#2028)

## [2.119.3] - 2026-02-20

### Changed

- Documentation: add changelog entries for t1276

## [2.119.2] - 2026-02-20

### Added

- add repo-sync parent dirs onboarding question to onboarding-helper.sh (t1264.3) (#2016)

### Changed

- Documentation: add changelog entries for upcoming release
- Documentation: update model files from aidevops (t1133)
- Documentation: update model files from aidevops (t1133)

### Fixed

- document t1200 merge conflict resolution — no conflict exists, all subtasks merged (t1274) (#2020)

## [2.119.1] - 2026-02-20

### Changed

- Documentation: add changelog entries for v2.120.0 (t1273)
- Documentation: update model files from aidevops (t1133)
- Documentation: update model files from aidevops (t1133)
- Documentation: update model files from aidevops (t1133)
- Documentation: update model files from aidevops (t1133)
- Documentation: update model files from aidevops (t1133)
- Documentation: update model files from aidevops (t1133)
- Documentation: update model files from aidevops (t1133)
- Documentation: update model files from aidevops (t1133)
- Documentation: update model files from aidevops (t1133)
- Documentation: update model files from aidevops (t1133)

## [2.119.0] - 2026-02-20

### Added

- add missing MuAPI endpoints — specialized apps, storyboarding, payments (#2013)
- add t1271 mobile-app-dev and browser-extension-dev agents task
- auto-detect plan refs from PLANS.md Task/TODO field in compose_issue_body (t1268) (#2000)

### Changed

- Documentation: add changelog entries for v2.119.0
- Documentation: update model files from aidevops (t1133)
- Documentation: update model files from aidevops (t1133)

## [2.118.0] - 2026-02-20

### Added

- add t1269 — fix stuck evaluating tasks with crash-resilient evaluation
- add 'get' command to secret-helper.sh for programmatic secret retrieval (#1990)
- add daily repo sync via repo-sync-helper.sh (t1264) (#1989)

### Changed

- Documentation: update model files from aidevops (t1133)
- Documentation: update model files from aidevops (t1133)
- Documentation: update model files from aidevops (t1133)
- Documentation: update model files from aidevops (t1133)
- Documentation: update model files from aidevops (t1133)

### Fixed

- resolve SIGPIPE in _launchd_is_loaded under pipefail (t1265)
- skip LaunchAgent plist rewrite when content unchanged (t1265)
- supervisor auto-pickup skips tasks with assignee:/started: fields (t1062) (#1519)
- exclude cancelled tasks from 7-day success rate metric (t1248) (#1983)

## [2.117.0] - 2026-02-19

### Added

- add local-hosting.md agent — comprehensive localdev knowledge base (t1224.6) (#1939)
- add auto-unblock detection for tasks with resolved blockers (t1243) (#1935)
- add unified localdev dashboard with cert status, process health, and LocalWP sites.json (t1224.5) (#1934)
- add trivial bugfix threshold bypass for auto-dispatch eligibility (t1241) (#1930)
- implement localdev branch — subdomain routing for worktrees (t1224.3) (#1916)
- implement localdev add/rm commands (t1224.2) (#1908)
- add VirusTotal IP reputation provider (t1200.4) (#1871)
- add ip-reputation agent doc, /ip-check slash command, subagent index + AGENTS.md updates, per-subcommand --help (t1200.3) (#1867)
- add launchd scheduler backend for macOS (t1219) (#1864)
- add AI-powered semantic dedup for task creation (t1220) (#1863)
- add ip-reputation-helper.sh with 5 free-tier providers (t1200.1) (#1856)
- break down t1200 into 3 dispatchable subtasks (t1212) (#1842)
- tune worker hung timeout based on task ~estimate field (t1199) (#1826)
- add auto-subtasking detection and cross-repo dispatch fairness (t1188.2) (#1827)
- add per-task-type hang timeout tuning and worker heartbeat (t1196) (#1819)
- add multi-platform detection and API adapters for Gitea/GitLab issue sync (t1120.3) (#1815)
- expand blocker statuses for auto-dispatch eligibility assessment (t1188.1) (#1810)
- add multi-repo TODO scanning and auto-dispatch eligibility to AI context (#1801)
- filter verified/cancelled tasks from AI context snapshot (t1178) (#1779)
- add supervisor DB cross-reference to issue audit to reduce false positives (t1156) (#1773)
- add auto-dispatch eligibility assessment to supervisor AI reasoning (t1134) (#1782)
- add Phase 0.6 queue-dispatchability reconciliation (t1180) (#1783)
- add model cost-efficiency check to supervisor dispatch (t1149) (#1769)
- add completed-task exclusion list to supervisor AI context (t1148) (#1768)
- add cancelled-task sync between supervisor DB and TODO.md (t1131) (#1727)
- Phase 3a — auto-adopt untracked PRs into supervisor pipeline (#1704)
- add supervisor self-healing for stuck evaluating tasks, dispatch stalls, and action executor robustness (#1683)
- add last_skill_check and skill_updates_applied to auto-update state schema (t1081.3) (#1638)
- add --non-interactive headless support (t1081.2) (#1630)
- add comprehensive AI supervisor e2e test suite (t1085.7) (#1635)
- wire Phase 14 AI supervisor pipeline into pulse.sh (t1085.5) (#1617)
- add PR template with changelog and diff summary (t1082.4) (#1615)
- add Phase 13 skill update PR pipeline to supervisor pulse cycle (t1082.2) (#1610)
- add AI supervisor reasoning engine (t1085.2) (#1609)
- add AI supervisor context builder (t1085.1) (#1607)
- add daily skill freshness check to auto-update-helper.sh (t1081) (#1591)
- update context7 agent with skill registry, telemetry disable, and package rename (#1570)
- add tenant-aware config, server refs, and SSH config integration to wp-helper.sh (t1059) (#1568)

### Changed

- Documentation: update model files from aidevops (t1133)
- Documentation: update model files from aidevops (t1133)
- Documentation: update model files from aidevops (t1133)
- Documentation: update model files from aidevops (t1133)
- Documentation: t1255 duplicate of t1253 — cross-repo dispatch investigation complete (#1961)
- Documentation: update model files from aidevops (t1133)
- Documentation: update model files from aidevops (t1133)
- Documentation: reflect localdev architecture in localhost.md, AGENTS.md, subagent-index.toon (t1224.9) (#1953)
- Documentation: update model files from aidevops (t1133)
- Documentation: update model files from aidevops (t1133)
- Documentation: add Turbostarter/Turborepo quirks to local-hosting.md (t1224.7) (#1943)
- Documentation: update model files from aidevops (t1133)
- Documentation: update model files from aidevops (t1133)
- Documentation: update model files from aidevops (t1133)
- Documentation: update model files from aidevops (t1133)
- Documentation: update model files from aidevops (t1133)
- Documentation: update model files from aidevops (t1133)
- Documentation: update model files from aidevops (t1133)
- Documentation: update model files from aidevops (t1133)
- Documentation: update model files from aidevops (t1133)
- Documentation: update model files from aidevops (t1133)
- Documentation: add dual-CLI architecture plan (t1160) — OpenCode primary + Claude Code fallback
- Documentation: document daily skill refresh and repo version wins on update (t1081.4) (#1639)

### Fixed

- improve semantic dedup to prevent duplicate task creation (t1218) (#1969)
- resolve stale evaluating recovery false positives in Phase 0.7 (t1258) (#1966)
- reduce stale-evaluating frequency via rate limit cooldown and eval checkpoint (t1256) (#1963)
- treat 'failed' and 'blocked' as terminal in subtask sibling ordering (t1253) (#1959)
- reduce stale-evaluating rate via heartbeat, configurable timeout, and PR fast-path (t1251) (#1952)
- reduce stale-evaluating recovery frequency with fast-path detection (t1250) (#1950)
- auto-unblock tasks when blocker is deployed/verified in DB (t1247) (#1945)
- separate IFS variable declaration from assignment in issue-sync-helper.sh (t1122) (#1941)
- remove hardcoded t1243 task ref from auto-unblock commit message (t1246) (#1938)
- persist PR URL to DB immediately in evaluate_worker() to reduce stale evaluating (t1245) (#1940)
- resolve TODO.md stash merge conflicts — keep t1238+t1239, t1241, merge t1244 metadata (t1244) (#1933)
- prevent cross-repo subtask misregistration in create_subtasks (t1240) (#1925)
- add cross-repo task registration validation to prevent misregistration (t1239) (#1926)
- create_subtasks executor edge cases causing recurring failures (t1238) (#1924)
- block cross-repo subtask creation when task not in DB + skip completed parents (t1237) (#1919)
- replace declare -A with bash 3.2-compatible grep lookup in ai-context.sh (t1236) (#1918)
- guard cmd_push() against cross-repo issue creation (t1235) (#1913)
- add cross-repo guard to issue-sync-helper.sh (t1235) (#1912)
- remove misplaced private repo subtasks from aidevops TODO.md (privacy breach)
- strengthen execute_action_plan array validation guard (t1223) (#1872)
- add post-write verification to create_subtasks executor (t1217) (#1858)
- add semantic dedup to AI task creation to prevent duplicate tasks (t1218) (#1859)
- add subtask visibility to eligibility assessment and post-exec verification (t1214) (#1850)
- write diagnostic actions log on parse failure for better observability (t1211) (#1843)
- document create_subtasks required fields in AI reasoning prompt (t1210) (#1839)
- reconcile supervisor DB state inconsistencies for running/evaluating/pr_review (t1208) (#1837)
- harden AI actions pipeline against empty/malformed model responses (t1197) (#1823)
- harden AI supervisor pipeline against 'expected array' parsing errors (t1201) (#1829)
- add -n flag to tea CLI commands for non-interactive mode (t1121) (#1814)
- add Phase 0.8 stale running task recovery using started_at (t1193) (#1813)
- treat empty/non-JSON AI responses as empty action plan (t1189) (#1807)
- pass task model to cmd_reprompt and skip escalation for infra failures (t1186) (#1806)
- harden AI actions pipeline against empty/malformed model responses (t1187) (#1805)
- harden AI pipeline JSON parser against whitespace responses and improve failure logging (t1184) (#1797)
- strip ANSI codes from opencode output to fix AI actions pipeline parse errors (t1182) (#1792)
- 3 supervisor pipeline bugs — PR-aware reaping, atomic eval transitions, batch merge (#1790)
- handle concurrency guard empty output in AI pipeline to eliminate rc=1 errors (t1157) (#1781)
- add double-check pattern in cmd_push to prevent duplicate issue creation (t1142) (#1741)
- remove backticks from t1134 description to prevent parser artifact (t1159) (#1776)
- eliminate jq JSON parsing errors from shell variable interpolation in supervisor (t1125) (#1702)
- require new_priority field in adjust_priority AI actions (t1126) (#1703)
- prevent duplicate GitHub issues by using API list instead of search index (#1715)
- skip markdown code-fenced lines in TODO.md parser (t1124) (#1692)
- make JSON parser handle multiple code blocks and unclosed blocks (t1123) (#1675)
- prevent git stdout noise from breaking jq action logging (t1106) (#1654)
- increase AI reasoning timeout from 120s to 300s (t1085) (#1643)
- use --format default for opencode run (text is invalid) (t1085) (#1642)
- remove artificial pulse counter from Phase 14, use natural guards (t1085) (#1641)
- replace GNU timeout with portable fallback for macOS cron (t1085) (#1640)
- expand AI reasoning prompt with self-improvement and efficiency analysis (t1085) (#1614)
- add efficiency guards to AI reasoning engine (t1085.2) (#1611)
- remove hardcoded t1082 task ID from skill-update-helper.sh pr pipeline (#1608)
- address CodeRabbit feedback on auto-update-helper.sh (t1084) (#1597)
- align haiku and opus model IDs to non-dated aliases (t1083) (#1595)
- remove SC2034 unused variables and SC2068/SC2221 warnings across 9 files (t1077) (#1576)
- cap verification retries, recover stuck verifying state, fix bot review dismissal (t1075) (#1566)

## [2.116.0] - 2026-02-17

### Added

- add t1070 — post blocked reason comments on GitHub issues
- create tech-stack-lookup.md orchestrator agent (t1063.2) (#1531)
- add tech stack lookup agent tasks t1063-t1068 — open-source BuiltWith alternative

### Changed

- Documentation: add v2.116.0 changelog entries

### Fixed

- auto-retry timed-out workers before marking failed (t1074) (#1560)
- multi-commit rebase loop + sequential subtask dispatch (t1072, t1073) (#1558)
- prevent pulse crash when PR mergedAt is null (t1071) (#1553)
- add t1071 — pulse Phase 3b2 crash on mergedAt:null kills rebase retry
- dedup_todo_task_ids removes duplicates instead of renaming (t1069) (#1549)
- remove duplicate task entries t1069-t1077 and merge conflict markers, add t1069 dedup fix task
- wp-helper.sh SSH stdin consumption and Cloudways template path (t1057, t1058) (#1513)

## [2.116.0] - 2026-02-17

### Added

- Tech stack lookup system — open-source BuiltWith alternative with multiple providers (t1063-t1068)
  - Unbuilt.app provider agent (t1064)
  - CRFT Lookup provider agent (t1065)
  - Open Tech Explorer provider agent (t1066)
  - Wappalyzer OSS provider agent (t1067)
  - Reverse tech stack lookup with filtering (t1068)
  - `/tech-stack` slash command (t1063.3)
  - tech-stack-lookup.md orchestrator agent (t1063.2)
- Qwen3-TTS as TTS provider in voice agent — Apache-2.0, 10 languages, 97ms streaming latency (t1061)
- Post blocked reason comments on GitHub issues when status:blocked is applied (t1070)

### Fixed

- **Critical**: Pulse crash on `mergedAt:null` — `grep -o` returned exit 1 under `set -euo pipefail`, killing the entire pulse and preventing Phase 3.5 rebase retry and Phase 3.6 opus escalation from ever running (t1071)
- **Critical**: `git rebase --continue` failed in headless/cron — `TERM` unset caused nano editor error, aborting all AI-resolved rebases (t1071)
- Multi-commit rebase loop — branches with multiple conflicting commits are now fully rebased instead of aborting after the first conflict (t1072)
- Sequential subtask dispatch — subtasks (e.g., t1063.1, t1063.2) now dispatch in order instead of in parallel, preventing merge conflicts from sibling tasks modifying the same files (t1073)
- Auto-retry timed-out workers — Phase 4 now checks retries remaining before marking failed; workers with existing PRs transition to pr_review instead (t1074)
- dedup_todo_task_ids() now deletes merge-conflict duplicates instead of renaming them to ghost task IDs (t1069)
- wp-helper.sh SSH stdin consumption fix (t1057)
- Cloudways template path fix (t1058)

## [2.115.22] - 2026-02-16

### Added

- add status:needs-testing label for tasks awaiting manual/integration testing (#1505)

### Changed

- Documentation: add changelog entry for t1056 Intel brew fix

### Fixed

- issue-sync includes PR proof-log and error context when closing issues (t1055) (#1504)
- defer batch post-completion actions to end of pulse cycle (t1052) (#1498)

## [2.115.21] - 2026-02-15

### Changed

- Version bump and maintenance updates

## [2.115.20] - 2026-02-15

### Changed

- Version bump and maintenance updates

## [2.115.19] - 2026-02-15

### Changed

- Version bump and maintenance updates

## [2.115.18] - 2026-02-15

### Changed

- Version bump and maintenance updates

## [2.115.17] - 2026-02-15

### Changed

- Version bump and maintenance updates

## [2.115.16] - 2026-02-15

### Changed

- Version bump and maintenance updates

## [2.115.15] - 2026-02-15

### Changed

- Version bump and maintenance updates

## [2.115.14] - 2026-02-15

### Changed

- Version bump and maintenance updates

## [2.115.13] - 2026-02-15

### Changed

- Version bump and maintenance updates

## [2.115.12] - 2026-02-15

### Changed

- Version bump and maintenance updates

## [2.115.11] - 2026-02-15

### Changed

- Version bump and maintenance updates

## [2.115.10] - 2026-02-15

### Changed

- Version bump and maintenance updates

## [2.115.9] - 2026-02-15

### Changed

- Version bump and maintenance updates

## [2.115.8] - 2026-02-15

### Changed

- Version bump and maintenance updates

## [2.115.7] - 2026-02-15

### Changed

- Version bump and maintenance updates

## [2.115.6] - 2026-02-15

### Changed

- Version bump and maintenance updates

## [2.115.5] - 2026-02-15

### Changed

- Version bump and maintenance updates

## [2.115.4] - 2026-02-15

### Changed

- Version bump and maintenance updates

## [2.115.3] - 2026-02-15

### Changed

- Version bump and maintenance updates

## [2.115.2] - 2026-02-15

### Fixed

- auto-verify deployed tasks without VERIFY.md entries (t1051) (#1494)

## [2.115.1] - 2026-02-15

### Added

- add Phase 3b2 reconciliation and triage command to supervisor (#1488)

### Fixed

- swap stat -f %m to Linux-first order for cross-platform compat (#1491) (#1492)
- Phase 3b2 and triage gh pr view fails from cron (missing --repo) (#1490)
- Phase 3b2 and triage must not skip verification for verify_failed tasks (#1489)
- revert 5 falsely completed verify_failed tasks (t1043, t1044.2, t1048, t1049, t1050)
- suppress quality gate console noise, keep secrets-only TUI alerts (#1487)

## [2.115.0] - 2026-02-15

### Added

- Add cross-document linking for email collections (#1472)
- add MIME parsing for .eml/.msg to document-creation-helper.sh (t1044.1) (#1420)
- add Synapse Admin API helpers to matrix-dispatch-helper.sh (t1056.2) (#1471)
- add contact deduplication and update-on-discovery (t1044.4) (#1436)
- implement atomic task ID allocation with CAS push loop (t1047) (#1458)
- add comprehensive test suite for entity extraction (t1051.6) (#1462)
- add Phase 3.6 — escalate rebase-blocked PRs to opus worker (#1483)

### Fixed

- cap quality hook console output to prevent TUI flooding (#1486)
- improve escalation lock with PID tracking and post-dispatch creation (#1485)
- hoist max_retry_cycles to function scope for Phase 3.6 access (#1484)
- stash dirty worktree before rebase to prevent 'uncommitted changes' error (#1481)
- abort stale rebase state before retrying (#1480)
- handle AI-completed rebase and increase max attempts (#1477)
- detect AI-completed rebase and increase max attempts (t1048) (#1478)
- ai-research tool uses OAuth from auth.json instead of requiring ANTHROPIC_API_KEY (#1475)

## [2.114.0] - 2026-02-14

### Added

- integrate normalise with convert pipeline (#1456)

## [2.113.1] - 2026-02-14

### Added

- add Reader-LM and RolmOCR conversion providers (t1043) (#1411)

### Fixed

- resolve symlink in npm global install CLI wrapper
- implement check-regression subcommand, fix 24 SonarCloud findings, rate-limit Phase 10c (#1437)
- align verify ShellCheck with CI severity and fix Phase 7b reconciliation (#1406)

## [2.113.0] - 2026-02-13

### Added

- add E2E audit pipeline verification test (t1032.8) (#1381)
- add document creation agent with OCR support (t1042) (#1405)
- wire Phase 10b to unified audit orchestrator with fallback (t1032.5) (#1377)
- add Phase 3.5 auto-retry for merge-conflict tasks (t1029) (#1355)
- add issue title update with task ID prefix after allocation (t1028) (#1353)
- add action:model issue label tracking to supervisor (t1010) (#1342)
- auto-unclaim stale worker assignments after 2h timeout (t1024) (#1340)
- per-repo health issues — stats filtered by repo for privacy (#1335)
- per-runner health issues + update only on stats change (#1332)
- runner labels on health issue + verify_failed in title (#1330)
- operational health issue title with runner/available/claimed/blocked counts (#1324)
- update pinned health issue title with live queue stats on each pulse (#1321)
- show CPU% as primary in TUI dashboard (t1020) (#1320)
- add pre-dispatch reverification for previously-claimed tasks (t1008) (#1316)
- protect assignee ownership in supervisor (t1017, t1019) (#1315)
- PR task ID validation — test harness + CI workflow patch (t318.5) (#1260)

### Changed

- Documentation: align README philosophy with build.txt mission principles (#1360)
- Documentation: expand build.txt mission statement with broader dev scope, resource utilisation, root-cause fixing, and gap awareness (#1358)
- Refactor: update health issue description directly, remove comment machinery (#1333)
- Documentation: add PR task ID check implementation notes (t318.1) (#1284)

### Fixed

- resolve bot review threads and fix triage severity logic (t1041) (#1401)
- Phase 3c must not close issues for no_pr/task_only deployments (#1391)
- add Phase 3c to reconcile terminal DB states with GitHub issues (#1390)
- use correct column names (from_state/to_state) in fix-cycle count query (#1388)
- guard complete->deployed transition to require PR merge when pr_url exists (t1030) (#1385)
- migrate legacy [Supervisor] health issue to [Supervisor:username] format (t1036) (#1383)
- restore ALL_STATUS_LABELS constant lost in t1031 modularisation (t1035) (#1375)
- resolve TODO.md merge conflict markers (t1010/t1025 duplicate)
- use relative path as agent name to prevent collisions (t1015) (#1336)
- health issue progress uses actionable count, excluding cancelled/skipped (#1323)
- wire resolve_rebase_conflicts() into rebase_sibling_pr() for AI-assisted conflict resolution (t1021) (#1322)
- plugin config hook overrides worker osgrep disabled setting (#1296)
- add PATH and GH_TOKEN detection to supervisor cron install (t1006) (#1291)
- beads-sync-helper.sh accept positional args (t1007) (#1292)
- coderabbit pulse gh auth fails in cron (no keyring access) (#1288)
- resolve SonarCloud quality gate failure and all 16 code smells (#1286)

## [2.112.0] - 2026-02-12

### Added

- enforce task ID in PR titles for audit traceability (t318.2) (#1283)
- add DB-TODO reconciliation pulse phase (t1001) (#1275)

### Changed

- Documentation: move changelog entries to [Unreleased] for version-manager
- Documentation: add v2.112.0 changelog entries

### Fixed

- use base-10 arithmetic for task ID comparison to prevent octal parsing errors
- use INSTALL_DIR instead of BASH_SOURCE in deploy_aidevops_agents (t316.4) (#1269)
- use stat -c (Linux) before stat -f (macOS) to prevent unbound variable error on Linux (#1267)

## [2.111.0] - 2026-02-12

### Added

- add mandatory proof-log check to pre-commit hook (t317.1) (#1249)
- complete setup.sh function audit and module assignment (t316.1) (#1233)
- add TODO.md dedup Phase 0.5b to supervisor pulse cycle (t319.4) (#1261)
- complete PR task ID backfill audit (t318.4) (#1255)

### Changed

- Documentation: update AGENTS.md task completion rules (t317.3) (#1250)
- Documentation: add comprehensive verification report for t316.5 (t316.5) (#1241)

### Fixed

- wire escalate_model_on_failure, improve classifier, add auto-upgrade safeguard (#1257)

## [2.110.14] - 2026-02-12

### Added

- create supervisor module skeleton (t311.2) (#1218)
- auto-escalate model to opus on worker failure + extend timeouts (t314) (#1215)
- add pre-dispatch staleness check to prevent wasting worker tokens (t312) (#1211)
- add Phase 10b to auto-create TODO tasks from quality findings (t299) (#1206)

### Changed

- Documentation: add t315 changelog entry for oh-my-opencode fix
- Documentation: add supervisor module map — catalogue 155 functions across 17 domains (t311.1) (#1207)

### Fixed

- make oh-my-opencode removal optional, default to keeping it (#1221)
- add SUPERVISOR_SKIP_STALENESS env var to bypass staleness check (#1217)
- narrow t313 queue priority to cmd_next() dispatch queries only (#1213)

## [2.110.13] - 2026-02-12

### Added

- auto-resolve merge conflicts with escalating strategy (t302) (#1203)
- auto-decompose t311 from PLANS.md (2026-02-12-modularise-oversized-shell-scripts)
- extend Rosetta audit to scan /usr/local/bin and /Applications for x86 binaries
- enhance Rosetta audit with migrate/dry-run, shell linting setup (t301)
- add supervisor Phase 10b — auto-create TODO tasks from quality findings (t299) (#1170)

### Changed

- Documentation: add missing [namespace] argument to plugin init help text (t308) (#1191)
- Documentation: add proof-log for Homebrew/Beads Linux install (OrbStack Ubuntu test)

### Fixed

- add path traversal sanitization to plugin namespaces in setup.sh (t305) (#1188)
- add namespace validation to prevent path traversal in plugin deployment (t306) (#1190)
- reorder migration phases — install ARM before removing x86 (t301)
- add validate_namespace call in plugin init command (t307) (#1189)
- replace undefined SUPERVISOR_STATE_DIR with SUPERVISOR_DIR in Phase 10b (t300) (#1174)

## [2.110.12] - 2026-02-11

### Added

- add Homebrew install offer and Beads binary download fallback for Linux (#1168)

### Changed

- Documentation: add changelog entry for Homebrew/Beads Linux install (#1168)

## [2.110.11] - 2026-02-11

### Added

- workers comment on GH issues when blocked (t296) (#1167)
- auto-create batches when auto-pickup finds new tasks (t296) (#1162)
- graduate 19 high-confidence memories to shared docs (t293) (#1152)

### Changed

- Documentation: add changelog entries for v2.110.11
- Documentation: add explicit PR-required rule for all non-planning changes (t297) (#1160)

### Fixed

- issue-sync title truncation — split at em dash, full description in body (#1165)
- correct SUPERVISOR_AUTO_ISSUE help text default (true -> false) (#1164)
- pass auto-dispatch tag through as GitHub label
- replace hardcoded tag-to-label allowlist with passthrough (t295) (#1154)
- replace template task IDs with placeholders to prevent issue-sync auto-creation

## [2.110.10] - 2026-02-11

### Added

- add OCR approaches research document (t012.1) (#1136)

## [2.110.9] - 2026-02-11

### Added

- write pr:#NNN to TODO.md when closing issues (t280) (#1117)

### Changed

- Refactor: move wavespeed.md to tools/video/ with setup.sh migration (#1106)
- Refactor: migrate YouTube agents from root to content/distribution/youtube/ (#1104)

### Fixed

- pre-dispatch check matched [x] in task description, not checkbox (t290) (#1132)
- find_closing_pr() now reads pr:#NNN format from TODO.md (t291) (#1129)
- PRs now cross-reference GitHub issues via Ref #NNN (t288) (#1118)
- stash dirty working tree before batch auto-release (t276) (#1119)
- guard against marking #plan tasks [x] when subtasks are open (t278) (#1110)
- setup.sh stale file cleanup + false-close audit (t285, t286) (#1111)
- remove 2>/dev/null from cmd_add calls in auto-pickup (t279) (#1109)

## [2.110.8] - 2026-02-11

### Changed

- Documentation: add changelog entry for t284 opencode plugin fix

### Fixed

- unmark t008, t012 as incomplete — subtasks still open, PRs closed due to merge conflicts from parallel dispatch
- remove Zod-incompatible args from opencode plugin tools (t284)

## [2.110.7] - 2026-02-11

### Changed

- Documentation: changelog for t283 string lookup fix

### Fixed

- replace associative array with string lookup in cmd_close (t283) (#1086)

## [2.110.6] - 2026-02-11

### Changed

- Documentation: changelog for t283 set -u fix

### Fixed

- associative array lookup under set -u in cmd_close (t283) (#1085)

## [2.110.5] - 2026-02-11

### Changed

- Documentation: add changelog entry for t283 issue-sync performance fix

### Fixed

- cmd_close pre-fetches open issues to avoid 2000+ API calls per run (t283) (#1084)

## [2.110.4] - 2026-02-11

### Added

- auto-decompose t012 from PLANS.md (ocr-invoicereceipt-extraction-pipeline)
- auto-decompose t008 from PLANS.md (aidevops-opencode-plugin)
- default output to ~/Downloads/higgsfield/ for interactive sessions (t270) (#1054)

### Changed

- Documentation: add changelog entries for v2.110.4

### Fixed

- verify_gh_cli accepts GH_TOKEN/GITHUB_TOKEN env vars for GitHub Actions compatibility (#1083)
- recognize pr:#NNN field as completion evidence in issue-sync close (#1075)
- remove unsupported --metadata flag from auto-decomposition cmd_add (#1071)
- prevent shell injection and race conditions in issue-sync workflow (#1070)
- unify image selector for generation detection (t267) (#1068)
- use resolve_ai_cli() and standard dispatch pattern for decomposition worker (t274) (#1066)

## [2.110.3] - 2026-02-11

### Added

- add UGC brief storyboard template to story.md and image.md (t272) (#1055)
- auto-recall memories in Build+ workflow and session start (t273) (#1056)
- add --count flag to download command to limit downloads (t268) (#1052)
- add results-driven mission principle and completion summary instruction (#1050)
- respawn supervisor after batch completion when memory exceeds threshold (t264.1) (#1043)
- add domain expertise check to Build+ workflow (step 2b) (#1039)
- supervisor session memory monitoring with respawn detection (t264) (#1040)
- add infinite loop guard for deploying auto-recovery (t263) (#1036)
- exclude skill reference files from subagent stub generation (t258) (#1035)
- add WaveSpeed AI service agent with REST API helper (t258) (#1016)
- include task description in worker session titles (t262)
- accept planning-only PRs for planning tasks (t261) (#1024)
- add Runway API agent for video, image, and audio generation (#1015)
- add comfy-cli agent for ComfyUI automations (t259) (#1020)
- fix deploying->deployed transition stuck state (t248) (#1018)

### Changed

- Documentation: add changelog entries for v2.110.3
- Documentation: add auto-dispatch tagging guidance for TODO creation (t273) (#1051)
- Documentation: document t247 clean_exit_no_signal reduction strategy (t247) (#1038)
- Refactor: simplify shared UI helpers with guard clauses and dedup (t250.5) (#1034)
- Refactor: extract generateVideo() into 8 focused helpers (t250.3) (#1032)
- Refactor: extract generateImage() into 6 focused helpers (t250.2) (#1021)

### Fixed

- sanitize supervisor arithmetic to prevent syntax errors (#1062)
- redirect Phase 3/3b stderr to log and capture errors (t265) (#1061)
- redirect Phase 3/3b stderr to log and capture errors (t265) (#1059)
- add missing DIM color constant for respawn-history output (t264.1) (#1049)
- SCRIPTS_DIR typo breaks quality gate model escalation (set -u unbound variable) (#1037)
- add PR URL discovery for terminal-state tasks (t260) (#1025)
- add --force flag to batch release to handle empty CHANGELOG (t257) (#1023)
- replace crontab stdin pipe with temp file to prevent macOS hang (t254) (#1022)
- prevent worker process accumulation exhausting system RAM (#1031)

## [2.110.2] - 2026-02-11

### Added

- use source file description in generated subagent stubs (t255) (#1017)

## [2.110.1] - 2026-02-11

### Added

- add orchestration commands to quality-sweep-helper.sh for daily sweep (t245.4) (#1013)
- verify API model IDs via platform probing, fix incorrect mappings (t252)
- add Codacy API integration — fetch, normalize, deduplicate (t245.2) (#1000)
- auto-create PR for orphaned branches instead of retrying (t247.2) (#988)
- expand model routing classifier with haiku tier, tag hints, and TODO.md model: field (t246) (#986)
- Higgsfield Cloud API client + model priority fix (#975)
- add quality-sweep-helper.sh with SonarCloud API integration (t245.1) (#984)
- Email Testing Suite cross-references (t214) (#963)
- add unlimited model auto-selection with SOTA quality ranking (t236.2) (#970)
- retroactive verification audit — 292 tasks verified, 69 unverifiable (t238) (#968)
- add dry-run, health-check, and smoke-test to higgsfield-helper (t236.5) (#969)

### Changed

- Documentation: add t249 to changelog
- Refactor: extract parseArgs() into data-driven flag map and main() into command registry (t250.1, t250.4) (#1002)

### Fixed

- inject mandatory read instruction into subagent stubs (t249) (#1014)
- clamp caption scene index to last scene when out of range (t244) (#981)
- replace execSync with execFileSync to prevent shell injection (t243) (#980)
- separate reloadAttempted flag from retryAttempted in waitForGeneration (t242) (#979)
- harden worktree auto-cleanup after deploy (t240) (#978)
- add missing closing brace for batchLipsync function (#976)
- Remotion staticFile path handling, Seedance video download matching, caption normalization (#926)

## [2.110.0] - 2026-02-10

### Added

- add auto-update polling daemon (t231) (#955)
- add retry logic, credit guard, and cost estimation (t236.1) (#962)
- add ShellCheck pre-push gate to worker prompt (t234) (#961)
- add proof-log coverage for all pr_url mutations (t235) (#960)
- auto-dismiss CodeRabbit reviews that block merge pipeline (#952)
- serial merge strategy for sibling subtasks (#951)
- Auto-merge PRs when SonarCloud GH Action passes but external quality gate fails (#947)
- expand Higgsfield UI automation — Cinema Studio, Motion Control, Edit/Inpaint, Upscale, Asset Library (#942)
- link closing PR reference when issue-sync closes issues (t220) (#944)
- disable osgrep in worker MCP configs to save CPU (t221) (#945)
- integrate email accessibility checks into email-health-check + email-design-test (t215.6) (#943)
- add WAVE API integration for comprehensive accessibility analysis (t215.4) (#941)
- update AGENTS.md and cross-references for accessibility (#940)
- surface Lighthouse accessibility as first-class output in pagespeed (#936)
- add Playwright contrast extraction for all visible elements (t215.3) (#937)
- add accessibility-audit-helper.sh — CLI wrapping axe-core, WAVE API, WebAIM contrast, Lighthouse a11y (#935)
- add email-design-test-helper.sh — CLI for local + EOA API email design testing (#930)
- add email-delivery-test-helper.sh — spam testing + inbox placement CLI (t214.4) (#933)
- add email delivery test subagent for spam filter testing and inbox placement (#929)
- add content-level checks to email health check (inspired by EOA Campaign Precheck) (#934)
- add unified web + email accessibility audit agent (t215.1) (#932)
- add critical thinking directive and Socratic pre-flight questions to subjective agents
- email testing suite — design rendering + delivery testing + health check enhancements (t214)
- eager orphaned PR scan after worker evaluation (t216)
- add accessibility & contrast testing for websites and emails (t215)
- auto-deploy agents after supervisor merges PRs (t213)
- add Higgsfield UI automation subagent for subscription credit usage (#797)
- faster PR merge pipeline with parallel CI + review triage (t219) (#922)
- add structured proof-logs for task completion trust (t218) (#921)
- enforce Task tool parallelism in worker prompt + track usage (t217) (#918)
- Thumbnail A/B testing pipeline (t207)
- add content calendar and posting cadence engine (t208)
- multi-channel content fan-out orchestration (t206)
- add voice-pipeline-helper.sh — CapCut cleanup + ElevenLabs transformation chain (t204)

### Changed

- Documentation: update changelog for v2.110.0 release
- Documentation: add email-design-test.md — local Playwright rendering + Email on Acid API v5 integration (#928)
- Documentation: add t220-t223 — issue-sync PR linking, osgrep worker perf, deploying stuck state, PR cross-contamination
- Documentation: mark t135.4/.5/.6/.10/.14 complete — all had merged PRs from Feb 7
- Documentation: mark t198 complete (PR #834 merged previously)
- Refactor: archive 4 remaining fix scripts to _archive/ (t135.12) (#925)
- Documentation: mark t214 complete with PR #923
- Documentation: mark t213, t215, t216 complete; fix corrupted t215 line
- Documentation: mark t204, t206, t208 complete with merged PR links

### Fixed

- add missing local declarations in cmd_transition to prevent cross-contamination (#967)
- add force:true to all generate button clicks to bypass overlay interception (#958)
- asset chain dialog scoping, media upload agreement dismissal, and result download (#956)
- pre-dispatch check for already-merged PRs (#950)
- prevent PR cross-contamination in task linking (#949)
- auto-recover deploying stuck state when deploy completes (#948)
- worker incremental commit protocol to prevent context-exhaustion data loss (t228) (#946)
- setup.sh cross-shell grep -c arithmetic error
- use detect_repo_slug() instead of broken inline regex for GitHub API calls (#902)

## [2.109.0] - 2026-02-10

### Added

- add YouTube slash commands - /youtube setup, /youtube research, /youtube script (#901)
- add cross-shell compatibility step to setup.sh (#900)
- add unified video-gen-helper.sh for Sora 2, Veo 3.1, and Nanobanana Pro APIs (t203) (#885)
- add seed-bracket-helper.sh for AI video generation seed bracketing (t202) (#884)
- add orphaned PR scanner to supervisor pulse (t210) (#882)
- add retry with exponential backoff to PR validation (t211) (#881)
- add distribution channel reference agents (t199.8) (#880)
- create optimization.md - A/B testing, variant generation, analytics loops (#877)
- add character production guide - facial engineering, character bibles, personas (t199.7) (#875)
- add image production guide with Nanobanana JSON templates (#874)
- create content/production/audio.md - voice pipeline, sound design, emotional cues (t199.6) (#873)
- add content/production/video.md - AI video generation guide (t199.5) (#872)
- add content/story.md - narrative design and storytelling frameworks (#849)
- add production/writing.md - scripts, copy, captions (#846)
- enhance worktree registry prune to clean corrupted entries (t197) (#847)
- rewrite content.md as multi-media multi-channel orchestrator (#840)
- enhance research.md with 7 advanced research frameworks (#842)
- add research subagent for audience research, niche validation, competitor analysis (#836)

### Changed

- Documentation: mark t207 complete - thumbnail A/B testing pipeline
- Performance: enable Anthropic prompt caching in setup (#838)

### Fixed

- issue-sync status labels — use claimed on assign, done on close (t212) (#883)
- enforce anthropic-only model resolution, reject opencode/* proxy models (#878)
- detect billing/credits errors and block immediately instead of retrying (#876)
- resolve clean_exit_no_signal false retry loop (t198) (#834)
- use actual CPU idle% for adaptive throttling on macOS (#835)
- sync homebrew formula version and enable subtask GitHub Issues (#848)
- prevent RETURN trap clobbering with cleanup stack (t196) (#827)

## [2.108.0] - 2026-02-09

### Added

- add YouTube competitor research and content automation agent (#811)
- add OpenClaw guided onboarding with Tailscale and OrbStack agents
- add OpenCode model registry integration for daily model refresh (t194) (#810)
- enhance pull command with orphan issue detection (t020.4) (#809)
- enhance TODO.md parser with full field extraction and rich issue body (t020.1) (#804)
- add pre-dispatch verification to prevent dispatching already-done tasks (#806)
- rewrite PLANS.md extraction with awk for performance + fuzzy anchor matching (t020.2) (#805)
- add trap cleanup for temp files across 13 scripts (t135.9) (#800)

### Changed

- Documentation: add task ID collision prevention rule to AGENTS.md (t201) (#820)
- Refactor: delegate supervisor issue creation to issue-sync-helper.sh (t020.6) (#812)
- Performance: add auth caching and auto model tier routing to supervisor (#794)

### Fixed

- resolve 12 MD022 violations in youtube/script-writer.md (#828)
- validate PR title/branch contains task ID before attribution (t195) (#826)
- replace ls with find in review-pulse-helper.sh (SC2012) (t196) (#818)
- revert false t020.6 completion — supervisor attributed t194's PR #810 to t020.6
- scope pre-dispatch TODO.md check to first occurrence and skip health probe for OpenCode (#808)
- prevent pre-dispatch false positives from substring and non-completion matches (#807)
- make trap RETURN cleanup safe under set -u (nounset) (#802)
- enforce Anthropic-only model routing, remove all Google/OpenRouter fallbacks (#799)
- redirect supervisor log functions to stderr (unblocks all workers) (#796)

## [2.106.0] - 2026-02-09

### Added

- add SOPS + gocryptfs encryption stack (t134) (#718)
- add verify-run-helper.sh with proof logging to verify-proof-log.md (#715)
- add cloud voice agents and S2S model docs (t080) (#713)
- provider-agnostic task claiming via TODO.md (t165) (#712)
- add tools/vision/ category for visual AI models (t131) (#710)
- add OrbStack VM self-test for setup.sh fresh install (#706)
- add /list-verify command for verification queue (#705)
- add compaction-resilient session state — continuation prompts and auto-checkpoints (t187) (#699)
- add pre-migration safety backups for non-git state (t188) (#697)
- add worktree ownership registry to prevent cross-session removal (t189)
- add memory audit pulse — periodic self-improvement scan (t185)
- add transcription-helper.sh for audio/video transcription (t072)
- add memory graduation — promote validated learnings into shared docs (t184)
- add memory deduplication and auto-pruning (t181)
- one-command install — auto-install git, Node.js, Bun, OpenCode, and OrbStack VM support
- add post-merge verification phase to supervisor state machine (t180)
- issue-sync reconciliation — close stale issues, fix ref:GH# drift, wire into supervisor pulse (t179)
- add /runners-check command for quick queue health diagnostics
- add document extraction subagent, workflow, and CLI helper (t073)
- add agent-device subagent for AI-driven mobile automation (t120)
- enhance cloud GPU deployment guide with provider CLIs, monitoring, and updated pricing (t133)
- add /compare-models and /compare-models-free slash commands for model capability comparison (t168) (#660)
- add daily CodeRabbit review pulse for self-improving codebase quality (t166) (#657)
- add uncertainty decision framework for headless workers (t176) (#656)
- add git heuristic signals to evaluate_worker (t175) (#655)
- add mission statement with ROI and self-improvement directives (#652)
- add --headless flag to full-loop for autonomous worker operation (t174) (#642)
- bidirectional adaptive concurrency - scale up when resources available (#637)
- provider-agnostic task claiming via TODO.md assignee: field (t165) (#627)
- register Mom Test UX/CRO agent and fix cross-references (t101)
- distributed task claiming via GitHub Issue assignees (t164)
- add platform persona adaptations for content guidelines (t076) (#614)
- comprehensive TTS/STT model catalog (t071) (#613)
- integrate Content Calendar Workflow subagent into framework (t075) (#611)
- integrate LinkedIn and Reddit subagents into framework cross-references (t077) (#610)
- integrate Tirith terminal security guard into framework (t124) (#605)
- add Playwright device emulation subagent (t098) (#604)
- add AXe CLI for iOS simulator accessibility automation (t100) (#603)
- integrate Lumen subagent into framework cross-references (t078) (#602)
- add DocStrange subagent for document conversion and structured extraction (t074) (#600)
- integrate SEO Machine content analysis and writing workflows (t017) (#599)
- add iOS Simulator MCP integration for AI-driven simulator interaction (t097) (#597)
- complete XcodeBuildMCP integration with mobile domain indexing (t095) (#596)
- add Maestro for mobile and web E2E testing (t096) (#595)
- add Uncloud multi-machine container orchestration integration (t016) (#594)
- add image SEO enhancement with AI vision subagents (t013) (#593)
- add intent-based resolution rules to conflict-resolution guide (#592)
- add Pipecat-OpenCode voice bridge subagent (t114) (#581)
- improve agent testing framework with JSON output parsing and shipped test suites (t118) (#587)
- integrate QuickFile MCP server into aidevops framework (t007) (#585)
- iPhone Shortcut for voice dispatch to OpenCode (t113) (#577)
- add hyprwhspr speech-to-text subagent for Linux (t027) (#575)
- add objective-runner-helper.sh with safety guardrails (t111) (#566)
- add cloud GPU deployment guide for AI model hosting (#565)
- Claude Code destructive command hooks (t009) (#562)
- integrate Shannon AI pentester for security testing (t023) (#561)
- batch subagent creation + orchestration fixes (#557)
- integrate Shannon AI pentester for security testing (t023) (#556)
- add Claude Code destructive command safety hooks (t009) (#554)
- add git conflict resolution skill (t153) (#552)
- add GHA workflow and PRD content rendering for issue-sync (t020.2, t020.3) (#543)
- add issue-sync-helper.sh for bi-directional TODO/PLANS ↔ GitHub issue sync (t020) (#542)
- integrate session-review and agent-review into batch completion lifecycle (t128.9) (#494)

### Changed

- Documentation: evaluate tools/multimodal/ vs current per-modality structure (t132) (#708)
- Documentation: add development lifecycle enforcement to user guide (t186) (#700)
- Refactor: extract npm_global_install() helper for sudo-aware global installs (#694)
- Documentation: add t189 (worktree ownership safety) and immediate AGENTS.md rule to prevent cross-session worktree removal [skip ci]
- Documentation: add t187 (compaction-resilient sessions) and t188 (pre-migration safety backups) [skip ci]
- Documentation: add t185 — memory audit pulse for automated self-improvement loop
- Documentation: add t184 — graduate validated memories into shared docs for all users
- Documentation: add todo/VERIFY.md for post-merge verification queue, update t180 design
- Documentation: mark t073 complete (PR #667 merged), fix corrupted task line
- Documentation: add t180-t183 from memory audit — verification phase, dedup, GHA safety, dispatch errors
- Documentation: add t179 issue-sync reconciliation task to TODO.md
- Documentation: mark t120 and t133 complete in TODO.md
- Documentation: t167 research — Gemini Code Assist full codebase review findings (#650)
- Refactor: deduplicate agent instructions and trim AGENTS.md for token efficiency (#651)
- Documentation: add t169-t174 for open bugfixes and runner improvements
- Documentation: mark t101 complete - PR #628 merged, mom-test-ux registered in index
- Documentation: mark t060, t062 complete - research notes already in TODO.md, verified content
- Documentation: mark t152, t153 complete - PRs #548, #552 already merged
- Documentation: mark t164 complete - PR #621 merged with distributed task claiming
- Documentation: mark t071, t075, t076, t077 complete with verified merged PRs
- Documentation: add t168 - /compare-models and /compare-models-free commands for model capability comparison
- Documentation: add t167 - investigate Gemini Code Assist for full codebase review pulse
- Documentation: add t166 - daily CodeRabbit full codebase review pulse for self-improving aidevops
- Documentation: reconcile 20 tasks with verified merged PRs
- Documentation: mark t163 complete - PR #622 merged with verified deliverables
- Documentation: VoiceInk to OpenCode macOS Shortcut guide (t112) (#576)
- Documentation: supervisor improves the process, never does work for workers (#570)
- Documentation: runners supervisor continuous loop — never stop, 1min pulse (#567)
- Documentation: complete t060 research - jj (Jujutsu) VCS evaluation for aidevops (#563)
- Documentation: clarify /runners supervisor role — orchestrate only, dispatch fixes as tasks (#560)

### Fixed

- normalize grep BRE patterns and shellcheck flags in verify-run-helper.sh (#716)
- strip verbose workflow from /onboarding command prompt (#714)
- secretlint-helper.sh install and scan in git worktrees (t191) (#717)
- remove agent: Onboarding from /onboarding command frontmatter (#709)
- add blank lines before category headings in graduation output (MD022) (#703)
- remove --agent Onboarding flag from opencode launch (#704)
- remove auth gate from onboarding launch — OpenCode handles auth itself (#702)
- add spinner to MCP package installs for visible progress (#701)
- decouple OpenCode commands from config guard, reorder after CLI install, add auth check (#698)
- setup.sh set-e resilience, template path, npm/sudo, and venv recovery
- Tabby repo pollution + missing npm on ARM64 Ubuntu (#688)
- improve supervisor dispatch error capture when worker fails to start (t183)
- validate auto-fixes before committing in GHA workflow (t182)
- xcode-select timeout + OrbStack VM exact match (#683)
- cancel stale diagnostic subtasks in pulse Phase 4c
- anchor task ID grep to capture dotted subtask IDs
- add PR check to force-fresh worktree cleanup path
- check for open PRs before deleting 'stale' branches in worktree cleanup (#663)
- handle missing worktrees in cmd_reprompt between retries (t178) (#659)
- enforce worker TODO.md restriction with multi-layer guards (t173) (#649)
- pass --non-interactive to setup.sh in aidevops update (t169) (#646)
- suppress stdout pollution in create_task_worktree (t169, t173) (#643)
- supervisor identity matching — prefer GitHub username, fuzzy compare (#641)
- add GitHub auth precheck to cmd_dispatch and full-loop (#640)
- resolve supervisor concurrency limiter race condition (t172) (#639)
- seed evaluate_worker PR URL from DB to prevent clean_exit_no_signal retry loop (#638)
- import-credentials now handles multi-tenant credential files (t170) (#636)
- detect and clean stale branches before worker dispatch
- prevent false task completion cascade (t163) (#622)
- resolve merge conflict - accept PR #616 revert of false completions
- revert 32 falsely marked-complete tasks in TODO.md (#616)
- detect backend quota errors on EXIT:0 and defer retries (t095-diag-1) (#601)
- supervisor DB migration safety - dynamic column detection and backup before ALTER TABLE (t162) (#598)
- supervisor DB safety - add backup-before-migrate and explicit column migrations (t162) (#591)
- supervisor TODO.md push fails under concurrent workers (t160) (#589)
- resolve clean_exit_no_signal retry loop in supervisor evaluation (t161) (#586)
- reduce duplication and add modern Git features to conflict-resolution (#583)
- prevent concurrent pulse dispatch exceeding concurrency limits (t159) (#584)
- supervisor dispatch passes task description to workers (t158) (#574)
- prevent TODO.md race condition with serialized locking and worker restriction (#569)
- add health check to supervisor reprompt to prevent wasting retries on dead backends (#568)
- refresh version cache after setup.sh completes (#551)
- guard ((var++)) with || true to prevent silent exit under set -e (#548)
- sync Homebrew formula version during release and add to version validator (t135.11) (#495)

## [2.105.4] - 2026-02-07

### Fixed

- add ShellCheck enforcement to CI code-quality workflow (t135.6) (#432)
- add SQLite WAL mode + busy_timeout to supervisor, memory, mail helpers (t135.3) (#433)

## [2.105.1] - 2026-02-07

### Fixed

- deploy greeting template via setup.sh and include app name in greeting (#421)

## [2.105.0] - 2026-02-07

### Added

- add runtime context hint to session greeting (#419)
- add Oh My Zsh setup option and fix bash/zsh shell compatibility (#418)
- add voice bridge -- talk to AI agents via speech (#416)
- add VirusTotal API integration for skill security scanning (#410)
- add three-tier agent lifecycle (draft, private, shared) (#409)
- add skill scan results audit trail (#406)
- gopass integration & credentials rename (t131) (#405)
- auto-install Cisco Skill Scanner during setup (#404)
- add voice AI integration with HuggingFace speech-to-speech pipeline (#403)
- separate --force from security scan bypass in skill imports (#402)
- integrate Cisco Skill Scanner for security scanning of imported skills (#400)
- add --non-interactive flag to setup.sh for CI/CD and AI agent shells (#399)

### Changed

- Documentation: add plugin system plan for private extension repos (t136)
- Documentation: update README with recent feature changes (#420)
- Refactor: remove oh-my-opencode integration and fix SKILL-SCAN-RESULTS agent (#413)
- Refactor: remove non-OpenCode AI tool support from aidevops (#412)
- Documentation: add draft agent awareness to orchestration agents (#411)
- Documentation: update t135.12 to use _archive/ folder name (user preference)
- Documentation: add t135 codebase quality hardening plan from Opus 4.6 review
- Documentation: mention scan results audit trail in README (#408)
- Documentation: add gitignore *credential* pattern note to t131.1
- Documentation: add PRD and tasks for gopass integration & credentials rename (t131)
- Documentation: add gopass integration plan (t131) to TODO and PLANS

### Fixed

- speech-to-speech helper syntax errors and venv support (#407)
- surface AI reviewer feedback posted as COMMENTED in pr-loop WAITING state (#401)

## [2.104.0] - 2026-02-06

### Added

- add AI bot review verification to pr-loop and full-loop workflows (t129) (#394)
- add schema-validator subagent and helper script (t085) (#391)
- add programmatic-seo subagent for building SEO pages at scale (t091) (#389)
- add WebPageTest subagent for real-world performance testing (t090) (#388)
- add ContentKing/Conductor Monitoring subagent (t089) (#387)
- add Semrush SEO subagent with Analytics API v3 integration (t087) (#386)
- add Rich Results Test subagent (t084) (#385)
- create Screaming Frog subagent (t086) (#383)
- add Bing Webmaster Tools subagent (t083) (#382)
- add analytics-tracking subagent for GA4 setup and event tracking (t094) (#390)
- add /runners command for orchestrated batch dispatch (#393)
- Supervisor post-PR lifecycle (t128.8) (#392)
- add memory and self-assessment integration to supervisor (t128.6) (#380)
- add cron integration and auto-pickup to supervisor (t128.5) (#381)
- add TODO.md auto-update on task completion/failure (t128.4) (#379)
- add 3-tier outcome evaluation and re-prompt cycle to supervisor (t128.3) (#378)
- add worker dispatch with worktree isolation to supervisor (t128.2)
- add supervisor-helper.sh with SQLite schema and state machine (t128.1)

### Changed

- Refactor: rename .agent/ to .agents/ for industry alignment (#396)
- Documentation: mark t128.6 complete - memory and self-assessment integration
- Documentation: mark t128.5 complete - cron integration and auto-pickup
- Documentation: mark t128.4 complete - TODO.md auto-update on completion/failure
- Documentation: mark t128.3 complete - outcome evaluation and re-prompt cycle
- Documentation: mark t128.2 complete - worker dispatch with worktree isolation
- Documentation: mark t128.1 complete - supervisor SQLite schema and state machine
- Documentation: add t128 Autonomous Supervisor Loop plan, PRD, and subtasks

### Fixed

- resolve SonarCloud security hotspots for clear-text protocols and npm ignore-scripts (#397)
- supervisor integration testing fixes (t128.7) (#384)
- remove eval in ampcode-cli.sh, use arrays + format whitelist (#375)
- remove deprecated "compaction" key from OpenCode config (#374)
- add missing blank lines between CHANGELOG.md release sections

## [2.102.0] - 2026-02-06

### Added

- add agent testing framework with isolated AI sessions (t118)
- add Playwright device emulation subagent (t098) (#367)
- add auto-capture flag, privacy filters, and /memory-log command (t058) (#365)
- add MinerU subagent for PDF-to-markdown conversion (#364)
- add Matrix bot integration for runner dispatch (t109.4) (#363)

### Changed

- Documentation: update README for recently merged PRs (#370)
- Documentation: add agent testing framework section to README
- Documentation: add Playwright device emulation to README Browser Automation section
- Documentation: add curl-copy authenticated scraping workflow subagent (#368)

### Fixed

- pass directory param to OpenCode session rename API
- replace awk -v with while-read to avoid BSD awk newline warnings (#371)
- improve secret detection regex to catch hyphenated API keys (t058) (#369)
- remove eval-based patterns from credential-helper.sh (t107) (#366)
- replace eval with safe array args in system-cleanup.sh find commands (#361)
- correct TODO commit guidance to use main for planning-only and worktrees for mixed changes (#360)
- re-run setup.sh when deployed agent VERSION mismatches repo (#358)

## [2.101.0] - 2026-02-06

### Added

- auto-migrate mailbox on update, replace auto-prune with storage report (#357)
- migrate inter-agent mailbox from TOON files to SQLite (#356)
- add memory namespace support for per-runner isolation (t109.3) (#351)
- headless dispatch docs + runner-helper.sh (t109.1, t109.2) (#348)
- Claude-Flow inspired features - model routing, semantic memory, pattern tracking (t102)
- add Neural-Chromium subagent for agent-native browser automation (#340)

### Changed

- Refactor: use args array for opencode launch command (#354)
- Documentation: add runner templates and parallel vs sequential guide (t109.5) (#353)
- Documentation: mark t109.3 memory namespace integration complete
- Documentation: update README headless dispatch section with runner-helper.sh examples
- Documentation: add Pi agent review for aidevops inspiration (t103) (#347)
- Documentation: add t102 features to README - semantic memory, pattern tracking, model routing (#345)

### Fixed

- resolve setup onboarding errors (macOS head -z, model selection, agent routing) (#346)
- namespace maintenance - orphan cleanup, shared access tracking, migrate, embeddings (t109.3) (#352)
- correct SQL single-quote escaping in memory-helper.sh (#350)
- use gtimeout on macOS, fallback to no timeout if neither available (#349)
- pattern-tracker stats now shows task type breakdown (#344)
- add main-branch write restrictions for subagents (#343)
- enforce README gate as mandatory step in loop workflows (#342)

## [2.100.20] - 2026-02-05

### Changed

- Documentation: add MCP auto-installation plan to PLANS.md (#338)

## [2.100.6] - 2026-02-05

### Fixed

- add explicit guidance to use generator script for OpenCode config (#319)
- check multiple OpenCode config locations (#318)

## [2.100.3] - 2026-02-04

### Changed

- Documentation: add SonarCloud security hotspot guidance to preflight/postflight (#315)

## [2.100.2] - 2026-02-04

### Fixed

- remove non-existent npm package breaking CI (#314)

## [2.100.1] - 2026-02-04

### Fixed

- prevent command injection in credential-helper.sh (#313)

## [2.100.0] - 2026-02-04

### Added

- add Ollama GLM-OCR support for local document OCR (#311)
- add iOS Simulator support to agent-browser (#308)

### Changed

- Documentation: add GLM-OCR to README documentation (#312)
- Documentation: add terminal capabilities section to AGENTS.md (#309)
- Documentation: add backlog tasks and loop auto-advance (#298)

### Fixed

- consolidate SonarCloud security hotspot exclusions for shell scripts (#307)

## [2.99.0] - 2026-02-04

### Added

- add cron agent for scheduled AI task dispatch (#304)

### Fixed

- harden cron scripts for secure remote use (#305)

## [2.98.0] - 2026-02-04

### Added

- OpenCode server docs, privacy filter, and self-improving agents (t115, t116, t117) (#302)
- import robust-skills from ccheney/robust-skills (#296)
- support multiple AI code reviewers in PR loop (#295)

### Changed

- Documentation: add self-improving agent system plan and tasks (t110-t118) (#301)
- Documentation: add parallel agents & headless dispatch plan (t104) (#300)
- Documentation: add security follow-up tasks and plans (#292)
- Refactor: improve skill categorization and reorganize imported skills (#297)

### Fixed

- correct SonarCloud rule prefix from shell: to shelldre: (#303)

## [2.97.1] - 2026-02-03

### Added

- add @socket subagent for dependency security scanning (#287)
- add sentry to Build+ allowed subagents (#283)
- add @sentry subagent for error monitoring MCP (#282)
- disable sentry and socket MCPs by default (#281)
- disable google-analytics-mcp and context7 by default (#280)
- disable on-demand MCPs globally in opencode.json (#277)
- MCP on-demand loading - disable playwriter, augment, gh_grep globally (#275)

### Changed

- Documentation: add security subagents and tools to README
- Documentation: update README counts and add sentry/socket subagents
- Documentation: trim sentry subagent to focus on auth/token setup (#285)
- Documentation: add Next.js SDK setup instructions to @sentry subagent (#284)

### Fixed

- route /agent-review command to Build+ instead of disabled Build-Agent (#293)
- catch updown api key secrets with secretlint (#291)
- add concurrency to all GitHub workflows (#290)
- address SonarCloud S7679 positional parameter violations (#289)
- remove invalid '|| exit' after 'then' in clawdhub-helper.sh (#288)
- auto-detect OpenCode port in session-rename tool (#286)
- move disable_ondemand_mcps to run after all MCP setup functions (#279)
- correct MCP name gh-grep to gh_grep in disable_ondemand_mcps (#278)

## [2.97.0] - 2026-02-02

### Added

- add @socket subagent for dependency security scanning (#287)
- add sentry to Build+ allowed subagents (#283)
- add @sentry subagent for error monitoring MCP (#282)
- disable sentry and socket MCPs by default (#281)
- disable google-analytics-mcp and context7 by default (#280)
- disable on-demand MCPs globally in opencode.json (#277)
- MCP on-demand loading - disable playwriter, augment, gh_grep globally (#275)

### Changed

- Documentation: update README counts and add sentry/socket subagents
- Documentation: trim sentry subagent to focus on auth/token setup (#285)
- Documentation: add Next.js SDK setup instructions to @sentry subagent (#284)

### Fixed

- address SonarCloud S7679 positional parameter violations (#289)
- remove invalid '|| exit' after 'then' in clawdhub-helper.sh (#288)
- auto-detect OpenCode port in session-rename tool (#286)
- move disable_ondemand_mcps to run after all MCP setup functions (#279)
- correct MCP name gh-grep to gh_grep in disable_ondemand_mcps (#278)

## [2.96.0] - 2026-02-02

### Added

- add security analysis with OSV, Ferret, and git history scanning (#274)

### Fixed

- make markdown lint blocking for changed files (#271)
- add blank line before fenced code block in remember.md (#270)

## [2.95.0] - 2026-01-31

### Added

- add proactive auto-remember triggers and session distill (#269)
- add relational versioning and dual timestamps (#268)
- add Mullvad Browser support for privacy-focused automation (#267)

## [2.94.0] - 2026-01-31

### Added

- auto-load aidevops AGENTS.md via instructions config (#266)

## [2.93.5] - 2026-01-31

### Changed

- Refactor: rename moltbot to openclaw branding (#265)
- Documentation: add Bitwarden cloud vs Vaultwarden detection documentation (#264)

## [2.93.2] - 2026-01-29

### Fixed

- resolve Codacy markdown style issues and add markdown standards (#258)

## [2.93.1] - 2026-01-29

### Added

- add /seo-audit command (#257)

## [2.93.0] - 2026-01-29

### Added

- import seo-audit skill from marketingskills repo (#255)

### Changed

- Documentation: update README with seo-audit skill and subagent count (#256)

## [2.92.5] - 2026-01-29

### Changed

- Documentation: add changelog entry for full-loop workflow fixes

### Fixed

- improve full-loop workflow reliability (#254)

## [2.92.4] - 2026-01-29

### Added

- add /pr-loop slash command for iterative PR monitoring (#251)

### Changed

- Documentation: add changelog entry for pr-loop command
- Documentation: update README counts and add new slash commands from recent PRs (#252)

### Fixed

- resolve SonarCloud code quality issues (#253)

## [2.92.3] - 2026-01-29

### Fixed

- make version scripts cross-platform and add validation (#250)

## [2.92.1] - 2026-01-28

### Fixed

- correct MainWP REST API endpoints and auth method (#247)

## [2.90.8] - 2026-01-27

### Changed

- Documentation: add changelog entry for browser custom engine support

### Fixed

- add language specifiers to fenced code blocks (#242)
- detect fd-find as fdfind on Debian/Ubuntu (#241)
- correct path to agent-review.md in generate-opencode-commands.sh (#237)

## [2.90.7] - 2026-01-27

### Changed

- Version bump and maintenance updates

## [2.90.6] - 2026-01-27

### Changed

- Version bump and maintenance updates

## [2.90.5] - 2026-01-26

### Changed

- Version bump and maintenance updates

## [2.90.4] - 2026-01-26

### Changed

- Documentation: add changelog entries for v2.90.4

## [2.90.3] - 2026-01-26

### Added

- add /neuronwriter slash command for content optimization (#235)

## [2.90.2] - 2026-01-26

### Changed

- Documentation: add yt-dlp agent, /yt-dlp command, and NeuronWriter to README (#234)

## [2.90.1] - 2026-01-26

### Added

- add /yt-dlp slash command for YouTube downloads (#233)

## [2.90.0] - 2026-01-26

### Added

- add yt-dlp agent for YouTube video/audio downloads (#232)

## [2.89.1] - 2026-01-25

### Fixed

- remove .opencode/agent symlink causing Services/ entries in tab completion (#228)

## [2.89.0] - 2026-01-25

### Changed

- Documentation: mark t079 as complete
- Refactor: consolidate Plan+ and AI-DevOps into Build+ (#226)

## [2.88.5] - 2026-01-25

### Added

- cache session greeting for agents without Bash (#224)
- cache session greeting for agents without Bash

### Fixed

- Plan+ uses Read for version check (no Bash tool available) (#223)
- Plan+ uses Read for version check (no Bash tool available)

## [2.88.4] - 2026-01-25

### Fixed

- add mandatory version check instruction directly to Plan+ agent (#222)
- add mandatory version check instruction directly to Plan+ agent

## [2.88.3] - 2026-01-25

### Fixed

- insist all agents run update check script (all have permission) (#221)
- insist all agents run update check script (all have permission)

## [2.88.2] - 2026-01-25

### Fixed

- use placeholder versions in AGENTS.md example to prevent hallucination (#220)
- use placeholder versions in AGENTS.md example to prevent hallucination

## [2.88.1] - 2026-01-25

### Added

- detect app name in session greeting (#219)

## [2.88.0] - 2026-01-25

### Added

- improve session titles to include task descriptions (#211)
- add email-health-check command and subagent (#213)
- add web performance subagent and /performance command (#209)
- auto-mark tasks complete from commit messages in release (#208)
- add debug-opengraph and debug-favicon subagents (#206)

### Changed

- Refactor: use 'AI DevOps' identity in system prompt
- Refactor: standardize Claude Code naming across documentation (#217)
- Documentation: update README with performance subagent and fix counts
- Documentation: update agent structure counts after email-health-check addition
- Documentation: add recent features to README (#215)
- Documentation: update README counts to reflect current state (#214)
- Documentation: complete t037 ALwrity review for SEO/marketing inspiration (#207)

### Fixed

- add planning-commit-helper.sh to Plan+ bash permissions
- prevent false positive task marking in auto-complete (#216)

## [2.87.3] - 2026-01-25

### Fixed

- pass positional args correctly to case statement (#205)

## [2.87.2] - 2026-01-25

### Fixed

- add external_directory permission to Plan+ agent (#204)

## [2.87.1] - 2026-01-25

### Fixed

- use custom system prompt for ALL primary agents (#203)

## [2.86.1] - 2026-01-25

### Added

- add playwright-cli subagent for AI agent automation (#196)
- allow version check script for initial greeting (#194)

### Changed

- Refactor: replace repomix MCP with CLI (#197)
- Refactor: remove repomix/playwriter from default agent tools (#195)
- Documentation: update README with recent PR features (#193)

## [2.83.1] - 2026-01-25

### Changed

- Refactor: remove serper MCP, use curl subagent instead (#187)
- Refactor: move claude-code-mcp to on-demand loading (#184)

### Fixed

- replace broken uvx command with uv tool run for serper MCP (#186)
- replace remaining associative array in install_mcp_packages
- replace associative array with parallel arrays in MCP migration
- unconditionally disable claude-code-mcp tools globally in setup

## [2.83.0] - 2026-01-24

### Added

- add ClawdHub skill registry as import source with browser automation (#183)

### Changed

- Documentation: add ClawdHub skills and import source to README

## [2.82.0] - 2026-01-24

### Added

- add Examples & Inspiration section to Remotion agent (#182)

## [2.81.0] - 2026-01-24

### Added

- add anti-detect browser automation stack

### Changed

- Documentation: update README with anti-detect browser section and counts

### Fixed

- resolve merge conflict with main and address CodeRabbit review

## [2.80.1] - 2026-01-24

### Fixed

- resolve MCP binary paths to full absolute paths for PATH-independent startup (#179)

## [2.80.0] - 2026-01-24

### Added

- implement multi-tenant credential storage (#178)

### Changed

- Documentation: add changelog entries for multi-tenant credentials
- Documentation: add list-keys subagent documentation

## [2.78.0] - 2026-01-24

### Added

- add HeyGen AI avatar video creation skill (#170)

## [2.77.3] - 2026-01-24

### Fixed

- auto-install fd and ripgrep in non-interactive mode (#171)

## [2.77.2] - 2026-01-24

### Fixed

- add remote sync verification to release script and tag rollback (#168)
- add Homebrew PATH detection early in setup.sh requirements check (#169)
- prefer Homebrew/pyenv python3 over macOS system python in setup.sh (#167)

## [2.77.1] - 2026-01-24

### Changed

- Documentation: add worktree path re-read instruction to AGENTS.md (#166)
- Documentation: update README metrics to match actual counts (#165)

## [2.77.0] - 2026-01-24

### Added

- add Playwright MCP auto-setup to setup.sh (#150)

### Changed

- Documentation: update browser tool docs with benchmarks and add benchmark agent (#163)

### Fixed

- replace bc version comparison with integer arithmetic in crawl4ai-helper (#164)

## [2.76.1] - 2026-01-24

### Changed

- Version bump and maintenance updates

## [2.76.0] - 2026-01-24

### Added

- add Video main agent for AI video generation and prompt engineering (#161)

### Changed

- Documentation: add PR #159, #160, #157 features to README

### Fixed

- remove hardcoded model IDs from agent config generation
- correct tools frontmatter format in pre-edit.md

## [2.75.0] - 2026-01-24

### Added

- multi-agent orchestration & token efficiency (p013/t068) (#158)
- aidevops update now checks planning template versions (#160)
- add session-time-helper and risk field to task format (#159)
- add content summaries to subagent routing table (#157)
- add video-prompt-design subagent for Veo 3 meta prompt framework (#156)

### Changed

- Documentation: add multi-agent orchestration section to README

## [2.74.1] - 2026-01-23

### Fixed

- correct ultimate-multisite plugin URL in wp-preferred.md (#155)

## [2.74.0] - 2026-01-23

### Added

- add technology stack subagents for modern web development (#152)

## [2.73.0] - 2026-01-23

### Added

- add aidevops skill CLI command with telemetry disabled (#154)

## [2.72.0] - 2026-01-22

### Added

- add MiniSim iOS/Android emulator launcher support (#151)

## [2.71.0] - 2026-01-22

### Added

- add Higgsfield AI API support with Context7 documentation (#149)

### Changed

- Documentation: add feature branch scenario guidance to pre-edit workflow (#148)

## [2.70.4] - 2026-01-21

### Changed

- Documentation: add cross-reference from cloudflare.md to cloudflare-platform.md (#147)

## [2.70.3] - 2026-01-21

### Fixed

- resolve Homebrew install failures and improve setup.sh error handling (#146)

## [2.70.2] - 2026-01-21

### Changed

- Documentation: add cloudflare-platform to AGENTS.md subagent table (#145)

## [2.70.1] - 2026-01-21

### Changed

- Documentation: address code review feedback on Imported Skills section (#144)

## [2.70.0] - 2026-01-21

### Added

- import cloudflare-platform skill and add update checking to setup (#142)
- Agent Design Pattern Improvements (t052-t057, t067) (#140)
- add anime.js skill imported via Context7 (#137)
- import Remotion video skill from GitHub (#138)

### Changed

- Documentation: add Imported Skills section to README (#143)
- Documentation: update README with new skills and accurate counts (#141)
- Documentation: update README with Remotion skill and accurate counts

### Fixed

- portable regex and nested skill support (#139)

## [2.69.0] - 2026-01-21

### Added

- Agent Design Pattern Improvements (t052-t057, t067) (#140)
- add anime.js skill imported via Context7 (#137)
- import Remotion video skill from GitHub (#138)

### Changed

- Documentation: update README with new skills and accurate counts (#141)
- Documentation: update README with Remotion skill and accurate counts

### Fixed

- portable regex and nested skill support (#139)

## [2.68.0] - 2026-01-21

### Added

- add /add-skill command for external skill import (#135)

### Changed

- Documentation: add /add-skill command to README (#136)

## [2.67.2] - 2026-01-21

### Changed

- Documentation: add changelog entry for dynamic badge fix

### Fixed

- handle dynamic GitHub release badge in version-manager.sh (#134)

## [2.67.1] - 2026-01-21

### Changed

- Documentation: add changelog entry for version validation fix

### Fixed

- consolidate version validation to single source of truth (#133)

## [2.67.0] - 2026-01-21

### Added

- add readme-helper.sh for dynamic count management (#131)
- add agent design subagents for planning discussions (#132)

### Changed

- Documentation: improve README maintainability and add AI-CONTEXT block (#130)

## [2.66.0] - 2026-01-21

### Added

- Auto-create fd alias on Debian/Ubuntu (#127)

## [2.65.0] - 2026-01-20

### Added

- add README create/update workflow and /readme command (#129)
- add humanise subagent for AI writing pattern removal (#128)
- add humanise subagent for AI writing pattern removal

### Changed

- Documentation: update README and CHANGELOG for humanise feature

### Fixed

- show curl errors for better debugging

## [2.64.0] - 2026-01-20

### Added

- add humanise subagent for AI writing pattern removal (#128)
- add humanise subagent for AI writing pattern removal

### Changed

- Documentation: update README and CHANGELOG for humanise feature

### Fixed

- show curl errors for better debugging

## [2.64.0] - 2026-01-20

### Added

- add humanise subagent for AI writing pattern removal (#128)
- add /humanise slash command for on-demand text humanisation
- add humanise-update-helper.sh to check for upstream skill updates

## [2.63.0] - 2026-01-19

### Added

- add /list-todo and /show-plan commands (#126)

## [2.62.1] - 2026-01-19

### Changed

- Refactor: elevate mcp_glob warning to MANDATORY section (#125)

## [2.62.0] - 2026-01-18

### Added

- add granular bash permissions for file discovery (#123)

### Fixed

- update CLI commands to match official docs (#124)

## [2.61.1] - 2026-01-18

### Fixed

- add missing default cases in tool-version-check.sh (S131) (#122)
- handle pull_request_review_comment events in OpenCode Agent workflow (#121)

## [2.61.0] - 2026-01-18

### Added

- add OpenClaw (formerly Moltbot, Clawdbot) integration for mobile AI access (#118)

### Changed

- Documentation: add one-time Bash guidance for Plan+ file discovery (#119)

### Fixed

- prefer Worktrunk (wt) over worktree-helper.sh (#120)

## [2.60.2] - 2026-01-18

### Fixed

- add context budget, file discovery, and capability guardrails (#117)

## [2.60.1] - 2026-01-17

### Changed

- Documentation: add Worktrunk as recommended worktree tool (#116)

## [2.60.0] - 2026-01-17

### Added

- Add file discovery performance guidance to AGENTS.md with preference order (git ls-files, fd, rg, mcp_glob)
- Add setup_file_discovery_tools() to setup.sh for automatic fd/ripgrep installation
- Add File Discovery Tools section to README.md with documentation

## [2.59.0] - 2026-01-17

### Added

- add auto-commit for planning files (TODO.md, todo/) (#114)

## [2.58.0] - 2026-01-17

### Added

- add path-based write permissions for Plan+ agent (#112)
- add worktrunk as default worktree tool with fallback (#109)

### Fixed

- clean up aidevops runtime files before worktree removal
- change state files from .md to .state extension (#111)
- exclude loop-state from agent discovery and deployment (#110)
- add backup rotation to prevent file accumulation (#108)

## [2.57.0] - 2026-01-17

### Added

- add worktrunk as default worktree tool with fallback (#109)

### Fixed

- add backup rotation to prevent file accumulation (#108)

## [2.56.0] - 2026-01-15

### Added

- point Claude Code MCP to fork (#105)
- add claude-code-mcp server (#103)
- auto-deploy Google Analytics MCP to OpenCode config (#100)
- add Google Analytics MCP integration (#98)
- add /review-issue-pr slash command (#95)
- add review-issue-pr for triaging external contributions (#94)

### Fixed

- improve secretlint performance with ignore patterns (#107)
- handle preflight PASS output (#106)
- resolve unbound variable and use opencode run (#104)
- suppress jq output in plugin array checks
- output options as YAML object instead of string (#101)

## [2.55.0] - 2026-01-14

### Added

- add Peekaboo MCP server integration for macOS GUI automation (#91)
- add macos-automator MCP for AppleScript automation (#89)
- add sweet-cookie documentation for cookie extraction (#90)

### Changed

- Documentation: add && aidevops update to npm/bun/brew install commands (#87)

## [2.54.2] - 2026-01-14

### Fixed

- resolve next.js security vulnerability CVE-2025-66478 (#79)

## [2.54.1] - 2026-01-14

### Fixed

- include aidevops.sh in version updates (#78)

## [2.54.0] - 2026-01-14

### Added

- add subagent filtering via frontmatter (#75)

### Changed

- Documentation: add troubleshooting section with support links to QuickFile agent (#76)
- Documentation: add upgrade-planning and update-tools to CLI commands
- Documentation: add Bun as installation option

### Fixed

- add SonarCloud exclusions for shell code smell rules (#77)

## [2.53.3] - 2026-01-13

### Changed

- Documentation: use aidevops.sh/install URL
- Documentation: use aidevops.sh URL for direct install option
- Documentation: update README with npm/Homebrew install, repo tracking, v2.53.2

## [2.53.0] - 2026-01-13

### Added

- add frontend debugging guide with browser verification patterns (#69)

## [2.52.1] - 2026-01-13

### Fixed

- correct onboarding command path to root agent location (#72)
- use prefix increment to avoid set -e exit on zero (#70)

## [2.52.0] - 2026-01-13

### Added

- add upgrade-planning command (#68)

### Changed

- Documentation: update CHANGELOG.md for v2.52.0 release

## [2.52.0] - 2026-01-13

### Added

- add `aidevops upgrade-planning` command to upgrade TODO.md/PLANS.md to latest TOON-enhanced templates
- add protected branch check to `init` and `upgrade-planning` with worktree creation option
- preserve existing tasks when upgrading planning files with automatic backup

### Fixed

- fix awk frontmatter stripping logic for template processing
- fix BSD/macOS sed compatibility for JSON updates (use awk for portable newlines)

## [2.51.1] - 2026-01-12

### Changed

- Documentation: update CHANGELOG.md for v2.51.1 release

## [2.51.1] - 2026-01-12

### Added

- Loop state migration in setup.sh from `.claude/` to `.agents/loop-state/` (#67)

## [2.51.0] - 2026-01-12

### Added

- add FluentCRM MCP integration for sales and marketing (#64)
- migrate loop state to .agents/loop-state and enhance re-anchor (#65)

### Changed

- Documentation: update CHANGELOG.md for v2.51.0 release
- Documentation: add individual network request throttling to Chrome DevTools (#66)
- Documentation: change governing law to Jersey
- Documentation: add TERMS.md with liability disclaimers

### Fixed

- add missing return statements to shell functions (S7682) (#63)

## [2.51.0] - 2026-01-12

### Added

- FluentCRM MCP integration for sales and marketing automation (#64)
- Ralph loop guardrails system - failures become actionable "signs" (#65)
- Single-task extraction in re-anchor prompts (Loom's "pin" concept) (#65)
- Linkage section in plans-template.md for spec-as-lookup-table pattern (#65)

### Changed

- Loop state directory migrated from `.claude/` to `.agents/loop-state/` (backward compatible) (#65)
- Ralph loop documentation updated with context pollution prevention philosophy (#65)
- Chrome DevTools docs: add individual network request throttling (#66)
- Linter thresholds improved and preflight issues fixed (#62)
- Legal: change governing law to Jersey, add TERMS.md (#62)

### Fixed

- Add missing return statements to shell functions (SonarCloud S7682) (#63)

## [2.50.0] - 2026-01-12

### Added

- add GSC sitemap submission via Playwright automation (#60)
- add agent-browser support for headless browser automation CLI (#59)

### Changed

- Documentation: update browser-automation guide with agent-browser as default (#61)

## [2.49.0] - 2026-01-11

### Added

- add tool update checking to setup.sh and aidevops CLI (#56)
- add OpenProse DSL for multi-agent orchestration (#57)

### Changed

- Documentation: note that OpenProse telemetry is disabled by default in aidevops (#58)
- Documentation: add Twilio and Telfon to README service coverage

## [2.47.0] - 2026-01-11

### Added

- add summarize and bird CLI subagents (t034, t035) (#40)

### Changed

- Documentation: add agent design patterns documentation and improvement plan (#39)

### Fixed

- prevent removal of unpushed branches and uncommitted changes (#42)

## [2.46.0] - 2026-01-11

### Added

- implement v2 architecture with fresh context per iteration (#38)

## [2.45.0] - 2026-01-11

### Added

- add /session-review and /full-loop commands for comprehensive AI workflow (#33)
- add code-simplifier subagent and enforce worktree-first workflow (#34)
- add cross-session memory system with SQLite FTS5 (#32)

### Changed

- Documentation: update CHANGELOG.md for v2.45.0 release
- Documentation: add latest capabilities to README
- Documentation: improve agent instructions based on session review (#31)

### Fixed

- add missing default cases to case statements (#35)

## [2.45.0] - 2026-01-11

### Added

- Cross-session memory system with SQLite FTS5 (`/remember`, `/recall`) (#32)
- Code-simplifier subagent and `/code-simplifier` command (#34)
- `/session-review` and `/full-loop` commands for comprehensive AI workflow (#33)
- Multi-worktree awareness for Ralph loops (`status --all`, parallel warnings)
- Auto-discovery for OpenCode commands from `scripts/commands/*.md` (#37)

### Fixed

- SonarCloud S131 violations - add missing default cases to case statements (#35)

### Changed

- Enforce worktree-first workflow - main repo stays on `main` branch
- Documentation: add multi-worktree section to ralph-loop.md

## [2.44.0] - 2026-01-11

### Added

- add session mapping script and improve pre-edit check (#29)

### Fixed

- resolve postflight ShellCheck and return statement issues (#30)

## [2.43.0] - 2026-01-10

### Added

- add session management and parallel work spawning (#26)
- add interactive mode with step-by-step confirmation (#23)

### Changed

- Documentation: add session management section to README
- Documentation: add line break before tagline
- Documentation: make aidevops bold links to aidevops.sh in prose
- Documentation: add tagline to philosophy section
- Documentation: add philosophy section explaining git-first workflow approach
- Documentation: add OpenCode Anthropic OAuth plugin section to README (#24)

## [2.42.2] - 2026-01-09

### Added

- add opencode-anthropic-auth plugin integration

### Changed

- Documentation: improve AGENTS.md progressive disclosure with descriptive hints (#22)

## [2.42.1] - 2026-01-09

### Changed

- Version bump and maintenance updates

## [2.41.2] - 2025-12-23

### Fixed

- enforce git workflow with pre-edit-check script

## [2.41.1] - 2025-12-23

### Changed

- Version bump and maintenance updates

## [2.41.0] - 2025-12-22

### Added

- inherit OpenCode prompts for Build+ and Plan+ agents (#7)

### Changed

- Refactor: demote build-agent and build-mcp to tools/ subagents

## [2.40.10] - 2025-12-22

### Changed

- Documentation: add comprehensive docstrings to opencode-github-setup-helper.sh
- Documentation: add t022 to Done with time logged

### Fixed

- update .coderabbit.yaml to match v2 schema
- handle git command exceptions in session-rename tool

## [2.40.7] - 2025-12-22

### Changed

- Refactor: move wordpress from root to tools/wordpress
- Documentation: add t021 for auto-marking tasks complete in release workflow
- Documentation: mark t011 as completed in TODO.md

## [2.40.6] - 2025-12-22

### Changed

- Refactor: demote wordpress.md from main agent to subagent

## [2.40.5] - 2025-12-22

### Changed

- Documentation: strengthen git workflow instructions with numbered options

## [2.40.4] - 2025-12-22

### Changed

- Documentation: clarify setup.sh step applies only to aidevops repo
- Documentation: add mandatory setup.sh step to release workflow

### Fixed

- auto-add ~/.local/bin to PATH during installation

## [2.40.3] - 2025-12-22

### Changed

- Version bump and maintenance updates

## [2.40.2] - 2025-12-22

### Added

- add parallel session workflow with branch-synced session naming (#6)
- add OpenCode GitHub/GitLab integration support (#5)

### Changed

- Documentation: update changelog for v2.40.2

## [2.40.2] - 2025-12-22

### Added

- Parallel session workflow with branch-synced session naming
- `/sync-branch` and `/rename` commands for OpenCode session management
- `session-rename` custom tool to update session titles via API
- Branch merge workflow in release.md for merging work branches
- Verb prefix guidance for branch naming (add-, improve-, fix-, remove-)

## [2.40.1] - 2025-12-22

### Changed

- Documentation: add Beads viewer installation and usage instructions

## [2.40.0] - 2025-12-22

### Added

- add backup rotation with per-type organization

### Fixed

- include marketplace.json in version commit staging

## [2.39.1] - 2025-12-21

### Added

- integrate Beads task graph visualization

### Changed

- Documentation: add Beads integration to README and templates

### Fixed

- correct Beads CLI command names in documentation

## [2.39.0] - 2025-12-21

### Added

- integrate Beads task graph visualization

### Fixed

- correct Beads CLI command names in documentation

## [2.38.1] - 2025-12-21

### Changed

- Version bump and maintenance updates

## [2.38.0] - 2025-12-21

### Added

- add persistent browser profile support

### Changed

- Documentation: add agent architecture evaluation tasks

### Fixed

- add branch check to Critical Rules for enforcement

## [2.37.3] - 2025-12-21

### Added

- add Oh-My-OpenCode Sisyphus agents after WordPress in Tab order

### Changed

- Refactor: use minimal AGENTS.md files in database directories
- Documentation: add critical rule to re-read files before editing

### Fixed

- add language specifiers to code blocks (MD040) and blank lines around fences (MD031)
- add missing return statements to 3 scripts
- swap Build+ before Plan+ in Tab order
- add mode: subagent to all agent files for OpenCode compatibility

## [2.37.2] - 2025-12-21

### Changed

- Refactor: simplify planning UX with auto-detection

## [2.37.0] - 2025-12-20

### Added

- add Agent Skills compatibility with SKILL.md generation
- add declarative database schema workflow with aidevops init database

### Fixed

- prevent postflight workflow circular dependency

## [2.36.1] - 2025-12-20

### Added

- add declarative database schema workflow with aidevops init database

### Fixed

- prevent postflight workflow circular dependency

## [2.36.0] - 2025-12-20

### Added

- add declarative database schema workflow with aidevops init database

## [2.35.3] - 2025-12-20

### Added

- add interactive setup wizard for new users

### Changed

- Documentation: add aidevops init, time tracking, and /log-time-spent to README

### Fixed

- change onboarding.md mode from 'agent' to 'subagent'

## [2.35.2] - 2025-12-20

### Added

- add interactive setup wizard for new users

### Changed

- Documentation: add aidevops init, time tracking, and /log-time-spent to README

## [2.35.1] - 2025-12-20

### Added

- add interactive setup wizard for new users

### Changed

- Documentation: add aidevops init, time tracking, and /log-time-spent to README

## [2.35.0] - 2025-12-20

### Added

- add interactive setup wizard for new users

### Changed

- Documentation: add aidevops init, time tracking, and /log-time-spent to README

## [2.34.1] - 2025-12-20

### Changed

- Documentation: add aidevops init, time tracking, and /log-time-spent to README

## [2.34.0] - 2025-12-20

### Added

- add TODO.md planning system with time tracking
- add domain-research subagent with THC and Reconeer APIs
- add TODO.md and planning workflow for task tracking
- add shadcn/ui MCP support for component browsing and installation

### Changed

- Documentation: update README with recent features

## [2.33.0] - 2025-12-18

### Added

- add domain-research subagent with THC and Reconeer APIs
- add TODO.md and planning workflow for task tracking
- add shadcn/ui MCP support for component browsing and installation

## [2.32.0] - 2025-12-18

### Added

- add TODO.md and planning workflow for task tracking
- add shadcn/ui MCP support for component browsing and installation

## [2.31.0] - 2025-12-18

### Added

- add shadcn/ui MCP support for component browsing and installation

## [2.30.0] - 2025-12-18

### Added

- add oh-my-opencode integration with cross-agent references

### Changed

- Documentation: update CHANGELOG.md with comprehensive v2.29.0 release notes

## [2.29.0] - 2025-12-18

### Added

- **OpenCode Antigravity OAuth Plugin** - Auto-install/update during setup
  - Enables Google OAuth authentication for premium model access
  - Available models: gemini-3-pro-high, claude-opus-4-5-thinking, claude-sonnet-4-5-thinking
  - Multi-account load balancing for rate limit distribution and failover
  - Documentation in README.md, aidevops.md, and opencode.md
  - See: https://github.com/NoeFabris/opencode-antigravity-auth
- **GSC User Helper Script** - New `gsc-add-user-helper.sh` for bulk adding users to Google Search Console properties
- **Site Crawler v2.0.0** - Major rewrite of `site-crawler-helper.sh` (~1,000 lines added)
  - Enhanced crawling capabilities
  - Improved SEO analysis features
- **Playwright Bulk Setup** - Improved browser automation documentation in `google-search-console.md` (+148 lines)

### Changed

- Updated `build-agent.md` with browser automation reference
- Enhanced `google-search-console.md` with comprehensive Playwright setup guidance

## [2.28.0] - 2025-12-16

### Added

- add site crawler and content quality scoring agents for SEO auditing

## [2.27.4] - 2025-12-15

### Changed

- Documentation: add MCP config validation errors, WordPress plugin workflow, SCF subagent
- Documentation: fix duplicate changelog entry for v2.27.3

### Fixed

- resolve ShellCheck SC2129 and SC2086 in fix-s131-default-cases.sh

## [2.27.3] - 2025-12-13

### Fixed

- Add retry loop for website docs push race condition (3 attempts with backoff)
- Add retry pattern to sync-wiki.yml workflow

### Added

- Document git push retry pattern in github-actions.md design patterns

## [2.27.2] - 2025-12-13

### Changed

- Documentation: add changelog for v2.27.2
- Documentation: update AGENTS.md with complete SonarCloud exclusion patterns
- Documentation: add SonarCloud security hotspot guidance to prevent recurring issues
- Documentation: fix changelog formatting for v2.27.1

### Fixed

- add *-verify.sh to SonarCloud exclusions
- add S6506 (HTTPS not enforced) to SonarCloud exclusions
- auto-exclude S5332 security hotspots via sonar-project.properties
- resolve code-review-monitoring workflow failures
- resolve SonarCloud critical issues and website docs push conflict

## [2.27.2] - 2025-12-13

### Fixed

- Auto-exclude SonarCloud security hotspots (S5332, S6506) via sonar-project.properties
- Resolve code-review-monitoring workflow failures (SARIF upload, git push race)
- Resolve SonarCloud S131 critical issues (missing default cases)
- Fix website docs workflow push conflicts

### Added

- S131 default case fixer script for future use (`fix-s131-default-cases.sh`)
- SonarCloud security hotspot guidance in AGENTS.md and code-standards.md

## [2.27.1] - 2025-12-13

### Changed

- Performance: use Bun in GitHub Actions for faster CI (~3x faster installs)
- Refactor: prefer Bun over Node.js/npm across local scripts

## [2.27.0] - 2025-12-13

### Added

- add browser tools auto-setup (Bun, dev-browser, Playwriter)
- add dev-browser stateful browser automation support
- add Playwriter MCP to setup auto-configuration
- add Playwriter MCP browser automation support

## [2.26.0] - 2025-12-13

### Added

- add SQL migrations workflow with best practices

## [2.25.0] - 2025-12-13

### Added

- auto-discover primary agents from .agents/*.md files
- add comprehensive git workflow with branch safety and preflight checks

### Changed

- Documentation: add framework internals trigger to progressive disclosure

## [2.24.0] - 2025-12-09

### Added

- add uncommitted changes check before release
- complete osgrep integration with self-testing improvements

## [2.23.1] - 2025-12-09

### Changed

- Documentation: remove ClearSERP references from changelog

## [2.23.0] - 2025-12-09

### Added

- add Google Search Console and Bing Webmaster Tools integration
- add strategic keyword research system
- enable context7 MCP for SEO agent

### Changed

- Documentation: update keyword research documentation
- Documentation: add changelog entry for SEO context7
- Documentation: add changelog entry for new subagents
- Documentation: add new subagents and /list-keys command to README
- Documentation: add changelog entry for README updates
- Documentation: add DataForSEO and Serper MCPs to README

### Fixed

- resolve changelog update regex and restore CHANGELOG.md

## [2.22.0] - 2025-12-07

### Added

- add strategic keyword research system
- enable context7 MCP for SEO agent

### Changed

- Documentation: add changelog entry for SEO context7
- Documentation: add changelog entry for new subagents
- Documentation: add new subagents and /list-keys command to README
- Documentation: add changelog entry for README updates
- Documentation: add DataForSEO and Serper MCPs to README

### Fixed

- resolve changelog update regex and restore CHANGELOG.md

## [2.21.0] - 2025-12-07

### Added

- **Keyword Research System** - Strategic keyword research with SERP weakness detection
  - New `keyword-research.md` subagent with comprehensive documentation
  - New `keyword-research-helper.sh` script (~1000 lines, bash 3.2 compatible)
  - 6 research modes: keyword expansion, autocomplete, domain research, competitor research, keyword gap, extended SERP analysis
  - 17 SERP weakness detection categories across domain/authority, technical, content, and SERP composition
  - KeywordScore algorithm (0-100) based on weakness count, volume, and difficulty
  - Multi-provider support: DataForSEO (primary), Serper (autocomplete), Ahrefs (domain ratings)
  - Locale support with saved preferences (US/UK/CA/AU/DE/FR/ES)
  - Output formats: Markdown tables (TUI) and CSV export to ~/Downloads
- **New OpenCode Slash Commands** - 3 new SEO workflow commands
  - `/keyword-research` - Seed keyword expansion with volume, CPC, difficulty
  - `/autocomplete-research` - Google autocomplete long-tail discovery
  - `/keyword-research-extended` - Full SERP analysis with weakness detection
- **OpenCode CLI Testing Reference** - Added to main agents (build-agent, build-mcp, build-plus, aidevops, seo)
  - Pattern: `opencode run "Test query" --agent [agent-name]`
  - New `opencode-test-helper.sh` script for testing MCP and agent configurations

### Changed

- Updated `seo.md` with keyword research subagent references
- Updated `generate-opencode-commands.sh` with 3 new SEO commands (18 total)
- Updated README with keyword research section and SEO workflow commands

### Fixed

- Added missing return statements to API functions in `keyword-research-helper.sh`
- Added missing return statements to print functions in `opencode-test-helper.sh`

## [2.20.5] - 2025-12-07

### Added

- enable context7 MCP for SEO agent

### Changed

- Documentation: add changelog entry for SEO context7
- Documentation: add changelog entry for new subagents
- Documentation: add new subagents and /list-keys command to README
- Documentation: add changelog entry for README updates
- Documentation: add DataForSEO and Serper MCPs to README

### Fixed

- resolve changelog update regex and restore CHANGELOG.md

## [2.20.4] - 2025-12-07

### Changed

- Documentation: add changelog entry for new subagents
- Documentation: add new subagents and /list-keys command to README
- Documentation: add changelog entry for README updates
- Documentation: add DataForSEO and Serper MCPs to README

### Fixed

- resolve changelog update regex and restore CHANGELOG.md

## [2.20.3] - 2025-12-07

### Changed

- Documentation: add changelog entry for README updates
- Documentation: add DataForSEO and Serper MCPs to README

### Fixed

- resolve changelog update regex and restore CHANGELOG.md

## [2.20.2] - 2025-12-07

### Fixed

- resolve changelog update regex and restore CHANGELOG.md

## [2.19.13] - 2025-12-06

### Security

- **SonarCloud Security Hotspots Resolved** - Fixed 9 of 10 security hotspots
  - Added `--proto '=https'` to curl commands to enforce HTTPS and prevent protocol downgrade attacks
  - Added `--ignore-scripts` to npm install commands to prevent execution of postinstall scripts
  - Files fixed: aidevops-update-check.sh, codacy-cli.sh, qlty-cli.sh, linter-manager.sh, markdown-lint-fix.sh, setup-mcp-integrations.sh
  - 1 hotspot acknowledged as safe (localhost-helper.sh http:// for local dev when SSL disabled)

## [2.19.12] - 2025-12-06

### Fixed

- Version bump release (no functional changes)

## [2.19.11] - 2025-12-06

### Added

- **Session Greeting with Version Check** - AI assistants now greet with aidevops version at session start
  - Automatic version check via `aidevops-update-check.sh` script
  - Update notification when new version available
  - Clickable URL format: "Hi! We're running https://aidevops.sh v{version}"

### Changed

- **OpenCode AGENTS.md Instructions** - Strengthened version check compliance
  - Changed from "MANDATORY" to "CRITICAL - DO THIS FIRST"
  - Explicit Bash tool specification to prevent webfetch errors
  - Added `instructions` field to opencode.json for reliable loading

### Fixed

- **TypeError on Session Start** - Fixed `undefined is not an object (evaluating 'response.headers')` error
  - Caused by ambiguous "silently run" instruction interpreted as webfetch
  - Now explicitly specifies Bash tool for version check script
- **Local Linter False Positives** - Improved accuracy of linters-local.sh
  - Return statement check now recognizes `return $var` and `return $((expr))` patterns
  - Positional parameter check excludes multi-line awk scripts, heredocs, and comments
  - Reduced false positives from 15 to 0
- **SonarCloud S131 Violations** - Added default cases to case statements
  - version-manager.sh, postflight-check.sh, generate-opencode-agents.sh
- **SonarCloud S7682 and S7679 Issues** - Resolved return statement and positional parameter violations

## [2.17.1] - 2025-12-06

### Changed

- Removed AI tool symlink directories and files that caused duplicate `@` references in OpenCode
- Updated .gitignore to ignore tool-specific symlinks (.ai, .kiro, .continue, .cursorrules, .windsurfrules, .continuerules, .claude/, .codex/, .cursor/, .factory/)
- Added "AI Tool Configuration" section to AGENTS.md documenting canonical agent location (~/.aidevops/agents/)

## [2.17.0] - 2025-12-06

### Added

- **linters-local.sh Script** - New local quality check script for offline linting
  - ShellCheck, secretlint, and pattern-based checks
  - No external service dependencies required
- **code-standards.md** - Consolidated code review guidance and quality standards
- **code-audit-remote.md Workflow** - Remote repository audit workflow
  - CodeRabbit, Codacy, and SonarCloud integration
- **pr.md Workflow** - Unified PR orchestrator (renamed from pull-request.md)
- **Stagehand Python MCP Templates** - New templates for Python-based browser automation
  - `stagehand-both.json` - Combined TypeScript and Python configuration
  - `stagehand-python.json` - Python-only configuration

### Changed

- **changelog.md Workflow** - Improved entry writing guidance and formatting
- **Consolidated Code Review Agents** - Merged code-quality.md into code-standards.md
- **Renamed pull-request.md to pr.md** - Shorter, consistent naming
- **Updated Workflow Agents** - Enhanced branch, preflight, postflight, release workflows
- **Cross-Reference Updates** - Updated ~40 agent files with new paths

### Removed

- **quality-check.sh** - Replaced by linters-local.sh
- **code-quality.md** - Consolidated into code-standards.md
- **code-review.md Workflow** - Consolidated into code-audit-remote.md

## [2.16.0] - 2025-12-06

### Added

- **Unified PR Command** - New `/pr` command orchestrating all quality checks
  - Combines linters-local, code-audit-remote, and code-standards checks
  - Intent vs reality analysis for comprehensive PR validation
- **Local Linting Command** - New `/linters-local` command for fast, offline linting
  - ShellCheck, secretlint, and pattern checks
  - No external service dependencies
- **Remote Audit Command** - New `/code-audit-remote` command for remote auditing
  - CodeRabbit, Codacy, and SonarCloud integration
- **Code Standards Command** - New `/code-standards` command for quality standards checking
- **New Scripts and Workflows**:
  - `linters-local.sh` - Local linting script (replaces quality-check.sh)
  - `workflows/pr.md` - Unified PR orchestrator workflow
  - `workflows/code-audit-remote.md` - Remote auditing workflow
  - `tools/code-review/code-standards.md` - Quality standards reference

### Changed

- **Renamed Scripts and Workflows** - Clarified naming for local vs remote operations
  - `quality-check.sh` → `linters-local.sh` (clarifies local-only scope)
  - `workflows/code-review.md` → `workflows/code-audit-remote.md` (clarifies remote services)
  - `tools/code-review/code-quality.md` → `tools/code-review/code-standards.md` (clarifies reference purpose)
  - `workflows/pull-request.md` → `workflows/pr.md` (now orchestrates all checks)
  - `@code-quality` subagent → `@code-standards`
- **Updated Documentation** - Comprehensive cross-reference updates
  - Updated `generate-opencode-commands.sh` with new command structure
  - Updated AGENTS.md with new quality workflow documentation
  - Updated README.md with new commands and workflow
  - Updated cross-references across ~40 agent files

### Removed

- `quality-check.sh` - Replaced by `linters-local.sh`
- `workflows/code-review.md` - Replaced by `workflows/code-audit-remote.md`
- `workflows/pull-request.md` - Replaced by `workflows/pr.md`
- `tools/code-review/code-quality.md` - Replaced by `tools/code-review/code-standards.md`

## [2.15.0] - 2025-12-06

### Added

- **OpenCode Commands Generation** - New `generate-opencode-commands.sh` script
  - Creates 13 workflow slash commands for OpenCode: `/agent-review`, `/preflight`, `/postflight`, `/release`, `/version-bump`, `/changelog`, `/code-audit-remote`, `/linters-local`, `/feature`, `/bugfix`, `/hotfix`, `/context`, `/pr`
  - Commands deployed to `~/.config/opencode/commands/` directory
  - Integrated into `setup.sh` for automatic deployment during installation

## [2.14.0] - 2025-12-06

### Added

- **Conversation Starter Workflow** - New `workflows/conversation-starter.md` for Plan+ and Build+
  - Unified prompts for git repository context (12 workflow options)
  - Remote services menu for non-git contexts (9 service integrations)
  - Automatic subagent context loading based on user selection

### Changed

- **Plan+ Agent Refactored** - Aligned with upstream OpenCode Plan prompts
  - 5-phase planning workflow: Understand, Investigate, Synthesize, Finalize, Handoff
  - Parallel explore agents support (1-3 agents in single message)
  - Reduced AI-CONTEXT from 100 to 49 lines (within instruction budget)
  - Added context tools table (osgrep, Augment, context-builder, Context7)

- **Build+ Agent Refactored** - Aligned with upstream OpenCode Build prompt (beast.txt)
  - Reduced AI-CONTEXT from 119 to 55 lines (within instruction budget)
  - Added context tools and quality integration tables
  - Preserved all 9 workflow steps with enhanced guidance
  - Added file reading best practices section

## [2.13.0] - 2025-12-06

### Added

- **One-liner Install Command** - Universal install/update via curl
  - `bash <(curl -fsSL https://raw.githubusercontent.com/marcusquinn/aidevops/main/setup.sh)`
  - Auto-detects curl execution, clones repo to ~/Git/aidevops
  - Re-executes local setup.sh after cloning for full setup
- **Global `aidevops` CLI Command** - New CLI installed to /usr/local/bin/aidevops
  - `aidevops status` - Comprehensive installation status check
  - `aidevops update` - Update to latest version
  - `aidevops uninstall` - Clean removal with prompts
  - `aidevops version` - Version info with update check
  - `aidevops help` - Usage information
- **Interactive Setup Prompts** - Enhanced setup.sh with optional installations
  - Required dependencies (jq, curl, ssh) via detected package manager
  - Optional dependencies (sshpass)
  - Recommended tools (Tabby terminal, Zed editor)
  - OpenCode extension for Zed
  - Git CLI tools (gh, glab)
  - SSH key generation
  - Shell aliases
- **Multi-Platform Package Manager Support** - Auto-detects brew, apt, dnf, yum, pacman, apk
- **Multi-Shell Support** - Detects and configures bash, zsh, fish, ksh with correct rc files
- **CLI Reference Documentation** - New `.wiki/CLI-Reference.md` with complete CLI docs

### Changed

- **setup.sh** - Major refactor with bootstrap_repo(), install_aidevops_cli(), setup_recommended_tools()
- **README.md** - Updated Quick Start section with one-liner install
- **Getting-Started.md** - Comprehensive installation guide update
- **Home.md** - Updated with new install method

## [2.12.0] - 2025-12-05

### Added

- **YAML Frontmatter with Tool Permissions** - Added to ~120 subagent files
  - Standardized tool permission declarations across all subagents
  - Enables OpenCode to enforce tool access controls per agent
- **Agent Directory Architecture Documentation** - Documented `.agents/` vs `.opencode/agent/` structure
  - Clarified deployment paths and directory purposes

### Changed

- **OpenCode Frontmatter Format** - Updated `build-agent.md` with correct format
  - Removed invalid `list` tool references from frontmatter
  - Removed invalid `permission` blocks from frontmatter
  - Aligned with OpenCode configuration validation requirements

### Removed

- **Duplicate Wiki File** - Removed `Workflow-Guides.md` (duplicate of `Workflows-Guide.md`)

### Fixed

- **OpenCode Config Validation Errors** - Fixed frontmatter format issues
  - Corrected tool permission syntax across subagent files
  - Resolved validation errors preventing agent loading

## [2.11.0] - 2025-12-05

### Added

- **osgrep Local Semantic Search** - New tool integration for 100% private semantic code search
  - Documentation in `.agents/tools/context/osgrep.md`
  - Config templates for osgrep MCP integration
  - Updated setup.sh and scripts for osgrep CLI support
  - GitHub issue comments submitted (#58, #26) for upstream bug tracking

## [2.10.0] - 2025-12-05

### Added

- **Conversation Starter Prompts** - Plan+ and Build+ agents now offer guided workflow selection
  - Git repository context: Workflow menu (Feature, Bug Fix, Hotfix, Refactor, PR, Release, etc.)
  - Non-git context: Remote services menu (101domains, Closte, Cloudflare, Hetzner, etc.)
  - Automatic subagent context loading based on user selection
- **Workflow Subagents** - Three new workflow subagents for release lifecycle
  - `workflows/preflight.md` - Pre-release quality checks (ShellCheck, Secretlint, SonarCloud)
  - `workflows/pull-request.md` - PR/MR workflow for GitHub, GitLab, and Gitea
  - `workflows/postflight.md` - Post-release CI/CD verification and rollback procedures
- **Preflight Integration** - Automatic quality gates before version bumping
  - New `--skip-preflight` flag for emergency releases
  - Phased checks: instant blocking, fast blocking, medium, slow advisory

### Changed

- **Enhanced Branch Lifecycle** - Expanded `workflows/branch.md` from 7 to 11 stages
  - New stages: Preflight, Version, Postflight
  - Subagent references at each lifecycle stage
  - Visual workflow chain diagram

## [2.9.0] - 2025-12-05

### Added

- **Branch Workflow System** - New `workflows/branch.md` with 6 branch type subagents
  - Feature, bugfix, hotfix, refactor, chore, experiment branch workflows
  - Standardized naming conventions and merge strategies
- **Setup.sh --clean Flag** - Remove stale deployed files during setup
  - New `verify-mirrors.sh` script for checking agent directory mirrors
- **Git Safety Practices** - Added to all build agents
  - Pre-destructive operation stash guidance
  - Protection for uncommitted and untracked files
- **Changelog Workflow** - New `workflows/changelog.md` subagent
  - Changelog validation in version-manager.sh
  - `changelog-check` and `changelog-preview` commands
  - Enforced changelog updates before releases

### Changed

- **Restructured Git Tools** - `tools/git.md` reorganized with platform CLI subagents
  - GitHub, GitLab, and Gitea CLI helpers as dedicated subagents
  - New `git/authentication.md` and `git/security.md` subagents
- **Consolidated Security Documentation** - Scripts security merged into `aidevops/security.md`
- **Separated Version Workflows** - Split into `version-bump.md` and `release.md` for clarity

### Removed

- Redundant `workflows/README.md` (content merged into main workflow docs)
- `release-improvements.md` (consolidated into release.md)

## [2.8.1] - 2025-12-04

### Added

- **OpenCode Tools** - Custom tool definitions for OpenCode AI assistant
- **MCP Testing Infrastructure** - Docker-based testing for MCP servers

### Changed

- Minor documentation updates and quality improvements

## [2.8.0] - 2025-12-04

### Added

- **Build-Agent** - New main agent for composing efficient AI agents
  - Promoted from `agent-designer.md` to main agent status
  - Comprehensive guidance on instruction budgets and agent design
- **Build-MCP** - New main agent for MCP server development
  - TypeScript + Bun + ElysiaJS stack guidance
  - Tool, resource, and prompt registration patterns

### Changed

- **Agent Naming Conventions** - Documented in `agent-designer.md`
- Reduced instruction count in agent-designer.md for efficiency
- Updated README with Build-Agent and Build-MCP in main agents table

## [2.7.4] - 2025-12-04

### Fixed

- **Outscraper API URL Correction** - Fixed base URL from `api.outscraper.cloud` to `api.app.outscraper.com`
  - Matches official Python SDK at <https://github.com/outscraper/outscraper-python>

### Added

- **Outscraper Account & Billing API Documentation** - New endpoints not available in Python SDK
  - `GET /profile/balance` - Account balance, status, and upcoming invoice
  - `GET /invoices` - User invoice history
- **Outscraper Task Management API Documentation** - Full task lifecycle control
  - `POST /tasks` - Create UI tasks programmatically
  - `POST /tasks-validate` - Validate and estimate task cost before creation
  - `PUT /tasks/{taskId}` - Restart tasks
  - `DELETE /tasks/{taskId}` - Terminate tasks
  - `GET /webhook-calls` - Failed webhook calls (last 24 hours)
  - `GET /locations` - Country locations for Google Maps searches
- **SDK vs Direct API Clarification** - Added "In SDK" column to endpoint tables
  - Clearly marked which features require direct API calls vs SDK methods
  - Added link to official SDK repository
- **Expanded Tool Coverage** - Additional tools documented
  - `yelp_reviews`, `yelp_search`, `trustpilot_search`, `yellowpages_search`
  - `contacts_and_leads`, `whitepages_phones`, `whitepages_addresses`
  - `company_websites_finder`, `similarweb`
- **Python Examples** - Comprehensive code examples for all API patterns
  - Account & Billing section (Direct API Only)
  - Task Management section (Direct API + SDK hybrid)
  - Proper initialization patterns with both SDK and direct requests

### Changed

- **Account Access Documentation** - Replaced incorrect "Account Limitations" section
  - Previously stated account info was dashboard-only (incorrect)
  - New "Account Access via API" section with accurate endpoint information

## [2.7.3] - 2025-12-04

### Fixed

- **Outscraper MCP Documentation Improvements** - Enhanced documentation quality and accuracy
  - Fixed JSON syntax error in documentation (malformed JSON block with extra braces)
  - Standardized install command from `uvx` to `uv tool run` for consistency
  - Added "Tested tools" section documenting verified functionality (Dec 2024)
  - Added OpenCode-specific troubleshooting section for `env` key and `uvx` command issues

## [2.7.2] - 2025-12-04

### Fixed

- **Outscraper MCP Server Fails to Start** - Fixed `uvx` command conflict
  - `uvx` on some systems is a different tool (not uv's uvx alias)
  - Changed to `uv tool run outscraper-mcp-server` which is the correct way to run Python tools with uv
  - Updated `generate-opencode-agents.sh`, `outscraper.md`, `outscraper.json` template, and `outscraper-config.json.txt`

## [2.7.1] - 2025-12-04

### Fixed

- **OpenCode MCP Config Validation Error** - Fixed invalid `env` key in MCP configuration
  - OpenCode does not support the `env` key for MCP server configs
  - Changed to bash wrapper pattern: `/bin/bash -c "VAR=$VAR command"`
  - Updated `generate-opencode-agents.sh`, `outscraper.md`, `outscraper.json` template, and `outscraper-config.json.txt`

## [2.7.0] - 2025-12-04

### Added

- **Outscraper MCP Server Integration** - Data extraction service for OpenCode
  - Automatic MCP server configuration in `generate-opencode-agents.sh`
  - Adds `outscraper` to MCP section with uvx command and environment variable
  - Subagent-only access pattern via `@outscraper` for controlled usage

### Changed

- **Tool-Specific Subagent Strategy** - Enhanced security model for external service tools
  - Added special handling for tool-specific subagents (outscraper, mainwp, localwp, quickfile, google-search-console)
  - Main agents (Content, Marketing, Research, Sales, SEO) no longer have direct outscraper access
  - Tools disabled globally (`outscraper_*: false`) with access only through dedicated subagents
- Updated `outscraper.md` documentation to reflect subagent-only access pattern
- Updated `outscraper-config.json.txt` agent enablement section

## [2.6.0] - 2025-12-04

### Added

- **Repomix AI Context Generation** - Configuration and documentation for Repomix integration
  - `repomix.config.json` - Default configuration with XML output, line numbers, security checks, smart includes for .md/.sh/.json.txt files
  - `.repomixignore` - Additional exclusions beyond .gitignore (symlinked dirs, binaries, generated outputs)
  - `repomix-instruction.md` - Custom AI instructions embedded in Repomix output to help AI understand codebase structure

### Changed

- Updated `.gitignore` with `repomix-output.*` patterns to exclude generated outputs
- Enhanced `README.md` with comprehensive "Repomix - AI Context Generation" section:
  - Comparison table with Augment Context Engine
  - Quick usage commands and configuration files reference
  - Key design decisions (no pre-generated files, .gitignore inheritance, Secretlint enabled, symlinks excluded)
  - MCP integration configuration example

## [2.5.3] - 2025-12-04

### Security

- **Plan+ Agent Permission Bypass Fix** - Closed vulnerability allowing read-only agent to bypass restrictions
  - Disabled `bash` tool to prevent shell command file writes
  - Disabled `task` tool to prevent spawning write-capable subagents (subagents don't inherit parent permissions)
  - Added explicit `write: deny` permission for defense in depth
  - Updated `.agents/plan-plus.md` documentation to reflect strict read-only mode

### Added

- **Permission Model Limitations Documentation** - New section in `.agents/tools/opencode/opencode.md`
  - Documents OpenCode permission inheritance behavior
  - Explains subagent permission isolation
  - Provides guidance for securing read-only agents

## [2.2.0] - 2025-11-30

### Added

- **Secretlint Integration** - Secret detection tool to prevent committing credentials
  - New `secretlint-helper.sh` for installation, scanning, and pre-commit hook management
  - Configuration files `.secretlintrc.json` and `.secretlintignore` for project-specific setup
  - Comprehensive documentation in `.agents/secretlint.md`
  - Multi-provider detection: AWS, GCP, GitHub, OpenAI, Anthropic, Slack, npm tokens
  - Private key detection: RSA, DSA, EC, OpenSSH keys
  - Database connection string scanning
  - Docker support for running scans without Node.js

### Changed

- Updated `quality-check.sh` with secretlint integration for comprehensive secret scanning
- Enhanced `pre-commit-hook.sh` with secretlint pre-commit checks
- Extended `linter-manager.sh` with secretlint as a supported security linter
- Updated `.gitignore` with exceptions for secretlint tool files

### Fixed

- Removed duplicate/unreachable return statements in helper scripts
- Replaced eval with array-based execution for improved security
- Changed hardcoded /tmp paths to mktemp for safer temporary file handling
- Added input validation for target patterns in quality scripts
- Fixed unused variables and awk field references
- Fixed markdown formatting issues

## [2.0.0] - 2025-11-29

### Added

- **Comprehensive AI Workflow Documentation** - 9 new workflow guides in `.agents/workflows/`:
  - `git-workflow.md` - Git practices and branch strategies
  - `bug-fixing.md` - Bug fix and hotfix workflows
  - `feature-development.md` - Feature development lifecycle
  - `code-review.md` - Universal code review checklist
  - `error-checking-feedback-loops.md` - CI/CD feedback automation with GitHub API
  - `multi-repo-workspace.md` - Multi-repository safety guidelines
  - `release-process.md` - Semantic versioning and release management
  - `wordpress-local-testing.md` - WordPress testing environments
  - `README.md` - Workflow index and guide
- **Quality Feedback Helper Script** - `quality-feedback-helper.sh` for GitHub API-based quality tool feedback retrieval (Codacy, CodeRabbit, SonarCloud, CodeFactor)
- OpenCode as preferred CLI AI assistant in documentation
- Grep by Vercel MCP server integration for GitHub code search
- Cross-tool AI assistant symlinks (.cursorrules, .windsurfrules, CLAUDE.md, GEMINI.md)
- OpenCode custom tool definitions in `.opencode/tool/`
- Consolidated `.agents/` directory structure
- Developer preferences guidance in `.agents/memory/README.md`

### Changed

- **Major milestone**: Comprehensive AI assistant workflow documentation
- Reorganized CLI AI assistants list with OpenCode at top
- Moved AmpCode and Continue.dev from Security section to CLI Assistants
- Updated MCP server count to 13
- Standardized service counts across documentation (30+)
- Enhanced `.markdownlint.json` configuration

### Fixed

- All CodeRabbit, Codacy, and ShellCheck review issues resolved
- Duplicate timestamp line in system-cleanup.sh
- Hardcoded path in setup-mcp-integrations.sh
- SC2155 ShellCheck violations in workflow scripts
- MD040 markdown code block language identifiers
- MD031 blank lines around code blocks

## [1.9.1] - 2024-11-28

### Added

- Snyk security scanning as 29th service integration
- Enhanced quality automation workflows

### Fixed

- Code quality improvements via automated fixes

## [1.9.0] - 2024-11-27

### Added

- Version validation workflow
- Auto-version bump scripts
- Enhanced Git CLI helpers for GitHub, GitLab, and Gitea

### Changed

- Improved quality check scripts
- Updated documentation structure

## [1.8.0] - 2024-11-19

### Added

- Zero technical debt milestone achieved
- Multi-platform quality compliance (SonarCloud, CodeFactor, Codacy)
- Universal parameter validation patterns across all provider scripts
- Automated quality tool integration

### Changed

- **Positional Parameters (S7679)**: 196 → 0 violations (100% elimination)
- **SonarCloud Issues**: 585 → 0 issues (perfect compliance)
- All provider scripts now use proper main() function wrappers
- Enhanced error handling with local variable usage

### Fixed

- Return statement issues across all scripts
- ShellCheck violations in 21 files

## [1.7.2] - 2024-11-15

### Added

- Initial MCP integrations (10 servers)
- Browser automation with Stagehand AI
- SEO tools integration (Ahrefs, Google Search Console)

### Changed

- Expanded service coverage to 26+ integrations

## [1.7.0] - 2024-11-10

### Added

- TOON Format integration for token-efficient data exchange
- DSPy integration for prompt optimization
- PageSpeed Insights and Lighthouse integration
- Updown.io monitoring integration

### Changed

- Restructured documentation for better clarity

## [1.6.0] - 2024-11-01

### Added

- Git platform CLI helpers (GitHub, GitLab, Gitea)
- Coolify and Vercel CLI integrations
- Cloudron hosting support

### Changed

- Enhanced multi-account support across providers

## [1.5.0] - 2024-10-15

### Added

- Quality CLI manager for unified tool access
- CodeRabbit AI-powered code review integration
- Qlty universal linting platform support

### Changed

- Improved quality automation workflows

## [1.0.0] - 2024-09-01

### Added

- Initial release of AI DevOps Framework
- Core provider integrations (Hostinger, Hetzner, Cloudflare)
- SSH key management utilities
- AGENTS.md guidance system
- Basic quality assurance setup

[Unreleased]: https://github.com/marcusquinn/aidevops/compare/v2.29.0...HEAD
[2.29.0]: https://github.com/marcusquinn/aidevops/compare/v2.28.0...v2.29.0
[2.28.0]: https://github.com/marcusquinn/aidevops/compare/v2.27.4...v2.28.0
[2.27.4]: https://github.com/marcusquinn/aidevops/compare/v2.27.3...v2.27.4
[2.27.3]: https://github.com/marcusquinn/aidevops/compare/v2.27.2...v2.27.3
[2.27.2]: https://github.com/marcusquinn/aidevops/compare/v2.27.1...v2.27.2
[2.27.1]: https://github.com/marcusquinn/aidevops/compare/v2.27.0...v2.27.1
[2.27.0]: https://github.com/marcusquinn/aidevops/compare/v2.26.0...v2.27.0
[2.26.0]: https://github.com/marcusquinn/aidevops/compare/v2.25.0...v2.26.0
[2.25.0]: https://github.com/marcusquinn/aidevops/compare/v2.24.0...v2.25.0
[2.24.0]: https://github.com/marcusquinn/aidevops/compare/v2.23.1...v2.24.0
[2.23.1]: https://github.com/marcusquinn/aidevops/compare/v2.23.0...v2.23.1
[2.23.0]: https://github.com/marcusquinn/aidevops/compare/v2.22.0...v2.23.0
[2.22.0]: https://github.com/marcusquinn/aidevops/compare/v2.21.0...v2.22.0
[2.21.0]: https://github.com/marcusquinn/aidevops/compare/v2.20.5...v2.21.0
[2.20.5]: https://github.com/marcusquinn/aidevops/compare/v2.20.4...v2.20.5
[2.20.4]: https://github.com/marcusquinn/aidevops/compare/v2.20.3...v2.20.4
[2.20.3]: https://github.com/marcusquinn/aidevops/compare/v2.20.2...v2.20.3
[2.20.2]: https://github.com/marcusquinn/aidevops/compare/v2.19.13...v2.20.2
[2.19.13]: https://github.com/marcusquinn/aidevops/compare/v2.19.12...v2.19.13
[2.19.12]: https://github.com/marcusquinn/aidevops/compare/v2.19.11...v2.19.12
[2.19.11]: https://github.com/marcusquinn/aidevops/compare/v2.17.1...v2.19.11
[2.17.1]: https://github.com/marcusquinn/aidevops/compare/v2.17.0...v2.17.1
[2.17.0]: https://github.com/marcusquinn/aidevops/compare/v2.16.0...v2.17.0
[2.16.0]: https://github.com/marcusquinn/aidevops/compare/v2.15.0...v2.16.0
[2.15.0]: https://github.com/marcusquinn/aidevops/compare/v2.14.0...v2.15.0
[2.14.0]: https://github.com/marcusquinn/aidevops/compare/v2.13.0...v2.14.0
[2.13.0]: https://github.com/marcusquinn/aidevops/compare/v2.12.0...v2.13.0
[2.12.0]: https://github.com/marcusquinn/aidevops/compare/v2.11.0...v2.12.0
[2.11.0]: https://github.com/marcusquinn/aidevops/compare/v2.10.0...v2.11.0
[2.10.0]: https://github.com/marcusquinn/aidevops/compare/v2.9.0...v2.10.0
[2.9.0]: https://github.com/marcusquinn/aidevops/compare/v2.8.1...v2.9.0
[2.8.1]: https://github.com/marcusquinn/aidevops/compare/v2.8.0...v2.8.1
[2.8.0]: https://github.com/marcusquinn/aidevops/compare/v2.7.4...v2.8.0
[2.7.4]: https://github.com/marcusquinn/aidevops/compare/v2.7.3...v2.7.4
[2.7.3]: https://github.com/marcusquinn/aidevops/compare/v2.7.2...v2.7.3
[2.7.2]: https://github.com/marcusquinn/aidevops/compare/v2.7.1...v2.7.2
[2.7.1]: https://github.com/marcusquinn/aidevops/compare/v2.7.0...v2.7.1
[2.7.0]: https://github.com/marcusquinn/aidevops/compare/v2.6.0...v2.7.0
[2.6.0]: https://github.com/marcusquinn/aidevops/compare/v2.5.3...v2.6.0
[2.5.3]: https://github.com/marcusquinn/aidevops/compare/v2.2.0...v2.5.3
[2.2.0]: https://github.com/marcusquinn/aidevops/compare/v2.0.0...v2.2.0
[2.0.0]: https://github.com/marcusquinn/aidevops/compare/v1.9.1...v2.0.0
[1.9.1]: https://github.com/marcusquinn/aidevops/compare/v1.9.0...v1.9.1
[1.9.0]: https://github.com/marcusquinn/aidevops/compare/v1.8.0...v1.9.0
[1.8.0]: https://github.com/marcusquinn/aidevops/compare/v1.7.2...v1.8.0
[1.7.2]: https://github.com/marcusquinn/aidevops/compare/v1.7.0...v1.7.2
[1.7.0]: https://github.com/marcusquinn/aidevops/compare/v1.6.0...v1.7.0
[1.6.0]: https://github.com/marcusquinn/aidevops/compare/v1.5.0...v1.6.0
[1.5.0]: https://github.com/marcusquinn/aidevops/compare/v1.0.0...v1.5.0
[1.0.0]: https://github.com/marcusquinn/aidevops/releases/tag/v1.0.0
