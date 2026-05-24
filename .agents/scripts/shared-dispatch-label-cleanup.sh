#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# shared-dispatch-label-cleanup.sh — terminal issue dispatch-label hygiene.

[[ -n "${_SHARED_DISPATCH_LABEL_CLEANUP_LOADED:-}" ]] && return 0
_SHARED_DISPATCH_LABEL_CLEANUP_LOADED=1

: "${LOGFILE:=${HOME}/.aidevops/logs/pulse.log}"
: "${REPOS_JSON:=${HOME}/.config/aidevops/repos.json}"
: "${PULSE_STALE_DISPATCH_LABEL_SWEEP_INTERVAL:=86400}"
: "${PULSE_STALE_DISPATCH_LABEL_SWEEP_LIMIT_PER_REPO:=50}"

_TERMINAL_DISPATCH_LABELS=(
	"auto-dispatch"
	"status:available"
	"status:queued"
	"status:claimed"
	"status:in-progress"
	"status:in-review"
)

_dispatch_label_cleanup_stamp_file() {
	printf '%s\n' "${HOME}/.aidevops/logs/pulse-stale-dispatch-label-sweep.last"
	return 0
}

clear_terminal_issue_dispatch_labels() {
	local issue_number="$1"
	local repo_slug="$2"
	local context="${3:-terminal}"

	if [[ ! "$issue_number" =~ ^[0-9]+$ || -z "$repo_slug" ]]; then
		return 1
	fi

	local -a edit_args=("issue" "edit" "$issue_number" "--repo" "$repo_slug")
	local label
	for label in "${_TERMINAL_DISPATCH_LABELS[@]}"; do
		edit_args+=("--remove-label" "$label")
	done

	if gh "${edit_args[@]}" >/dev/null 2>&1; then
		echo "[pulse-wrapper] dispatch-label-cleanup: stripped terminal dispatch labels from ${repo_slug}#${issue_number} (${context})" >>"$LOGFILE"
		return 0
	fi

	echo "[pulse-wrapper] dispatch-label-cleanup: failed to strip terminal dispatch labels from ${repo_slug}#${issue_number} (${context})" >>"$LOGFILE"
	return 1
}

_dispatch_label_sweep_due() {
	if [[ "${PULSE_STALE_DISPATCH_LABEL_SWEEP_FORCE:-0}" == "1" ]]; then
		return 0
	fi

	local stamp_file
	stamp_file=$(_dispatch_label_cleanup_stamp_file)
	[[ -f "$stamp_file" ]] || return 0

	local now_epoch stamp_epoch age
	now_epoch=$(date +%s 2>/dev/null || echo "0")
	stamp_epoch=$(cat "$stamp_file" 2>/dev/null || echo "0")
	[[ "$now_epoch" =~ ^[0-9]+$ ]] || now_epoch=0
	[[ "$stamp_epoch" =~ ^[0-9]+$ ]] || stamp_epoch=0
	age=$((now_epoch - stamp_epoch))

	if [[ "$age" -ge "$PULSE_STALE_DISPATCH_LABEL_SWEEP_INTERVAL" ]]; then
		return 0
	fi
	return 1
}

_dispatch_label_sweep_mark_run() {
	local stamp_file
	stamp_file=$(_dispatch_label_cleanup_stamp_file)
	mkdir -p "$(dirname "$stamp_file")" 2>/dev/null || true
	date +%s >"$stamp_file" 2>/dev/null || true
	return 0
}

_dispatch_label_sweep_repos() {
	local repos_json="${1:-$REPOS_JSON}"
	[[ -f "$repos_json" ]] || return 1
	jq -r '
		.initialized_repos[]? |
		select((.pulse // false) == true) |
		select((.local_only // false) == false) |
		.slug // empty
	' "$repos_json" 2>/dev/null
	return 0
}

sweep_closed_auto_dispatch_issues() {
	if ! _dispatch_label_sweep_due; then
		return 0
	fi

	local repos_json="${1:-$REPOS_JSON}"
	local limit="${PULSE_STALE_DISPATCH_LABEL_SWEEP_LIMIT_PER_REPO:-50}"
	[[ "$limit" =~ ^[0-9]+$ ]] || limit=50
	[[ "$limit" -gt 0 ]] || limit=50

	local total=0 repo_slug issue_number issue_numbers
	while IFS= read -r repo_slug; do
		[[ -n "$repo_slug" ]] || continue
		issue_numbers=$(gh issue list --repo "$repo_slug" --state closed \
			--label "auto-dispatch" --limit "$limit" \
			--json number --jq '.[].number' 2>/dev/null) || issue_numbers=""
		[[ -n "$issue_numbers" ]] || continue
		while IFS= read -r issue_number; do
			[[ "$issue_number" =~ ^[0-9]+$ ]] || continue
			clear_terminal_issue_dispatch_labels "$issue_number" "$repo_slug" "closed-issue-sweep" || true
			total=$((total + 1))
		done <<<"$issue_numbers"
	done < <(_dispatch_label_sweep_repos "$repos_json" || true)

	_dispatch_label_sweep_mark_run
	echo "[pulse-wrapper] dispatch-label-cleanup: closed issue sweep stripped labels from ${total} issue(s)" >>"$LOGFILE"
	return 0
}
