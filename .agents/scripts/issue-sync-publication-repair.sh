#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# =============================================================================
# Issue Sync — Stale Planning Publication Repair (GH#34149)
# =============================================================================
# An issue-first task carries publication:pending until its TODO.md row and
# todo/tasks/<task>-brief.md reach the default branch. When the creating session
# never publishes (abandoned worktree, closed or conflicting planning PR), no
# other actor owns the transition, so a worker-ready issue would stay
# undispatchable forever.
#
# This module lets `issue-sync-helper.sh pull` (run by Pulse in a fresh
# default-branch workspace) repair such issues after a bounded grace window:
# capture the issue body as the brief, seed the TODO row with ref:GH#N, and let
# the existing allowlisted planning publisher land both. Default-branch
# reconciliation (planning-publication-reconcile.sh) remains the only path that
# projects dispatch labels and removes publication:pending.
#
# Usage: source "${SCRIPT_DIR}/issue-sync-publication-repair.sh"
#
# Dependencies (resolved at call time):
#   - issue-sync-lib.sh (_seed_orphan_todo_line, task_identity_validate)
#   - issue-sync-helper-labels.sh (_issue_labels_include_exact)
#   - brief-readiness-helper.sh stub, verify-brief-helper.sh check-readiness
#
# Part of aidevops framework: https://aidevops.sh

[[ "${BASH_SOURCE[0]}" == "${0}" ]] && set -euo pipefail

[[ -n "${_ISSUE_SYNC_PUBLICATION_REPAIR_LOADED:-}" ]] && return 0
_ISSUE_SYNC_PUBLICATION_REPAIR_LOADED=1

_PUBLICATION_REPAIR_PENDING_LABEL="publication:pending"
_PUBLICATION_REPAIR_COUNT=0

# Pulse owns repair. GitHub Actions publishes TODO.md only, so a brief written
# there would be discarded and the landed row would fail reconciliation.
_publication_repair_enabled() {
	[[ "${GITHUB_ACTIONS:-}" != "true" ]] || return 1
	[[ "${AIDEVOPS_PUBLICATION_REPAIR:-1}" != "0" ]] || return 1
	return 0
}

_publication_repair_hours() {
	local hours="${AIDEVOPS_PUBLICATION_REPAIR_HOURS:-6}"
	[[ "$hours" =~ ^[1-9][0-9]*$ ]] || hours=6
	printf '%s\n' "$hours"
	return 0
}

_publication_repair_limit() {
	local limit="${AIDEVOPS_PUBLICATION_REPAIR_LIMIT:-10}"
	[[ "$limit" =~ ^[1-9][0-9]*$ ]] || limit=10
	printf '%s\n' "$limit"
	return 0
}

# Prints whole hours since an ISO-8601 UTC timestamp; fails on invalid input.
_publication_repair_age_hours() {
	local created_at="$1" created_epoch="" now_epoch=""
	[[ "$created_at" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]] || return 1
	created_epoch=$(date -u -d "$created_at" +%s 2>/dev/null) ||
		created_epoch=$(date -j -u -f '%Y-%m-%dT%H:%M:%SZ' "$created_at" +%s 2>/dev/null) || return 1
	now_epoch=$(date -u +%s) || return 1
	[[ "$created_epoch" =~ ^[0-9]+$ && "$now_epoch" =~ ^[0-9]+$ ]] || return 1
	((created_epoch <= now_epoch)) || return 1
	printf '%s\n' "$(((now_epoch - created_epoch) / 3600))"
	return 0
}

# Labels that express a deliberate hold or live ownership. Repair never adds
# auto-dispatch over them; reconciliation preserves them after publication.
_publication_repair_has_hold() {
	local labels_json="$1"
	printf '%s' "$labels_json" | jq -e 'any(.[]?.name;
		. == "no-auto-dispatch" or . == "hold-for-review" or
		. == "parent-task" or . == "meta" or . == "needs-maintainer-review" or
		. == "status:queued" or . == "status:claimed" or
		. == "status:in-progress" or . == "status:in-review" or . == "status:done")' \
		>/dev/null 2>&1 && return 0
	return 1
}

#aidevops:trust-boundary -- GH#34149: the captured issue body becomes worker
# instructions on the default branch. Only repository OWNER/MEMBER/COLLABORATOR
# authors qualify; any lookup failure defers repair (fail closed).
_publication_repair_author_trusted() {
	local repo="$1" num="$2" association=""
	association=$(gh api "repos/${repo}/issues/${num}" --jq '.author_association // empty' 2>/dev/null) || return 1
	case "$association" in
	OWNER | MEMBER | COLLABORATOR) return 0 ;;
	esac
	return 1
}

_publication_repair_capture_brief() {
	local repo="$1" num="$2" task_id="$3" project_root="$4"
	local brief_path="${project_root}/todo/tasks/${task_id}-brief.md"
	if [[ -e "$brief_path" || -L "$brief_path" ]]; then
		[[ -f "$brief_path" && ! -L "$brief_path" ]] || return 1
		return 0
	fi
	"${SCRIPT_DIR}/brief-readiness-helper.sh" stub "$task_id" "$num" "$repo" "$project_root" >/dev/null 2>&1 || return 1
	[[ -f "$brief_path" && ! -L "$brief_path" ]] || return 1
	return 0
}

# Worker-ready issues default to auto-dispatch (workflows/new-task.md); the
# pending projection stripped it at creation, so restore it here.
_publication_repair_labels() {
	local labels_json="$1" brief_path="$2"
	if ! _publication_repair_has_hold "$labels_json" &&
		"${SCRIPT_DIR}/verify-brief-helper.sh" check-readiness "$brief_path" >/dev/null 2>&1; then
		printf '%s' "$labels_json" | jq -c '. + [{"name":"auto-dispatch"}] | unique_by(.name)' 2>/dev/null && return 0
	fi
	printf '%s\n' "$labels_json"
	return 0
}

# Repair one open publication:pending issue whose task row is absent from the
# default-branch TODO.md. Returns 0 when the row was seeded (or would be, in
# dry-run); 1 when the issue is young, untrusted, over budget or not repairable,
# in which case the caller keeps the legacy deferral.
publication_repair_stale_orphan() {
	local repo="$1" num="$2" task_id="$3" title="$4" issue_line="$5" todo_file="$6"
	local project_root="${todo_file%/*}" created_at="" age_hours="" labels_json="" brief_path=""
	_publication_repair_enabled || return 1
	[[ "$_PUBLICATION_REPAIR_COUNT" -lt "$(_publication_repair_limit)" ]] || return 1
	[[ "$num" =~ ^[1-9][0-9]*$ ]] || return 1
	task_identity_validate "$task_id" || return 1
	[[ "$project_root" != "$todo_file" && -d "$project_root" ]] || return 1
	created_at=$(printf '%s' "$issue_line" | jq -r '.createdAt // empty' 2>/dev/null) || return 1
	age_hours=$(_publication_repair_age_hours "$created_at") || return 1
	[[ "$age_hours" -ge "$(_publication_repair_hours)" ]] || return 1
	labels_json=$(printf '%s' "$issue_line" | jq -c '.labels // []' 2>/dev/null) || return 1
	_publication_repair_author_trusted "$repo" "$num" || {
		print_warning "Publication repair skipped for #${num} (${task_id}): author is not a repository collaborator"
		return 1
	}
	if [[ "${DRY_RUN:-}" == "true" ]]; then
		_PUBLICATION_REPAIR_COUNT=$((_PUBLICATION_REPAIR_COUNT + 1))
		print_info "[DRY-RUN] Would repair stale ${_PUBLICATION_REPAIR_PENDING_LABEL} #${num} (${task_id}, ${age_hours}h): capture brief and seed TODO row"
		return 0
	fi
	brief_path="${project_root}/todo/tasks/${task_id}-brief.md"
	local brief_preexisting=0
	[[ -e "$brief_path" ]] && brief_preexisting=1
	_publication_repair_capture_brief "$repo" "$num" "$task_id" "$project_root" || {
		print_warning "Publication repair could not capture ${brief_path##*/} for #${num}; retaining ${_PUBLICATION_REPAIR_PENDING_LABEL}"
		return 1
	}
	labels_json=$(_publication_repair_labels "$labels_json" "$brief_path")
	if ! _seed_orphan_todo_line "$num" "$task_id" "$title" "$labels_json" "$todo_file" ""; then
		# Never publish a brief without its TODO row.
		[[ "$brief_preexisting" -eq 1 ]] || rm -f "$brief_path"
		return 1
	fi
	_PUBLICATION_REPAIR_COUNT=$((_PUBLICATION_REPAIR_COUNT + 1))
	print_success "Publication repair: ${task_id} (#${num}) pending ${age_hours}h; brief captured and TODO row seeded for default-branch reconciliation"
	return 0
}
