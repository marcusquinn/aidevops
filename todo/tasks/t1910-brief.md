---
mode: subagent
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->
# t1910: Extend complexity scanner to Qlty-scored file types (.py/.mjs/.js/.ts)

## Origin

- **Created:** 2026-04-07
- **Session:** claude-code:qlty-maintainability-a-grade
- **Created by:** ai-interactive
- **Conversation context:** Qlty maintainability badge dropped to C. Investigation revealed that `complexity-scan-helper.sh` only scans `.sh` and `.md` files — it is completely blind to the `.py`, `.mjs`, `.js`, and `.ts` files that Qlty actually scores for the maintainability badge. The scanner has been running every 15 minutes but detecting nothing relevant to the badge.

## What

Add `_scan_python_files()`, `_scan_js_files()` functions to `complexity-scan-helper.sh` that detect Python and JavaScript/TypeScript files exceeding complexity thresholds. These functions should use `lizard` (already installed in CI) for Python CCN and line-count/function-count heuristics for JS/MJS/TS. The `cmd_scan()` function must call these scanners when `--type all` or `--type py` / `--type js`.

## Why

- The Qlty maintainability badge scores Python/JS/TS files — the scanner doesn't scan them
- 45 files with Qlty smells exist today with no automated detection in the pulse
- The pulse's `complexity-scan-helper.sh` runs every 15 minutes but only catches shell/markdown violations
- Without this, new complexity in Python/JS/TS ships undetected until a human notices the badge dropped

## Tier

`tier:standard`

**Tier rationale:** Multi-function addition to an existing script, following established patterns (`_scan_shell_files`, `_scan_md_files`). Requires judgment about thresholds but the patterns are clear.

## How (Approach)

### Files to Modify

- `EDIT: .agents/scripts/complexity-scan-helper.sh:274-340` — add `_scan_python_files()` and `_scan_js_files()` modeled on `_scan_shell_files()` and `_scan_md_files()`
- `EDIT: .agents/scripts/complexity-scan-helper.sh:372-420` — extend `cmd_scan()` to accept `--type py|js` and call the new scanners
- `EDIT: .agents/scripts/complexity-scan-helper.sh:596-628` — update help text with new types

### Implementation Steps

1. Add `_scan_python_files()` after `_scan_md_files()` (line ~340):

```bash
_scan_python_files() {
    local repo_path="$1"
    local state_file="$2"

    local check_results
    check_results=$(batch_hash_check "$repo_path" "$state_file" '*.py') || check_results=""
    [[ -z "$check_results" ]] && return 0

    while IFS='|' read -r status file_path; do
        [[ -n "$file_path" ]] || continue
        echo "$file_path" | grep -qE "$_EXCLUDED_DIRS" && continue
        [[ "$status" == "unchanged" ]] && continue

        local full_path="${repo_path}/${file_path}"
        local metrics
        metrics=$(compute_file_metrics "$full_path") || metrics="0|0|0|0|python"

        local line_count func_count long_func_count max_nesting file_type
        IFS='|' read -r line_count func_count long_func_count max_nesting file_type <<<"$metrics"

        # Python threshold: >500 lines OR >8 nesting depth OR lizard CCN >8
        if [[ "$line_count" -gt 500 ]] || [[ "$max_nesting" -gt "$COMPLEXITY_NESTING_DEPTH_THRESHOLD" ]]; then
            printf '%s|%s|%s|%s|%s|%s|%s\n' "$status" "$file_path" "$line_count" "$func_count" "$long_func_count" "$max_nesting" "$file_type"
        fi
    done <<<"$check_results"
    return 0
}
```

2. Add `_scan_js_files()` similarly, handling `*.mjs`, `*.js`, `*.ts` patterns via three `batch_hash_check` calls merged into one result stream.

3. Extend `cmd_scan()` case logic:

```bash
if [[ "$scan_type" == "all" || "$scan_type" == "py" ]]; then
    _scan_python_files "$repo_path" "$state_file" >>"$results_tmp"
fi

if [[ "$scan_type" == "all" || "$scan_type" == "js" ]]; then
    _scan_js_files "$repo_path" "$state_file" >>"$results_tmp"
fi
```

4. Update help text to list new `--type py|js` options.

### Verification

```bash
# Scanner finds known offenders
.agents/scripts/complexity-scan-helper.sh scan . --type py --format pipe | grep -q "email_jmap_adapter.py" && echo PASS
.agents/scripts/complexity-scan-helper.sh scan . --type js --format pipe | grep -q "oauth-pool.mjs" && echo PASS

# Full scan includes all types
.agents/scripts/complexity-scan-helper.sh scan . --format json | python3 -c "import sys,json; d=json.load(sys.stdin); types=set(r['type'] for r in d); assert 'python' in types and 'javascript' in types, f'Missing types: {types}'; print('PASS')"

# ShellCheck clean
shellcheck .agents/scripts/complexity-scan-helper.sh
```

## Acceptance Criteria

- [ ] `_scan_python_files()` detects `.py` files exceeding 500 lines or nesting >8
  ```yaml
  verify:
    method: bash
    run: ".agents/scripts/complexity-scan-helper.sh scan . --type py --format pipe 2>/dev/null | grep -q 'py' && echo PASS || echo FAIL"
  ```
- [ ] `_scan_js_files()` detects `.mjs`, `.js`, `.ts` files exceeding 500 lines or nesting >8
  ```yaml
  verify:
    method: bash
    run: ".agents/scripts/complexity-scan-helper.sh scan . --type js --format pipe 2>/dev/null | grep -q 'mjs\|\.js\|\.ts' && echo PASS || echo FAIL"
  ```
- [ ] `cmd_scan()` with `--type all` includes Python and JS results alongside shell and markdown
- [ ] `batch_hash_check()` correctly handles multiple glob patterns for JS extensions
- [ ] Help text updated with new type options
- [ ] ShellCheck clean
  ```yaml
  verify:
    method: bash
    run: "shellcheck .agents/scripts/complexity-scan-helper.sh"
  ```

## Context & Decisions

- Reuse existing `batch_hash_check()` and `compute_file_metrics()` infrastructure — don't reinvent
- `compute_file_metrics()` already handles Python via the `elif [[ "$ext" == "py" ]]` branch — just needs JS/TS added
- Python threshold at 500 lines (lower than shell's 1500) because Python files are denser and Qlty flags at lower counts
- JS/MJS/TS threshold at 500 lines to match Python — these are the Qlty-scored types
- Don't add `qlty` CLI dependency to the scanner — keep it shell-heuristic-based for speed (<30s target)

## Relevant Files

- `.agents/scripts/complexity-scan-helper.sh:1` — target file (652 lines)
- `.agents/scripts/complexity-scan-helper.sh:278-303` — `_scan_shell_files()` pattern to follow
- `.agents/scripts/complexity-scan-helper.sh:311-340` — `_scan_md_files()` pattern to follow
- `.agents/scripts/complexity-scan-helper.sh:47-116` — `compute_file_metrics()` (needs JS/TS branch)
- `.agents/scripts/pulse-wrapper.sh:5480-5600` — pulse integration that calls the scanner

## Dependencies

- **Blocked by:** nothing
- **Blocks:** t1912 (re-queue logic depends on scanner detecting JS/Python files)
- **External:** none

## Estimate Breakdown

| Phase | Time | Notes |
|-------|------|-------|
| Research/read | 15m | Review existing scanner functions |
| Implementation | 1.5h | Add _scan_python_files, _scan_js_files, extend cmd_scan |
| Testing | 30m | Verify detection of known offenders, shellcheck |
| **Total** | **~2h** | |
