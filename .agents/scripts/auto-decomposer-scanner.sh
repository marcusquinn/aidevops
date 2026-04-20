#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# auto-decomposer-scanner.sh — Dispatch workers to decompose stale parent-tasks
#
# Finds `parent-task` labeled issues where the
# `<!-- parent-needs-decomposition -->` nudge has been sitting unanswered
# for ≥SCANNER_NUDGE_AGE_HOURS (default 24h). For each such parent, files
# a worker-ready `tier:thinking` issue asking the dispatched worker to
# read the parent, identify phases/components, and create child
# implementation issues.
#
# Why this exists (t2442):
#   Before t2442, `pulse-issue-reconcile.sh` would detect a parent-task
#   with zero children and post an advisory `<!-- parent-needs-decomposition -->`
#   nudge comment — then do nothing. Because `parent-task` blocks
#   dispatch unconditionally (`dispatch-dedup-helper.sh` returns
#   `PARENT_TASK_BLOCKED`), the issue entered a dispatch black hole: no
#   worker could pick it up, no automation would decompose it, and the
#   nudge comment was advisory-only. Six open backlog issues in
#   marcusquinn/aidevops sat in this state by the time t2442 was filed.
#
#   This scanner closes the loop. After 24h of advisory silence, it
#   files a separate `auto-dispatch` issue that the pulse can actually
#   dispatch a worker against — and that worker, NOT the parent's own
#   (blocked) dispatch slot, performs the decomposition.
#
# Idempotency:
#   Dedupes via title match (`Decompose parent-task #NNNN`) AND the
#   `source:auto-decomposer` label. Re-runs are no-ops. Generator
#   marker in body (`<!-- aidevops:generator=auto-decompose parent=NNNN -->`)
#   is available to pre-dispatch validators that want to re-verify the
#   parent still qualifies before spawning a worker.
#
# Worker-is-triager philosophy (GH#18538):
#   The generated issue body includes explicit Outcome A/B/C instructions
#   so the dispatched worker verifies the premise before burning tokens
#   on a decomposition that may already be done, obsolete, or
#   misclassified. Common Outcome A cases: parent already has a
#   `## Children` section posted between scan and dispatch; parent was
#   relabelled; parent is actually a single-unit task the maintainer
#   forgot to remove `parent-task` from.
#
# Usage:
#   auto-decomposer-scanner.sh {scan|dry-run|help} [REPO]
#
# Env:
#   SCANNER_NUDGE_AGE_HOURS       (default 24)  — minimum nudge age in hours
#   SCANNER_MAX_ISSUES            (default 3)   — cap per-repo decompose issues per run
#   SCANNER_PARENT_LIST_LIMIT     (default 100) — max parent-task issues to list
#
# t2442: https://github.com/marcusquinn/aidevops/issues/20139

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
# shellcheck source=shared-constants.sh
[[ -f "${SCRIPT_DIR}/shared-constants.sh" ]] && source "${SCRIPT_DIR}/shared-constants.sh"

SCANNER_NUDGE_AGE_HOURS="${SCANNER_NUDGE_AGE_HOURS:-24}"
SCANNER_MAX_ISSUES="${SCANNER_MAX_ISSUES:-3}"
SCANNER_PARENT_LIST_LIMIT="${SCANNER_PARENT_LIST_LIMIT:-100}"
SCANNER_LABEL="source:auto-decomposer"

log() { echo "[auto-decomposer] $*" >&2; }

# Compute the age in hours of the first `<!-- parent-needs-decomposition -->`
# nudge comment on a parent issue. Prints the age on stdout (empty string
# if no nudge found, or on date-parse failure). Uses GNU date on Linux
# and BSD date on macOS via feature detection.
#
# Exit codes:
#   0 — always (caller inspects the printed value)
_nudge_age_hours() {
	local repo="$1"
	local issue_num="$2"
	local created_at
	created_at=$(gh issue view "$issue_num" --repo "$repo" --json comments \
		--jq '[.comments[] | select(.body | contains("<!-- parent-needs-decomposition -->")) | .createdAt] | first // ""' \
		2>/dev/null || echo "")
	if [[ -z "$created_at" ]]; then
		printf ''
		return 0
	fi
	local created_epoch=""
	if date --version >/dev/null 2>&1; then
		created_epoch=$(date -d "$created_at" +%s 2>/dev/null || echo "")
	else
		created_epoch=$(date -j -u -f "%Y-%m-%dT%H:%M:%SZ" "$created_at" +%s 2>/dev/null || echo "")
	fi
	if [[ -z "$created_epoch" ]]; then
		log "parent #${issue_num}: cannot parse nudge timestamp '${created_at}'"
		printf ''
		return 0
	fi
	local now_epoch
	now_epoch=$(date +%s)
	printf '%s' "$(((now_epoch - created_epoch) / 3600))"
	return 0
}

# Return 0 if a decompose issue already exists for this parent (any
# state — open, closed, merged, superseded). We dedupe across all states
# so that a closed "premise falsified" Outcome A never triggers another
# dispatch; re-escalation requires the maintainer to delete the closed
# issue.
_decompose_issue_exists() {
	local repo="$1"
	local parent_num="$2"
	local title_prefix="Decompose parent-task #${parent_num}"
	# Filter by exact title prefix via jq rather than `in:title` substring
	# search. `in:title` matches substrings — a title like "Decompose parent-
	# task #12345 context" would false-positive-hit when looking for #1234.
	# We list all issues carrying the dedup label (bounded — one per parent)
	# and filter client-side for an exact prefix match. --paginate keeps the
	# filter correct once the scanner has been running long enough that the
	# dedup-labelled set exceeds one page.
	local count
	count=$(gh issue list --repo "$repo" --label "$SCANNER_LABEL" \
		--state all --limit 1000 \
		--json title \
		--jq "[.[] | select(.title | startswith(\"${title_prefix}\"))] | length" \
		2>/dev/null || echo "0")
	[[ "$count" =~ ^[1-9][0-9]*$ ]]
}

# Render the worker-ready decompose issue body. The body includes 5 of
# the 7 t2417 heading signals (What / Why / How / Acceptance / Session
# Origin) so the pre-flight brief-readiness check treats it as worker-
# ready and skips the separate brief file. Generator marker is inline
# so pre-dispatch validators can reverify the premise without parsing
# the title.
_build_decompose_body() {
	local repo="$1"
	local parent_num="$2"
	local parent_title="$3"
	cat <<MD
<!-- aidevops:generator=auto-decompose parent=${parent_num} -->

## What

Decompose parent-task [#${parent_num}](https://github.com/${repo}/issues/${parent_num}) — _${parent_title}_ — into child implementation issues.

## Why

Parent-task #${parent_num} has carried the \`parent-task\` label for
≥${SCANNER_NUDGE_AGE_HOURS}h since \`pulse-issue-reconcile.sh\` posted its
\`<!-- parent-needs-decomposition -->\` nudge. Without child issues the
parent is a dispatch black hole: the \`parent-task\` label blocks
dispatch unconditionally in \`dispatch-dedup-helper.sh\` (\`PARENT_TASK_BLOCKED\`),
but the nudge comment is advisory-only — no automation actually
decomposes the parent.

This issue closes that loop. Implementing it clears the block on
#${parent_num} by replacing it with tracked children.

## How

1. **Read the parent issue** at https://github.com/${repo}/issues/${parent_num}
   and identify logical phases, components, or sub-tasks. Look for
   explicit \`## Phase\` sections, bullet lists of work items, or
   natural seams in the narrative.
2. **For each child:** claim a fresh task ID via \`claim-task-id.sh\`.
   Include \`ref:GH#${parent_num}\` in the TODO entry so the hierarchy
   is traceable. Use \`#auto-dispatch\` unless the child genuinely
   needs credentials or further decomposition of its own.
3. **Edit parent #${parent_num}'s body** to add a \`## Children\` section
   listing each child as \`- #<NNNN> — <short description>\`. This
   lets \`reconcile_completed_parent_tasks\` detect completion and
   close the parent automatically once all children merge.
4. **If the parent is genuinely single-unit** (cannot be split, or its
   scope has changed so it no longer needs a parent), close THIS
   issue with an Outcome A rationale comment explaining why, and
   remove the \`parent-task\` label from #${parent_num} so it can
   dispatch normally.

## Acceptance

- Parent #${parent_num} has a \`## Children\` section listing ≥2 children, OR
- Parent #${parent_num} is closed / relabelled with a rationale, OR
- THIS issue is closed with an Outcome A rationale (parent should not have been a parent).

## Session Origin

Auto-generated by \`.agents/scripts/auto-decomposer-scanner.sh\` (t2442).
Dispatched after parent #${parent_num}'s \`<!-- parent-needs-decomposition -->\`
nudge aged ≥${SCANNER_NUDGE_AGE_HOURS}h without a human response.

---

### You are the triager (worker-is-triager rule)

This issue is auto-created. **Verify the premise before acting** — the
parent may have been decomposed by another session between scan and
dispatch. Read the CURRENT state of #${parent_num} first, not the state
that existed when this issue was filed.

- **Outcome A — premise falsified → close THIS issue.** If #${parent_num}
  now has a \`## Children\` section, linked child PRs/issues with
  \`Resolves #${parent_num}\` / \`Ref #${parent_num}\` / \`For #${parent_num}\`,
  explicit \`## Phase N\` refs, or has been closed/relabelled,
  close THIS issue with the counter-evidence. No PR needed.
- **Outcome B — premise correct → implement.** Follow the \`## How\`
  steps above. Open any code PRs with \`Ref #${parent_num}\` or
  \`For #${parent_num}\` (parent stays open until children merge, per
  the t2046 parent-task PR keyword rule). For THIS follow-up issue
  itself, use \`Resolves #<this-issue-number>\` so the merge pass
  closes it cleanly.
- **Outcome C — genuine judgment call.** Only if the decomposition
  requires an architectural / policy / breaking-change decision you
  cannot resolve autonomously: post a decision comment with
  **Premise check**, **Analysis**, **Recommended path**, and
  **Specific question**, then apply \`needs-maintainer-review\`.
  Ambiguity about scope or style is NOT Outcome C.
MD
	return 0
}

# Create the decompose issue via gh_create_issue. Honours dry-run by
# logging intent without side effects.
_create_decompose_issue() {
	local repo="$1"
	local parent_num="$2"
	local parent_title="$3"
	local dry_run="$4"
	local title="Decompose parent-task #${parent_num}: ${parent_title}"
	local body
	body=$(_build_decompose_body "$repo" "$parent_num" "$parent_title")

	if [[ "$dry_run" == "true" ]]; then
		log "[DRY-RUN] Would create: ${title}"
		log "[DRY-RUN] Body length: ${#body} chars"
		return 0
	fi

	local sig_helper="${SCRIPT_DIR}/gh-signature-helper.sh"
	local sig=""
	[[ -x "$sig_helper" ]] && sig=$("$sig_helper" footer 2>/dev/null || echo "")

	# Ensure the dedup label exists (idempotent). --force keeps colour /
	# description in sync with the scanner's source of truth.
	gh label create "$SCANNER_LABEL" --repo "$repo" \
		--description "Auto-created by auto-decomposer-scanner.sh (t2442)" \
		--color "C2E0C6" --force >/dev/null 2>&1 || true

	# GH#18670 (Fix 7) parity: hardcode origin:worker as defence in depth
	# against pulse-wrapper.sh missing export of AIDEVOPS_HEADLESS=true
	# or against manual invocation from a dev shell.
	gh_create_issue --repo "$repo" --title "$title" \
		--label "auto-dispatch,tier:thinking,${SCANNER_LABEL},origin:worker" \
		--body "${body}${sig}"
	return 0
}

do_scan() {
	local repo="$1"
	local dry_run="$2"
	log "Scanning ${repo} for stale parent-tasks (nudge ≥${SCANNER_NUDGE_AGE_HOURS}h)"

	local parents_json
	parents_json=$(gh issue list --repo "$repo" --label "parent-task" \
		--state open --limit "$SCANNER_PARENT_LIST_LIMIT" \
		--json number,title 2>/dev/null || echo "[]")
	if [[ "$parents_json" == "[]" ]]; then
		log "No open parent-task issues in ${repo}"
		return 0
	fi

	local issues_created=0 total_seen=0 skipped_no_nudge=0 skipped_too_young=0 skipped_existing=0
	while IFS=$'\t' read -r parent_num parent_title; do
		[[ -z "$parent_num" ]] && continue
		total_seen=$((total_seen + 1))
		if [[ "$issues_created" -ge "$SCANNER_MAX_ISSUES" ]]; then
			log "Max decompose issues per run reached (${SCANNER_MAX_ISSUES})"
			break
		fi

		if _decompose_issue_exists "$repo" "$parent_num"; then
			log "parent #${parent_num}: decompose issue already exists, skip"
			skipped_existing=$((skipped_existing + 1))
			continue
		fi

		local hours
		hours=$(_nudge_age_hours "$repo" "$parent_num")
		if [[ -z "$hours" ]]; then
			log "parent #${parent_num}: no decomposition nudge yet, skip"
			skipped_no_nudge=$((skipped_no_nudge + 1))
			continue
		fi
		if [[ "$hours" -lt "$SCANNER_NUDGE_AGE_HOURS" ]]; then
			log "parent #${parent_num}: nudge ${hours}h old (threshold ${SCANNER_NUDGE_AGE_HOURS}h), skip"
			skipped_too_young=$((skipped_too_young + 1))
			continue
		fi

		log "parent #${parent_num}: nudge ${hours}h old, filing decompose issue"
		_create_decompose_issue "$repo" "$parent_num" "$parent_title" "$dry_run"
		issues_created=$((issues_created + 1))
	done < <(printf '%s' "$parents_json" | jq -r '.[] | "\(.number)\t\(.title)"')

	log "Scan done. Parents seen: ${total_seen}, created: ${issues_created}, skipped(existing): ${skipped_existing}, skipped(no-nudge): ${skipped_no_nudge}, skipped(too-young): ${skipped_too_young}"
	return 0
}

main() {
	local command="${1:-}"
	local repo="${2:-}"
	if [[ -z "$command" ]]; then
		echo "Usage: $(basename "$0") {scan|dry-run|help} [REPO]" >&2
		return 2
	fi
	if [[ -z "$repo" ]] && [[ "$command" != "help" && "$command" != "-h" && "$command" != "--help" ]]; then
		repo=$(gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null || echo "")
		if [[ -z "$repo" ]]; then
			echo "ERROR: Cannot determine repo (not in a gh-tracked checkout and no REPO arg)" >&2
			return 1
		fi
	fi
	case "$command" in
	scan) do_scan "$repo" "false" ;;
	dry-run) do_scan "$repo" "true" ;;
	-h | --help | help)
		cat <<EOF
Usage: $(basename "$0") {scan|dry-run|help} [REPO]

  scan      Scan open parent-task issues; file worker-ready decompose
            issues for parents whose nudge is ≥SCANNER_NUDGE_AGE_HOURS
            old. Dedupes via title + source:auto-decomposer label.
  dry-run   Same as scan but logs what would be created.
  help      This message.

Env vars:
  SCANNER_NUDGE_AGE_HOURS    (default 24)   Minimum nudge age in hours
  SCANNER_MAX_ISSUES         (default 3)    Cap per-repo decompose issues per run
  SCANNER_PARENT_LIST_LIMIT  (default 100)  Max parent-task issues to list

t2442: closes the parent-task dispatch black hole by dispatching a
worker to do the decomposition 24h after the advisory nudge is ignored.
EOF
		;;
	*)
		echo "ERROR: Unknown command '$command'" >&2
		return 2
		;;
	esac
	return 0
}

# Source guard: only run main() when executed as a script, not when
# sourced by the test harness.
(return 0 2>/dev/null) || main "$@"
