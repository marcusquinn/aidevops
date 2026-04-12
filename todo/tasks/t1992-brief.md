---
mode: subagent
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->
# t1992: Fix daily quality sweep serialization — multi-line sections corrupted by IFS=read -r

## Origin

- **Created:** 2026-04-12
- **Session:** claude-code:interactive
- **Created by:** marcusquinn (human) via ai-interactive
- **Parent task:** none
- **Conversation context:** While reviewing PR #18405 (t1982 consolidation fix), the user asked whether the daily code quality sweep would catch a post-merge bot finding (Gemini's jq-in-loop suggestion). Investigation found the sweep runs daily but its rendered output is truncated to a single corrupted ShellCheck section — the rest of the tool sections (Qlty, SonarCloud, Codacy, CodeRabbit, review_scan) never reach the posted comment despite `tool_count=5`.

## What

Fix the broken section serialization in `_quality_sweep_for_repo()` at `.agents/scripts/stats-functions.sh:2417-2429`. Today's code writes 12 fields to a temp file via `printf '%s\n' ...` and reads them back with a sequence of `IFS= read -r` calls. This pattern only works for single-line fields. Every section variable (`shellcheck_section`, `qlty_section`, `sonar_section`, `codacy_section`, `coderabbit_section`, `review_scan_section`) contains multi-line markdown with embedded newlines. The first line of each section lands in its variable; lines 2-N leak into subsequent variables. The rendered comment then shows fragments: the ShellCheck header appears correctly, but the `Errors/Warnings` counts and the `**Top findings:**` block are parsed as Qlty/Sonar/Codacy section content and never reach the template.

Replace the serialization with a multi-line-safe approach. Preferred: write each section to its own temp file (one file per variable), read each back with `cat` in one shot. Alternative: null-delimited `printf '%s\0'` + `IFS= read -rd ''` (works but needs bash ≥4.0 — verify macOS compatibility). Alternative: inline all sections into a single JSON object written once with `jq -n` and parsed with `jq -r` per field.

Also fix an adjacent bug in `_sweep_shellcheck()` at line 1754-1756: the error/warning counters use `grep -c ':.*: error:'` and `grep -c ':.*: warning:'`, but `shellcheck -f gcc` emits severity `note` for SC1091 (the most common finding) — not `warning` or `error`. So every SC1091 finding is detailed in `sc_details` but `sc_errors` and `sc_warnings` stay at zero. That's why today's sweep comment shows "(100 files scanned)" with no error/warning counts but three raw findings below.

After both fixes: posted sweep comment on issue #2632 should render all six tool sections with non-empty content, and ShellCheck counts should reflect the actual finding volume (note: SonarCloud reports 224 open issues + 161 `shelldre:S1481` dead vars — the sweep should surface these under the SonarCloud section).

## Why

The sweep is one of the framework's primary quality radars. It runs daily via the pulse, posts a comment on issue #2632, and the comment body is where the maintainer + supervisor LLM review findings to create actionable issues. Right now it's effectively dark — the supervisor is reading a near-empty comment and assuming "nothing much to do" when in fact:

- SonarCloud has 224 open issues (top rules: `shelldre:S1481=161`, `shelldre:S1066=63`)
- Qlty reports 109 smells locally
- CodeRabbit daily full-review trigger is failing (separate bug, tracked elsewhere)
- Codacy data is being silently dropped

The user's original question — "would the daily sweep catch jq-in-loop patterns?" — exposed this: the sweep can't catch any pattern if its output is corrupted. The discovered bug is higher-impact than the original jq-in-loop concern because it means the quality gate infrastructure has been largely blind for an unknown period (at least since the multi-operator pulse moved the sweep posting to account `milohiss`, today 02:55:17Z).

## Tier

### Tier checklist (verify before assigning)

- [ ] **2 or fewer files to modify?** → no (`stats-functions.sh` + new regression test + docs for serialization choice = 3)
- [ ] **Complete code blocks for every edit?** → no (skeletons provided, exact serialization strategy to pick from 3 options)
- [ ] **No judgment or design decisions?** → no (choice between temp-file-per-section / null-delim / jq single-JSON — each has trade-offs)
- [ ] **No error handling or fallback logic to design?** → no (what happens when a section tool fails midway? partial data should still render)
- [ ] **Estimate 1h or less?** → no (~2-3h including testing)
- [ ] **4 or fewer acceptance criteria?** → no (7 criteria)

**Selected tier:** `tier:standard`

**Tier rationale:** Multi-line I/O bug in a mission-critical serializer. Judgment needed on serialization approach (trade-offs: readability vs dependency on bash 4 vs extra files on disk). Requires a regression test that demonstrates the bug survives no future attempt to revert to per-line reads. Not novel enough for `tier:reasoning`.

## How (Approach)

### Files to Modify

- `EDIT: .agents/scripts/stats-functions.sh:2340-2395` — `_run_sweep_tools()`: change the output mechanism. Currently writes sections line-by-line; must write each section to a separate temp file, or use null-delimited output, or emit single JSON blob.
- `EDIT: .agents/scripts/stats-functions.sh:2408-2430` — `_quality_sweep_for_repo()`: change the read mechanism to match the new writer. Replace `IFS= read -r` chain with temp-file cats / null-delim reads / jq -r extractions.
- `EDIT: .agents/scripts/stats-functions.sh:1752-1770` — `_sweep_shellcheck()`: fix the severity grep patterns. Change `':.*: error:'` and `':.*: warning:'` to match gcc-format severities including `note:`, OR count the total non-empty lines and classify by parsing the `[SCxxxx]` rule tag instead. Document the chosen approach inline.
- `NEW: .agents/scripts/tests/test-quality-sweep-serialization.sh` — regression test proving multi-line sections round-trip correctly.
- `EDIT: .agents/scripts/tests/test-pulse-wrapper-characterization.sh` — if any of the touched function names change, update the function-existence list.

### Implementation Steps

1. **Pick the serialization strategy.** My recommendation: **one temp file per section**. Rationale: easiest to debug (you can `ls` the tmpdir and cat each file), no bash version constraints, no jq dependency inside the serialization path (jq is still used inside the tool functions but not for the inter-function payload).

   ```bash
   # In _run_sweep_tools:
   local sections_dir
   sections_dir=$(mktemp -d)
   printf '%s' "$tool_count"          >"${sections_dir}/tool_count"
   printf '%s' "$shellcheck_section"  >"${sections_dir}/shellcheck"
   printf '%s' "$qlty_section"        >"${sections_dir}/qlty"
   printf '%s' "$qlty_smell_count"    >"${sections_dir}/qlty_smell_count"
   printf '%s' "$qlty_grade"          >"${sections_dir}/qlty_grade"
   printf '%s' "$sonar_section"       >"${sections_dir}/sonar"
   printf '%s' "$sweep_gate_status"   >"${sections_dir}/sweep_gate_status"
   printf '%s' "$sweep_total_issues"  >"${sections_dir}/sweep_total_issues"
   printf '%s' "$sweep_high_critical" >"${sections_dir}/sweep_high_critical"
   printf '%s' "$codacy_section"      >"${sections_dir}/codacy"
   printf '%s' "$coderabbit_section"  >"${sections_dir}/coderabbit"
   printf '%s' "$review_scan_section" >"${sections_dir}/review_scan"
   printf '%s\n' "$sections_dir"  # emit the sections dir path as the single-line handshake
   ```

   ```bash
   # In _quality_sweep_for_repo:
   local sections_dir
   sections_dir=$(_run_sweep_tools "$repo_slug" "$repo_path")
   [[ -d "$sections_dir" ]] || {
       echo "[stats] Quality sweep: _run_sweep_tools produced no sections dir for ${repo_slug}" >>"$LOGFILE"
       return 0
   }

   local tool_count shellcheck_section qlty_section qlty_smell_count qlty_grade
   local sonar_section sweep_gate_status sweep_total_issues sweep_high_critical
   local codacy_section coderabbit_section review_scan_section
   tool_count=$(cat "${sections_dir}/tool_count" 2>/dev/null || echo 0)
   shellcheck_section=$(cat "${sections_dir}/shellcheck" 2>/dev/null || echo "")
   qlty_section=$(cat "${sections_dir}/qlty" 2>/dev/null || echo "")
   qlty_smell_count=$(cat "${sections_dir}/qlty_smell_count" 2>/dev/null || echo 0)
   qlty_grade=$(cat "${sections_dir}/qlty_grade" 2>/dev/null || echo UNKNOWN)
   sonar_section=$(cat "${sections_dir}/sonar" 2>/dev/null || echo "")
   sweep_gate_status=$(cat "${sections_dir}/sweep_gate_status" 2>/dev/null || echo UNKNOWN)
   sweep_total_issues=$(cat "${sections_dir}/sweep_total_issues" 2>/dev/null || echo 0)
   sweep_high_critical=$(cat "${sections_dir}/sweep_high_critical" 2>/dev/null || echo 0)
   codacy_section=$(cat "${sections_dir}/codacy" 2>/dev/null || echo "")
   coderabbit_section=$(cat "${sections_dir}/coderabbit" 2>/dev/null || echo "")
   review_scan_section=$(cat "${sections_dir}/review_scan" 2>/dev/null || echo "")

   rm -rf "$sections_dir"
   ```

2. **Fix the ShellCheck severity counters.** Replace the two brittle greps with a single parse over the gcc-format output. Example approach:

   ```bash
   # In _sweep_shellcheck, after $result is captured:
   # gcc format lines look like:
   #   file.sh:42:3: note: not following: ./shared-constants.sh was not specified ... [SC1091]
   #   file.sh:85:1: error: Syntax error ... [SC1009]
   #   file.sh:12:5: warning: Declare and assign separately ... [SC2155]
   # Count each severity type.
   local file_errors file_warnings file_notes
   file_errors=$(grep -cE ':[0-9]+:[0-9]+: error:' <<<"$result") || file_errors=0
   file_warnings=$(grep -cE ':[0-9]+:[0-9]+: warning:' <<<"$result") || file_warnings=0
   file_notes=$(grep -cE ':[0-9]+:[0-9]+: note:' <<<"$result") || file_notes=0
   sc_errors=$((sc_errors + file_errors))
   sc_warnings=$((sc_warnings + file_warnings))
   sc_notes=$((sc_notes + file_notes))
   ```

   And render `- **Notes**: ${sc_notes}` in the section template alongside Errors and Warnings so SC1091 (the noisiest rule) is actually visible.

3. **Write the regression test** at `.agents/scripts/tests/test-quality-sweep-serialization.sh`:

   ```bash
   #!/usr/bin/env bash
   set -euo pipefail
   # Source stats-functions.sh and call _run_sweep_tools / _quality_sweep_for_repo
   # with stubbed _sweep_* functions that return known multi-line markdown.
   # Assert every section variable in the caller matches its producer byte-for-byte.
   #
   # Use a fixture like:
   #   shellcheck_section="### ShellCheck\n\n- **Errors**: 0\n- **Warnings**: 0\n\n**Top findings:**\n  - finding 1\n  - finding 2\n  - finding 3\n"
   # Stub _sweep_shellcheck to printf "$shellcheck_section"
   # Call _run_sweep_tools and assert that the reader captures the full multi-line content.
   ```

   Minimum 5 assertions:
   1. `shellcheck_section` survives round-trip byte-for-byte with 10-line fixture
   2. `qlty_section` survives with 20-line fixture
   3. `sonar_section` + its integer metadata (`sweep_gate_status`, `sweep_total_issues`, `sweep_high_critical`) all read correctly when the section has embedded newlines
   4. `coderabbit_section` survives when empty string
   5. `review_scan_section` survives when it's the last field and the previous section has no trailing newline

4. **Manual smoke test** on the live repo:

   ```bash
   # Source stats-functions.sh in a shell, call _quality_sweep_for_repo on marcusquinn/aidevops
   # with a modified posting step (post to a throwaway issue or dry-run instead of #2632)
   # and verify the comment body includes all 6 tool sections with real data.
   ```

5. **Shellcheck clean** all touched files.

### Verification

```bash
cd ~/Git/aidevops-<worktree>
shellcheck .agents/scripts/stats-functions.sh
shellcheck .agents/scripts/tests/test-quality-sweep-serialization.sh
bash .agents/scripts/tests/test-quality-sweep-serialization.sh
bash .agents/scripts/tests/test-pulse-wrapper-characterization.sh
```

And a manual verification step (the code path is hard to test end-to-end without hitting GitHub):

```bash
# Dry-run the sweep against a scratch issue in a test repo and diff the posted body
# against expected content. Capture the actual comment body from #2632 on the next
# daily run and verify it has non-empty Qlty/SonarCloud/Codacy sections.
```

## Acceptance Criteria

- [ ] `_run_sweep_tools` and `_quality_sweep_for_repo` no longer use `IFS= read -r` for multi-line section transport (one reader per section via temp file / null-delim / jq).
  ```yaml
  verify:
    method: codebase
    pattern: "IFS= read -r shellcheck_section"
    path: ".agents/scripts/stats-functions.sh"
    expect: absent
  ```
- [ ] Each section variable in `_quality_sweep_for_repo` can contain embedded newlines and still round-trip through the writer/reader pipeline byte-for-byte.
  ```yaml
  verify:
    method: bash
    run: "bash .agents/scripts/tests/test-quality-sweep-serialization.sh"
  ```
- [ ] `_sweep_shellcheck` counts `note:` findings in addition to `error:` and `warning:` (or explicitly parses the `[SCxxxx]` rule tag), and the rendered section shows all three severity counts.
  ```yaml
  verify:
    method: codebase
    pattern: "sc_notes|sc_informational|SC1091"
    path: ".agents/scripts/stats-functions.sh"
  ```
- [ ] Regression test `test-quality-sweep-serialization.sh` passes with 5+ assertions covering: non-empty single-line sections, multi-line sections, empty sections, integer fields adjacent to multi-line strings, and a section as the last field of the payload.
  ```yaml
  verify:
    method: bash
    run: "rg -c '^test_' .agents/scripts/tests/test-quality-sweep-serialization.sh | xargs test 5 -le"
  ```
- [ ] `shellcheck` clean on all touched scripts.
  ```yaml
  verify:
    method: bash
    run: "shellcheck .agents/scripts/stats-functions.sh .agents/scripts/tests/test-quality-sweep-serialization.sh"
  ```
- [ ] `test-pulse-wrapper-characterization.sh` still passes (no function name regressions).
  ```yaml
  verify:
    method: bash
    run: "bash .agents/scripts/tests/test-pulse-wrapper-characterization.sh"
  ```
- [ ] Manual verification note added to the PR description: include a diff between today's broken sweep comment (before) and a dry-run of the fixed sweep (after), showing all six tool sections with non-empty content.
  ```yaml
  verify:
    method: manual
    prompt: "PR description contains before/after sweep comment diff"
  ```

## Context & Decisions

- **Why one-temp-file-per-section over null-delim or single-JSON:**
  - Temp files are easy to debug — `ls $sections_dir` shows each field as a named file, `cat` shows its exact content.
  - No bash version constraint (null-delim `read -rd ''` works on bash 4+ but we target bash 3.2 for macOS — see `reference/bash-compat.md`).
  - No jq dependency inside the serialization path (avoids "what if jq is unavailable in the sweep environment" edge cases).
  - Trade-off: extra syscalls for the writer (12 open/write/close) and for the reader (12 cat subshells). Negligible at daily cadence.
- **Why not just fix the grep patterns in _sweep_shellcheck and leave the serialization as-is:** the serialization is the root cause. Fixing only the grep would still leave Qlty/SonarCloud/Codacy/CodeRabbit/review_scan sections silently dropped.
- **SC1091 noise specifically:** SC1091 fires on every script that sources `shared-constants.sh` because `-x` was removed from the invocation (t1398.2 hardening). The fix here does NOT re-enable `-x` — we just want to count and display SC1091 notes honestly rather than hiding them as zero. A separate follow-up could add `shared-constants.sh` to shellcheck's include path to silence SC1091 entirely.
- **Ruled out:**
  - *Inline all 6 sections into the comment body as a single blob without serialization* — means `_run_sweep_tools` would have to also handle the rendering, coupling two concerns. The current separation (tools return markdown, caller renders the template) is cleaner if we fix the serialization.
  - *Switch to a proper dataclass-style associative array* — bash 4+ only, and associative arrays don't handle multi-line strings any better than the current approach.

## Relevant Files

- `.agents/scripts/stats-functions.sh:2282-2459` — sweep pipeline (`_build_sweep_comment`, `_run_sweep_tools`, `_quality_sweep_for_repo`)
- `.agents/scripts/stats-functions.sh:1701-1793` — `_sweep_shellcheck` (severity count bug)
- `.agents/scripts/stats-functions.sh:1804-1898` — `_sweep_qlty` (section producer — multi-line)
- `.agents/scripts/stats-functions.sh:1907-1988` — `_sweep_sonarcloud` (section producer — multi-line)
- `.agents/scripts/stats-functions.sh:2128-2227` — `_sweep_codacy`, `_sweep_coderabbit`, `_sweep_review_scanner`
- `.agents/scripts/tests/test-quality-feedback-main-verification.sh` — adjacent test pattern to reference
- Live repro: issue #2632 on `marcusquinn/aidevops`, most recent milohiss-authored comment

## Dependencies

- **Blocked by:** none
- **Blocks:** any downstream work that reads the sweep comment for supervisor LLM guidance (the supervisor reads #2632 for "what to work on" — broken sweep means broken guidance)
- **External:** none — all tool backends (ShellCheck, Qlty, SonarCloud, Codacy, CodeRabbit) already work in isolation; this fix only repairs the aggregation layer

## Estimate Breakdown

| Phase | Time | Notes |
|-------|------|-------|
| Read sweep pipeline end-to-end | 20m | |
| Refactor writer + reader to temp-file-per-section | 40m | Straightforward transform |
| Fix `_sweep_shellcheck` severity counters | 20m | Add note count + section template row |
| Write regression test (5+ assertions) | 40m | Fixture-based, stub `_sweep_*` functions |
| Shellcheck + characterization + manual dry-run | 20m | |
| PR description with before/after diff | 15m | |
| **Total** | **~2.5h** | |
