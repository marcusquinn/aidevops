# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

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
