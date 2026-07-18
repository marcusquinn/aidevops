#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# =============================================================================
# Issue Sync Helper — Explicit held-issue body synchronization
# =============================================================================

[[ "${BASH_SOURCE[0]}" == "${0}" ]] && set -euo pipefail

[[ -n "${_ISSUE_SYNC_HELPER_BODY_LOADED:-}" ]] && return 0
_ISSUE_SYNC_HELPER_BODY_LOADED=1

if [[ -z "${SCRIPT_DIR:-}" ]]; then
	_body_lib_path="${BASH_SOURCE[0]%/*}"
	[[ "$_body_lib_path" == "${BASH_SOURCE[0]}" ]] && _body_lib_path="."
	SCRIPT_DIR="$(cd "$_body_lib_path" && pwd)"
	unset _body_lib_path
fi

if ! command -v _gh_current_user_allows_repo_write >/dev/null 2>&1; then
	# shellcheck source=shared-gh-collaborator-permission.sh
	# shellcheck disable=SC1091
	source "${SCRIPT_DIR}/shared-gh-collaborator-permission.sh"
fi

_BODY_SYNC_SENTINEL="Synced from TODO.md by issue-sync-helper.sh"

_body_sync_canonical_body() {
	local body="$1"
	printf '%s' "$body" | awk '
		/^<!-- aidevops:sig -->[[:space:]]*$/ { exit }
		{ lines[NR] = $0; if ($0 !~ /^[[:space:]]*$/) last = NR }
		END {
			for (i = 1; i <= last; i++) {
				printf "%s", lines[i]
				if (i < last) printf "\n"
			}
		}'
	return 0
}

_body_sync_hash_body() {
	local body="$1"
	local digest=""
	if command -v shasum >/dev/null 2>&1; then
		digest=$(_body_sync_canonical_body "$body" | shasum -a 256 | cut -d' ' -f1) || return 1
		printf '%s\n' "$digest"
		return 0
	fi
	if command -v sha256sum >/dev/null 2>&1; then
		digest=$(_body_sync_canonical_body "$body" | sha256sum | cut -d' ' -f1) || return 1
		printf '%s\n' "$digest"
		return 0
	fi
	print_error "Held body sync requires a SHA-256 tool"
	return 1
}

_body_sync_temp_file() {
	local suffix="$1"
	local temp_root="${AIDEVOPS_TEMP_DIR:-${HOME}/.aidevops/.agent-workspace/tmp}"
	mkdir -p "$temp_root" || return 1
	chmod 700 "$temp_root" 2>/dev/null || true
	mktemp "${temp_root}/held-body-sync-${suffix}-XXXXXX"
	return $?
}

_body_sync_fetch_state() {
	local repo="$1"
	local issue_number="$2"
	gh issue view "$issue_number" --repo "$repo" \
		--json number,title,body,labels,assignees,state,updatedAt 2>/dev/null
	return $?
}

_body_sync_validate_state() {
	local state_json="$1"
	local issue_number="$2"
	jq -e --argjson issue "$issue_number" --arg string_type "string" '
		type == "object" and .number == $issue and
		(.title | type == $string_type) and (.body | type == $string_type) and
		(.updatedAt | type == $string_type) and
		(.state == "OPEN" or .state == "CLOSED") and
		(.labels | type == "array") and all(.labels[]; .name | type == $string_type) and
		(.assignees | type == "array") and all(.assignees[]; .login | type == $string_type)
	' <<<"$state_json" >/dev/null 2>&1
	return $?
}

_body_sync_state_digest() {
	local state_json="$1"
	printf '%s' "$state_json" | jq -Sc '{number,title,body,state,updatedAt,
		labels: ([.labels[].name] | sort), assignees: ([.assignees[].login] | sort)}'
	return $?
}

_body_sync_metadata_digest() {
	local state_json="$1"
	printf '%s' "$state_json" | jq -Sc '{number,title,state,
		labels: ([.labels[].name] | sort), assignees: ([.assignees[].login] | sort)}'
	return $?
}

_body_sync_has_hold() {
	local state_json="$1"
	jq -e 'any(.labels[]; .name == "no-auto-dispatch")' <<<"$state_json" >/dev/null 2>&1
	return $?
}

_body_sync_has_nonself_claim() {
	local state_json="$1"
	local self_login="$2"
	jq -e --arg self "$self_login" '
		([.labels[].name] as $labels |
		 any($labels[]; . == "status:queued" or . == "status:in-progress" or
			 . == "status:in-review" or . == "status:claimed" or
			 . == "consolidation-in-progress") or
		 ((any($labels[]; . == "origin:interactive")) and
		  (all($labels[]; . != "auto-dispatch")))) and
		any(.assignees[]; .login != $self)
	' <<<"$state_json" >/dev/null 2>&1
	return $?
}

_body_sync_scan_file() {
	local body_file="$1"
	local scanner="${BODY_SYNC_PROMPT_SCANNER:-${SCRIPT_DIR}/prompt-guard-helper.sh}"
	[[ -x "$scanner" ]] || {
		print_error "Held body sync cannot verify the current body: prompt scanner unavailable"
		return 1
	}
	PROMPT_GUARD_POLICY="${BODY_SYNC_PROMPT_SCANNER_POLICY:-moderate}" \
		PROMPT_GUARD_QUIET=true "$scanner" check-file "$body_file" >/dev/null 2>&1 || {
		print_error "Held body sync blocked by current-body prompt-injection scan"
		return 1
	}
	return 0
}

_body_sync_validate_authoritative_body() {
	local task_id="$1"
	local project_root="$2"
	local body="$3"
	local brief_file="${project_root}/todo/tasks/${task_id}-brief.md"
	local brief_bytes=0
	[[ -f "$brief_file" ]] || {
		print_error "Held body sync requires an authoritative brief: todo/tasks/${task_id}-brief.md"
		return 1
	}
	brief_bytes=$(wc -c <"$brief_file" | tr -d '[:space:]') || return 1
	[[ "$brief_bytes" =~ ^[0-9]+$ && "$brief_bytes" -ge 100 ]] || {
		print_error "Held body sync refused a stub brief for $task_id"
		return 1
	}
	[[ ${#body} -ge 200 && "$body" == *"## Task Brief"* && "$body" == *"$_BODY_SYNC_SENTINEL"* ]] || {
		print_error "Held body sync refused a non-authoritative or stub composed body for $task_id"
		return 1
	}
	return 0
}

_body_sync_record_audit() {
	local event_type="$1"
	local outcome="$2"
	local repo="$3"
	local issue_number="$4"
	local task_id="$5"
	local before_hash="$6"
	local after_hash="$7"
	local helper="${BODY_SYNC_AUDIT_HELPER:-${SCRIPT_DIR}/audit-log-helper.sh}"
	[[ -x "$helper" ]] || {
		print_error "Held body sync audit helper is unavailable"
		return 1
	}
	"$helper" log "$event_type" "held issue body sync: ${outcome}" \
		--detail "operation=held-body-sync" --detail "outcome=${outcome}" \
		--detail "repo=${repo}" --detail "issue=${issue_number}" \
		--detail "task_id=${task_id}" --detail "before_hash=${before_hash:-none}" \
		--detail "after_hash=${after_hash:-none}" >/dev/null 2>&1 || {
		print_error "Held body sync could not persist its ${outcome} audit receipt"
		return 1
	}
	return 0
}

_body_sync_block_audit() {
	local outcome="$1"
	local repo="$2"
	local issue_number="$3"
	local task_id="$4"
	local before_hash="${5:-}"
	_body_sync_record_audit operation.block "$outcome" "$repo" "$issue_number" "$task_id" "$before_hash" "" || true
	return 0
}

_body_sync_check_state_policy() {
	local state_json="$1"
	local issue_number="$2"
	local task_id="$3"
	local self_login="$4"
	local allow_closed="$5"
	_body_sync_validate_state "$state_json" "$issue_number" || {
		print_error "Held body sync state is malformed or uncertain; refusing #${issue_number}"
		return 1
	}
	_body_sync_has_hold "$state_json" || {
		print_error "Held body sync requires no-auto-dispatch to remain present on #${issue_number}"
		return 1
	}
	local issue_state=""
	issue_state=$(jq -r '.state' <<<"$state_json") || return 1
	if [[ "$issue_state" == "CLOSED" && "$allow_closed" != "true" ]]; then
		print_error "Held body sync refuses closed issue #${issue_number}; retry with the explicit --allow-closed mode"
		return 1
	fi
	if _body_sync_has_nonself_claim "$state_json" "$self_login"; then
		print_error "Held body sync refuses #${issue_number} (${task_id}): genuine non-self active claim detected"
		return 1
	fi
	return 0
}

_body_sync_verify_post_write() {
	local post_json="$1"
	local immediate_json="$2"
	local repo="$3"
	local issue_number="$4"
	local task_id="$5"
	local before_hash="$6"
	local expected_hash="$7"
	local before_metadata="" after_metadata="" actual_hash="" post_body=""
	_body_sync_validate_state "$post_json" "$issue_number" || {
		_body_sync_block_audit post-write-state-malformed "$repo" "$issue_number" "$task_id" "$before_hash"
		return 1
	}
	_body_sync_has_hold "$post_json" || {
		_body_sync_block_audit hold-not-preserved "$repo" "$issue_number" "$task_id" "$before_hash"
		print_error "Held body sync verification failed: no-auto-dispatch is absent on #${issue_number}"
		return 1
	}
	before_metadata=$(_body_sync_metadata_digest "$immediate_json") || return 1
	after_metadata=$(_body_sync_metadata_digest "$post_json") || return 1
	[[ "$before_metadata" == "$after_metadata" ]] || {
		_body_sync_block_audit metadata-changed "$repo" "$issue_number" "$task_id" "$before_hash"
		print_error "Held body sync verification detected concurrent metadata changes on #${issue_number}"
		return 1
	}
	post_body=$(jq -r '.body' <<<"$post_json") || return 1
	actual_hash=$(_body_sync_hash_body "$post_body") || return 1
	[[ "$actual_hash" == "$expected_hash" ]] || {
		_body_sync_block_audit body-hash-mismatch "$repo" "$issue_number" "$task_id" "$before_hash"
		print_error "Held body sync post-write body hash mismatch on #${issue_number}"
		return 1
	}
	_body_sync_record_audit operation.verify verified "$repo" "$issue_number" "$task_id" "$before_hash" "$actual_hash" || return 1
	return 0
}

_body_sync_apply() {
	local task_id="$1"
	local repo="$2"
	local todo_file="$3"
	local project_root="$4"
	local issue_number="$5"
	local self_login="$6"
	local allow_closed="$7"
	local initial_json="" immediate_json="" post_json="" desired_body="" current_body=""
	local current_file="" desired_file="" before_hash="" expected_hash=""
	local initial_digest="" immediate_digest=""

	require_task_issue_mapping "$task_id" "$todo_file" "$repo" "$issue_number" || return 1
	initial_json=$(_body_sync_fetch_state "$repo" "$issue_number") || {
		print_error "Held body sync could not read #${issue_number}; refusing uncertain state"
		return 1
	}
	_body_sync_check_state_policy "$initial_json" "$issue_number" "$task_id" "$self_login" "$allow_closed" || return 1

	desired_body=$(compose_issue_body "$task_id" "$project_root") || return 1
	_body_sync_validate_authoritative_body "$task_id" "$project_root" "$desired_body" || return 1
	current_body=$(jq -r '.body' <<<"$initial_json") || return 1
	if [[ -n "$current_body" && "$current_body" != *"$_BODY_SYNC_SENTINEL"* ]]; then
		print_error "Held body sync preserves collaborator-authored body on #${issue_number}: framework sentinel absent"
		return 1
	fi

	current_file=$(_body_sync_temp_file current) || return 1
	desired_file=$(_body_sync_temp_file desired) || {
		rm -f "$current_file"
		return 1
	}
	trap 'rm -f "${current_file:-}" "${desired_file:-}"; trap - RETURN' RETURN
	printf '%s' "$current_body" >"$current_file" || return 1
	printf '%s' "$desired_body" >"$desired_file" || return 1
	_body_sync_scan_file "$current_file" || return 1

	immediate_json=$(_body_sync_fetch_state "$repo" "$issue_number") || {
		print_error "Held body sync pre-write re-read failed; refusing uncertain state"
		return 1
	}
	_body_sync_check_state_policy "$immediate_json" "$issue_number" "$task_id" "$self_login" "$allow_closed" || return 1
	initial_digest=$(_body_sync_state_digest "$initial_json") || return 1
	immediate_digest=$(_body_sync_state_digest "$immediate_json") || return 1
	[[ "$initial_digest" == "$immediate_digest" ]] || {
		print_error "Held body sync detected a concurrent state change on #${issue_number}; retry from fresh state"
		return 1
	}

	before_hash=$(_body_sync_hash_body "$current_body") || return 1
	expected_hash=$(_body_sync_hash_body "$desired_body") || return 1
	if [[ "$before_hash" == "$expected_hash" ]]; then
		_body_sync_record_audit operation.verify no-op "$repo" "$issue_number" "$task_id" "$before_hash" "$expected_hash" || return 1
		print_info "Held body unchanged on #${issue_number} (${task_id}); verified no-op"
		trap - RETURN
		rm -f "$current_file" "$desired_file"
		return 0
	fi

	if [[ "${DRY_RUN:-false}" == "true" ]]; then
		print_info "[DRY-RUN] Would synchronize body only on held issue #${issue_number} (${task_id})"
		trap - RETURN
		rm -f "$current_file" "$desired_file"
		return 0
	fi

	_body_sync_record_audit operation.verify authorized "$repo" "$issue_number" "$task_id" "$before_hash" "$expected_hash" || return 1
	if ! gh_issue_edit_safe "$issue_number" --repo "$repo" --body-file "$desired_file"; then
		_body_sync_block_audit write-failed "$repo" "$issue_number" "$task_id" "$before_hash"
		print_error "Held body sync write failed for #${issue_number}"
		return 1
	fi

	post_json=$(_body_sync_fetch_state "$repo" "$issue_number") || {
		_body_sync_block_audit post-write-read-failed "$repo" "$issue_number" "$task_id" "$before_hash"
		print_error "Held body sync could not verify #${issue_number} after write"
		return 1
	}
	_body_sync_verify_post_write "$post_json" "$immediate_json" "$repo" "$issue_number" \
		"$task_id" "$before_hash" "$expected_hash" || return 1
	print_success "Synchronized body only on held issue #${issue_number} (${task_id}); hold and metadata verified"
	trap - RETURN
	rm -f "$current_file" "$desired_file"
	return 0
}

cmd_sync_body() {
	local target_task="${1:-}"
	[[ "$target_task" =~ ^t[0-9]+(\.[0-9]+)*$ ]] || {
		print_error "sync-body requires exactly one task ID (tNNN)"
		return 1
	}
	_init_cmd || return 1
	local repo="$_CMD_REPO"
	local todo_file="$_CMD_TODO"
	local project_root="$_CMD_ROOT"
	local issue_number=""
	local self_login=""
	issue_number=$(resolve_task_gh_number "$target_task" "$todo_file" "$repo" || true)
	[[ "$issue_number" =~ ^[1-9][0-9]*$ ]] || {
		print_error "sync-body requires an immutable task/ref mapping for $target_task"
		return 1
	}
	# #aidevops:trust-boundary — re-resolve current identity and repository
	# permission for every invocation; never infer authority from edit success.
	_gh_current_user_allows_repo_write "$repo" || {
		print_error "sync-body requires current maintainer authority (${AIDEVOPS_GH_WRITE_PERMISSION_REASON:-unknown})"
		return 1
	}
	self_login="${AIDEVOPS_GH_WRITE_PERMISSION_USER:-}"
	[[ -n "$self_login" ]] || return 1
	case "${AIDEVOPS_GH_WRITE_PERMISSION_LEVEL:-unknown}" in
	admin | maintain) ;;
	*)
		print_error "sync-body requires admin or maintain authority (current: ${AIDEVOPS_GH_WRITE_PERMISSION_LEVEL:-unknown})"
		return 1
		;;
	esac
	_body_sync_apply "$target_task" "$repo" "$todo_file" "$project_root" \
		"$issue_number" "$self_login" "${ALLOW_CLOSED_BODY_SYNC:-false}"
	return $?
}
