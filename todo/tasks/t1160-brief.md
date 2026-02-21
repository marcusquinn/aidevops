---
mode: subagent
---
# t1160: Dual-CLI Architecture: OpenCode primary + Claude Code CLI fallback

## Origin

- **Created:** 2026-02-18
- **Session:** unknown
- **Created by:** ai-interactive

- **Commit:** af88d8eea45164655926638a443d8e635db332db — "chore: mark t1140 complete in TODO.md (https://github.com/marcusquinn/aidevops/pull/1740)"

## What

Dual-CLI Architecture: OpenCode primary + Claude Code CLI fallback

## Specification

```markdown
- [ ] t1160 Dual-CLI Architecture: OpenCode primary + Claude Code CLI fallback #plan #architecture #orchestration #cli ~20h model:opus category:infrastructure ref:GH#1746 logged:2026-02-18 — Add Claude Code CLI as a first-class fallback dispatch path alongside OpenCode (primary). Enables OAuth subscription billing for Anthropic model workers, built-in cost caps (--max-budget-usd), native fallback (--fallback-model), and future multi-subscription scaling via containerized instances. See PLANS.md for full design. No regressions to existing OpenCode dispatch.
  - [x] t1160.1 Create build_cli_cmd() abstraction in supervisor/dispatch.sh — replace 12+ duplicated if/else CLI branches with a single semantic-to-CLI-specific command builder function. Pure refactor, no behavior change. #auto-dispatch ~2h model:opus blocks:t1160.2,t1160.3,t1160.4,t1160.5,t1160.6,t1160.7 ref:GH#1747 assignee:marcusquinn started:2026-02-21T03:18:42Z pr:#2053 completed:2026-02-21
  - [x] t1160.2 Add SUPERVISOR_CLI env var to resolve_ai_cli() #auto-dispatch — allow explicit CLI preference override (default: auto-detect, opencode first). ~30m model:opus ref:GH#1748 assignee:marcusquinn started:2026-02-21T05:14:13Z pr:#2080 completed:2026-02-21
  - [x] t1160.3 Add Claude CLI branching to runner-helper.sh #auto-dispatch — currently hardcoded to opencode run with no fallback. ~1h model:opus ref:GH#1749 [proposed:auto-dispatch model:opus] assignee:marcusquinn started:2026-02-21T05:28:10Z pr:#2082 completed:2026-02-21
  - [x] t1160.4 Add Claude CLI branching to contest-helper.sh #auto-dispatch — currently hardcoded to opencode run. ~30m model:opus ref:GH#1750 [proposed:auto-dispatch model:opus] assignee:marcusquinn started:2026-02-21T06:08:22Z pr:#2086 completed:2026-02-21
  - [x] t1160.5 Fix email-signature-parser-helper.sh to use resolve_ai_cli() #auto-dispatch — currently hardcoded to claude -p. ~15m model:opus ref:GH#1751 assignee:marcusquinn started:2026-02-21T06:30:22Z pr:#2088 completed:2026-02-21
  - [x] t1160.6 Add claude to orphan process detection in pulse.sh Phase 5 #auto-dispatch — pgrep pattern only matches opencode. ~15m model:opus ref:GH#1752 assignee:marcusquinn started:2026-02-21T06:53:18Z pr:#2089 completed:2026-02-21
  - [x] t1160.7 Integration test: full dispatch cycle with SUPERVISOR_CLI=claude — verify worker spawn, output capture, evaluation, and cleanup all work with Claude CLI. ~1h model:opus ref:GH#1753 #auto-dispatch assignee:marcusquinn started:2026-02-21T07:33:54Z pr:#2096 completed:2026-02-21
  - [x] t1161 Claude Code config parity in setup.sh #auto-dispatch — generate-claude-agents.sh for slash commands, automated MCP registration via claude mcp add-json, enhanced settings.json with tool permissions. Wire into setup.sh as update_claude_config(). Conditional on claude binary existing. ~4h model:opus blocks:t1162 ref:GH#1754 assignee:marcusquinn started:2026-02-21T08:09:13Z pr:#2099 completed:2026-02-21
    - [x] t1161.1 Create generate-claude-commands.sh #auto-dispatch — generate slash commands to ~/.claude/commands/ from same source as OpenCode commands. ~2h model:opus ref:GH#1755 assignee:marcusquinn started:2026-02-21T08:09:44Z pr:#2098 completed:2026-02-21
    - [x] t1161.2 Automate MCP registration via claude mcp add-json #auto-dispatch — use existing configs/mcp-templates/ claude_code_command entries. ~1h model:opus ref:GH#1756 assignee:marcusquinn started:2026-02-21T08:24:52Z pr:#2100 completed:2026-02-21
    - [x] t1161.3 Enhance ~/.claude/settings.json with tool permissions #auto-dispatch — merge with existing safety hooks, don't overwrite. ~30m model:opus ref:GH#1757 assignee:marcusquinn started:2026-02-21T09:02:46Z pr:#2101 completed:2026-02-21
    - [x] t1161.4 Wire update_claude_config() into setup.sh #auto-dispatch — parallel to update_opencode_config(), conditional on claude binary. ~30m model:opus ref:GH#1758 assignee:marcusquinn started:2026-02-21T10:48:34Z pr:#2103 completed:2026-02-21
  - [x] t1162 Worker MCP isolation for Claude CLI dispatch #auto-dispatch — generate per-worker MCP config JSON for --mcp-config --strict-mcp-config flags. Equivalent to generate_worker_mcp_config() for OpenCode. ~2h model:opus blocks:t1163 ref:GH#1759 assignee:marcusquinn started:2026-02-21T09:19:35Z pr:#2102 completed:2026-02-21
  - [x] t1163 OAuth-aware dispatch routing #auto-dispatch — detect OAuth availability (claude CLI works without ANTHROPIC_API_KEY), add SUPERVISOR_PREFER_OAUTH env var (default: true), prefer Claude CLI for Anthropic models when OAuth available, keep OpenCode for non-Anthropic. Budget tracker integration for subscription billing type. ~2h model:opus blocks:t1164 ref:GH#1760 assignee:marcusquinn started:2026-02-21T09:36:05Z pr:#2104 completed:2026-02-21
  - [x] t1164 End-to-end verification of dual-CLI architecture #auto-dispatch — mixed batch with Anthropic + non-Anthropic tasks, verify correct CLI routing, OAuth detection, fallback on auth failure, cost tracking, no regressions to pure-OpenCode dispatch. ~2h model:opus blocks:t1165 ref:GH#1761 assignee:marcusquinn started:2026-02-21T13:19:59Z pr:#2105 completed:2026-02-21
    - Notes: BLOCKED by supervisor: Merge conflict — auto-rebase failed
  - [ ] t1165 Containerized Claude Code CLI instances for multi-subscription scaling #auto-dispatch — OrbStack/Docker containers each with own OAuth token (CLAUDE_CODE_OAUTH_TOKEN via claude setup-token), supervisor dispatches to container pool, per-container rate limit tracking, health checks, auto-scaling. ~6h model:opus ref:GH#1762 assignee:marcusquinn started:2026-02-21T11:06:24Z
    - Notes: BLOCKED by supervisor: FAILED: ai_assessment_unparseable
    - [ ] t1165.1 Design container image and OAuth token provisioning #auto-dispatch — Dockerfile with claude CLI + git + aidevops agents, token injection via env var, volume mounts for repo access. ~2h model:opus ref:GH#1763 assignee:marcusquinn started:2026-02-21T10:29:46Z
    - [ ] t1165.2 Container pool manager in supervisor — spawn/destroy containers, health checks, round-robin dispatch across pool, per-container rate limit tracking. ~2h model:opus ref:GH#1764 assignee:marcusquinn started:2026-02-21T13:51:44Z
    - [x] t1165.3 Remote container support — dispatch to containers on remote hosts via SSH/Tailscale, credential forwarding, log collection. ~1h model:opus ref:GH#1765 [proposed:auto-dispatch model:opus] assignee:marcusquinn started:2026-02-21T15:36:02Z status:deployed pr:#2109 completed:2026-02-21
    - [x] t1165.4 Integration test: multi-container batch dispatch — verify parallel workers across containers, correct OAuth routing, container lifecycle, log aggregation. ~1h model:opus ref:GH#1766 [proposed:auto-dispatch model:opus] assignee:marcusquinn started:2026-02-21T16:11:10Z status:deployed pr:#2111 completed:2026-02-21
```




## Acceptance Criteria

- [ ] Implementation matches the specification above
- [ ] Tests pass
- [ ] Lint clean

## Relevant Files

<!-- TODO: Add relevant file paths after codebase analysis -->
