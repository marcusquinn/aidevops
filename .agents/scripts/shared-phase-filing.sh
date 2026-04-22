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
#   AIDEVOPS_SEQUENTIAL_PHASE_AUTOFILE=0|1 (default 0)
#   When 0, auto_file_next_phase is a no-op. Set to 1 to enable.
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

# Feature flag: default OFF for initial rollout.
AIDEVOPS_SEQUENTIAL_PHASE_AUTOFILE="${AIDEVOPS_SEQUENTIAL_PHASE_AUTOFILE:-0}"

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
# Parse the ## Phases section from a parent issue body.
# Outputs one line per phase in tab-separated format:
#   phase_num\tdescription\tmarker\tchild_issue
#
# marker is one of: auto-fire, requires-decision, none
# child_issue is the issue number (digits only) or empty
#
# Args: $1=parent_body
# Output: phase lines on stdout
# Returns: 0 always
#######################################
_parse_phases_section() {
	local body="$1"
	[[ -n "$body" ]] || return 0

	# Extract the ## Phases section: everything between "## Phases" and the
	# next ## heading (or end of string). Use awk for multi-line extraction.
	local phases_block
	phases_block=$(printf '%s' "$body" | awk '
		/^## Phases/ { found=1; next }
		found && /^## / { exit }
		found { print }
	')
	[[ -n "$phases_block" ]] || return 0

	# Parse each phase line. Format:
	#   - Phase <N> - <description> [auto-fire:on-prior-merge] [#<child>]
	#   - Phase <N>: <description> [requires-decision]
	# We are flexible with separators (-, :, whitespace).
	printf '%s\n' "$phases_block" | while IFS= read -r line; do
		# Match lines starting with "- Phase <N>"
		if printf '%s' "$line" | grep -qE '^[[:space:]]*-[[:space:]]+[Pp]hase[[:space:]]+[0-9]+'; then
			local phase_num description marker child_ref

			# Extract phase number
			phase_num=$(printf '%s' "$line" | grep -oE '[Pp]hase[[:space:]]+[0-9]+' | grep -oE '[0-9]+')

			# Extract description: text after "Phase N" separator (- or :) up to first [
			description=$(printf '%s' "$line" | sed -E 's/^[[:space:]]*-[[:space:]]+[Pp]hase[[:space:]]+[0-9]+[[:space:]]*[-:][[:space:]]*//' | sed -E 's/[[:space:]]*\[.*//')

			# Determine marker
			if printf '%s' "$line" | grep -qiF '[auto-fire:on-prior-merge]'; then
				marker="auto-fire"
			elif printf '%s' "$line" | grep -qiF '[requires-decision]'; then
				marker="requires-decision"
			else
				marker="none"
			fi

			# Extract child issue reference (#NNNN not inside a marker bracket)
			# Look for standalone #NNNN outside of [...]
			child_ref=$(printf '%s' "$line" | grep -oE '#[0-9]+' | grep -oE '[0-9]+' | head -1)
			# But skip if the #NNNN is inside a marker (unlikely but guard)
			# Simple approach: if #NNNN appears after a ], it's a child ref
			# If it only appears inside [...], it's not. For now, accept any #NNNN
			# that is NOT the phase number itself.
			if [[ "$child_ref" == "$phase_num" ]]; then
				child_ref=""
			fi

			printf '%s\t%s\t%s\t%s\n' "$phase_num" "$description" "$marker" "$child_ref"
		fi
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
		/#${child_issue_num}/!s/[[:space:]]*$/ #${child_issue_num}/
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
	local child_api="repos/${repo_slug}/issues/${child_issue}"

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
	parent_body=$(printf '%s' "$_parent_json" | jq -r '.body // ""')
	parent_title=$(printf '%s' "$_parent_json" | jq -r '.title // ""')

	# Guard 3: parse phases
	local phases
	phases=$(_parse_phases_section "$parent_body")
	if [[ -z "$phases" ]]; then
		_phase_log "Parent #${parent_issue}: no ## Phases section found, skip"
		return 0
	fi

	# Find which phase the merged child corresponds to.
	# Look for a phase line where child_ref matches child_issue.
	local merged_phase_num=""
	while IFS=$'\t' read -r p_num p_desc p_marker p_child; do
		if [[ "$p_child" == "$child_issue" ]]; then
			merged_phase_num="$p_num"
			break
		fi
	done <<< "$phases"

	if [[ -z "$merged_phase_num" ]]; then
		# Child issue not found in any phase line — may be a non-phase child
		# or the parent's ## Phases section was not updated with the child ref.
		# Try matching by child issue title containing "Phase N".
		local child_title
		child_title=$(gh api "$child_api" \
			--jq '.title // ""' 2>/dev/null) || child_title=""
		if [[ -n "$child_title" ]]; then
			local title_phase_num
			title_phase_num=$(printf '%s' "$child_title" | grep -ioE '[Pp]hase[[:space:]]+[0-9]+' | grep -oE '[0-9]+' | head -1)
			if [[ -n "$title_phase_num" ]]; then
				merged_phase_num="$title_phase_num"
				_phase_log "Child #${child_issue}: matched Phase ${merged_phase_num} via title '${child_title}'"
			fi
		fi
	fi

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
	if [[ "$next_marker" != "auto-fire" ]]; then
		_phase_log "Parent #${parent_issue}: Phase ${next_phase_num} marker is '${next_marker}', not auto-fire — skip"
		return 0
	fi

	# Guard: dedup — next phase must not already have a child issue
	if [[ -n "$next_child" ]]; then
		_phase_log "Parent #${parent_issue}: Phase ${next_phase_num} already has child #${next_child} — skip"
		return 0
	fi

	# Dedup: check if an issue already exists with this phase title
	local dedup_title="Phase ${next_phase_num}"
	local existing_count
	existing_count=$(gh issue list --repo "$repo_slug" --state all \
		--search "Phase ${next_phase_num} in:title" --limit 20 \
		--json title,number \
		| jq --arg parent "$parent_issue" --arg pnum "$next_phase_num" \
		'[.[] | select(.title | test("Phase " + $pnum + "[^0-9]"; "i")) | select(.title | test("#" + $parent + "|" + $parent; "i") or true)] | length' \
		2>/dev/null) || existing_count=0
	# Narrow dedup: look for issues referencing both this parent and this phase
	# This is best-effort; the ## Phases child_ref check above is the primary dedup.

	_phase_log "Filing Phase ${next_phase_num} ('${next_desc}') for parent #${parent_issue}"

	# Build issue body
	local issue_body
	issue_body=$(_build_phase_child_body "$parent_issue" "$parent_title" "$next_phase_num" "$next_desc" "$repo_slug")

	# Append signature footer
	local _phase_sig=""
	local _sig_helper="${AGENTS_DIR:-${HOME}/.aidevops/agents}/scripts/gh-signature-helper.sh"
	if [[ -x "$_sig_helper" ]]; then
		_phase_sig=$("$_sig_helper" footer --no-session --tokens 0 \
			--session-type routine 2>/dev/null || true)
	fi

	# Create the issue
	local issue_title="Phase ${next_phase_num} of #${parent_issue}: ${next_desc}"
	local issue_labels="auto-dispatch,tier:standard,origin:worker"
	local new_issue_url

	# gh_create_issue is always available via shared-constants.sh (sourced
	# by pulse-wrapper.sh before this module). It handles origin labelling
	# and signature injection automatically.
	new_issue_url=$(gh_create_issue --repo "$repo_slug" \
		--title "$issue_title" \
		--label "$issue_labels" \
		--body "${issue_body}${_phase_sig}" 2>>"$_log")

	if [[ -z "$new_issue_url" ]]; then
		_phase_log "Failed to create Phase ${next_phase_num} issue for parent #${parent_issue}"
		return 0
	fi

	# Extract issue number from URL
	local new_issue_num
	new_issue_num=$(printf '%s' "$new_issue_url" | grep -oE '[0-9]+$')

	_phase_log "Filed Phase ${next_phase_num} as #${new_issue_num} for parent #${parent_issue}"

	# Update parent's ## Phases section with the new child reference
	_update_parent_phases_section "$parent_issue" "$repo_slug" "$next_phase_num" "$new_issue_num"

	# Post a notification comment on the parent issue
	local notify_comment="Phase ${merged_phase_num} completed (child #${child_issue} merged). Auto-filed Phase ${next_phase_num} as #${new_issue_num}: ${next_desc}

_Sequential phase auto-filing by \`shared-phase-filing.sh\` (t2740)._"

	# gh_issue_comment is always available via shared-constants.sh
	gh_issue_comment "$parent_issue" --repo "$repo_slug" \
		--body "$notify_comment" 2>>"$_log" || true

	return 0
}
