# Autoagent — Safety Constraints

Sub-doc for `autoagent.md`. Loaded during Step 1 setup.

---

## Security Instruction Exemptions

Inherited from `autoresearch/agent-optimization.md`. Discard any hypothesis that removes or weakens the following — do not test:

| Category | Detection pattern |
|----------|------------------|
| Credential/secret handling | `credentials`, `NEVER expose`, `gopass`, `secret` |
| File operation safety | `Read before Edit`, `pre-edit-check`, `verify path` |
| Git safety | `pre-edit-check.sh`, `never edit on main`, `worktree` |
| Traceability | `PR title MUST`, `task ID`, `Closes #` |
| Prompt injection | `prompt injection`, `adversarial`, `scan` |
| Destructive operations | `destructive`, `confirm before`, `irreversible` |

Enforced by both the research program constraint list and the researcher model. Both layers must hold.

---

## Never-Modify Files

These files must not be modified by autoagent under any safety level:

| File | Reason |
|------|--------|
| `.agents/prompts/build.txt` security sections (rules 7–8) | Prompt injection and secret handling — core security posture |
| `.agents/tools/security/prompt-injection-defender.md` | Security threat model — changes require human review |
| `.agents/tools/credentials/gopass.md` | Credential handling — changes could expose secrets |
| `.agents/scripts/pre-edit-check.sh` | Git safety gate — disabling it breaks the entire safety model |
| `.agents/scripts/prompt-guard-helper.sh` | Prompt injection scanner — security-critical |

**Detection:** Before applying any modification, check if the target file matches this list. If yes, reject the hypothesis immediately without testing.

---

## Elevated-Only Files

These files may only be modified when `SAFETY_LEVEL == "elevated"`. At standard safety level, reject hypotheses targeting them:

| File | Reason |
|------|--------|
| `.agents/AGENTS.md` | Primary user-facing guide — changes affect all users |
| `.agents/prompts/build.txt` (non-security sections) | Core instruction set — high blast radius |
| `.agents/workflows/git-workflow.md` | Git workflow — changes affect all PRs and commits |
| `.agents/scripts/commands/full-loop.md` | Full-loop orchestration — changes affect all workers |

**Elevated approval:** When `SAFETY_LEVEL == "elevated"`, these files are allowed but require the regression gate to pass before keeping.

---

## Core Workflow Preservation

Autoagent must not break these invariants regardless of safety level:

1. **Git workflow:** Every code change must go through a worktree + PR. No direct commits to main.
2. **PR flow:** PRs must have task IDs, `Closes #NNN`, and signature footers.
3. **Task management:** TODO.md format must remain parseable by `issue-sync-helper.sh`.
4. **Pre-edit check:** `pre-edit-check.sh` must continue to block edits on main/master.
5. **Secret handling:** No credentials may appear in logs, output, or committed files.

If a hypothesis would break any of these invariants, reject it without testing.

---

## Regression Gate

Before keeping any improvement, verify that ALL comprehension tests still pass:

```bash
# Run full comprehension test suite
agent-test-helper.sh run --suite agent-optimization --json 2>/dev/null \
  | jq -e '.pass_rate >= .baseline_pass_rate'
# exit 0 = no regression; exit 1 = regression detected
```

**Rule:** No existing passing comprehension test may start failing as a result of a kept change.

- If regression detected → `git -C WORKTREE_PATH reset --hard HEAD` and log as `regression_fail`.
- The composite score improvement is not sufficient justification to accept a regression.

---

## Rollback Procedure

Rollback is always safe and always available:

```bash
# Revert to last known-good state (last committed improvement)
git -C WORKTREE_PATH reset --hard HEAD

# Verify clean state
git -C WORKTREE_PATH status --porcelain
# Should output nothing (empty = clean)
```

**When to rollback:**
- Constraint check fails
- Metric measurement errors
- Regression gate fails
- Any unexpected error during modification

**Rollback does not affect results.tsv** — the failed attempt is already logged before rollback.

---

## Safety Level Summary

| Safety level | Never-modify | Elevated-only | Regression gate |
|-------------|-------------|---------------|-----------------|
| `standard` (default) | Blocked | Blocked | Required |
| `elevated` | Blocked | Allowed | Required (stricter) |

Elevated safety level requires explicit opt-in in the research program (`safety_level: elevated`). It is never the default.
