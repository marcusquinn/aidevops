# SonarCloud Exemption Inventory

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

Tracks all SonarCloud rule suppressions for the AI DevOps Framework codebase.
Suppressions are either config-level (via `sonar-project.properties`) or per-site (`# NOSONAR` inline annotations).

See also: [parent task #20401](https://github.com/marcusquinn/aidevops/issues/20401) — SonarCloud rule tuning initiative.

---

## Config-Level Exclusions (`sonar-project.properties`)

All config-level exclusions apply to `**/*.sh` (all shell scripts) unless noted.

| Key | Rule | Name | Scope | Rationale | Added |
|-----|------|------|-------|-----------|-------|
| e1 | `shelldre:S6505` | npm install without --ignore-scripts | `**/*.sh` | Required for CLI tool installation with native dependencies (playwright, puppeteer, esbuild). `--ignore-scripts` breaks these tools. | Initial |
| e2 | `shelldre:S5332` | Clear-text protocol | `**/*.sh` | All HTTP URLs are localhost, protocol detection, or XML namespace declarations (not active insecure traffic). | Initial |
| e3 | `shelldre:S6506` | HTTPS not enforced | `**/*.sh` | All curl commands use explicit HTTPS URLs, target localhost, or invoke verified official installers (bun.sh, homebrew). | Initial |
| e4 | `shelldre:S7679` | Positional parameters | `**/*.sh` | Standard `while/case` argument-parsing pattern used consistently across the framework. | Initial |
| e5 | `shelldre:S1192` | String literals | `**/*.sh` | 118/463 scripts use ANSI color codes as repeated literals. Extracting to per-script constants adds boilerplate with no safety benefit (confirmed GH#17869). | Initial |
| e6 | `shelldre:S7677` | Error messages to stderr | `**/*.sh` | Framework uses colored output for UX-facing status messages; traditional stderr separation is not appropriate. | Initial |
| e7 | `shelldre:S1135` | TODO comments | `**/*.sh` | TODO comments are tracked intentionally via the task management system. | Initial |
| e8 | `shelldre:S131` | Missing default case | `**/*.sh` | Many `case` statements intentionally skip unknown options; unknown commands are handled at the main dispatch level. | Initial |
| e9 | `shelldre:S7682` | Explicit return statements | `**/*.sh` | Shell convention allows implicit `return 0` for successful functions. | Initial |
| e10 | `shelldre:S2148` | Underscores in numeric literals | `**/*.sh` | Rule targets Java/Python syntax not applicable to shell scripts. | Initial |
| e11 | `shell:S6505` | (same as e1, shell: prefix) | `**/*.sh` | SonarCloud uses both `shelldre:` and `shell:` prefixes for the same rules. | Initial |
| e12 | `shell:S5332` | (same as e2, shell: prefix) | `**/*.sh` | Duplicate under `shell:` prefix. | Initial |
| e13 | `shell:S6506` | (same as e3, shell: prefix) | `**/*.sh` | Duplicate under `shell:` prefix. | Initial |
| e14 | `shelldre:S2076` | OS command injection | `**/*.sh` | Framework is a DevOps automation tool; all CLI commands are constructed from validated inputs (regex `[0-9]+`, ISO dates, allowlist-checked repo slugs). | Initial |
| e15 | `shell:S2076` | (same as e14, shell: prefix) | `**/*.sh` | Duplicate under `shell:` prefix. | Initial |
| e16 | `shelldre:S7688` | Use `[[` instead of `[` | `**/*.sh` | Both forms used intentionally: `[` for POSIX-compatible sourcing contexts, `[[` for bash-specific logic. | Initial |
| e17 | `shelldre:S7684` | Various shell patterns | `**/*.sh` | Stylistic preferences that don't affect correctness. | Initial |
| e18 | `shelldre:S1481` | Unused local variables | `**/*.sh` | Separate declaration and assignment (`local var; var=$(cmd)`) is used for `set -e` safety — `local var=$(cmd)` returns 0 even if the subshell fails, masking the error. SonarCloud's data-flow analysis often fails to track variable usage across these boundaries. Evidence: t2732 inventory classified 178/178 findings as false-positive. | t2733 |
| e19 | `shell:S1481` | (same as e18, shell: prefix) | `**/*.sh` | Duplicate under `shell:` prefix. | t2733 |
| e20 | `shelldre:S1066` | Collapsible if statements | `**/*.sh` | Nested `if` blocks are kept for readability: outer block is a precondition guard, inner block is the actual logic. Collapsing with `&&` obscures control flow. Evidence: t2732 inventory classified 97/97 findings as false-positive or tactical-exemption. | t2733 |
| e21 | `shell:S1066` | (same as e20, shell: prefix) | `**/*.sh` | Duplicate under `shell:` prefix. | t2733 |
| e22 | `shelldre:S100` | Function naming convention | `**/*.sh` | Framework convention is `snake_case` and `_leading_underscore` throughout 460+ scripts. camelCase would be inconsistent with the entire codebase. Evidence: t2732 inventory classified 18/18 findings as false-positive. | t2733 |
| e23 | `shell:S100` | (same as e22, shell: prefix) | `**/*.sh` | Duplicate under `shell:` prefix. | t2733 |

### Exclusion Summary by Phase

| Phase | Task | Rules | Count | Type |
|-------|------|-------|-------|------|
| Initial | — | S6505, S5332, S6506, S7679, S1192, S7677, S1135, S131, S7682, S2148, S2076, S7688, S7684 | 17 entries (e1-e17) | Security hotspots + style |
| Phase 2 | t2733 / #20454 | S1481, S1066, S100 | 6 entries (e18-e23) | Shell-idiom false positives |

---

## Per-Site NOSONAR Annotations

**For S1481/S1066/S100 (Phase 3 scope): Zero new per-site annotations required.**

Phase 1 (t2732 / #20453) inventory classified all S1481/S1066/S100 findings as false-positives:

| Rule | Findings | Classification | Disposition |
|------|----------|----------------|-------------|
| S1481 | 178 | 178/178 false-positive | Config-excluded (e18, e19) |
| S1066 | 97 | 97/97 false-positive or tactical-exemption | Config-excluded (e20, e21) |
| S100 | 18 | 18/18 false-positive | Config-excluded (e22, e23) |

Since all S1481/S1066/S100 findings are covered by Phase 2 config-level exclusions, no new per-site `# NOSONAR` annotations are needed for those rules.

### Existing Per-Site Annotations (Pre-Phase-2)

These annotations were added before config-level exclusions were established. They are now **redundant** with the corresponding config exclusions but retained for local documentation clarity.

| File | Line | Implied Rule | Annotation Text | Config Key |
|------|------|-------------|-----------------|------------|
| `.agents/scripts/dspyground-helper.sh` | 82 | S6505 | npm scripts required for CLI binary installation | e1, e11 |
| `.agents/scripts/agent-test-helper.sh` | 101 | S5332/S6506 | localhost dev server, no TLS needed | e2, e3, e12, e13 |
| `.agents/scripts/agent-test-helper.sh` | 165 | S5332/S6506 | localhost dev server health check, HTTP intentional | e2, e3, e12, e13 |
| `.agents/scripts/agent-test-helper.sh` | 234 | S5332/S6506 | localhost dev server API call, HTTP intentional | e2, e3, e12, e13 |
| `.agents/scripts/agent-test-helper.sh` | 270 | S5332/S6506 | localhost dev server API call, HTTP intentional | e2, e3, e12, e13 |
| `.agents/scripts/agent-test-helper.sh` | 285 | S5332/S6506 | localhost dev server, HTTP intentional | e2, e3, e12, e13 |
| `.agents/scripts/webhosting-helper.sh` | 121 | S5332 | HTTP for localhost proxy_pass (internal traffic) | e2, e12 |
| `.agents/scripts/stagehand-helper.sh` | 78 | S6505 | npm scripts for Playwright browser automation | e1, e11 |
| `.agents/scripts/stagehand-helper.sh` | 87 | S6505 | npm scripts for dependency compilation | e1, e11 |
| `.agents/scripts/agno-setup.sh` | 484 | S6505 | npm scripts for project scaffolding | e1, e11 |
| `.agents/scripts/agno-setup.sh` | 492 | S6505 | npm scripts for native dependencies | e1, e11 |
| `.agents/scripts/email-test-suite-helper.sh` | 69 | S5332 | xmlns URL is namespace identifier, not network request | e2, e12 |
| `.agents/scripts/gsc-sitemap-helper.sh` | 677 | S6505 | npm scripts for Playwright browser automation | e1, e11 |
| `.agents/scripts/snyk-helper.sh` | 192 | S1066 | merged nested if: check npm exists AND try install | e20, e21 |
| `.agents/scripts/snyk-helper.sh` | 203 | S6505 | npm scripts for CLI binary installation | e1, e11 |
| `.agents/scripts/ampcode-cli.sh` | 113 | S6505 | npm scripts for CLI binary installation | e1, e11 |
| `.agents/scripts/ampcode-cli.sh` | 128 | S6505 | npm scripts for CLI binary installation | e1, e11 |
| `.agents/scripts/webhosting-verify.sh` | 129 | S5332 | HTTP required to test HTTP→HTTPS redirect behavior | e2, e12 |
| `.agents/scripts/gh-failure-miner-helper.sh` | 291 | S2076 | inputs validated as `[0-9]+` / ISO date from `date(1)` | e14, e15 |

### When to Add Per-Site Annotations

Per-site `# NOSONAR[<rule>]: <reason>` annotations are appropriate when:

1. A specific finding is a legitimate smell in most files but is justified at one site
2. A new rule surfaces after config exclusions are established and only a few sites need suppression
3. A finding is not covered by a config-level exclusion and cannot be (e.g., rule applies correctly to most occurrences, but one specific instance has a documented reason)

Example annotation format:

```bash
local rc=0
command || rc=$?  # NOSONAR[S1481]: return-code capture for set -e safety in caller
```

---

## Process for New SonarCloud Findings

When new SonarCloud findings appear after a config change (SonarCloud may re-analyse with different rule sets):

1. **Triage the finding**: Is it a real code smell or a false positive for shell scripts?
2. **If false-positive for the entire codebase**: Add a new `multicriteria.eN` entry to `sonar-project.properties` with rationale. Update this inventory.
3. **If legitimate smell at a specific site**: Fix the code (preferred) or add a per-site `# NOSONAR[<rule>]: <reason>` annotation. Update the table above.
4. **If legitimate smell across the codebase**: Fix the code — don't suppress.

---

## Maintenance

This document is the authoritative record of all SonarCloud suppressions. Update it when:
- Adding new config-level exclusions to `sonar-project.properties`
- Adding per-site `# NOSONAR` annotations to any `.sh` file
- Removing suppressions when underlying issues are resolved

Reference: [sonar-project.properties](../sonar-project.properties) for the active config.
