<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->
# t2111: fix(issue-sync): ratchet rule in `_apply_tier_label_replace` — preserve cascade-escalated tier labels

## Origin

- **Created:** 2026-04-15
- **Session:** claude-code:interactive
- **Created by:** ai-interactive (operator asked about tier flip-flop on GH#19038)
- **Parent task:** none
- **Conversation context:** Operator noticed that GH#19038 had its tier escalated from `tier:standard` to `tier:thinking` by the cascade path, only to be reverted 5 minutes later by the `issue-sync` scheduled GitHub Actions run. Next pulse cycle then dispatched another `tier:standard` worker that failed the same way. Flip-flop is observable in the label event history on #19038 (00:38:49 escalation, 00:44:15/16 revert).

## What

Add a **ratchet rule** to `_apply_tier_label_replace` in `.agents/scripts/issue-sync-helper.sh` so that enrichment cannot downgrade a tier label that the cascade escalation (`escalate_issue_tier` in `worker-lifecycle-common.sh`) raised above the brief's declared tier.

Semantics: **brief tier is a floor, cascade tier is a ceiling; ceiling wins.**

Rank ordering: `tier:simple` (0) < `tier:standard` (1) < `tier:thinking` (2).

Behaviour:

| Existing tier label(s) on issue | Incoming `new_tier` from brief | Action |
|---|---|---|
| none | any | add new_tier |
| `tier:simple` | `tier:standard` | remove simple, add standard (pre-existing behaviour) |
| `tier:standard` | `tier:standard` | no-op (pre-existing behaviour) |
| `tier:thinking` | `tier:standard` | **no-op — escalation is preserved (NEW)** |
| `tier:thinking` | `tier:simple` | **no-op — escalation is preserved (NEW)** |
| `tier:simple` + `tier:thinking` (multi) | `tier:standard` | **no-op — max(existing) > new (NEW)** |
| `tier:simple` + `tier:standard` (multi) | `tier:thinking` | remove simple + standard, add thinking (upgrade) |

The rule key: compute `max_existing_rank` over all currently applied `tier:*` labels. If `max_existing_rank > new_rank`, leave labels untouched. Otherwise, apply the current replace-all logic.

## Why

The cascade escalation path (`escalate_issue_tier()` in `.agents/scripts/worker-lifecycle-common.sh:814`) writes the escalated tier **only to GitHub labels** — it does not modify the brief file or the TODO.md tag. The enrichment path (`cmd_enrich` → `_enrich_apply_labels` → `_apply_tier_label_replace` in `issue-sync-helper.sh:132`) reads the brief's `**Selected tier:**` line as the source of truth and unconditionally removes any non-matching `tier:*` label before re-applying the brief tier.

Result: every enrichment run after a cascade escalation reverts the escalation. Direct evidence on GH#19038:

```
00:38:49  marcusquinn           -tier:standard  +tier:thinking   (escalate_issue_tier)
00:44:15  github-actions[bot]   -tier:thinking
00:44:16  github-actions[bot]   +tier:standard                   (_apply_tier_label_replace)
01:20:20  pulse dispatches at tier:standard again → same worker_failed
```

Without the ratchet the cascade escalation is useless — the only way it would survive is if the brief were edited, which would require a separate commit path and would race with other edits. The ratchet is local to one function and requires no cross-file coordination.

## Tier

### Tier checklist

- [x] 2 or fewer files to modify (issue-sync-helper.sh + new test file)
- [x] Every target file under 500 lines **false** — issue-sync-helper.sh is 1713 lines
- [x] Exact oldString/newString for every edit (provided below)
- [x] No judgment or design decisions (the rule is specified precisely)
- [x] No error handling or fallback logic to design
- [x] No cross-package or cross-module changes
- [x] Estimate 1h or less
- [x] 4 or fewer acceptance criteria

File size exceeds 500 lines so tier:simple is disqualified. This is a tier:standard bug fix with precise replacement content. A standard worker following the provided oldString/newString would handle it cleanly, but I am implementing interactively.

**Selected tier:** `tier:standard`

**Tier rationale:** Single-function change in a 1700-line file with one new test harness. Bug is understood, semantics are specified, replacement blocks are inline. Not thinking-tier (no design work), not simple-tier (target file size > 500 lines).

## PR Conventions

Leaf task. PR body will use `Resolves #NNN`.

## How (Approach)

### Files to Modify

- EDIT: `.agents/scripts/issue-sync-helper.sh` — add `_tier_rank` helper; gate `_apply_tier_label_replace` on the ratchet rule.
- NEW: `.agents/scripts/tests/test-tier-label-ratchet.sh` — unit tests for the rank helper + one integration-style test that stubs `gh` and asserts the replace function no-ops when the existing label outranks the incoming.

### Implementation Steps

**Step 1 — add `_tier_rank` helper.** Insert above `_apply_tier_label_replace` (currently at line 118 in `issue-sync-helper.sh`). This is the canonical rank function used by the ratchet. Matches `_resolve_worker_tier` in `pulse-dispatch-core.sh` semantically (`thinking > standard > simple`).

```bash
# _tier_rank: emit numeric rank for a tier label. Higher rank = more capable model.
# Used by _apply_tier_label_replace to implement the ratchet rule: a cascade-
# escalated tier (written directly to labels by escalate_issue_tier in
# worker-lifecycle-common.sh) must not be downgraded by enrichment, even though
# the brief file still declares the pre-escalation tier.
#
# Arguments:
#   $1 - tier label (e.g., tier:simple, tier:standard, tier:thinking)
# Prints:
#   0/1/2 for known tiers, -1 for unknown/empty
_tier_rank() {
	case "${1:-}" in
	tier:simple) printf '0' ;;
	tier:standard) printf '1' ;;
	tier:thinking) printf '2' ;;
	*) printf -- '-1' ;;
	esac
}
```

**Step 2 — gate `_apply_tier_label_replace` on the ratchet.** Directly after the existing `existing_tiers=$(gh issue view ...)` block (around line 144-145), compute the max rank of any `tier:*` label currently present. If `max_existing_rank > new_rank`, return 0 with an info log. The rest of the function's logic stays as-is.

Exact oldString (currently lines 143-163 of `issue-sync-helper.sh`):

```bash
	local existing_tiers
	existing_tiers=$(gh issue view "$num" --repo "$repo" --json labels \
		--jq '[.labels[].name | select(startswith("tier:"))] | join(",")' 2>/dev/null || echo "")

	# Remove any existing tier labels that don't match the new one.
	if [[ -n "$existing_tiers" ]]; then
		local -a remove_args=()
		local _saved_ifs="$IFS"
		IFS=','
		local old
		for old in $existing_tiers; do
			[[ -z "$old" ]] && continue
			[[ "$old" == "$new_tier" ]] && continue
			remove_args+=("--remove-label" "$old")
		done
		IFS="$_saved_ifs"
		if [[ ${#remove_args[@]} -gt 0 ]]; then
			gh issue edit "$num" --repo "$repo" "${remove_args[@]}" 2>/dev/null ||
				print_warning "tier replace: failed to remove stale tier label(s) from #$num in $repo"
		fi
	fi
```

newString:

```bash
	local existing_tiers
	existing_tiers=$(gh issue view "$num" --repo "$repo" --json labels \
		--jq '[.labels[].name | select(startswith("tier:"))] | join(",")' 2>/dev/null || echo "")

	# Ratchet rule (t2111): if ANY existing tier label outranks the incoming
	# tier, this is a cascade-escalated issue (escalate_issue_tier raised it
	# above the brief's declared tier in worker-lifecycle-common.sh). The
	# brief is a FLOOR, the cascade is a CEILING, and the ceiling wins.
	# Without this guard, scheduled enrichment silently reverts every
	# escalation ~5 minutes after it fires, producing a tier:standard ->
	# tier:thinking -> tier:standard flip-flop that wastes dispatch cycles
	# on the same worker failure. See GH#19038 label event history.
	local new_rank
	new_rank=$(_tier_rank "$new_tier")
	if [[ -n "$existing_tiers" ]]; then
		local _rmax=-1
		local _saved_ifs="$IFS"
		IFS=','
		local _t _r
		for _t in $existing_tiers; do
			[[ -z "$_t" ]] && continue
			_r=$(_tier_rank "$_t")
			((_r > _rmax)) && _rmax=$_r
		done
		IFS="$_saved_ifs"
		if ((_rmax > new_rank)); then
			print_info "tier replace: preserving escalated tier on #$num (existing rank $_rmax > incoming rank $new_rank for $new_tier) — ratchet rule, see t2111"
			return 0
		fi
	fi

	# Remove any existing tier labels that don't match the new one.
	if [[ -n "$existing_tiers" ]]; then
		local -a remove_args=()
		local _saved_ifs="$IFS"
		IFS=','
		local old
		for old in $existing_tiers; do
			[[ -z "$old" ]] && continue
			[[ "$old" == "$new_tier" ]] && continue
			remove_args+=("--remove-label" "$old")
		done
		IFS="$_saved_ifs"
		if [[ ${#remove_args[@]} -gt 0 ]]; then
			gh issue edit "$num" --repo "$repo" "${remove_args[@]}" 2>/dev/null ||
				print_warning "tier replace: failed to remove stale tier label(s) from #$num in $repo"
		fi
	fi
```

**Step 3 — test harness.** Create `.agents/scripts/tests/test-tier-label-ratchet.sh` modeled on `test-tier-label-dedup.sh`. The harness:

1. Sources `issue-sync-helper.sh` under a test mode env var OR extracts `_tier_rank` via eval — simpler path: source the file with `_GH_STUB=1` to skip the heavy init, then call `_tier_rank` directly for rank tests.
2. Stubs `gh` on `PATH` (writes a shim that echoes canned label JSON for `gh issue view` and writes to a trace file for `gh issue edit`).
3. Calls `_apply_tier_label_replace test/repo 1 tier:standard` against a stubbed issue carrying `tier:thinking` and asserts the trace file contains NO `--remove-label tier:thinking` AND the function returned 0.
4. Repeats with an issue carrying `tier:simple` and asserts the trace file DOES contain `--remove-label tier:simple`.
5. Repeats with mixed `tier:simple,tier:thinking` + incoming `tier:standard` and asserts no-op (max rank 2 > 1).

### Verification

```bash
cd /Users/marcusquinn/Git/aidevops-feature-t2111-tier-ratchet
shellcheck .agents/scripts/issue-sync-helper.sh
bash .agents/scripts/tests/test-tier-label-ratchet.sh
bash .agents/scripts/tests/test-tier-label-dedup.sh   # regression
bash .agents/scripts/tests/test-issue-sync-tier-extraction.sh   # regression
```

All must exit 0 with no shellcheck diagnostics on the modified file.

## Acceptance Criteria

1. `_apply_tier_label_replace` preserves `tier:thinking` when incoming is `tier:standard` (the exact GH#19038 flip-flop case).
2. `_apply_tier_label_replace` preserves `tier:standard` when incoming is `tier:simple` (symmetric case).
3. `_apply_tier_label_replace` still upgrades `tier:simple` to `tier:standard` (pre-existing behaviour — must not regress).
4. New test harness `test-tier-label-ratchet.sh` passes and exercises all three cases above.
5. `test-tier-label-dedup.sh` still passes (regression for `_resolve_worker_tier`, which is unchanged but in the same subsystem).
6. `shellcheck` is clean on the modified `issue-sync-helper.sh`.
