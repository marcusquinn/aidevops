#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# tier-simple-body-shape-helper.sh — Auto-downgrade mis-tiered tier:simple
# issues to tier:standard before worker dispatch (t2389, GH#19929).
#
# Runs between _ensure_issue_body_has_brief and _run_predispatch_validator
# in pulse-dispatch-core.sh::dispatch_with_dedup. Only activates for issues
# carrying the tier:simple label. Parses the body for 4 high-precision
# disqualifiers (a subset of the 9 in reference/task-taxonomy.md) and, on
# any hit, swaps tier:simple → tier:standard + posts a feedback comment.
#
# Why a subset: the other 5 disqualifiers (skeleton code, conditional
# logic, error handling, cross-package changes, large-file + no verbatim)
# require fuzzier heuristics that risk false positives. High-precision
# only to avoid incorrectly downgrading correctly-tiered briefs.
#
# Non-blocking by design: always exits 0 regardless of outcome. The worker
# is always dispatched — at the correct tier if a disqualifier was found,
# at tier:simple otherwise. No issue is ever closed by this helper.
#
# Exit codes (check subcommand):
#   0  — always (non-blocking)
#
# Usage:
#   tier-simple-body-shape-helper.sh check <issue-number> <slug>
#   tier-simple-body-shape-helper.sh help
#
# Bypass:
#   AIDEVOPS_SKIP_TIER_VALIDATOR=1 — exit 0 immediately (with log)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)" || exit 1

# shellcheck source=/dev/null
source "${SCRIPT_DIR}/shared-constants.sh"

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------
_log() {
	local level="$1"
	shift
	printf '[tier-simple-validator] %s: %s\n' "$level" "$*" >&2
	return 0
}

# ---------------------------------------------------------------------------
# Disqualifier 1: >2 files in a "Files to modify" or "How" section.
#
# Counts two signals:
#   a) Lines matching NEW: or EDIT: prefix (the brief-template convention)
#   b) Bullet points containing an explicit file path with a known source
#      extension, but ONLY when they appear under ## Files to modify / ## How
#
# Global side-effect on hit: sets DISQUALIFIER_REASON + DISQUALIFIER_EVIDENCE.
# Returns 0 on pass (<= 2 files), 10 on fail (> 2 files).
# ---------------------------------------------------------------------------
_check_file_count() {
	local body="$1"

	# NEW:/EDIT: prefix matches (brief-template convention)
	local ne_count
	ne_count=$(printf '%s\n' "$body" | grep -cE '^[[:space:]]*-?[[:space:]]*(NEW|EDIT):' || true)
	ne_count=${ne_count:-0}

	# Explicit file-path bullets inside ## Files to modify / ## How sections
	# (not prose mentions elsewhere in the body).
	local section_files
	section_files=$(printf '%s\n' "$body" | awk '
		BEGIN { in_section = 0 }
		/^##[[:space:]]+(Files[[:space:]]+to[[:space:]]+modify|Files[[:space:]]+to[[:space:]]+Modify|How)[[:space:]]*$/ {
			in_section = 1; next
		}
		in_section && /^##[[:space:]]/ { exit }
		in_section { print }
	' | grep -cE '\.(sh|py|md|ts|tsx|js|jsx|yml|yaml|json|toml|go|rs|php|rb|css|html)[[:space:]:`)]' || true)
	section_files=${section_files:-0}

	# Take the max of the two signals — they may overlap, but a high count
	# in either one alone is enough to disqualify.
	local count="$ne_count"
	if [[ "$section_files" -gt "$count" ]]; then
		count="$section_files"
	fi

	if [[ "$count" -gt 2 ]]; then
		DISQUALIFIER_REASON="file count > 2 (found ${count})"
		DISQUALIFIER_EVIDENCE="Files to modify / How section has ${count} file references (NEW:/EDIT: count=${ne_count}, section-path count=${section_files}). tier:simple requires <=2 files."
		return 10
	fi
	return 0
}

# ---------------------------------------------------------------------------
# Disqualifier 2: estimate > 1h.
#
# Parses ~Nh, ~Nm, ~Nd tokens from the body. Converts to minutes. Fails on
# > 60 minutes. Multiple estimates take the max.
#
# Only looks at tokens inside the body — not in signature footer or
# automated markers.
# ---------------------------------------------------------------------------
_check_estimate() {
	local body="$1"

	# Strip the signature footer block (anything after <!-- aidevops:sig -->)
	# to avoid picking up session-time tokens from the footer.
	local cleaned
	cleaned=$(printf '%s\n' "$body" | awk '
		/<!-- aidevops:sig -->/ { exit }
		{ print }
	')

	local max_minutes=0
	local tokens
	tokens=$(printf '%s\n' "$cleaned" | grep -oE '~[0-9]+[hmd]' || true)

	while IFS= read -r tok; do
		[[ -n "$tok" ]] || continue
		local n unit
		n=$(printf '%s' "$tok" | grep -oE '[0-9]+' | head -1)
		unit=$(printf '%s' "$tok" | grep -oE '[hmd]$')
		[[ -n "$n" && -n "$unit" ]] || continue

		local minutes=0
		case "$unit" in
			m) minutes="$n" ;;
			h) minutes=$((n * 60)) ;;
			d) minutes=$((n * 60 * 8)) ;;  # 8h workday
		esac

		if [[ "$minutes" -gt "$max_minutes" ]]; then
			max_minutes="$minutes"
		fi
	done <<<"$tokens"

	if [[ "$max_minutes" -gt 60 ]]; then
		DISQUALIFIER_REASON="estimate > 1h (max token translates to ${max_minutes} minutes)"
		DISQUALIFIER_EVIDENCE="Body contains a ~Nh/Nd estimate token that resolves to ${max_minutes} minutes. tier:simple requires <=60 minutes."
		return 10
	fi
	return 0
}

# ---------------------------------------------------------------------------
# Disqualifier 3: >4 acceptance criteria checkboxes.
#
# Counts - [ ] and - [x] lines inside ## Acceptance / ## Acceptance criteria
# / ## Acceptance Criteria sections. Checkboxes elsewhere (e.g. tier
# checklist, rollout plan) don't count.
# ---------------------------------------------------------------------------
_check_acceptance_count() {
	local body="$1"

	local count
	count=$(printf '%s\n' "$body" | awk '
		BEGIN { in_section = 0 }
		/^##[[:space:]]+Acceptance([[:space:]]+[Cc]riteria)?[[:space:]]*$/ {
			in_section = 1; next
		}
		in_section && /^##[[:space:]]/ { exit }
		in_section { print }
	' | grep -cE '^[[:space:]]*-[[:space:]]+\[[x[:space:]]\]' || true)
	count=${count:-0}

	if [[ "$count" -gt 4 ]]; then
		DISQUALIFIER_REASON="acceptance criteria > 4 (found ${count})"
		DISQUALIFIER_EVIDENCE="Body has ${count} acceptance criteria checkboxes in the ## Acceptance section. tier:simple requires <=4 criteria."
		return 10
	fi
	return 0
}

# ---------------------------------------------------------------------------
# Disqualifier 4: judgment keywords present in the brief body.
#
# Case-insensitive match against a curated keyword set from the taxonomy.
# These tokens signal reasoning work ("design a fallback", "coordinate
# cross-package changes") that tier:simple (haiku) cannot do reliably.
#
# Skips:
#   - Signature footer (session metadata may include any word)
#   - Provenance markers
#   - The tier checklist section in the brief (may quote the keywords as
#     part of explaining what triggers a disqualifier)
# ---------------------------------------------------------------------------
_check_judgment_keywords() {
	local body="$1"

	# Strip signature footer, provenance, and tier checklist sections.
	local cleaned
	cleaned=$(printf '%s\n' "$body" | awk '
		BEGIN { in_skip = 0 }
		/<!-- aidevops:sig -->/ { exit }
		/<!-- provenance:start -->/ { in_skip = 1; next }
		/<!-- provenance:end -->/ { in_skip = 0; next }
		/^##[[:space:]]+Tier[[:space:]]+checklist([[:space:]].*)?$/ { in_skip = 1; next }
		in_skip && /^##[[:space:]]/ { in_skip = 0 }
		!in_skip { print }
	')

	# Keyword set from task-taxonomy.md "tier:simple Disqualifiers" row 7.
	# Tab-delimited pairs: "pattern<TAB>description" so the evidence line
	# reads naturally.
	local keywords=(
		'graceful degradation'
		'fallback'
		'retry logic'
		'conditional logic'
		'coordinate'
		'design a'
		'design the'
		'architecture'
		'trade-off'
		'strategy'
	)

	local hit=""
	local kw
	for kw in "${keywords[@]}"; do
		if printf '%s\n' "$cleaned" | grep -qiE "(^|[^a-zA-Z])${kw}([^a-zA-Z]|$)"; then
			hit="$kw"
			break
		fi
	done

	if [[ -n "$hit" ]]; then
		DISQUALIFIER_REASON="judgment keyword present: \"${hit}\""
		DISQUALIFIER_EVIDENCE="Body contains the judgment keyword \"${hit}\" outside skipped sections (footer/provenance/tier-checklist). Keywords like this signal reasoning work, not transcription."
		return 10
	fi
	return 0
}

# ---------------------------------------------------------------------------
# Apply the downgrade: swap tier:simple → tier:standard + post feedback.
#
# Idempotent via the <!-- tier-simple-auto-downgrade --> marker. If the
# marker is already present in any comment, skip the comment post but
# still ensure the label swap is applied (in case it was reverted).
#
# Fails open: if the API call fails, dispatch still proceeds — the worker
# will either succeed at tier:simple (and the body-shape check was a false
# positive) or fail and cascade up normally.
# ---------------------------------------------------------------------------
_apply_downgrade() {
	local slug="$1"
	local issue_num="$2"
	local reason="$3"
	local evidence="$4"

	local marker='<!-- tier-simple-auto-downgrade -->'

	# Swap the label first. If this fails, skip the comment (no point
	# telling the maintainer we downgraded if we didn't actually downgrade).
	if ! gh issue edit "$issue_num" --repo "$slug" \
		--remove-label "tier:simple" --add-label "tier:standard" \
		>/dev/null 2>&1; then
		_log "WARN" "failed to swap tier labels on #${issue_num} in ${slug} — skipping feedback comment"
		return 0
	fi

	_log "INFO" "downgraded #${issue_num} in ${slug}: tier:simple → tier:standard (${reason})"

	# Idempotency check for the feedback comment.
	local existing=""
	existing=$(gh api "repos/${slug}/issues/${issue_num}/comments" \
		--jq "[.[] | select(.body | contains(\"${marker}\"))] | length" \
		2>/dev/null) || existing=""
	if [[ "$existing" =~ ^[1-9][0-9]*$ ]]; then
		_log "INFO" "feedback comment already present on #${issue_num} — skipping post"
		return 0
	fi

	local comment_body="${marker}
## Tier Auto-Downgrade: simple → standard

Pre-dispatch body-shape check detected a \`tier:simple\` disqualifier. Swapped \`tier:simple\` → \`tier:standard\` before worker dispatch.

**Disqualifier:** ${reason}

**Evidence:** ${evidence}

The worker is still dispatching — just at the appropriate tier. See \`.agents/reference/task-taxonomy.md\` \"Tier Assignment Validation\" for the full disqualifier list.

_Automated by \`tier-simple-body-shape-helper.sh\` (t2389). Posted once per issue via the \`${marker}\` marker; re-runs are no-ops._"

	gh issue comment "$issue_num" --repo "$slug" --body "$comment_body" \
		>/dev/null 2>&1 || _log "WARN" "feedback comment post failed on #${issue_num} — label swap still applied"

	return 0
}

# ---------------------------------------------------------------------------
# Main check entry point.
#
# Arguments:
#   $1 - issue number
#   $2 - repo slug (owner/repo)
#
# Returns 0 always (non-blocking by design).
# ---------------------------------------------------------------------------
cmd_check() {
	local issue_num="$1"
	local slug="$2"

	[[ "$issue_num" =~ ^[0-9]+$ ]] || {
		_log "WARN" "invalid issue number: ${issue_num}"
		return 0
	}
	[[ -n "$slug" ]] || {
		_log "WARN" "empty slug"
		return 0
	}

	# Bypass for emergency recovery.
	if [[ "${AIDEVOPS_SKIP_TIER_VALIDATOR:-0}" == "1" ]]; then
		_log "INFO" "AIDEVOPS_SKIP_TIER_VALIDATOR=1 — bypassing check for #${issue_num}"
		return 0
	fi

	# Fetch labels + body in a single round-trip.
	local issue_json
	issue_json=$(gh issue view "$issue_num" --repo "$slug" \
		--json labels,body 2>/dev/null) || {
		_log "WARN" "gh issue view failed for #${issue_num} in ${slug} — skipping check"
		return 0
	}

	# Only activate for tier:simple.
	local has_simple
	has_simple=$(printf '%s' "$issue_json" | \
		jq -r '[.labels[].name] | any(. == "tier:simple")' 2>/dev/null) || has_simple="false"
	if [[ "$has_simple" != "true" ]]; then
		return 0
	fi

	local body
	body=$(printf '%s' "$issue_json" | jq -r '.body // ""' 2>/dev/null) || body=""
	if [[ -z "$body" ]]; then
		_log "INFO" "empty body on #${issue_num} — nothing to check"
		return 0
	fi

	# Run the 4 checks. First hit wins (no need to run remaining checks
	# once a disqualifier is found — the downgrade is the same either way).
	DISQUALIFIER_REASON=""
	DISQUALIFIER_EVIDENCE=""

	local check
	for check in _check_file_count _check_estimate _check_acceptance_count _check_judgment_keywords; do
		local rc=0
		"$check" "$body" || rc=$?
		if [[ "$rc" -eq 10 ]]; then
			_apply_downgrade "$slug" "$issue_num" \
				"$DISQUALIFIER_REASON" "$DISQUALIFIER_EVIDENCE"
			return 0
		fi
	done

	_log "INFO" "#${issue_num} in ${slug}: tier:simple body shape OK (no disqualifier)"
	return 0
}

# ---------------------------------------------------------------------------
# Usage help
# ---------------------------------------------------------------------------
cmd_help() {
	cat <<'EOF'
tier-simple-body-shape-helper.sh — Auto-downgrade mis-tiered tier:simple
issues (t2389, GH#19929).

Usage:
  tier-simple-body-shape-helper.sh check <issue-number> <slug>
  tier-simple-body-shape-helper.sh help

Commands:
  check    Inspect the issue body; if tier:simple disqualifiers are
           present, swap tier:simple → tier:standard and post a
           feedback comment.
  help     Print this message.

Exit codes:
  0        Always (non-blocking by design — never stops dispatch).

Bypass:
  AIDEVOPS_SKIP_TIER_VALIDATOR=1 to exit 0 immediately without checking.

See .agents/reference/task-taxonomy.md "Tier Assignment Validation"
for the full disqualifier list. This helper enforces the 4 high-precision
checks; the other 5 (skeleton code, conditional logic, error handling,
cross-package changes, large-file + no verbatim) require fuzzier
heuristics and are left to task-creation-time discipline.
EOF
	return 0
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
main() {
	local subcmd="${1:-help}"
	shift || true

	case "$subcmd" in
		check)
			if [[ $# -lt 2 ]]; then
				_log "ERROR" "check requires <issue-number> <slug>"
				return 2
			fi
			cmd_check "$1" "$2"
			;;
		help|--help|-h)
			cmd_help
			;;
		*)
			_log "ERROR" "unknown subcommand: ${subcmd}"
			cmd_help >&2
			return 2
			;;
	esac
}

# Allow sourcing without executing (for test harnesses).
if [[ "${BASH_SOURCE[0]:-$0}" == "${0}" ]]; then
	main "$@"
fi
