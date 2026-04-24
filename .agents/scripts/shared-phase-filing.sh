#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# =============================================================================
# Shared Phase Filing Helpers (t2740 — Gap C)
# =============================================================================
# Sequential phase auto-filing for parent-task issues. When a phase child PR
# merges and its linked child issue is closed, this module inspects the parent
# issue's ## Phases section and auto-files the next phase as a new child issue.
#
# Public API:
#   - auto_file_next_phase <child_issue> <repo_slug>
#       Finds the parent-task issue for the closed child, parses its ## Phases
#       section, and files the next unfiled phase marked [auto-fire:on-prior-merge].
#       Best-effort; failures are logged but never propagate.
#
# Feature flag:
#   AIDEVOPS_SEQUENTIAL_PHASE_AUTOFILE=0|1 (default 1, ON since t2787)
#   When 0, auto_file_next_phase is a no-op. Defaults to 1 (enabled).
#
# Phase line format in parent issue body's ## Phases section:
#   - Phase <N> - <description> [auto-fire:on-prior-merge] [#<child_issue>]
#   - Phase <N> - <description> [requires-decision]
#
# The marker [auto-fire:on-prior-merge] opts a phase into auto-filing.
# The marker [requires-decision] explicitly blocks auto-filing.
# Phases with NO marker are also skipped (conservative default).
# Phases that already have a #<child_issue> reference are skipped (dedup).
#
# Parent discovery:
#   From the closed child issue body, extracts Ref #NNN, For #NNN, or
#   Parent: #NNN back-references and checks each for parent-task label.
#
# Usage: source "${SCRIPT_DIR}/shared-phase-filing.sh"
#
# Dependencies:
#   - gh CLI
#   - shared-constants.sh (for gh_create_issue, gh_issue_comment)
#   - LOGFILE env var (for logging; falls back to /dev/null)
#
# Cross-references:
#   - t2740/GH#20476 (this feature)
#   - auto-decomposer-scanner.sh (initial decomposition; this handles N→N+1)
#   - pulse-merge.sh::_handle_post_merge_actions (call site)
#   - reference/parent-task-lifecycle.md (overall lifecycle)
# =============================================================================

# Include guard — prevent double-sourcing.
[[ -n "${_SHARED_PHASE_FILING_LOADED:-}" ]] && return 0
_SHARED_PHASE_FILING_LOADED=1

# Feature flag: default ON since Phase 1 (parser) and Phase 2 (close guard) landed (t2787).
# Override: AIDEVOPS_SEQUENTIAL_PHASE_AUTOFILE=0 to disable.
AIDEVOPS_SEQUENTIAL_PHASE_AUTOFILE="${AIDEVOPS_SEQUENTIAL_PHASE_AUTOFILE:-1}"

# Phase marker constants — single source of truth for marker string values
# used by _parse_phases_section, _phase_marker_for_line, and auto_file_next_phase.
# Keeps the codebase DRY and satisfies the repeated-string-literal quality gate.
_PHASE_MARKER_AUTO_FIRE="auto-fire"
_PHASE_MARKER_REQUIRES_DECISION="requires-decision"
_PHASE_MARKER_NONE="none"

_phase_log() {
	local _log="${LOGFILE:-/dev/null}"
	echo "[phase-filing] $*" >>"$_log"
	return 0
}

#######################################
# Find the parent-task issue for a child issue by scanning the child's
# body for back-references (Ref #NNN, For #NNN, Parent: #NNN) and
# checking each referenced issue for the parent-task label.
#
# Args: $1=child_issue, $2=repo_slug
# Output: parent issue number on stdout (empty if none found)
# Returns: 0 always
#######################################
_find_parent_task_for_child() {
	local child_issue="$1"
	local repo_slug="$2"
	local child_api="repos/${repo_slug}/issues/${child_issue}"

	# Read child issue body and title in a single API call
	local child_body child_title
	local _child_json
	_child_json=$(gh api "$child_api" \
		--jq '{body: (.body // ""), title: (.title // "")}' 2>/dev/null) || _child_json=""
	[[ -n "$_child_json" ]] || return 0
	child_body=$(printf '%s' "$_child_json" | jq -r '.body // ""')
	child_title=$(printf '%s' "$_child_json" | jq -r '.title // ""')
	[[ -n "$child_body" ]] || return 0

	# Extract issue references from body: Ref #NNN, For #NNN, Parent: #NNN
	# Also match "parent-task #NNN" and "parent #NNN" patterns
	local refs
	refs=$(printf '%s\n%s' "$child_body" "$child_title" \
		| grep -ioE '(Ref|For|Parent:?|parent-task)\s*#[0-9]+' \
		| grep -oE '[0-9]+' \
		| sort -un)
	[[ -n "$refs" ]] || return 0

	# Check each referenced issue for parent-task label
	local ref_num
	while IFS= read -r ref_num; do
		[[ -n "$ref_num" ]] || continue
		local ref_labels
		ref_labels=$(gh api "repos/${repo_slug}/issues/${ref_num}" \
			--jq '[.labels[].name] | join(",")' 2>/dev/null) || ref_labels=""
		if [[ ",${ref_labels}," == *",parent-task,"* ]]; then
			printf '%s' "$ref_num"
			return 0
		fi
	done <<< "$refs"

	return 0
}

#######################################
# Determine the marker for a phase line. Shared by list-form and bold-form
# parsers. Explicit inline markers take precedence; otherwise the fallback
# is used (caller supplies 'none' for list form, or the global-opt-in value
# for bold form so <!-- phase-auto-fire:on --> can flip narrative phases).
#
# Args: $1=line, $2=fallback_marker
# Output: marker on stdout (auto-fire|requires-decision|none|<fallback>)
# Returns: 0 always
#######################################
_phase_marker_for_line() {
	local line="$1" fallback="${2:-$_PHASE_MARKER_NONE}"
	if printf '%s' "$line" | grep -qiF '[auto-fire:on-prior-merge]'; then
		printf '%s' "$_PHASE_MARKER_AUTO_FIRE"
	elif printf '%s' "$line" | grep -qiF '[requires-decision]'; then
		printf '%s' "$_PHASE_MARKER_REQUIRES_DECISION"
	else
		printf '%s' "$fallback"
	fi
	return 0
}

#######################################
# Parse a single list-form phase line:
#   - Phase <N> - <description> [auto-fire:on-prior-merge] [#<child>]
#   - Phase <N>: <description> [requires-decision]
# Separator is `-` or `:`, flexible whitespace.
#
# Args: $1=line
# Output: tab-separated <phase_num>\t<desc>\t<marker>\t<child_ref> on stdout
#         (empty output if line doesn't match list form)
# Returns: 0 always
#######################################
_parse_phase_line_list_form() {
	local line="$1"
	printf '%s' "$line" | grep -qE '^[[:space:]]*-[[:space:]]+[Pp]hase[[:space:]]+[0-9]+' || return 0

	local phase_num description marker child_ref
	phase_num=$(printf '%s' "$line" | grep -oE '[Pp]hase[[:space:]]+[0-9]+' | grep -oE '[0-9]+')

	# Description: strip leading "- Phase N -/:", trailing child ref, then
	# trailing marker brackets (order matters — see t2755 parser notes).
	description=$(printf '%s' "$line" | sed -E \
		-e 's/^[[:space:]]*-[[:space:]]+[Pp]hase[[:space:]]+[0-9]+[[:space:]]*[-:][[:space:]]*//' \
		-e 's/[[:space:]]*#[0-9]+[[:space:]]*$//' \
		-e 's/[[:space:]]*\[(auto-fire|requires-decision)[^]]*\][[:space:]]*$//')

	marker=$(_phase_marker_for_line "$line" "$_PHASE_MARKER_NONE")

	# Child ref: trailing bare #NNN at end of line only (anchored).
	child_ref=$(printf '%s' "$line" | sed -nE 's/.*#([0-9]+)[[:space:]]*$/\1/p')

	printf '%s\t%s\t%s\t%s\n' "$phase_num" "$description" "$marker" "$child_ref"
	return 0
}

#######################################
# Parse a single bold-heading phase line:
#   **Phase <N> — <description>**
#   **Phase <N> - <description> [auto-fire:on-prior-merge]**
#   **Phase <N>: <description>** #<child>
#   **Phase <N> — <description> #<child>**
# Separators: em-dash, en-dash, hyphen, colon (any non-alnum leading char).
# Child ref may appear inside or outside the bold span.
#
# Args: $1=line, $2=global_auto_fire (fallback marker when none explicit)
# Output: tab-separated <phase_num>\t<desc>\t<marker>\t<child_ref> on stdout
#         (empty output if line doesn't match bold form)
# Returns: 0 always
#######################################
_parse_phase_line_bold_form() {
	local line="$1" global_auto_fire="${2:-none}"
	printf '%s' "$line" | grep -qE '^\*\*[Pp]hase[[:space:]]+[0-9]+' || return 0

	local phase_num description marker child_ref
	phase_num=$(printf '%s' "$line" | grep -oE '\*\*[Pp]hase[[:space:]]+[0-9]+' | grep -oE '[0-9]+')

	# Description extraction for bold form:
	#   1. Strip leading **Phase N (with trailing whitespace)
	#   2. Strip leading non-alnum separator run (em-dash/en-dash/hyphen/colon/space)
	#   3. Strip trailing child ref, closing `**`, marker brackets — in that order
	#      so #NNN appearing INSIDE the bold span (**Phase N — desc #NNN**) is
	#      matched before we lose the `**` terminator, and markers adjacent to
	#      the closing `**` (**Phase N — desc [auto-fire:on-prior-merge]**) are
	#      peeled cleanly.
	description=$(printf '%s' "$line" \
		| sed -E 's/^\*\*[Pp]hase[[:space:]]+[0-9]+[[:space:]]*//' \
		| sed -E 's/^[^[:alnum:]]*//' \
		| sed -E 's/[[:space:]]*#[0-9]+[[:space:]]*\*\*[[:space:]]*$//;s/[[:space:]]*#[0-9]+[[:space:]]*$//;s/\*\*[[:space:]]*$//;s/[[:space:]]*\[(auto-fire|requires-decision)[^]]*\][[:space:]]*$//')

	marker=$(_phase_marker_for_line "$line" "$global_auto_fire")

	# Child ref: match #NNN either outside (`** #NNN`) or inside (`#NNN**`).
	# Strip closing `**` first so the anchored tail regex finds either form.
	child_ref=$(printf '%s' "$line" \
		| sed -E 's/\*\*[[:space:]]*$//' \
		| sed -nE 's/.*#([0-9]+)[[:space:]]*$/\1/p')

	printf '%s\t%s\t%s\t%s\n' "$phase_num" "$description" "$marker" "$child_ref"
	return 0
}

#######################################
# Parse the ## Phases section from a parent issue body.
# Outputs one line per phase in tab-separated format:
#   phase_num\tdescription\tmarker\tchild_issue
#
# Supported phase-line forms (mixable within a single body):
#   List form:  - Phase <N> - <description> [marker] [#<child>]
#   Bold form:  **Phase <N> — <description> [marker]** [#<child>]
#
# marker is one of: auto-fire, requires-decision, none
# child_issue is the issue number (digits only) or empty
#
# Global opt-in: an HTML comment `<!-- phase-auto-fire:on -->` anywhere in
# the parent body flips ALL bold-form phases without explicit markers to
# `auto-fire`. List-form phases always require explicit markers (conservative
# — the legacy convention is opt-in per line).
#
# Args: $1=parent_body
# Output: phase lines on stdout
# Returns: 0 always
#######################################
_parse_phases_section() {
	local body="$1"
	[[ -n "$body" ]] || return 0

	# Global opt-in marker: flips narrative bold-form phases to auto-fire.
	local global_auto_fire="$_PHASE_MARKER_NONE"
	if printf '%s' "$body" | grep -qF '<!-- phase-auto-fire:on -->'; then
		global_auto_fire="$_PHASE_MARKER_AUTO_FIRE"
	fi

	# Extract the ## Phases section: everything between "## Phases" and the
	# next ## heading (or end of string). Use awk for multi-line extraction.
	local phases_block
	phases_block=$(printf '%s' "$body" | awk '
		/^## Phases/ { found=1; next }
		found && /^## / { exit }
		found { print }
	')
	[[ -n "$phases_block" ]] || return 0

	# Dispatch each non-empty line to the appropriate per-form parser.
	# Each helper emits a parsed row on match or nothing on no-match, so a
	# simple serial call chain is sufficient — no duplicate emission risk.
	printf '%s\n' "$phases_block" | while IFS= read -r line; do
		[[ -n "$line" ]] || continue
		_parse_phase_line_list_form "$line"
		_parse_phase_line_bold_form "$line" "$global_auto_fire"
	done
	return 0
}

#######################################
# Build the worker-ready issue body for a newly auto-filed phase child.
# Includes 5+ heading signals (What, Why, How, Acceptance, Session Origin)
# so brief-readiness-helper.sh skips separate brief creation (t2417).
#
# Args: $1=parent_issue, $2=parent_title, $3=phase_num, $4=phase_desc,
#       $5=repo_slug
# Output: issue body on stdout
# Returns: 0 always
#######################################
_build_phase_child_body() {
	local parent_issue="$1"
	local parent_title="$2"
	local phase_num="$3"
	local phase_desc="$4"
	local repo_slug="$5"

	cat <<MD
<!-- aidevops:generator=phase-autofile parent=${parent_issue} phase=${phase_num} -->

## What

Implement Phase ${phase_num} of parent-task [#${parent_issue}](https://github.com/${repo_slug}/issues/${parent_issue}): ${phase_desc}

## Why

This phase was auto-filed after the prior phase's PR merged successfully.
Parent task #${parent_issue} (_${parent_title}_) uses sequential phase
decomposition. Phase $((phase_num - 1)) has been completed and merged.

## How

1. Read the parent issue at https://github.com/${repo_slug}/issues/${parent_issue}
   for full context on the overall task and this phase's requirements.
2. Review any prior phase PRs for patterns and conventions established.
3. Implement Phase ${phase_num}: ${phase_desc}
4. Use \`Resolves #<this-issue>\` in the PR body and \`For #${parent_issue}\`
   to reference the parent without closing it.

## Acceptance

- Phase ${phase_num} implementation complete per parent issue description
- All modified files pass linting (shellcheck for .sh, markdownlint for .md)
- Tests added or updated as appropriate

## Session Origin

Auto-filed by \`shared-phase-filing.sh\` (t2740) after prior phase merged.
Parent: #${parent_issue}. Ref #${parent_issue}.
MD
	return 0
}

#######################################
# Update the parent issue's ## Phases section to record the newly filed
# child issue number on the appropriate phase line. Best-effort.
#
# Args: $1=parent_issue, $2=repo_slug, $3=phase_num, $4=child_issue_num
# Returns: 0 always
#######################################
_update_parent_phases_section() {
	local parent_issue="$1"
	local repo_slug="$2"
	local phase_num="$3"
	local child_issue_num="$4"
	local _log="${LOGFILE:-/dev/null}"
	local parent_api="repos/${repo_slug}/issues/${parent_issue}"

	# Read current parent body
	local parent_body
	parent_body=$(gh api "$parent_api" \
		--jq '.body // ""' 2>/dev/null) || parent_body=""
	[[ -n "$parent_body" ]] || return 0

	# Find the phase line and append the child issue reference.
	# Use sed to find the line matching "Phase <N>" and append " #<child>".
	# BSD sed compatible (macOS default). The pattern matches "Phase <N>"
	# where <N> is exactly $phase_num (word-bounded by whitespace/punctuation),
	# and appends the child ref only if it's not already present.
	local updated_body
	updated_body=$(printf '%s' "$parent_body" | sed -E "/^[[:space:]]*-[[:space:]]+[Pp]hase[[:space:]]+${phase_num}([^0-9]|$)/ {
		/#${child_issue_num}([^0-9]|$)/!s/[[:space:]]*$/ #${child_issue_num}/
	}")

	# Only update if the body actually changed
	if [[ "$updated_body" != "$parent_body" ]]; then
		# gh_issue_edit_safe is always available via shared-constants.sh
		gh_issue_edit_safe "$parent_issue" --repo "$repo_slug" \
			--body "$updated_body" 2>>"$_log" || true
		_phase_log "Updated parent #${parent_issue} ## Phases section with child #${child_issue_num} for Phase ${phase_num}"
	fi
	return 0
}

#######################################
# Identify which phase number a merged child issue belongs to.
# First tries matching by child reference in phases data.
# Falls back to matching by phase number in the child issue's title.
#
# Args: $1=child_issue, $2=repo_slug, $3=phases (tab-separated phase lines)
# Output: phase number on stdout (empty if not found)
# Returns: 0 always
#######################################
_identify_merged_phase() {
	local child_issue="$1"
	local repo_slug="$2"
	local phases="$3"
	local child_api="repos/${repo_slug}/issues/${child_issue}"
	local merged_phase_num=""

	# Try matching by child_ref recorded in phases data
	while IFS=$'\t' read -r p_num p_desc p_marker p_child; do
		if [[ "$p_child" == "$child_issue" ]]; then
			merged_phase_num="$p_num"
			break
		fi
	done <<< "$phases"

	if [[ -z "$merged_phase_num" ]]; then
		# Child issue not found in any phase line — may be a non-phase child
		# or the parent's ## Phases section was not updated with the child ref.
		# Fallback: match by phase number in the child issue's title.
		local child_title
		child_title=$(gh api "$child_api" \
			--jq '.title // ""' 2>/dev/null) || child_title=""
		if [[ -n "$child_title" ]]; then
			local title_phase_num
			title_phase_num=$(printf '%s' "$child_title" \
				| grep -ioE '[Pp]hase[[:space:]]+[0-9]+' \
				| grep -oE '[0-9]+' \
				| head -1)
			if [[ -n "$title_phase_num" ]]; then
				merged_phase_num="$title_phase_num"
				_phase_log "Child #${child_issue}: matched Phase ${merged_phase_num} via title '${child_title}'"
			fi
		fi
	fi

	printf '%s' "$merged_phase_num"
	return 0
}

#######################################
# Build and create a new phase child issue on GitHub.
# Handles issue body generation, signature footer appending, and issue creation.
#
# Args: $1=parent_issue, $2=parent_title, $3=phase_num, $4=phase_desc, $5=repo_slug
# Output: new issue URL on stdout (empty on failure)
# Returns: 0 always
#######################################
_create_phase_child_issue() {
	local parent_issue="$1"
	local parent_title="$2"
	local phase_num="$3"
	local phase_desc="$4"
	local repo_slug="$5"
	local _log="${LOGFILE:-/dev/null}"

	local issue_body
	issue_body=$(_build_phase_child_body \
		"$parent_issue" "$parent_title" "$phase_num" "$phase_desc" "$repo_slug")

	# Append signature footer
	local _phase_sig=""
	local _sig_helper="${AGENTS_DIR:-${HOME}/.aidevops/agents}/scripts/gh-signature-helper.sh"
	if [[ -x "$_sig_helper" ]]; then
		_phase_sig=$("$_sig_helper" footer --no-session --tokens 0 \
			--session-type routine 2>/dev/null || true)
	fi

	local issue_title="Phase ${phase_num} of #${parent_issue}: ${phase_desc}"
	local issue_labels="auto-dispatch,tier:standard,origin:worker"
	local new_issue_url

	# gh_create_issue is always available via shared-constants.sh (sourced
	# by pulse-wrapper.sh before this module). Handles origin labelling
	# and signature injection automatically.
	new_issue_url=$(gh_create_issue --repo "$repo_slug" \
		--title "$issue_title" \
		--label "$issue_labels" \
		--body "${issue_body}${_phase_sig}" 2>>"$_log")

	printf '%s' "${new_issue_url:-}"
	return 0
}

#######################################
# Post phase-transition notifications after a new child issue is filed.
# Updates the parent issue's ## Phases section with the new child reference
# and posts a completion notification comment on the parent.
#
# Args: $1=parent_issue, $2=repo_slug, $3=next_phase_num, $4=new_issue_num,
#       $5=merged_phase_num, $6=child_issue, $7=next_desc
# Returns: 0 always
#######################################
_post_phase_transition_notifications() {
	local parent_issue="$1"
	local repo_slug="$2"
	local next_phase_num="$3"
	local new_issue_num="$4"
	local merged_phase_num="$5"
	local child_issue="$6"
	local next_desc="$7"
	local _log="${LOGFILE:-/dev/null}"

	# Update parent's ## Phases section with the new child reference
	_update_parent_phases_section \
		"$parent_issue" "$repo_slug" "$next_phase_num" "$new_issue_num"

	# Post a notification comment on the parent issue
	local notify_comment="Phase ${merged_phase_num} completed (child #${child_issue} merged). Auto-filed Phase ${next_phase_num} as #${new_issue_num}: ${next_desc}

_Sequential phase auto-filing by \`shared-phase-filing.sh\` (t2740)._"

	# gh_issue_comment is always available via shared-constants.sh
	gh_issue_comment "$parent_issue" --repo "$repo_slug" \
		--body "$notify_comment" 2>>"$_log" || true

	return 0
}

#######################################
# Main entry point: auto-file the next phase for a parent-task issue
# after a child phase PR merges.
#
# Called from pulse-merge.sh::_handle_post_merge_actions and
# full-loop-helper.sh::cmd_merge after a successful PR merge closes
# a child issue.
#
# Guards:
#   1. Feature flag AIDEVOPS_SEQUENTIAL_PHASE_AUTOFILE must be 1
#   2. Child issue must reference a parent-task issue
#   3. Parent must have a ## Phases section
#   4. Next phase must exist, be marked [auto-fire:on-prior-merge],
#      and not already have a child issue filed
#
# Args: $1=child_issue (just closed), $2=repo_slug
# Returns: 0 always (best-effort, failures logged)
#######################################
auto_file_next_phase() {
	local child_issue="$1"
	local repo_slug="$2"
	local _log="${LOGFILE:-/dev/null}"

	# Guard 1: feature flag
	if [[ "${AIDEVOPS_SEQUENTIAL_PHASE_AUTOFILE:-0}" != "1" ]]; then
		return 0
	fi

	# Guard 2: child_issue must be non-empty
	[[ -n "$child_issue" ]] || return 0

	_phase_log "Checking child #${child_issue} in ${repo_slug} for parent-task phase auto-filing"

	# Find parent-task issue
	local parent_issue
	parent_issue=$(_find_parent_task_for_child "$child_issue" "$repo_slug")
	if [[ -z "$parent_issue" ]]; then
		_phase_log "Child #${child_issue}: no parent-task issue found, skip"
		return 0
	fi
	_phase_log "Child #${child_issue}: found parent-task #${parent_issue}"

	# Read parent issue body and title in a single API call
	local parent_api="repos/${repo_slug}/issues/${parent_issue}"
	local parent_body parent_title _parent_json
	_parent_json=$(gh api "$parent_api" \
		--jq '{body: (.body // ""), title: (.title // "")}' 2>/dev/null) || _parent_json=""
	[[ -n "$_parent_json" ]] || return 0
	parent_body=$(printf '%s' "$_parent_json" | jq -r '.body // ""')
	parent_title=$(printf '%s' "$_parent_json" | jq -r '.title // ""')

	# Guard 3: parse phases
	local phases
	phases=$(_parse_phases_section "$parent_body")
	if [[ -z "$phases" ]]; then
		_phase_log "Parent #${parent_issue}: no ## Phases section found, skip"
		return 0
	fi

	# Identify which phase the merged child corresponds to
	local merged_phase_num
	merged_phase_num=$(_identify_merged_phase "$child_issue" "$repo_slug" "$phases")
	if [[ -z "$merged_phase_num" ]]; then
		_phase_log "Child #${child_issue}: cannot determine which phase it belongs to in parent #${parent_issue}, skip"
		return 0
	fi
	_phase_log "Child #${child_issue}: corresponds to Phase ${merged_phase_num} of parent #${parent_issue}"

	# Find the next phase (N+1)
	local next_phase_num=$((merged_phase_num + 1))
	local next_desc="" next_marker="" next_child=""
	while IFS=$'\t' read -r p_num p_desc p_marker p_child; do
		if [[ "$p_num" == "$next_phase_num" ]]; then
			next_desc="$p_desc"
			next_marker="$p_marker"
			next_child="$p_child"
			break
		fi
	done <<< "$phases"

	if [[ -z "$next_desc" ]]; then
		_phase_log "Parent #${parent_issue}: no Phase ${next_phase_num} found, all phases may be complete"
		return 0
	fi

	# Guard: next phase must be opted in
	if [[ "$next_marker" != "$_PHASE_MARKER_AUTO_FIRE" ]]; then
		_phase_log "Parent #${parent_issue}: Phase ${next_phase_num} marker is '${next_marker}', not ${_PHASE_MARKER_AUTO_FIRE} — skip"
		return 0
	fi

	# Guard: dedup — ## Phases child_ref check is the primary mechanism
	if [[ -n "$next_child" ]]; then
		_phase_log "Parent #${parent_issue}: Phase ${next_phase_num} already has child #${next_child} — skip"
		return 0
	fi

	_phase_log "Filing Phase ${next_phase_num} ('${next_desc}') for parent #${parent_issue}"

	# Build and create the new phase child issue
	local new_issue_url
	new_issue_url=$(_create_phase_child_issue \
		"$parent_issue" "$parent_title" "$next_phase_num" "$next_desc" "$repo_slug")
	if [[ -z "$new_issue_url" ]]; then
		_phase_log "Failed to create Phase ${next_phase_num} issue for parent #${parent_issue}"
		return 0
	fi

	# Extract issue number from URL
	local new_issue_num; new_issue_num=$(printf '%s' "$new_issue_url" | grep -oE '[0-9]+$')
	_phase_log "Filed Phase ${next_phase_num} as #${new_issue_num} for parent #${parent_issue}"

	# Update parent section and post completion notification
	_post_phase_transition_notifications \
		"$parent_issue" "$repo_slug" "$next_phase_num" "$new_issue_num" \
		"$merged_phase_num" "$child_issue" "$next_desc"
	return 0
}
