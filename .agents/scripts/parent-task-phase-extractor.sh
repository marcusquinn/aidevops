#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# parent-task-phase-extractor.sh — Deterministic phase extractor for well-formed parent-task bodies
#
# Detects and files phases from parent-task issue bodies that follow the
# well-formed phase template. Zero LLM, zero paraphrasing — pure regex +
# verbatim text extraction.
#
# Complements auto-decomposer-scanner.sh (which handles the general case via
# LLM). This scanner short-circuits for parent bodies that already contain a
# fully-written phase plan, avoiding hallucination risk on already-written
# content.
#
# Detection algorithm (all conditions must hold for EVERY phase):
#   - ^### Phase \d+: heading line
#   - At least one ^- EDIT: or ^- NEW: line in the phase section
#   - **Reference pattern:** sub-section present
#   - **Verification:** sub-section present
#   - **Acceptance:** sub-section present with ≥1 criterion bullet (^- )
#
# Fail-safe: if ANY phase is missing ANY required sub-section, the scanner
# NO-OPs entirely. All-or-nothing. Partial extraction is not performed.
#
# Dispatch guard: parents carrying no-auto-dispatch are skipped unconditionally.
#
# Usage:
#   parent-task-phase-extractor.sh check  ISSUE_NUM SLUG   — exit 0 if eligible
#   parent-task-phase-extractor.sh run    ISSUE_NUM SLUG   — detect + file + update
#   parent-task-phase-extractor.sh help                    — usage message
#
# Exit codes for run:
#   0 — fired: at least one child issue filed
#   1 — no-op: body not eligible (missing sub-sections, <2 phases, no-auto-dispatch, or error)
#
# Env:
#   PHASE_EXTRACTOR_DRY_RUN    (default 0) — 1 = log intent without side effects
#   PHASE_EXTRACTOR_MIN_PHASES (default 2) — minimum phases required for eligibility
#
# t2771: https://github.com/marcusquinn/aidevops/issues/20641
# _run_extractor body: 109 lines (9 over limit). complexity-bump-ok applied.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
# shellcheck source=shared-constants.sh
[ -f "${SCRIPT_DIR}/shared-constants.sh" ] && source "${SCRIPT_DIR}/shared-constants.sh"

PHASE_EXTRACTOR_DRY_RUN="${PHASE_EXTRACTOR_DRY_RUN:-0}"
PHASE_EXTRACTOR_MIN_PHASES="${PHASE_EXTRACTOR_MIN_PHASES:-2}"

# Generator marker for pre-dispatch-validator compatibility.
readonly PHASE_EXTRACTOR_GENERATOR_MARKER="aidevops:generator=phase-extractor"

log() { printf '[phase-extractor] %s\n' "$*" >&2; }

#######################################
# Enumerate phases from a parent issue body. For each ### Phase N: block,
# checks all required sub-sections and emits a single-line record:
#   PHASE_NUM<TAB>HEADING<TAB>STATUS
# where STATUS is "complete" or "incomplete".
#
# All detection logic runs inside awk to avoid multi-line shell variable
# handling issues. The caller reads only single-line records.
#
# Args: $1=body_content (may be multi-line)
# Output: one tab-separated line per phase
# Returns: 0 always
#######################################
_enumerate_phases_metadata() {
	local body="$1"
	[ -n "$body" ] || return 0

	printf '%s\n' "$body" | awk '
		BEGIN {
			phase_num=""; heading=""
			has_edit=0; has_ref=0; has_verify=0; has_accept=0; has_bullet=0
			in_accept=0
		}

		/^### Phase [0-9]+:/ {
			if (phase_num != "") _emit_phase()
			phase_num = $0
			sub(/^### Phase /, "", phase_num)
			sub(/:.*/, "", phase_num)
			heading = $0
			sub(/^### Phase [0-9]+:[[:space:]]*/, "", heading)
			has_edit=0; has_ref=0; has_verify=0; has_accept=0; has_bullet=0
			in_accept=0
			next
		}

		phase_num != "" {
			if ($0 ~ /^- (EDIT|NEW):/) has_edit=1
			if (index($0, "**Reference pattern:**") > 0) has_ref=1
			if (index($0, "**Verification:**") > 0) has_verify=1
			if (index($0, "**Acceptance:**") > 0) {
				has_accept=1; in_accept=1
			}
			if (in_accept && $0 ~ /^- /) has_bullet=1
			# A different bold heading ends the acceptance section
			if (in_accept && $0 ~ /^\*\*[^*]+\*\*/ && \
				index($0, "**Acceptance:**") == 0) in_accept=0
		}

		END { if (phase_num != "") _emit_phase() }

		function _emit_phase(    status) {
			status = (has_edit && has_ref && has_verify && has_accept && has_bullet) \
				? "complete" : "incomplete"
			printf "%s\t%s\t%s\n", phase_num, heading, status
		}
	'
	return 0
}

#######################################
# Extract the raw block content for a single phase (all lines from
# ^### Phase N: up to the next ^### Phase or end of body).
#
# Args: $1=body_content, $2=phase_num
# Output: block content on stdout (multi-line)
# Returns: 0 always
#######################################
_extract_phase_block() {
	local body="$1"
	local target="$2"

	printf '%s\n' "$body" | awk -v t="$target" '
		$0 ~ ("^### Phase " t ":") { found=1; print; next }
		found && /^### Phase [0-9]+:/ { exit }
		found { print }
	'
	return 0
}

#######################################
# Check whether a parent issue body is eligible for phase extraction.
# Eligibility: ≥PHASE_EXTRACTOR_MIN_PHASES phase blocks AND all complete.
#
# Args: $1=body_content
# Returns: 0 if eligible, 1 if not
#######################################
_body_is_eligible() {
	local body="$1"
	[ -n "$body" ] || return 1

	local phase_count=0
	local all_complete=1

	# Read single-line metadata records from awk — no multi-line issues.
	while IFS='	' read -r p_num _heading status; do
		[ -n "$p_num" ] || continue
		phase_count=$((phase_count + 1))
		[ "$status" = "complete" ] || all_complete=0
	done < <(_enumerate_phases_metadata "$body")

	[ "$phase_count" -ge "$PHASE_EXTRACTOR_MIN_PHASES" ] || return 1
	[ "$all_complete" -eq 1 ] || return 1
	return 0
}

#######################################
# Build the issue body for a child phase issue. Verbatim copy of the phase
# section from the parent + auto-generated ## Context block linking back.
#
# Uses "For #NNN" (NOT Closes/Resolves) per the parent-task PR keyword rule.
#
# Args: $1=parent_num, $2=parent_title, $3=phase_num, $4=phase_heading,
#       $5=phase_block, $6=repo_slug
# Output: issue body on stdout
# Returns: 0 always
#######################################
_build_child_body() {
	local parent_num="$1"
	local parent_title="$2"
	local phase_num="$3"
	local phase_heading="$4"
	local phase_block="$5"
	local repo_slug="$6"

	cat <<MD
<!-- ${PHASE_EXTRACTOR_GENERATOR_MARKER} parent=${parent_num} phase=${phase_num} -->

## What

${phase_block}

## Context

Auto-filed from parent-task [#${parent_num}](https://github.com/${repo_slug}/issues/${parent_num}) — _${parent_title}_ — via deterministic phase extraction (t2771).

Phase content is verbatim from the parent body. No LLM paraphrasing was applied.

For #${parent_num}

## Session Origin

Auto-filed by \`parent-task-phase-extractor.sh\` (t2771). Verbatim extraction from parent #${parent_num} Phase ${phase_num}.
MD
	return 0
}

#######################################
# Append a ## Children section to the parent issue body, or add new child
# lines to an existing ## Children section.
#
# Args: $1=current_body, $2=child_lines (newline-separated "- #NNN — ...")
# Output: updated body on stdout
# Returns: 0 always
#######################################
_append_children_section() {
	local body="$1"
	local child_lines="$2"
	[ -n "$child_lines" ] || { printf '%s' "$body"; return 0; }

	if printf '%s\n' "$body" | grep -qE '^## Children'; then
		# Append to existing section
		printf '%s\n' "$body" | awk -v lines="$child_lines" '
			/^## Children/ { found=1 }
			found && /^## / && !/^## Children/ {
				print lines
				found=0
			}
			{ print }
			END { if (found) print lines }
		'
	else
		# Append new ## Children section at the end
		printf '%s\n' "$body"
		printf '\n## Children\n\n%s\n' "$child_lines"
	fi
	return 0
}

#######################################
# Run the phase extractor against a parent issue. Fetches the body from
# GitHub, checks eligibility, files child issues, updates parent body.
#
# Args: $1=issue_num, $2=repo_slug
# Returns: 0 if fired (children filed), 1 if no-op
#######################################
_run_extractor() {
	local issue_num="$1"
	local repo_slug="$2"

	# Fetch parent issue body and title in a single API call
	local parent_json
	parent_json=$(gh api "repos/${repo_slug}/issues/${issue_num}" \
		--jq '{body: (.body // ""), title: (.title // ""), labels: [.labels[].name]}' \
		2>/dev/null) || parent_json=""
	if [ -z "$parent_json" ]; then
		log "#${issue_num}: failed to fetch issue, no-op"
		return 1
	fi

	local parent_body parent_title parent_labels
	parent_body=$(printf '%s' "$parent_json" | jq -r '.body // ""')
	parent_title=$(printf '%s' "$parent_json" | jq -r '.title // ""')
	parent_labels=$(printf '%s' "$parent_json" | jq -r '.labels | join(",")')

	# Dispatch guard: skip parents with no-auto-dispatch (user opt-out)
	case ",${parent_labels}," in
	*",no-auto-dispatch,"*)
		log "#${issue_num}: carries no-auto-dispatch, no-op"
		return 1
		;;
	esac

	# Eligibility check
	if ! _body_is_eligible "$parent_body"; then
		log "#${issue_num}: body not eligible (missing sub-sections or <${PHASE_EXTRACTOR_MIN_PHASES} phases)"
		return 1
	fi

	log "#${issue_num}: eligible — filing phases"

	local filed_count=0
	local child_lines=""

	# Determine tier label to inherit from parent (default tier:standard)
	local child_tier="tier:standard"
	case ",${parent_labels}," in
	*",tier:thinking,"*) child_tier="tier:thinking" ;;
	esac

	while IFS='	' read -r phase_num phase_heading _status; do
		[ -n "$phase_num" ] || continue

		# Extract full verbatim block for this phase
		local phase_block
		phase_block=$(_extract_phase_block "$parent_body" "$phase_num")

		local child_title="${parent_title}: Phase ${phase_num} — ${phase_heading}"

		if [ "$PHASE_EXTRACTOR_DRY_RUN" = "1" ]; then
			log "[DRY-RUN] Would file: ${child_title}"
			filed_count=$((filed_count + 1))
			child_lines="${child_lines}- #DRY_RUN — Phase ${phase_num}: ${phase_heading}
"
			continue
		fi

		local child_body
		child_body=$(_build_child_body \
			"$issue_num" "$parent_title" "$phase_num" "$phase_heading" \
			"$phase_block" "$repo_slug")

		# Append signature footer if helper is available
		local sig=""
		local sig_helper="${SCRIPT_DIR}/gh-signature-helper.sh"
		[ -x "$sig_helper" ] && sig=$("$sig_helper" footer 2>/dev/null || true)

		local new_issue_url
		new_issue_url=$(gh_create_issue --repo "$repo_slug" \
			--title "$child_title" \
			--label "auto-dispatch,${child_tier},origin:worker" \
			--body "${child_body}${sig}" 2>/dev/null) || new_issue_url=""

		if [ -z "$new_issue_url" ]; then
			log "#${issue_num}: failed to file Phase ${phase_num} child, aborting"
			# Partial extraction is not permitted — return 1 so caller
			# falls back to nudge path. Children already filed stay open.
			return 1
		fi

		local new_issue_num
		new_issue_num=$(printf '%s' "$new_issue_url" | grep -oE '[0-9]+$')
		log "#${issue_num}: filed Phase ${phase_num} as #${new_issue_num}: ${phase_heading}"
		filed_count=$((filed_count + 1))
		child_lines="${child_lines}- #${new_issue_num} — Phase ${phase_num}: ${phase_heading}
"
	done < <(_enumerate_phases_metadata "$parent_body")

	[ "$filed_count" -gt 0 ] || return 1

	if [ "$PHASE_EXTRACTOR_DRY_RUN" = "1" ]; then
		log "[DRY-RUN] Would update parent #${issue_num} ## Children section"
		return 0
	fi

	# Update parent body with ## Children section
	local updated_body
	local child_lines_trimmed="${child_lines%$'\n'}"
	updated_body=$(_append_children_section "$parent_body" "$child_lines_trimmed")

	gh_issue_edit_safe "$issue_num" --repo "$repo_slug" \
		--body "$updated_body" 2>/dev/null || true

	log "#${issue_num}: updated ## Children section with ${filed_count} phase(s)"
	return 0
}

#######################################
# check subcommand — exit 0 if parent is eligible, 1 if not.
# Does not file any issues.
#######################################
_cmd_check() {
	local issue_num="$1"
	local repo_slug="$2"

	local parent_body
	parent_body=$(gh api "repos/${repo_slug}/issues/${issue_num}" \
		--jq '.body // ""' 2>/dev/null) || parent_body=""
	if [ -z "$parent_body" ]; then
		log "check: failed to fetch #${issue_num}"
		return 1
	fi

	if _body_is_eligible "$parent_body"; then
		printf 'eligible\n'
		return 0
	else
		printf 'ineligible\n'
		return 1
	fi
}

main() {
	local command="${1:-}"
	case "$command" in
	run)
		local issue_num="${2:-}" repo_slug="${3:-}"
		if [ -z "$issue_num" ] || [ -z "$repo_slug" ]; then
			printf 'Usage: %s run ISSUE_NUM SLUG\n' "$(basename "$0")" >&2
			return 2
		fi
		_run_extractor "$issue_num" "$repo_slug"
		;;
	check)
		local issue_num="${2:-}" repo_slug="${3:-}"
		if [ -z "$issue_num" ] || [ -z "$repo_slug" ]; then
			printf 'Usage: %s check ISSUE_NUM SLUG\n' "$(basename "$0")" >&2
			return 2
		fi
		_cmd_check "$issue_num" "$repo_slug"
		;;
	-h | --help | help)
		cat <<EOF
Usage: $(basename "$0") {run|check|help} ISSUE_NUM SLUG

  run    ISSUE_NUM SLUG   Detect well-formed phases and file each as a child issue.
                          Exits 0 if children were filed, 1 if body was not eligible.
  check  ISSUE_NUM SLUG   Check eligibility without filing. Prints "eligible" or
                          "ineligible" and exits accordingly.
  help                    This message.

Detection criteria (all required for every phase):
  - ### Phase N: heading
  - At least one "- EDIT:" or "- NEW:" line
  - **Reference pattern:** sub-section
  - **Verification:** sub-section
  - **Acceptance:** sub-section with ≥1 bullet

If ANY phase is missing ANY sub-section, the extractor NO-OPs entirely.
Parents carrying no-auto-dispatch are always skipped.

Env vars:
  PHASE_EXTRACTOR_DRY_RUN    (default 0)  Set to 1 to log intent without side effects.
  PHASE_EXTRACTOR_MIN_PHASES (default 2)  Minimum phase count for eligibility.

t2771: https://github.com/marcusquinn/aidevops/issues/20641
EOF
		;;
	*)
		printf 'ERROR: Unknown command %q\n' "${command}" >&2
		printf 'Usage: %s {run|check|help} ISSUE_NUM SLUG\n' "$(basename "$0")" >&2
		return 2
		;;
	esac
	return 0
}

# Source guard: only run main() when executed as a script, not when sourced
# by the test harness.
(return 0 2>/dev/null) || main "$@"
