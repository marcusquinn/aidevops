# Autoagent — Safety Constraints

Sub-doc for `autoagent.md`. Loaded during Step 1 (Setup) before any modifications.

---

## Overview

The autoagent modifies framework files autonomously. These constraints prevent it from breaking core workflows, weakening security, or creating regressions. Safety is enforced at two layers: the research program constraint list (shell commands) and the researcher model (this doc).

---

## Security Instruction Exemptions

Discard any hypothesis that removes or weakens the following — do not test:

| Category | Detection pattern |
|----------|------------------|
| Credential/secret handling | `credentials`, `NEVER expose`, `gopass`, `secret` |
| File operation safety | `Read before Edit`, `pre-edit-check`, `verify path` |
| Git safety | `pre-edit-check.sh`, `never edit on main`, `worktree` |
| Traceability | `PR title MUST`, `task ID`, `Closes #` |
| Prompt injection | `prompt injection`, `adversarial`, `scan` |
| Destructive operations | `destructive`, `confirm before`, `irreversible` |

Inherited from `autoresearch/agent-optimization.md`. Both layers must hold.

---

## Never-Modify Files

These files must NEVER be modified by the autoagent under any safety level:

| File | Reason |
|------|--------|
| `prompts/build.txt` security sections (rules 7–8) | Prompt injection and secret handling — core security posture |
| `tools/credentials/gopass.md` | Credential management — modification could expose secrets |
| `tools/security/prompt-injection-defender.md` | Security threat model — modification weakens defenses |
| `hooks/git_safety_guard.py` | Git safety hook — modification bypasses pre-edit checks |
| `.agents/configs/simplification-state.json` | Shared hash registry — modification corrupts simplification tracking |

**Enforcement:** Before applying any modification, check the target file against this list. If matched → discard hypothesis immediately, do not test.

---

## Elevated-Only Files

These files require `SAFETY_LEVEL=elevated` in the research program. Under `standard` safety level, skip hypotheses targeting these files:

| File | Reason |
|------|--------|
| `AGENTS.md` | Primary user guide — changes affect all users |
| `prompts/build.txt` (non-security sections) | Core instruction set — high blast radius |
| `workflows/git-workflow.md` | Git workflow — changes affect all PRs and commits |
| `workflows/pre-edit.md` | Pre-edit gate — changes affect all file modifications |
| `reference/agent-routing.md` | Routing table — changes affect all task dispatch |

**Enforcement:** If `SAFETY_LEVEL == "standard"` and hypothesis targets an elevated-only file → skip, log as "safety_skip", continue to next hypothesis.

---

## Core Workflow Preservation

The following workflows must remain functional after any modification. These are verified by the regression gate:

1. **Git workflow**: `pre-edit-check.sh` must exit 0 on a clean feature branch
2. **PR flow**: `gh pr create` must succeed with standard arguments
3. **Task management**: `claim-task-id.sh` must allocate IDs without collision
4. **Pulse dispatch**: `pulse-wrapper.sh` must complete without error on a test repo
5. **Memory system**: `aidevops-memory store` and `recall` must succeed

---

## Regression Gate

Before the keep decision on any hypothesis, verify ALL comprehension tests still pass:

```bash
# Run full test suite — not just the composite score
agent-test-helper.sh run --suite agent-optimization --json 2>/dev/null | \
  jq -e '.pass_rate >= .baseline_pass_rate' 2>/dev/null

# Verify no previously-passing test now fails
agent-test-helper.sh run --suite agent-optimization --json 2>/dev/null | \
  jq -r '.failures[]? | .test_name' | while read -r test; do
    echo "REGRESSION: $test now failing"
  done
```

**Rule:** No existing passing comprehension test may start failing as a result of a hypothesis. A hypothesis that improves the composite score but causes a regression must be discarded.

---

## Rollback Procedure

Rollback is always safe and always available:

```bash
# Revert all uncommitted changes in the worktree
git -C "$WORKTREE_PATH" reset --hard HEAD

# Verify clean state
git -C "$WORKTREE_PATH" status --porcelain
# Expected: empty output (no changes)
```

**When to rollback:**
- Constraint check fails
- Metric measurement errors
- Regression gate fails
- Safety constraint violation detected after modification

**Rollback does not affect:**
- `results.tsv` (append-only log)
- Memory entries (already stored)
- The experiment branch HEAD (only uncommitted changes are reverted)

---

## Safety Level Summary

| Safety level | Never-modify | Elevated-only | Regression gate |
|-------------|-------------|--------------|----------------|
| `standard` (default) | Enforced | Skipped | Enforced |
| `elevated` | Enforced | Allowed | Enforced |

**Note:** `elevated` safety level allows modifying `AGENTS.md`, `build.txt` non-security sections, and workflow docs. It does NOT relax the never-modify list or the regression gate. Elevated level requires explicit opt-in in the research program.

---

## Constraint Shell Commands

The research program's `## Constraints` section contains shell commands that must all pass (exit 0) before a hypothesis is accepted. Standard constraints for framework self-modification:

```bash
# Git safety: pre-edit-check must pass on feature branch
~/.aidevops/agents/scripts/pre-edit-check.sh

# ShellCheck: no new violations in modified scripts
shellcheck --severity=error .agents/scripts/*.sh

# Markdownlint: no violations in modified docs
markdownlint-cli2 .agents/**/*.md

# Regression gate: comprehension tests pass
agent-test-helper.sh run --suite agent-optimization --json | jq -e '.pass_rate >= .baseline_pass_rate'
```

All constraints must pass. First failure short-circuits (remaining constraints not run). Constraint failure → rollback → log as `constraint_fail` → continue to next hypothesis.
