---
mode: subagent
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->
# t1913: Automate ratchet-down of complexity thresholds

## Origin

- **Created:** 2026-04-07
- **Session:** claude-code:qlty-maintainability-a-grade
- **Created by:** ai-interactive
- **Conversation context:** Qlty maintainability badge dropped to C. Investigation found that `complexity-thresholds.conf` has been bumped UP 11 times (documented in comments) but never ratcheted down. The design says "lower after simplification PRs merge" but the mechanism is manual and never triggered. The ratchet must be automated to actually converge.

## What

Add a `ratchet-check` command to `complexity-scan-helper.sh` that compares current violation baselines against the thresholds in `complexity-thresholds.conf`. When the actual baseline drops below the threshold by more than a configurable gap (default 5), the command outputs the proposed new thresholds. The pulse calls this after simplification-debt issues close and creates a `chore/ratchet-down` PR to lower the thresholds.

## Why

- Thresholds have only gone UP (11 bumps documented in comments) — never down
- Without automated ratcheting, simplification wins don't translate into tighter gates
- The design intent ("lower after simplification PRs merge") exists in comments but has no automation
- This closes the loop: simplification reduces violations → ratchet tightens thresholds → CI blocks regression

## Tier

`tier:standard`

**Tier rationale:** Adding a new command to an existing script, following established patterns. The logic is straightforward: count violations, compare to thresholds, output proposed values.

## How (Approach)

### Files to Modify

- `EDIT: .agents/scripts/complexity-scan-helper.sh` — add `cmd_ratchet_check()` command
- `EDIT: .agents/scripts/pulse-wrapper.sh` — call ratchet-check after simplification backfill, create PR if gap detected

### Implementation Steps

1. Add `cmd_ratchet_check()` to `complexity-scan-helper.sh`:

```bash
cmd_ratchet_check() {
    local repo_path="${1:-.}"
    local gap="${2:-5}"
    local conf_file="${repo_path}/.agents/configs/complexity-thresholds.conf"

    [[ -f "$conf_file" ]] || { _log "ERROR" "Config not found: $conf_file"; return 1; }

    # Read current thresholds
    local func_threshold nest_threshold size_threshold
    func_threshold=$(grep '^FUNCTION_COMPLEXITY_THRESHOLD=' "$conf_file" | cut -d= -f2)
    nest_threshold=$(grep '^NESTING_DEPTH_THRESHOLD=' "$conf_file" | cut -d= -f2)
    size_threshold=$(grep '^FILE_SIZE_THRESHOLD=' "$conf_file" | cut -d= -f2)

    # Count actual violations (same logic as CI steps)
    # ... (count violations using lint-file-discovery.sh patterns)

    # Compare and output proposals
    local proposed=0
    if [[ $((func_threshold - actual_func)) -ge "$gap" ]]; then
        echo "FUNCTION_COMPLEXITY_THRESHOLD: ${func_threshold} → $((actual_func + 2))"
        proposed=$((proposed + 1))
    fi
    # ... similar for nest_threshold, size_threshold

    [[ "$proposed" -gt 0 ]] && return 0 || return 1
}
```

2. In pulse-wrapper.sh, after `_simplification_state_backfill_closed()` runs and finds entries, call `complexity-scan-helper.sh ratchet-check` and create a PR if it returns 0.

3. Add `ratchet-check` to the main dispatch case in `complexity-scan-helper.sh`.

### Verification

```bash
# Command exists and runs
.agents/scripts/complexity-scan-helper.sh ratchet-check . 5

# ShellCheck clean
shellcheck .agents/scripts/complexity-scan-helper.sh
```

## Acceptance Criteria

- [ ] `cmd_ratchet_check()` compares actual violation counts against thresholds in config
  ```yaml
  verify:
    method: codebase
    pattern: "ratchet.check"
    path: ".agents/scripts/complexity-scan-helper.sh"
  ```
- [ ] Outputs proposed thresholds when gap exceeds configured minimum (default 5)
- [ ] Returns exit 0 when ratchet-down is possible, exit 1 when thresholds are already tight
- [ ] Pulse integration creates a PR (or issue) when ratchet-down is available
- [ ] Proposed threshold is set to `actual_count + 2` (buffer for concurrent PRs)
- [ ] ShellCheck clean
  ```yaml
  verify:
    method: bash
    run: "shellcheck .agents/scripts/complexity-scan-helper.sh"
  ```

## Context & Decisions

- Buffer of +2 above actual count prevents flapping — concurrent PRs may temporarily increase violations before their simplification merges
- Gap threshold of 5 prevents noise — only propose ratcheting when meaningful reduction has accumulated
- The ratchet-check is idempotent — running it twice with no intervening changes produces the same proposal
- Bash 3.2 compat threshold (`BASH32_COMPAT_THRESHOLD`) is also ratchetable — include it in the check
- Comments documenting bump history in the config file are valuable audit trail — don't remove them, add a new ratchet-down comment

## Relevant Files

- `.agents/scripts/complexity-scan-helper.sh:634-651` — main dispatch (add `ratchet-check` case)
- `.agents/configs/complexity-thresholds.conf:1-46` — threshold config file
- `.github/workflows/code-quality.yml:312-429` — CI steps that count violations (reference for counting logic)
- `.agents/scripts/lint-file-discovery.sh` — shared file discovery used by CI

## Dependencies

- **Blocked by:** nothing (can ship independently)
- **Blocks:** sustained threshold convergence
- **External:** none

## Estimate Breakdown

| Phase | Time | Notes |
|-------|------|-------|
| Research/read | 15m | Review CI violation counting logic |
| Implementation | 1.5h | Add ratchet-check command, pulse integration |
| Testing | 30m | Test with current baselines vs thresholds |
| **Total** | **~2h** | |
