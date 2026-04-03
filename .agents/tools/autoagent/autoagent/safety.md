# Autoagent — Safety Constraints

Sub-doc for `autoagent.md`. Loaded during Step 1 (Setup) before any modifications.

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

NEVER modify under any safety level:

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

Require `SAFETY_LEVEL=elevated`. Under `standard`, skip hypotheses targeting these files:

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

These workflows must remain functional after any modification (verified by regression gate):

1. **Git workflow**: `pre-edit-check.sh` must exit 0 on a clean feature branch
2. **PR flow**: `gh pr create` must succeed with standard arguments
3. **Task management**: `claim-task-id.sh` must allocate IDs without collision
4. **Pulse dispatch**: `pulse-wrapper.sh` must complete without error on a test repo
5. **Memory system**: `aidevops-memory store` and `recall` must succeed

---

## Regression Gate

Before the keep decision on any hypothesis, verify ALL comprehension tests still pass:

```bash
agent-test-helper.sh run --suite agent-optimization --json 2>/dev/null | \
  jq -e '.failed == 0' 2>/dev/null
```

**Rule:** No existing passing comprehension test may start failing (`failed == 0`). A hypothesis that improves the composite score but causes a regression must be discarded.

---

## Rollback Procedure

```bash
git -C "$WORKTREE_PATH" reset --hard HEAD
git -C "$WORKTREE_PATH" status --porcelain
```

Rollback when: constraint check fails, metric measurement errors, regression gate fails, or safety constraint violation detected after modification.

---

## Safety Level Summary

| Safety level | Never-modify | Elevated-only | Regression gate |
|-------------|-------------|--------------|----------------|
| `standard` (default) | Enforced | Skipped | Enforced |
| `elevated` | Enforced | Allowed | Enforced |

**Note:** `elevated` allows modifying `AGENTS.md`, `build.txt` non-security sections, and workflow docs. It does NOT relax the never-modify list or the regression gate. Requires explicit opt-in in the research program.

---

## Constraint Shell Commands

All must pass (exit 0) before a hypothesis is accepted. First failure short-circuits → rollback → log as `constraint_fail` → next hypothesis.

```bash
~/.aidevops/agents/scripts/pre-edit-check.sh
shellcheck --severity=error .agents/scripts/*.sh
markdownlint-cli2 .agents/**/*.md
agent-test-helper.sh run --suite agent-optimization --json | jq -e '.failed == 0'
```
