<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->
# t2064: Consolidate `email_imap_adapter.py` and `email_imap_adapter_core.py`

## Origin

- **Created:** 2026-04-14
- **Session:** claude-code:quality-a-grade
- **Created by:** ai-interactive (from C→A qlty audit conversation)
- **Parent task:** none
- **Conversation context:** Qlty rating is stuck at C. Local `qlty smells --all --sarif` shows 109 smells total. 22 of 26 `identical-code` smells — roughly **28% of all smells** in the repo — are literally this one pair of files duplicating each other. Single highest-leverage fix.

## What

Merge `.agents/scripts/email_imap_adapter.py` (911 lines) and `.agents/scripts/email_imap_adapter_core.py` (864 lines) into a single module with no duplicated code paths. After this change, `qlty smells --all --sarif | jq '[.runs[0].results[] | select(.ruleId == "qlty:identical-code") | select(.locations[0].physicalLocation.artifactLocation.uri | contains("email_imap"))] | length'` returns `0`.

Users of either module continue to work: whichever symbols the rest of the codebase currently imports from `email_imap_adapter.py` or `email_imap_adapter_core.py` remain importable from the same path (via re-export shim if needed). Behaviour is byte-equivalent on existing callsites.

## Why

- **Largest single smell reducer in the codebase.** Local SARIF confirms 22 `qlty:identical-code` smells are paired between these two files, plus ~6 additional `file-complexity` / `function-complexity` smells on the same pair. Merging them removes ~28 smells in one PR — ~26% of the total 109.
- Moving from 109 smells to ~81 in one merge moves the Qlty Cloud grade closer to B territory. Combined with the other tasks filed in this batch (t2065–t2073), this is the foundation for C→A.
- The duplication isn't theoretical — `diff` shows the files diverge only at line 229+, where one defines `_parse_imap_date` and the other defines `_parse_envelope_from_fetch`. Everything else is literally identical.

## Tier

### Tier checklist

- [ ] 2 or fewer files to modify? (3–5 files: both adapters, any callers, test harness)
- [ ] Complete code blocks for every edit? No — requires judgment on which file becomes canonical
- [ ] No judgment or design decisions? No — must decide naming, extraction boundaries
- [ ] No error handling / fallback logic to design? No — IMAP error paths must be preserved exactly
- [ ] Estimate 1h or less? No
- [ ] 4 or fewer acceptance criteria? Close but design-heavy

**Selected tier:** `tier:thinking`

**Tier rationale:** Merging two 900-line Python modules without breaking IMAP behaviour requires reading both files in full, mapping every callsite via `rg "email_imap_adapter"`, and synthesising a clean module boundary. This is semantic refactor work — not mechanical. Opus-tier.

## PR Conventions

Leaf task. PR body: `Resolves #NNN`.

## How (Approach)

### Worker Quick-Start

```bash
# 1. Baseline the smell count for these files:
~/.qlty/bin/qlty smells --all --sarif --no-snippets --quiet 2>/dev/null \
  | jq '[.runs[0].results[] | select(.locations[0].physicalLocation.artifactLocation.uri | test("email_imap_adapter"))] | length'
# Expected: ~31 smells between the two files.

# 2. Find every caller:
rg -l "email_imap_adapter(_core)?" .agents/ --type py --type sh

# 3. Diff the two files to confirm duplication scope:
diff .agents/scripts/email_imap_adapter.py .agents/scripts/email_imap_adapter_core.py | wc -l
# Roughly 347 lines differ out of ~1775 total; the bulk is identical.
```

### Files to Modify

- `EDIT: .agents/scripts/email_imap_adapter.py` (911 lines) — canonical destination OR becomes re-export shim
- `EDIT: .agents/scripts/email_imap_adapter_core.py` (864 lines) — canonical destination OR becomes re-export shim
- `EDIT: {any caller scripts}` — identified via `rg -l "email_imap_adapter"`
- `EDIT/NEW: tests covering IMAP envelope parsing and date header parsing` — must cover both `_parse_imap_date` and `_parse_envelope_from_fetch` code paths to prove the merge is behaviour-preserving

### Implementation Steps

1. **Decide canonical module.** Read both files end to end. The `_core.py` name suggests it was the original; `email_imap_adapter.py` is the facade. Preferred approach: keep `email_imap_adapter.py` as the canonical module and delete `email_imap_adapter_core.py`, folding its unique symbols (`_parse_envelope_from_fetch`, etc.) into the canonical file. Add a thin re-export shim at `email_imap_adapter_core.py` path if any caller still imports it, OR update all callers in the same PR.

2. **Map callers.** `rg -l "email_imap_adapter" .agents/` — every match is a caller to check. Likely callers include `email-voice-miner.py`, `email_jmap_adapter.py`, `email-thread-reconstruction.py`, `email-summary.py`.

3. **Extract shared helpers to clear duplication.** The duplicated 22-line/44-line/68-line blocks are IMAP parsing helpers. Factor them into private functions referenced once in the canonical module.

4. **Preserve behaviour byte-for-byte** on the public surface (functions referenced by external callers). Add unit tests covering: date header parsing (valid/invalid), envelope-from-fetch parsing, multi-byte subject encoding, IDLE/NOOP handling if present.

5. **Delete the redundant file** and update all imports.

### Verification

```bash
# 0 smells from email_imap_adapter*
~/.qlty/bin/qlty smells --all --sarif --no-snippets --quiet 2>/dev/null \
  | jq '[.runs[0].results[] | select(.locations[0].physicalLocation.artifactLocation.uri | test("email_imap_adapter"))] | length'
# Expected: 0 (or <5 residual complexity, MUCH less than 31)

# No broken imports
python3 -c "import sys; sys.path.insert(0, '.agents/scripts'); import email_imap_adapter; print('ok')"

# Callers still resolve
for f in $(rg -l "email_imap_adapter" .agents/scripts/); do
  python3 -c "import ast; ast.parse(open('$f').read())" && echo "ok: $f"
done
```

## Acceptance Criteria

- [ ] `qlty smells --all --sarif` reports **zero** `identical-code` smells between `email_imap_adapter.py` and `email_imap_adapter_core.py`
  ```yaml
  verify:
    method: bash
    run: "~/.qlty/bin/qlty smells --all --sarif --no-snippets --quiet 2>/dev/null | jq -e '[.runs[0].results[] | select(.ruleId == \"qlty:identical-code\") | select(.locations[0].physicalLocation.artifactLocation.uri | test(\"email_imap\"))] | length == 0'"
  ```
- [ ] Total smell count on `email_imap_adapter*` drops from ~31 to ≤5
  ```yaml
  verify:
    method: bash
    run: "~/.qlty/bin/qlty smells --all --sarif --no-snippets --quiet 2>/dev/null | jq -e '[.runs[0].results[] | select(.locations[0].physicalLocation.artifactLocation.uri | test(\"email_imap_adapter\"))] | length <= 5'"
  ```
- [ ] All existing callers continue to import successfully (no `ModuleNotFoundError`, no `ImportError`)
- [ ] Unit tests cover both `_parse_imap_date` and `_parse_envelope_from_fetch` paths, pass green
- [ ] `python3 -m py_compile .agents/scripts/email_imap_adapter*.py` succeeds
- [ ] Repo-wide total smell count drops by at least 20

## Context & Decisions

- The `_core` split was likely an earlier attempt to segregate "pure parsing" from "network/IMAP-state" logic, but the split drifted and the two files re-converged on identical helpers.
- Do NOT attempt to re-split into pure/impure sub-modules as part of this task — that is a separate concern and would blow the estimate. Merge first, refactor structure later if needed.
- The merge must be byte-equivalent on observable IMAP behaviour. If behaviour differs between the two files today (e.g., one handles a malformed header differently), **preserve the union** — flag it in the PR description for human review, don't silently pick one.

## Relevant Files

- `.agents/scripts/email_imap_adapter.py:229` — `_parse_imap_date` (unique to this file)
- `.agents/scripts/email_imap_adapter_core.py:229` — `_parse_envelope_from_fetch` (unique to this file)
- `.agents/scripts/email_imap_adapter_core.py:365` — `cmd_fetch_body` (31-complexity function flagged by qlty)
- `.agents/scripts/email_jmap_adapter.py` — likely imports from one of the two
- `.agents/scripts/email-voice-miner.py` — likely caller

## Dependencies

- **Blocked by:** none
- **Blocks:** progress on the qlty C→A campaign (batch t2064–t2073)
- **External:** none

## Estimate Breakdown

| Phase | Time | Notes |
|-------|------|-------|
| Research/read | 30m | Both adapter files end-to-end, all callers |
| Implementation | 2–3h | Merge, add tests, update callers |
| Testing | 30m | Run IMAP-dependent tests, manual smoke |
| **Total** | **~4h** | |
