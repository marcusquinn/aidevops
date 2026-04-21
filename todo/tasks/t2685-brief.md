<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->
# t2685: Harden gh signature-footer enforcement (PATH shim + plugin hook block)

## Pre-flight

- [x] Memory recall: `gh wrapper PATH shim signature footer` → 0 hits — no prior lessons (new failure class)
- [x] Discovery pass: 0 commits / 0 merged PRs / 0 open PRs touch target files in last 48h
- [x] File refs verified: 4 refs checked, all present at HEAD (`quality-hooks.mjs`, `shared-gh-wrappers.sh`, `gh-signature-helper.sh`, `_deployment.sh`)
- [x] Tier: `tier:standard` — straightforward enforcement hardening, existing patterns to follow, no novel design

## Origin

- **Created:** 2026-04-21
- **Session:** opencode:interactive (marcusquinn)
- **Created by:** ai-interactive
- **Parent task:** —
- **Conversation context:** While cleaning 443 duplicate nudge comments from awardsapp after the v3.8.88 dedup fix, the agent posted a hallucinated signature footer (human-readable prose containing `aidevops.sh` but none of the runtime/version/model/token metadata that `gh-signature-helper.sh` emits). Investigation showed the plugin hook accepted any command string containing `aidevops.sh` as sufficient evidence of a valid footer, and raw `gh` on PATH bypasses the shell wrappers entirely. Both gaps allow hallucinated footers through.

## What

Close the two gaps that let hallucinated signature footers through review:

1. **PATH shim** at `.agents/scripts/gh` (deployed to `~/.aidevops/agents/scripts/gh`, which is first on PATH via `shell-env.mjs`). Intercepts `gh issue comment|create` and `gh pr comment|create`, injects the helper-generated signature into `--body`/`--body-file` when the canonical marker `<!-- aidevops:sig -->` is absent, then exec's the real `gh`. All other subcommands pass through with one case-match + one exec. Bypass: `AIDEVOPS_GH_SHIM_DISABLE=1`.
2. **Plugin hook tightening** in `.agents/plugins/opencode-aidevops/quality-hooks.mjs::checkSignatureFooterGate`: replace the loose `cmd.includes("aidevops.sh")` check with marker-based detection (`<!-- aidevops:sig -->`), add transparent repair via `output.args.command` mutation, and throw a mentoring error when repair isn't safe.
3. **Prompt reinforcement** in `.agents/prompts/build.txt` §8 with a concrete anti-pattern example (the exact hallucination from t2685) and explicit descriptions of both enforcement layers.

## Why

The hallucination that triggered t2685 slipped past three supposed defenses:

- **Shell wrapper** (`gh_issue_comment` in `shared-gh-wrappers.sh`) — bypassed because the agent called raw `gh issue comment` in a Bash tool call; the shell function is only invoked when scripts source the library and call it by name.
- **Plugin hook** (`checkSignatureFooterGate`) — the literal prose `aidevops.sh` matched `cmd.includes("aidevops.sh")`; the hook logged WARN and allowed execution.
- **Prompt rule** (`build.txt` §8) — no runtime enforcement.

The failure mode is recurring (prior incidents in session logs). Without structural enforcement, every future model session can reproduce it. The fix adds two structural layers that catch the failure before the command reaches GitHub, and a reinforced prompt rule so the model learns the correct pattern.

## Tier

### Tier checklist

- [x] 2 or fewer files to modify? NO — 4 files changed, but each change is small
- [x] Every target file under 500 lines? `quality-hooks.mjs` is 340 lines, `build.txt` 608 lines, but edits are localized
- [ ] Exact `oldString`/`newString` for every edit? — brief drives narrative, not verbatim patches
- [x] No judgment or design decisions? — approach is well-established (existing shim/hook patterns)
- [x] No error handling or fallback logic to design? — reuses helper; fail-open is spec'd
- [x] No cross-package or cross-module changes? — all within `.agents/`
- [x] Estimate 1h or less? — 1-2h
- [x] 4 or fewer acceptance criteria? — 5 (see below)

**Selected tier:** `tier:standard`

**Tier rationale:** Multi-file change but no architectural decisions; the pattern (PATH shim + plugin hook + prompt rule) mirrors existing layered defenses (git safety guard, privacy guard). Not a single-file mechanical edit, so not `tier:simple`; no novel design, so not `tier:thinking`.

## PR Conventions

Leaf (non-parent) issue — PR body uses `Resolves #NNN`.

## How (Approach)

### Files to Modify

- **NEW: `.agents/scripts/gh`** — PATH shim. Self-contained bash script; duplicates the sig-injection logic from `_gh_wrapper_auto_sig` (shared-gh-wrappers.sh) to avoid sourcing 1500 lines on every write. Fast pass-through for non-write subcommands. Recursion guard. Emergency bypass env var.
- **EDIT: `.agents/plugins/opencode-aidevops/quality-hooks.mjs`** — split `checkSignatureFooterGate` into composable helpers (`isGhWriteCommand`, `isMachineProtocolCommand`, `hasTrustedSignatureSignal`, `tryRepairSignature`), mutate `output.args.command` for transparent repair, throw for unparseable commands with an error message that teaches the next attempt. Export functions for test harness.
- **EDIT: `.agents/scripts/setup/_deployment.sh`** — `chmod +x` the shim after deployment (existing loop only chmods `*.sh`).
- **EDIT: `.agents/prompts/build.txt`** §8 — concrete anti-pattern example + layered enforcement documentation.
- **NEW: `.agents/scripts/tests/test-gh-shim.sh`** — 10 test cases covering pass-through, injection, idempotency, bypass, recursion guard.
- **NEW: `.agents/plugins/opencode-aidevops/tests/test-signature-footer-gate.mjs`** — 32 test cases (5 describe blocks) covering each helper + end-to-end block vs repair paths, including the exact t2685 regression case (`--body "... aidevops.sh ..."` with no marker).

### Files Scope

- `.agents/scripts/gh`
- `.agents/scripts/setup/_deployment.sh`
- `.agents/plugins/opencode-aidevops/quality-hooks.mjs`
- `.agents/plugins/opencode-aidevops/tests/test-signature-footer-gate.mjs`
- `.agents/prompts/build.txt`
- `.agents/scripts/tests/test-gh-shim.sh`
- `TODO.md`
- `todo/tasks/t2685-brief.md`

### Implementation Steps

1. Write the `gh` shim at `.agents/scripts/gh`. Model on `_gh_wrapper_auto_sig` (shared-gh-wrappers.sh lines 280-349) for sig injection; marker-based dedup for idempotency.
2. Add chmod for `scripts/gh` in `setup/_deployment.sh` (line ~85 area).
3. Tighten `checkSignatureFooterGate` in `quality-hooks.mjs`. Split into helpers; add `tryRepairSignature` with heredoc/command-substitution refusal; throw on repair failure with instructive message.
4. Extend `build.txt` §8 with anti-pattern example and enforcement layer description.
5. Write `test-gh-shim.sh` using a stub gh binary and stub sig helper in `$TMPDIR`.
6. Write `test-signature-footer-gate.mjs` using `node:test`, import exports, stub sig helper on disk for `tryRepairSignature` tests.
7. Run all three test suites until green.

### Verification

```bash
# 1. Shim executable + passes shellcheck
chmod +x .agents/scripts/gh && shellcheck .agents/scripts/gh

# 2. Shim tests pass
bash .agents/scripts/tests/test-gh-shim.sh

# 3. Plugin hook tests pass
node --test .agents/plugins/opencode-aidevops/tests/test-signature-footer-gate.mjs

# 4. No regression in existing wrapper auto-sig tests
bash .agents/scripts/tests/test-gh-wrapper-auto-sig.sh

# 5. Plugin module syntax-valid
node --check .agents/plugins/opencode-aidevops/quality-hooks.mjs

# 6. Full plugin test suite clean
for f in .agents/plugins/opencode-aidevops/tests/*.mjs; do node --test "$f"; done
```

Expected: all green; 12 shim tests, 32 signature-gate tests, 30 wrapper tests (no regression), 74 other plugin tests.

## Acceptance Criteria

1. **Shim tests pass** — `bash .agents/scripts/tests/test-gh-shim.sh` reports 12/12 pass.
2. **Plugin hook tests pass** — `node --test .agents/plugins/opencode-aidevops/tests/test-signature-footer-gate.mjs` reports 32/32 pass.
3. **Regression-free** — existing `test-gh-wrapper-auto-sig.sh` remains 30/30, existing plugin tests remain at prior counts (12+21+12+20+9).
4. **Hallucination regression case covered** — test file explicitly asserts that `hasTrustedSignatureSignal('... --body "... from aidevops.sh session"')` returns `false` and that `checkSignatureFooterGate` on an unparseable body containing bare `aidevops.sh` throws.
5. **Shellcheck clean** — `shellcheck .agents/scripts/gh` produces no output.

## Context

### Prior art

- `_gh_wrapper_auto_sig` (shared-gh-wrappers.sh lines 280-349) — the shell-function equivalent. Shim duplicates this ~60-line logic to avoid sourcing the whole 1500-line wrapper library on every gh invocation.
- `privacy-guard-pre-push.sh` — same "layered defense" pattern (pre-push hook + prompt rule).
- `git_safety_guard.py` — similar plugin-hook-throws-to-block pattern for opencode.
- `coderabbit-nits-ok`, `new-file-smell-ok` labels — precedent for "marker as reliable signal, prose is not".

### Canonical failure

2026-04-21 cleanup session on awardsapp#2546 posted body: `"Successfully removed 75 duplicate \`<!-- parent-needs-decomposition -->\` nudge comments on this issue, retaining only the earliest legitimate one...\n\n— interactive cleanup from marcusquinn runtime."`

The literal `aidevops.sh` was nowhere; but the footer's absence was not detected because the prose was short enough that the hook didn't recognise it as a gh write without a sig — the prior hook's `cmd.includes("aidevops.sh")` logic happened to be the ONLY check, and this body didn't even contain that string. Under the t2685 hook, the command is either repaired transparently or blocked with an instructive error.

### Out of scope

- `gh issue edit` / `gh pr edit` — existing `gh_issue_edit_safe` and `gh_pr_edit_safe` handle destructive-edit safety but don't auto-inject sigs. The spec-original t2393 work was create/comment only. Extending edit-sig is a separate follow-up if needed.
- Deploy-time test runner — tests are shell and node, both runnable manually and in CI. No scheduled job.
