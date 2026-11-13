#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# Normalization pass and repository rotation.

[[ -n "${_PULSE_ISSUE_RECONCILE_ROTATION_LOADED:-}" ]] && return 0
_PULSE_ISSUE_RECONCILE_ROTATION_LOADED=1

# Normalization passes in canonical order. Each pass lists open issues per
# pulse repo, so a full sweep exceeds the remaining ownership budget on large
# fleets: with a fixed order the stage watchdog killed every cycle inside
# Pass 1 and Passes 2/2b/3 never ran (stale assignments and stampless
# interactive claims stayed dispatch-blocked for days).
_NORMALIZE_PASSES="reassign_self unassign_stale unassign_stampless_interactive label_invariants"

#######################################
# Print normalization passes least-recently-started first so a stage timeout
# never starves a pass. Missing, unreadable or future-dated start stamps sort
# first; ties keep the canonical order.
# Args: $1 state_dir, $2 now_epoch
# Stdout: one pass name per line
# Returns: 0 always
#######################################
_normalize_pass_order() {
	local state_dir="$1" now_epoch="$2" pass="" started=0 index=0
	[[ "$now_epoch" =~ ^[0-9]+$ ]] || now_epoch=0
	for pass in $_NORMALIZE_PASSES; do
		started=0
		if [[ -f "${state_dir}/${pass}" ]]; then
			read -r started <"${state_dir}/${pass}" 2>/dev/null || started=0
		fi
		[[ "$started" =~ ^[0-9]+$ && "$started" -le "$now_epoch" ]] || started=0
		printf '%s %s %s\n' "$started" "$index" "$pass"
		index=$((index + 1))
	done | sort -n -k1,1 -k2,2 | awk '{ print $3 }'
	return 0
}

# Best effort: an unwritable stamp only makes the pass sort first again.
_normalize_mark_pass_started() {
	local state_dir="$1" pass="$2" now_epoch=""
	now_epoch=$(date +%s 2>/dev/null) || return 0
	mkdir -p "$state_dir" 2>/dev/null || return 0
	printf '%s\n' "$now_epoch" >"${state_dir}/${pass}" 2>/dev/null || true
	return 0
}

# GH#37568: per-pass repo cursor. Pass rotation alone gives each pass a turn,
# but a pass slower than the remaining stage budget restarted at the first
# repo every turn, so late repos.json entries were rarely normalized. Set only
# by normalize_active_issue_assignments; direct calls keep canonical order.
_NORMALIZE_REPO_CURSOR_DIR=""

#######################################
# Print a pass's repo slugs starting after the repo it last started (wrapping).
# A missing, unreadable or unknown cursor keeps the canonical order.
# Args: $1 pass name, $2 newline-separated slugs
# Stdout: one slug per line
# Returns: 0 always
#######################################
_normalize_rotated_slugs() {
	local pass="$1" slugs="$2" last=""
	local cursor="${_NORMALIZE_REPO_CURSOR_DIR}/${pass}"
	if [[ -n "$_NORMALIZE_REPO_CURSOR_DIR" && -f "$cursor" ]]; then
		read -r last <"$cursor" 2>/dev/null || last=""
	fi
	if [[ -z "$last" ]]; then
		printf '%s\n' "$slugs"
		return 0
	fi
	printf '%s\n' "$slugs" | awk -v last="$last" '
		NF { slug[n++] = $0; if ($0 == last) start = n }
		END { for (i = 0; i < n; i++) print slug[(start + i) % n] }'
	return 0
}

# Record the repo before scanning it, so a repo slower than the remaining
# budget cannot pin the rotation. Best effort: a failed write only restarts
# the pass at its first repo.
_normalize_mark_repo_started() {
	local pass="$1" slug="$2"
	[[ -n "$_NORMALIZE_REPO_CURSOR_DIR" ]] || return 0
	mkdir -p "$_NORMALIZE_REPO_CURSOR_DIR" 2>/dev/null || return 0
	printf '%s\n' "$slug" >"${_NORMALIZE_REPO_CURSOR_DIR}/${pass}" 2>/dev/null || true
	return 0
}
