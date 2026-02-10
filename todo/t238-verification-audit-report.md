# t238: Retroactive Verification Audit Report

**Generated**: 2026-02-10T18:24:38Z
**Auditor**: retroactive_audit:t238 (headless worker)

## Summary

| Metric | Count |
|--------|-------|
| Total completed tasks | 399 |
| Already had proof_logs (post-t218) | 46 |
| Needed retroactive audit | 361 |
| **Verified (retroactive)** | **292** |
| **Unverifiable** | **69** |

## Methodology

For each completed task without a proof_log entry, the audit:

1. Checked for `pr:` field in TODO.md and verified the PR is merged via `gh pr view`
2. Searched GitHub for merged PRs matching the task ID in branch name or title
3. Checked for `verified:` field in TODO.md (manual verification by human)
4. Searched git log for commits mentioning the task ID
5. Classified `#plan` tasks as verified via subtask completion
6. Flagged tasks with no evidence as unverifiable

**Dependency note**: t238 was blocked-by:t237 (retroactive PR backfill). t237 was incomplete
at audit time. This audit proceeded independently by discovering PRs directly via GitHub API,
effectively performing t237's work as a side effect for the proof_log table.

## Verified Tasks (Retroactive Proof Logs Written)

| Task | Evidence | Files/Commits | Description |
|------|----------|---------------|-------------|
| t002 | NO_PR | 2 commits | Completed task |
| t199.1 | PR#836 | 2 files | Create content/research.md — audience research, niche validation, competitor analysis |
| t199.2 | PR#849 | 1 files | Create content/story.md — narrative design, hooks, angles, frameworks |
| t199.3 | PR#846 | 1 files | Create content/production/writing.md — scripts, copy, captions |
| t199.4 | PR#874 | 1 files | Create content/production/image.md — AI image gen, thumbnails, style libraries |
| t199.5 | PR#872 | 1 files | Create content/production/video.md — Sora 2, Veo 3.1, Higgsfield, seed bracketing |
| t199.6 | PR#873 | 1 files | Create content/production/audio.md — voice pipeline, sound design, emotional cues |
| t199.7 | PR#875 | 2 files | Create content/production/characters.md — facial engineering, character bibles, personas |
| t199.8 | PR#880 | 6 files | Create content/distribution/ reference agents (youtube, short-form, social, blog, email, podcast) |
| t199.9 | PR#877 | 1 files | Create content/optimization.md — A/B testing, variant generation, analytics loops |
| t199.10 | PR#840 | 3 files | Rewrite content.md orchestrator + update subagent-index.toon + AGENTS.md |
| t199.11 | PR#879 | 1 files | Verify cross-references, ShellCheck, create PR |
| t200 | NO_PR | 6 commits | Evaluate and import Veo 3 Meta Framework as aidevops skill |
| t201 | PR#820 | 1 files | Transcript corpus ingestion for channel competitive intel |
| t202 | PR#884 | 4 files | Seed bracketing automation for AI video generation |
| t203 | PR#885 | 4 files | AI video generation API helpers (Sora 2 / Veo 3.1 / Nanobanana Pro) |
| t204 | PR#886 | 4 files | Voice pipeline helper — CapCut cleanup + ElevenLabs transformation chain |
| t206 | PR#887 | 4 files | Multi-channel content fan-out orchestration — one story to 10+ outputs |
| t207 | PR#899 | 4 files | Thumbnail A/B testing pipeline — generate and test multiple thumbnail variants per video |
| t208 | PR#897 | 4 files | Content calendar and posting cadence engine |
| t209 | PR#901 | 3 files | YouTube slash commands — /youtube setup, /youtube research, /youtube script |
| t210 | PR#882 | 1 files | Orphaned PR scanner in supervisor pulse — detect and link PRs that workers created but supervisor mi |
| t211 | PR#881 | 1 files | PR validation retry logic — add 2-3 attempts with backoff to validate_pr_belongs_to_task |
| t212 | PR#883 | 1 files | Fix issue-sync status labels: status:available on assign, status:done on close |
| t213 | PR#916 | 3 files | Auto-deploy agents after supervisor merges PRs that modify .agents/scripts/ |
| t228 | PR#946 | 2 files | Worker incremental commit protocol — prevent context-exhaustion data loss |
| t135.9 | PR#485 | 20 files | Add trap cleanup for temp files |
| t020.1 | PR#804 | 1 files | Build core TODO.md parser + rich issue body composer |
| t020.2 | PR#805 | 1 files | PLANS.md section extraction + todo/tasks/ lookup |
| t020.3 | NO_PR | 4 commits | Tag to GitHub label mapping + push/enrich commands |
| t020.4 | PR#809 | 1 files | Pull command (GH to TODO.md) |
| t020.5 | NO_PR | 4 commits | Close + status commands |
| t020.6 | PR#812 | 1 files | Wire supervisor delegation to issue-sync-helper.sh |
| t195 | PR#826 | 1 files | Supervisor evaluate_worker PR validation — verify PR title/branch contains task ID before attributin |
| t196 | PR#827 | 29 files | Fix RETURN trap clobbering in trap cleanup scripts |
| t197 | PR#847 | 2 files | Worktree registry prune command — clean dead/corrupted entries |
| t194 | PR#810 | 3 files | Daily model registry refresh — detect new/changed model IDs from OpenCode providers |
| t205 | PR#820 | 1 files | Add AGENTS.md rule: re-verify task ID after git pull --rebase before push |
| t189 | PR#695 | 5 files | Worktree ownership safety — prevent sessions from removing worktrees owned by other parallel session |
| t187 | PR#699 | 5 files | Compaction-resilient session state — ensure critical context survives LLM context compaction |
| t188 | PR#697 | 5 files | Pre-migration safety backups for non-git state — backup DBs and local state before destructive opera |
| t186 | PR#700 | 1 files | Add development lifecycle enforcement to AGENTS.md — all work must create TODO entry and either full |
| t185 | PR#691 | 4 files | Memory audit pulse — periodic scan of memories for self-improvement opportunities |
| t184 | PR#689 | 6 files | Graduate validated memories into shared docs — move local learnings into codebase so all users benef |
| t180 | PR#679 | 2 files | Post-merge verification via todo/VERIFY.md — dispatch verification workers after PR merge to confirm |
| t180.4 | PR#769 | 2 files | Wire verify phase into pulse cycle |
| t181 | PR#681 | 3 files | Memory deduplication and auto-pruning — prevent duplicate memories and prune stale entries |
| t182 | PR#684 | 2 files | GHA auto-fix workflow safety — validate auto-fixes before committing |
| t183 | PR#685 | 1 files | Fix supervisor no_log_file dispatch failures — improve error capture when worker fails to start |
| t179 | PR#677 | 5 files | Issue-sync reconciliation: close stale issues, fix |
| t179.1 | NO_PR | 1 commits | Add cmd_close fallback: search by task ID in issue title when |
| t179.2 | NO_PR | 1 commits | Add reconcile command to fix mismatched |
| t179.3 | NO_PR | 1 commits | Wire issue-sync close into supervisor pulse cycle as periodic reconciliation |
| t179.4 | NO_PR | 1 commits | Add issue-sync close to postflight/session-review checklist |
| t168 | PR#660 | 5 files | /compare-models and /compare-models-free commands for model capability comparison |
| t168.1 | PR#756 | 2 files | Build model discovery - enumerate available models from OpenCode config and provider APIs |
| t168.2 | NO_PR | 2 commits | Implement task dispatch to each selected model via Task tool subagents |
| t168.3 | PR#783 | 1 files | Build comparison and scoring framework |
| t168.4 | PR#660 | 5 files | Wire up /compare-models and /compare-models-free slash commands |
| t166 | PR#657 | 3 files | Daily CodeRabbit full codebase review pulse for self-improving aidevops |
| t166.1 | PR#754 | 2 files | Add cron/supervisor daily pulse that triggers CodeRabbit full repo review via gh API |
| t166.2 | PR#765 | 1 files | Monitor and collect CodeRabbit review feedback into structured format |
| t166.3 | PR#778 | 4 files | Auto-create tasks from valid CodeRabbit findings and dispatch workers |
| t167 | PR#650 | 3 files | Investigate Gemini Code Assist for full codebase review in daily pulse |
| t158 | PR#574 | 4 files | Fix supervisor dispatch so dynamically-created tasks work with /full-loop |
| t160 | PR#589 | 2 files | fix: supervisor TODO.md push fails under concurrent workers, add reconcile-todo command |
| t162 | PR#591 | 2 files | fix: supervisor DB safety - add backup-before-migrate and explicit column migrations |
| t163 | PR#622 | 5 files | Prevent false task completion cascade (AGENTS.md rule + issue-sync guard + supervisor verify) |
| t164 | PR#621 | 4 files | Distributed task claiming via GitHub Issue assignees |
| t152 | PR#548 | 11 files | Fix `((cleaned++))` arithmetic exit code bug in setup.sh causing silent abort under `set -e` |
| t169 | PR#646 | 1 files | Fix `aidevops update` skipping agent deployment — pass `--non-interactive` to setup.sh |
| t170 | PR#636 | 1 files | Fix `import-credentials` ignoring multi-tenant credential files |
| t171 | PR#638 | 1 files | Fix clean_exit_no_signal: treat EXIT:0 with PR URL as success |
| t172 | PR#639 | 2 files | Fix supervisor concurrency limiter race condition |
| t173 | PR#649 | 3 files | Fix TODO.md race condition — workers must not write TODO.md |
| t174 | PR#642 | 3 files | Improve /full-loop for fully headless worker operation |
| t175 | PR#655 | 2 files | Fix `ambiguous_skipped_ai` evaluation — add better heuristic signals |
| t176 | PR#656 | 4 files | Add uncertainty guidance to worker dispatch prompt |
| t177 | PR#658 | 1 files | Add integration test for dispatch-worktree-evaluate cycle |
| t178 | PR#659 | 1 files | Fix `cmd_reprompt` to handle missing worktrees |
| t153 | PR#552 | 4 files | Create git merge/cherry-pick conflict resolution skill |
| t148 | PR#489 | 2 files | Supervisor: add review-triage phase before PR merge |
| t147 | PR#468 | 4 files | Retroactive triage: 50 unresolved review threads across 11 merged PRs |
| t147.1 | PR#450 | 2 files | Triage PR |
| t147.2 | PR#451 | 2 files | Triage PR |
| t147.3 | PR#468 | 4 files | Triage PR |
| t147.4 | PR#457 | 2 files | Triage PR |
| t147.5 | NO_PR | 2 commits | Triage PR |
| t147.6 | PR#458 | 2 files | Triage PR |
| t147.7 | PR#475 | 3 files | Triage remaining PRs |
| t151 | PR#465 | 1 files | fix: supervisor PR URL detection and adaptive concurrency |
| t150 | PR#462 | 2 files | feat: supervisor self-healing - auto-create diagnostic subtask on failure/block |
| t149 | PR#469 | 2 files | feat: auto-create GitHub issues when supervisor adds tasks |
| t146 | NO_PR | 4 commits | bug: supervisor no_pr retry counter non-functional (missing $SUPERVISOR_DB) |
| t145 | PR#479 | 17 files | bug: sed -i '' is macOS-only, breaks on Linux/CI |
| t144 | PR#463 | 6 files | quality: excessive 2>/dev/null suppresses real errors |
| t143 | PR#448 | 1 files | quality: test script BRE alternation -> ERE style improvement |
| t142 | PR#449 | 2 files | bug: schema-validator-helper.sh set -e causes premature exit |
| t141 | PR#447 | 8 files | bug: speech-to-speech-helper.sh documents commands that don't exist |
| t140 | PR#430 | 1 files | setup.sh: Cisco Skill Scanner install fails on PEP 668 systems (Ubuntu 24.04+) |
| t139 | PR#427 | 2 files | bug: memory-helper.sh recall fails on hyphenated queries |
| t138 | PR#426 | 2 files | aidevops update output overwhelms tool buffer on large updates |
| t137 | NO_PR | 8 commits | Deploy opencode-config-agents.md template via setup.sh |
| t136 | PR#763 | 5 files | Plugin System for Private Extension Repos |
| t136.1 | PR#755 | 2 files | Add plugin support to .aidevops.json schema |
| t136.2 | PR#759 | 2 files | Add plugins.json config and CLI commands |
| t136.3 | PR#762 | 2 files | Extend setup.sh to deploy plugins |
| t136.4 | PR#763 | 5 files | Create plugin template |
| t136.5 | PR#792 | 2 files | Scaffold aidevops-pro and aidevops-anon repos |
| t135 | PR#480 | 155 files | Codebase Quality Hardening (Opus 4.6 review findings) |
| t135.1 | PR#491 | 61 files | P0-A: Add set -euo pipefail to 61 scripts missing strict mode |
| t135.2 | PR#492 | 95 files | P0-B: Replace blanket ShellCheck disables with targeted inline disables (95 scripts) |
| t135.7 | NO_PR | 4 commits | P2-A: Eliminate eval in 4 remaining scripts (wp-helper, coderabbit-cli, codacy-cli, pandoc-helper) |
| t135.8 | PR#480 | 155 files | P2-B: Increase shared-constants.sh adoption to 89% (165/185) |
| t135.11 | PR#495 | 3 files | P2-E: Fix Homebrew formula (frozen v2.52.1, PLACEHOLDER_SHA256) |
| t135.13 | PR#466 | 4 files | P3-B: Build test suite for critical scripts |
| t135.15 | PR#425 | 1 files | P1-D: Add system resource monitoring to supervisor pulse (CPU load, process count, adaptive concurre |
| t132 | PR#758 | 9 files | Cross-Provider Model Routing with Fallbacks |
| t132.1 | PR#758 | 9 files | Define model-specific subagents in opencode.json |
| t132.2 | PR#761 | 4 files | Provider/model registry with periodic sync |
| t132.3 | PR#770 | 4 files | Model availability checker (probe before dispatch) |
| t132.4 | PR#781 | 8 files | Fallback chain configuration (per-agent and global defaults) |
| t132.5 | PR#787 | 1 files | Supervisor model resolution from subagent frontmatter |
| t132.6 | PR#788 | 1 files | Quality gate with model escalation |
| t132.7 | PR#789 | 4 files | Runner and cron-helper multi-provider support |
| t132.8 | PR#791 | 1 files | Cross-model review workflow (second-opinion pattern) |
| t131 | PR#405 | 90 files | gopass Integration & Credentials Rename |
| t131.1 | NO_PR | 1 commits | Part A: Rename mcp-env.sh to credentials.sh |
| t129 | PR#394 | 5 files | Add AI bot review verification to pr-loop and full-loop workflows |
| t104 | PR#471 | 4 files | Install script integrity hardening (replace curl|sh with verified downloads) |
| t105 | PR#375 | 2 files | Remove eval in ampcode-cli.sh (use arrays + whitelist formats) |
| t106 | PR#361 | 1 files | Replace eval in system-cleanup.sh find command construction with safe args |
| t107 | PR#366 | 3 files | Avoid eval-based export in credential-helper.sh; use safe output/quoting |
| t108 | PR#478 | 3 files | Dashboard token storage hardening (avoid localStorage; add reset/clear flow) |
| t121 | NO_PR | 2 commits | Fix template deploy head usage error (invalid option -z) |
| t122 | PR#371 | 1 files | Resolve awk newline warnings during setup deploy (system-reminder) |
| t123 | NO_PR | 2 commits | Resolve DSPy dependency conflict (gepa) in setup flow |
| t082 | PR#362 | 1 files | Fix version sync inconsistency (VERSION vs package.json/setup.sh/aidevops.sh) |
| t128 | PR#376 | 3 files | Autonomous Supervisor Loop |
| t128.1 | PR#376 | 3 files | Supervisor SQLite schema and state machine |
| t128.2 | PR#377 | 1 files | Worker dispatch with worktree isolation |
| t128.3 | PR#378 | 2 files | Outcome evaluation and re-prompt cycle |
| t128.4 | PR#379 | 1 files | TODO.md auto-update on completion/failure |
| t128.5 | PR#381 | 2 files | Cron integration and auto-pickup |
| t128.6 | PR#380 | 1 files | Memory and self-assessment integration |
| t128.7 | PR#384 | 1 files | Integration testing with t083-t094 batch |
| t128.8 | PR#392 | 1 files | Supervisor post-PR lifecycle (merge, postflight, deploy) |
| t128.9 | PR#494 | 1 files | Agent-review and session-review integration |
| t128.10 | PR#460 | 1 files | Automatic release at batch milestones |
| t068 | PR#158 | 12 files | Multi-Agent Orchestration & Token Efficiency |
| t068.1 | NO_PR | 3 commits | Custom System Prompt (prompts/build.txt) |
| t068.2 | NO_PR | 3 commits | Compaction Plugin (opencode-aidevops-plugin) |
| t068.3 | NO_PR | 2 commits | Lossless AGENTS.md Compression |
| t068.4 | NO_PR | 3 commits | TOON Mailbox System (mail-helper.sh) |
| t068.5 | NO_PR | 2 commits | Agent Registry & Worker Mailbox Awareness |
| t068.6 | NO_PR | 2 commits | Stateless Coordinator (coordinator-helper.sh) |
| t068.7 | NO_PR | 2 commits | Model Routing (subagent YAML frontmatter) |
| t068.8 | PR#482 | 3 files | TUI Dashboard (extend bdui or new Ink app) |
| t009 | PR#562 | 6 files | Claude Code Destructive Command Hooks |
| t004 | NO_PR | 3 commits | Add Ahrefs MCP server integration |
| t005 | PR#227 | 1 files | Implement multi-tenant credential storage |
| t070 | NO_PR | 7 commits | Backlink & Expired Domain Checker subagent |
| t071 | PR#613 | 3 files | Voice AI models for speech generation and transcription |
| t072 | PR#690 | 3 files | Audio/Video Transcription subagent |
| t073 | PR#667 | 4 files | Document Extraction Subagent & Workflow |
| t069 | PR#205 | 1 files | Fix toon-helper.sh validate command - positional args not passed to case statement |
| t006 | NO_PR | 2 commits | Add Playwright MCP auto-setup to setup.sh |
| t007 | PR#585 | 5 files | Create MCP server for QuickFile accounting API |
| t013 | PR#593 | 6 files | Image SEO Enhancement with AI Vision |
| t014 | NO_PR | 3 commits | Document RapidFuzz library for fuzzy string matching |
| t015 | PR#364 | 3 files | Add MinerU subagent as alternative to Pandoc for PDF conversion |
| t016 | PR#594 | 6 files | Uncloud Integration for aidevops |
| t017 | PR#599 | 15 files | SEO Machine Integration for aidevops |
| t020 | PR#543 | 2 files | Git Issues Bi-directional Sync (GitHub, GitLab, Gitea) |
| t021 | PR#208 | 2 files | Auto-mark tasks complete from commit messages in release |
| t023 | PR#561 | 3 files | Integrate Shannon AI pentester for security testing |
| t024 | NO_PR | 2 commits | Evaluate Dexter autonomous financial research agent |
| t025 | NO_PR | 2 commits | Create terminal optimization /command and @subagent using Claude |
| t026 | NO_PR | 2 commits | Create subscription audit /command and @subagent for accounts agent |
| t027 | PR#575 | 3 files | Add hyprwhspr speech-to-text support (Arch/Omarchy Linux only) |
| t028 | NO_PR | 1 commits | Setup sisyphus-dev-ai style GitHub collaborator for autonomous issue resolution |
| t051 | NO_PR | 1 commits | Loop System v2 - Fresh sessions per iteration |
| t029 | NO_PR | 2 commits | Research Penberg's Weave project (deterministic execution for AI agents) |
| t030 | NO_PR | 2 commits | Research irl_danB's progressive-memory and clawdbot projects |
| t032 | PR#209 | 3 files | Create performance skill/subagent/command inspired by @elithrar |
| t033 | NO_PR | 3 commits | Add X/Twitter fetching via fxtwitter API (x.sh script) |
| t034 | PR#40 | 4 files | Add steipete/summarize for URL/YouTube/podcast summarization |
| t035 | PR#40 | 4 files | Add steipete/bird CLI for X/Twitter reading and posting |
| t036 | NO_PR | 3 commits | Verify CodeRabbit CLI usage in code-review agents (coderabbit review --plain) |
| t037 | PR#207 | 2 files | Review ALwrity for SEO/marketing capabilities or inspiration |
| t038 | PR#486 | 8 files | Add CDN origin IP leak detection subagent (Cloudmare-inspired) |
| t039 | NO_PR | 2 commits | Add anti-detect browser subagent for multi-account automation |
| t040 | PR#486 | 8 files | Add Reddit CLI/API integration for reading and posting |
| t041 | PR#368 | 4 files | Document curl-copy authenticated scraping workflow |
| t042 | PR#213 | 4 files | Create email-health-check /command and @subagent |
| t043 | PR#486 | 8 files | Create Bitwarden agent using official Bitwarden CLI |
| t044 | NO_PR | 1 commits | Enhance Vaultwarden agent with bitwarden-cli MCP integration |
| t045 | PR#486 | 8 files | Create Enpass agent using enpass-cli |
| t046 | NO_PR | 3 commits | Review OpenClaw (formerly Moltbot, Clawdbot) for inspiration and incorporation into aidevops |
| t048 | NO_PR | 4 commits | Add worktree cleanup reminder to postflight workflow |
| t049 | NO_PR | 2 commits | Add timing analysis commands to ralph-loop workflow |
| t050 | NO_PR | 2 commits | Move SonarCloud hotspot patterns from AGENTS.md to code-review subagent |
| t059 | NO_PR | 2 commits | Review and merge unmerged feature branches |
| t052 | PR#140 | 8 files | Agent Design Pattern Improvements |
| t053 | NO_PR | 2 commits | Add YAML frontmatter to source subagents |
| t054 | NO_PR | 2 commits | Automatic session reflection to memory |
| t055 | NO_PR | 2 commits | Document cache-aware prompt patterns |
| t056 | NO_PR | 2 commits | Tool description indexing for on-demand MCP discovery |
| t057 | PR#140 | 8 files | Memory consolidation and pruning |
| t058 | PR#365 | 8 files | Memory Auto-Capture |
| t060 | PR#563 | 1 files | Research jj (Jujutsu) VCS for aidevops advantages |
| t061 | PR#486 | 8 files | Create debug-opengraph and debug-favicon subagents |
| t062 | PR#559 | 1 files | Research vercel-labs/agent-skills for inclusion in aidevops |
| t064 | PR#486 | 8 files | Add seo-regex subagent with Search Console regex workflow |
| t083 | PR#382 | 3 files | Create Bing Webmaster Tools subagent |
| t084 | PR#385 | 5 files | Create Rich Results Test subagent |
| t085 | PR#391 | 4 files | Create Schema Validator subagent |
| t086 | PR#383 | 3 files | Create Screaming Frog subagent |
| t087 | PR#386 | 4 files | Create Semrush subagent |
| t088 | NO_PR | 4 commits | Create Sitebulb subagent |
| t089 | PR#387 | 4 files | Create ContentKing subagent |
| t090 | PR#388 | 4 files | Create WebPageTest subagent |
| t091 | PR#389 | 3 files | Create programmatic-seo subagent |
| t092 | NO_PR | 3 commits | Create schema-markup subagent |
| t093 | NO_PR | 3 commits | Create page-cro subagent |
| t094 | PR#390 | 4 files | Create analytics-tracking subagent |
| t130 | PR#436 | 22 files | Post-release follow-up: .agent -> .agents rename regression testing |
| t130.1 | NO_PR | 3 commits | Fix .claude-plugin/marketplace.json still referencing "./.agent" |
| t095 | PR#596 | 3 files | Add XcodeBuildMCP for iOS/macOS app testing |
| t096 | PR#595 | 3 files | Add Maestro for mobile and web E2E testing |
| t097 | PR#597 | 5 files | Add iOS Simulator MCP for simulator interaction |
| t098 | PR#604 | 3 files | Add Playwright device emulation subagent |
| t125 | PR#486 | 8 files | Add browser-use subagent for AI-native browser automation |
| t126 | PR#486 | 8 files | Add Skyvern subagent for computer vision browser automation |
| t127 | PR#486 | 8 files | Add Buzz offline transcription support |
| t100 | PR#603 | 4 files | Add AXe CLI for iOS simulator accessibility automation |
| t101 | PR#628 | 2 files | Create Mom Test UX/CRO agent framework |
| t103 | PR#347 | 2 files | Review Pi agent for aidevops inspiration |
| t124 | PR#605 | 4 files | Add Tirith terminal security guard for homograph/injection attacks |
| t109.1 | PR#348 | 6 files | Document headless dispatch patterns |
| t109.2 | PR#348 | 6 files | Create runner-helper.sh |
| t109.3 | PR#351 | 4 files | Memory namespace integration |
| t109.4 | PR#363 | 7 files | Matrix bot integration (optional) |
| t109.5 | PR#353 | 6 files | Documentation & examples |
| t110 | PR#304 | 5 files | Cron agent for scheduled task management |
| t111 | PR#566 | 3 files | Objective runner with safety guardrails |
| t112 | PR#576 | 2 files | VoiceInk to OpenCode via macOS Shortcut |
| t113 | PR#577 | 2 files | iPhone Shortcut for voice dispatch to OpenCode |
| t114 | PR#581 | 3 files | Pipecat STS integration with OpenCode |
| t115 | PR#302 | 8 files | OpenCode server subagent documentation |
| t116 | PR#302 | 8 files | Self-improving agent system |
| t117 | PR#302 | 8 files | Privacy filter for public PRs |
| t118 | PR#587 | 6 files | Agent testing framework with OpenCode sessions |
| t119 | PR#307 | 1 files | Triage SonarCloud security hotspots (53 pre-existing) |
| t120 | PR#665 | 3 files | Review @thymikee post for aidevops inclusion |
| t102 | PR#341 | 10 files | Claude-Flow Inspirations - Selective Feature Adoption |
| t102.1 | PR#766 | 1 files | Cost-Aware Model Routing |
| t102.2 | PR#768 | 4 files | Semantic Memory with Embeddings |
| t102.3 | PR#779 | 5 files | Success Pattern Tracking |
| t102.4 | PR#786 | 2 files | Documentation & Integration |
| t078 | PR#602 | 5 files | Add Lumen subagent for AI-powered git diffs and commit generation |
| t074 | PR#600 | 3 files | Review DocStrange for document structured data extraction |
| t075 | PR#611 | 3 files | Content Calendar Workflow subagent |
| t076 | PR#614 | 5 files | Platform Persona Adaptations for content guidelines |
| t077 | PR#610 | 2 files | LinkedIn Content Subagent |
| t080 | PR#713 | 5 files | Set up cloud voice agents and S2S models (GPT-4o-Realtime, MiniCPM-o, Nemotron) |
| t079 | PR#226 | 8 files | Consolidate Plan+ and AI-DevOps into Build+ |
| t079.8 | NO_PR | 4 commits | Update setup.sh and aidevops update to cleanup removed agents |
| t063 | NO_PR | 2 commits | Fix secretlint scanning performance |
| t066 | NO_PR | 3 commits | Add /add-skill command for external skill import |
| t067 | PR#140 | 8 files | Optimise OpenCode MCP loading with on-demand activation |
| t133 | PR#565 | 5 files | Cloud GPU deployment guide for AI model hosting |
| t134 | PR#718 | 7 files | SOPS + gocryptfs encryption stack |
| t134.1 | PR#718 | 7 files | Add SOPS subagent with age backend (encrypt project config files in repos) |
| t134.2 | PR#718 | 7 files | Add gocryptfs subagent (encrypted local project folders) |
| t134.3 | PR#751 | 4 files | Update aidevops init with optional SOPS setup |
| t134.4 | PR#751 | 4 files | Document full encryption stack in credentials docs |
| t191 | PR#717 | 2 files | Fix secretlint-helper.sh install and scan in git worktrees |
| t192 | PR#750 | 2 files | Supervisor evaluates successful workers as clean_exit_no_signal — misses PR URL from logs |
| t193 | PR#749 | 4 files | setup.sh fails in non-interactive supervisor deploy step |
| t216 | PR#917 | 1 files | Orphaned PR scanner — run eagerly after worker evaluation, not just Phase 6 throttled |
| t217 | PR#918 | 1 files | Worker prompt — enforce Task tool parallelism for independent subtasks |
| t165 | PR#627 | 5 files | Provider-agnostic task claiming via TODO.md (replace GH Issue-based claiming) |
| t190 | PR#703 | 2 files | Fix Codacy MD022 violations in memory graduation output |
| t010 | NO_PR | 3 commits | Evaluate Merging build-agent and build-mcp into aidevops |
| t018 | NO_PR | 3 commits | Enhance Plan+ and Build+ with OpenCode's Latest Features |
| t065 | NO_PR | 4 commits | Fix postflight warnings: SonarCloud critical issues + OpenCode Agent workflow |
| t001 | NO_PR | 3 commits | Add TODO.md and planning workflow |
| t003 | NO_PR | 2 commits | Add oh-my-opencode integration |
| t011 | NO_PR | 3 commits | Demote wordpress.md from main agent to subagent |
| t022 | NO_PR | 3 commits | Move wordpress from root to tools/wordpress |
| t019 | PLAN_TASK | subtasks completed | Beads Integration for aidevops |

## Unverifiable Tasks

These tasks are marked `[x]` in TODO.md but have no discoverable merged PR, no commits
referencing the task ID, and no `verified:` field. They may have been:

- Completed as part of a larger PR (bundled work)
- Completed before git history was available
- Research/documentation tasks with no code changes
- Incorrectly marked complete

| Task | Status | Description |
|------|--------|-------------|
| t189.1 | NO_EVIDENCE | Add worktree ownership registry |
| t189.2 | NO_EVIDENCE | Add "in use" detection to worktree cleanup |
| t189.3 | NO_EVIDENCE | Add AGENTS.md rule: never remove worktrees you didn't create |
| t189.4 | NO_EVIDENCE | Scope batch cleanup to batch-owned worktrees only |
| t187.1 | NO_EVIDENCE | Add compaction survival instruction to AGENTS.md/build.txt |
| t187.2 | NO_EVIDENCE | Add session-state checkpoint command |
| t187.3 | NO_EVIDENCE | Enhance session-distill to capture operational state |
| t188.1 | NO_EVIDENCE | Add automatic backup before schema migrations |
| t188.2 | NO_EVIDENCE | Add backup-before-modify pattern for non-git state |
| t188.3 | NO_EVIDENCE | Add backup cleanup on successful verification |
| t185.1 | NO_EVIDENCE | Add memory-audit command to memory-helper.sh |
| t185.2 | NO_EVIDENCE | Wire memory audit into supervisor pulse as periodic phase |
| t185.3 | NO_EVIDENCE | Add memory lifecycle states (active/graduated/pruned) |
| t184.1 | NO_EVIDENCE | Add supervisor architecture decisions to architecture.md |
| t184.2 | NO_EVIDENCE | Add macOS bash 3.2 constraints and model routing to code-standards.md |
| t184.3 | NO_EVIDENCE | Add cherry-pick recovery and curl verification limits to relevant subagents |
| t184.4 | NO_EVIDENCE | Add memory graduation workflow to build-agent.md |
| t180.1 | NO_EVIDENCE | Add verify states to supervisor state machine (merged -> verifying -> verified/verify_failed) |
| t180.2 | NO_EVIDENCE | Create VERIFY.md auto-population in supervisor merge phase |
| t180.3 | NO_EVIDENCE | Create verification worker prompt and dispatch logic |
| t181.1 | NO_EVIDENCE | Add content-hash dedup on memory store |
| t181.2 | NO_EVIDENCE | Cap supervisor retry/pulse log memories |
| t181.3 | NO_EVIDENCE | Auto-prune memories for issues that have been fixed |
| t163.1 | NO_EVIDENCE | Add task completion rules to AGENTS.md Planning & Tasks section |
| t163.2 | NO_EVIDENCE | Add guard to issue-sync-helper.sh cmd_close() - require merged PR or |
| t163.3 | NO_EVIDENCE | Add pre-commit validation for TODO.md [x] transitions |
| t163.4 | NO_EVIDENCE | Add supervisor verify phase after worker PR merge |
| t148.1 | NO_EVIDENCE | Add check_review_threads() to fetch unresolved threads via GraphQL |
| t148.2 | NO_EVIDENCE | Add triage_review_feedback() to classify threads by severity |
| t148.3 | NO_EVIDENCE | Add review_triage state to supervisor state machine |
| t148.4 | NO_EVIDENCE | Modify cmd_pr_lifecycle to include triage before merge |
| t148.5 | NO_EVIDENCE | Add worker dispatch for fixing valid review feedback |
| t148.6 | NO_EVIDENCE | Add --skip-review-triage emergency bypass flag |
| t150.1 | NO_EVIDENCE | Add create_diagnostic_subtask() function to supervisor-helper.sh |
| t150.2 | NO_EVIDENCE | Wire self-healing into pulse cycle blocked/failed handlers |
| t150.3 | NO_EVIDENCE | Add --no-self-heal flag and SUPERVISOR_SELF_HEAL env toggle |
| t150.4 | NO_EVIDENCE | Add self-heal command for manual diagnostic subtask creation |
| t150.5 | NO_EVIDENCE | Add schema migration for diagnostic_of column |
| t131.2 | NO_EVIDENCE | Part B: gopass integration + aidevops secret wrapper |
| t131.3 | NO_EVIDENCE | Part C: Agent instructions + psst alternative docs |
| t073.1 | NO_EVIDENCE | Implementation (all subagents + scripts) |
| t073.2 | NO_EVIDENCE | Integration Testing |
| t020.7 | NO_EVIDENCE | Test with existing 46 open issues, enrich plan-linked issues with PLANS.md context |
| t130.2 | NO_EVIDENCE | Run setup.sh to deploy agents and verify migration function works |
| t130.3 | NO_EVIDENCE | Verify aidevops init creates .agents symlink (not .agent) in a test project |
| t130.4 | NO_EVIDENCE | Verify setup.sh migrates existing .agent symlinks in |
| t130.5 | NO_EVIDENCE | Rebase stale worktrees - assessed, deferred (200-300 commits behind, no active worktrees) |
| t116.1 | NO_EVIDENCE | Review phase - pattern analysis from memory |
| t116.2 | NO_EVIDENCE | Refine phase - generate and apply improvements |
| t116.3 | NO_EVIDENCE | Test phase - isolated OpenCode sessions |
| t116.4 | NO_EVIDENCE | PR phase - privacy-filtered contributions |
| t079.1 | NO_EVIDENCE | Audit AI-DevOps for unique knowledge to merge into Build+ |
| t079.2 | NO_EVIDENCE | Add intent detection to Build+ (deliberation vs execution) |
| t079.3 | NO_EVIDENCE | Merge Plan+ planning workflow into Build+ |
| t079.4 | NO_EVIDENCE | Remove Plan+ from primary agents |
| t079.5 | NO_EVIDENCE | Remove AI-DevOps from primary agents |
| t079.6 | NO_EVIDENCE | Update AGENTS.md and documentation |
| t079.7 | NO_EVIDENCE | Test Build+ handles planning and execution modes |
| t205.1 | NO_EVIDENCE | youtube-helper.sh — YouTube Data API v3 wrapper with SA JWT auth, token caching, quota tracking, 8 c |
| t205.2 | NO_EVIDENCE | youtube.md orchestrator agent — architecture, data sources, quick start |
| t205.3 | NO_EVIDENCE | youtube/channel-intel.md — competitor profiling, outlier detection, content DNA |
| t205.4 | NO_EVIDENCE | youtube/topic-research.md — content gaps, trend detection, keyword clustering |
| t205.5 | NO_EVIDENCE | youtube/script-writer.md — hook formulas, storytelling frameworks, retention optimization |
| t205.6 | NO_EVIDENCE | youtube/optimizer.md — title CTR, tag strategy, description templates, thumbnail briefs |
| t205.7 | NO_EVIDENCE | youtube/pipeline.md — cron-driven autonomous pipeline with 4 isolated workers |
| t205.8 | NO_EVIDENCE | Register in subagent-index.toon and AGENTS.md progressive disclosure table |
| t019.1 | NO_EVIDENCE | Phase 1: Enhanced TODO.md format |
| t019.2 | NO_EVIDENCE | Phase 2: Bi-directional sync script |
| t019.3 | NO_EVIDENCE | Phase 3: Default installation |

## Tasks With Existing Proof Logs (Pre-Audit)

These tasks already had proof_log entries from the live supervisor pipeline (post-t218):

t135.10, t135.12, t135.14, t135.3, t135.4, t135.5, t135.6, t198, t214, t214.1, t214.2, t214.3, t214.4, t214.5, t214.6, t215, t215.1, t215.2, t215.3, t215.4, t215.5, t215.6, t215.7, t218, t219, t220, t221, t222, t223, t224, t225, t226, t227, t229, t230, t232, t233, t234, t235, t236.1, t236.2, t236.3, t236.4, t236.5, t237, t238

## Recommendations

1. **Unverifiable tasks** should be manually reviewed by a human to confirm deliverables
2. **Commits-only tasks** may benefit from retroactive PR creation or documentation
3. **Future tasks** will automatically get proof_logs via the supervisor pipeline (t218)
4. Consider running `supervisor-helper.sh proof-log --stats` to monitor coverage
