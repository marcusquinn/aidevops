#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# Durable, structured one-shot scheduling for aidevops headless work.

set -euo pipefail
umask 077

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)" || exit 1
# shellcheck source=shared-constants.sh
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/shared-constants.sh"
# shellcheck source=deferred-job-lib.sh
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/deferred-job-lib.sh"
# shellcheck source=deferred-job-runner.sh
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/deferred-job-runner.sh"
# shellcheck source=deferred-job-maintenance.sh
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/deferred-job-maintenance.sh"
# shellcheck source=deferred-job-scheduler.sh
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/deferred-job-scheduler.sh"

_DJ_ARG_AT=""
_DJ_ARG_AFTER=""
_DJ_ARG_NAME=""
_DJ_ARG_DIR=""
_DJ_ARG_PROMPT_FILE=""
_DJ_ARG_ISSUE=""
_DJ_ARG_REPO=""
_DJ_ARG_WORKTREE=""
_DJ_ARG_BRANCH=""
_DJ_ARG_AGENT="Build+"
_DJ_ARG_TIER=""
_DJ_ARG_MODEL=""
_DJ_ARG_TITLE=""

print_usage() {
	cat <<'EOF'
deferred-job-helper.sh - Durable one-shot scheduling

Usage:
  aidevops schedule once (--at ISO-UTC | --after DURATION) --name NAME --dir PATH \
      (--prompt-file PATH | --issue N --repo OWNER/REPO) [options]
  aidevops schedule status [JOB_ID] [--json]
  aidevops schedule cancel JOB_ID

Options for once:
  --at ISO-UTC       Exact UTC timestamp, for example 2026-07-22T08:30:00Z
  --after DURATION   Relative delay using s, m, h, or d, for example 30m or 13h
  --name NAME        Private operator label shown by status
  --dir PATH         Dispatch working directory
  --prompt-file PATH Copy prompt into private state; prompt text is never stored in job JSON
  --issue N          GitHub issue number (requires --repo)
  --repo OWNER/REPO  Repository scope for issue work
  --worktree PATH    Existing issue worktree; otherwise canonical manual dispatch is used
  --branch NAME      Expected worktree branch, or manual-dispatch base ref
  --agent NAME       Agent name (default: Build+)
  --tier TIER        simple, standard, or thinking
  --model MODEL      Optional exact model override
  --title TITLE      Session title

Runner and maintenance commands:
  deferred-job-helper.sh run-due
  deferred-job-helper.sh install
  deferred-job-helper.sh uninstall [--purge]
  deferred-job-helper.sh prune [--days N]
  deferred-job-helper.sh render-scheduler [launchd|systemd|cron|all]

State is versioned and private under ~/.aidevops/.agent-workspace/scheduled/.
One launchd, systemd, or cron owner calls run-due; no per-job sleeper is created.
EOF
	return 0
}

_dj_reset_once_args() {
	_DJ_ARG_AT=""
	_DJ_ARG_AFTER=""
	_DJ_ARG_NAME=""
	_DJ_ARG_DIR=""
	_DJ_ARG_PROMPT_FILE=""
	_DJ_ARG_ISSUE=""
	_DJ_ARG_REPO=""
	_DJ_ARG_WORKTREE=""
	_DJ_ARG_BRANCH=""
	_DJ_ARG_AGENT="Build+"
	_DJ_ARG_TIER=""
	_DJ_ARG_MODEL=""
	_DJ_ARG_TITLE=""
	return 0
}

_dj_parse_once_args() {
	local arg=""
	local value=""
	_dj_reset_once_args
	while [[ $# -gt 0 ]]; do
		arg="$1"
		shift
		case "$arg" in
		--at | --after | --name | --dir | --prompt-file | --issue | --repo | --worktree | --branch | --agent | --tier | --model | --title)
			if [[ $# -eq 0 || -z "${1:-}" ]]; then
				printf 'ERROR: %s requires a value\n' "$arg" >&2
				return 2
			fi
			value="$1"
			shift
			case "$arg" in
			--at) _DJ_ARG_AT="$value" ;;
			--after) _DJ_ARG_AFTER="$value" ;;
			--name) _DJ_ARG_NAME="$value" ;;
			--dir) _DJ_ARG_DIR="$value" ;;
			--prompt-file) _DJ_ARG_PROMPT_FILE="$value" ;;
			--issue) _DJ_ARG_ISSUE="$value" ;;
			--repo) _DJ_ARG_REPO="$value" ;;
			--worktree) _DJ_ARG_WORKTREE="$value" ;;
			--branch) _DJ_ARG_BRANCH="$value" ;;
			--agent) _DJ_ARG_AGENT="$value" ;;
			--tier) _DJ_ARG_TIER="$value" ;;
			--model) _DJ_ARG_MODEL="$value" ;;
			--title) _DJ_ARG_TITLE="$value" ;;
			esac
			;;
		--help | -h)
			print_usage
			return 100
			;;
		*)
			printf 'ERROR: unknown schedule once option: %s\n' "$arg" >&2
			return 2
			;;
		esac
	done
	return 0
}

_dj_validate_once_common() {
	local canonical_dir=""
	local canonical_worktree=""
	local actual_slug=""
	if [[ -n "$_DJ_ARG_AT" && -n "$_DJ_ARG_AFTER" ]] || [[ -z "$_DJ_ARG_AT" && -z "$_DJ_ARG_AFTER" ]]; then
		printf 'ERROR: exactly one of --at or --after is required\n' >&2
		return 2
	fi
	if [[ ! "$_DJ_ARG_NAME" =~ ^[A-Za-z0-9][A-Za-z0-9._[:space:]-]{0,79}$ || "$_DJ_ARG_NAME" == *$'\n'* ]]; then
		printf 'ERROR: --name must be 1-80 safe printable characters\n' >&2
		return 2
	fi
	canonical_dir=$(_dj_canonical_dir "$_DJ_ARG_DIR" 2>/dev/null || true)
	if [[ -z "$canonical_dir" ]]; then
		printf 'ERROR: --dir must be an existing directory\n' >&2
		return 2
	fi
	_DJ_ARG_DIR="$canonical_dir"
	if [[ -n "$_DJ_ARG_PROMPT_FILE" && -n "$_DJ_ARG_ISSUE" ]] || [[ -z "$_DJ_ARG_PROMPT_FILE" && -z "$_DJ_ARG_ISSUE" ]]; then
		printf 'ERROR: exactly one of --prompt-file or --issue is required\n' >&2
		return 2
	fi
	if [[ -n "$_DJ_ARG_TIER" && ! "$_DJ_ARG_TIER" =~ ^(simple|standard|thinking)$ ]]; then
		printf 'ERROR: --tier must be simple, standard, or thinking\n' >&2
		return 2
	fi
	if [[ -n "$_DJ_ARG_MODEL" && ! "$_DJ_ARG_MODEL" =~ ^[A-Za-z0-9._:/-]+$ ]]; then
		printf 'ERROR: --model contains unsupported characters\n' >&2
		return 2
	fi
	if [[ -n "$_DJ_ARG_TITLE" && "$_DJ_ARG_TITLE" == *$'\n'* ]]; then
		printf 'ERROR: --title must not contain newlines\n' >&2
		return 2
	fi
	if [[ -n "$_DJ_ARG_WORKTREE" ]]; then
		[[ -n "$_DJ_ARG_ISSUE" ]] || {
			printf 'ERROR: --worktree is valid only with --issue\n' >&2
			return 2
		}
		canonical_worktree=$(_dj_canonical_dir "$_DJ_ARG_WORKTREE" 2>/dev/null || true)
		if [[ -z "$canonical_worktree" || "$canonical_worktree" != "$_DJ_ARG_DIR" ]]; then
			printf 'ERROR: --dir and --worktree must identify the same existing worktree\n' >&2
			return 2
		fi
		git -C "$canonical_worktree" rev-parse --is-inside-work-tree >/dev/null 2>&1 || {
			printf 'ERROR: --worktree is not a Git worktree\n' >&2
			return 2
		}
		actual_slug=$(_dj_origin_slug "$canonical_worktree" 2>/dev/null || true)
		if [[ -z "$actual_slug" || "$actual_slug" != "$_DJ_ARG_REPO" ]]; then
			printf 'ERROR: --worktree origin does not match --repo\n' >&2
			return 2
		fi
		_DJ_ARG_WORKTREE="$canonical_worktree"
		if [[ -z "$_DJ_ARG_BRANCH" ]]; then
			_DJ_ARG_BRANCH=$(git -C "$canonical_worktree" branch --show-current 2>/dev/null || true)
		fi
	fi
	return 0
}

_dj_validate_once_payload() {
	local prompt_size=0
	local guard_helper="${SCRIPT_DIR}/prompt-guard-helper.sh"
	if [[ -n "$_DJ_ARG_PROMPT_FILE" ]]; then
		if [[ ! -f "$_DJ_ARG_PROMPT_FILE" || ! -r "$_DJ_ARG_PROMPT_FILE" ]]; then
			printf 'ERROR: --prompt-file must be a readable regular file\n' >&2
			return 2
		fi
		prompt_size=$(wc -c <"$_DJ_ARG_PROMPT_FILE" | tr -d '[:space:]')
		if [[ ! "$prompt_size" =~ ^[0-9]+$ || "$prompt_size" -eq 0 || "$prompt_size" -gt 1048576 ]]; then
			printf 'ERROR: --prompt-file must contain 1 to 1048576 bytes\n' >&2
			return 2
		fi
		if [[ -x "$guard_helper" ]] && ! "$guard_helper" scan-file "$_DJ_ARG_PROMPT_FILE" >/dev/null 2>&1; then
			printf 'ERROR: prompt safety scan failed\n' >&2
			return 1
		fi
		return 0
	fi
	if [[ ! "$_DJ_ARG_ISSUE" =~ ^[1-9][0-9]*$ ]]; then
		printf 'ERROR: --issue must be a positive integer\n' >&2
		return 2
	fi
	if [[ ! "$_DJ_ARG_REPO" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]]; then
		printf 'ERROR: --repo must use OWNER/REPO format\n' >&2
		return 2
	fi
	return 0
}

_dj_resolve_due_time() {
	local now_epoch="$1"
	local due_epoch=0
	local delay_seconds=0
	if [[ -n "$_DJ_ARG_AT" ]]; then
		due_epoch=$(_dj_iso_to_epoch "$_DJ_ARG_AT" 2>/dev/null || true)
		if [[ -z "$due_epoch" ]]; then
			printf 'ERROR: --at must be an exact UTC timestamp such as 2026-07-22T08:30:00Z\n' >&2
			return 2
		fi
	else
		delay_seconds=$(_dj_parse_duration "$_DJ_ARG_AFTER" 2>/dev/null || true)
		if [[ -z "$delay_seconds" ]]; then
			printf 'ERROR: --after must be a positive duration such as 30m, 13h, or 2d\n' >&2
			return 2
		fi
		due_epoch=$((now_epoch + delay_seconds))
	fi
	printf '%s\n' "$due_epoch"
	return 0
}

_dj_prepare_private_prompt() {
	local job_id="$1"
	local dispatch_kind="$2"
	local prompt_path=""
	prompt_path=$(_dj_prompt_file "$job_id")
	if [[ "$dispatch_kind" == "issue-manual" ]]; then
		printf '%s\n' ""
		return 0
	fi
	if [[ -n "$_DJ_ARG_PROMPT_FILE" ]]; then
		cp "$_DJ_ARG_PROMPT_FILE" "$prompt_path" || return 1
	else
		printf '/full-loop Implement issue #%s in %s from the pre-created worktree. Drive autonomously through verified completion.\n' \
			"$_DJ_ARG_ISSUE" "$_DJ_ARG_REPO" >"$prompt_path"
	fi
	chmod 600 "$prompt_path"
	printf '%s\n' "$prompt_path"
	return 0
}

_dj_build_job_json() {
	local job_id="$1"
	local dispatch_kind="$2"
	local due_epoch="$3"
	local prompt_ref="$4"
	local prompt_digest="$5"
	local now_epoch="$6"
	local now_iso=""
	local due_iso=""
	local producer_version=""
	local title="$_DJ_ARG_TITLE"
	now_iso=$(_dj_epoch_to_iso "$now_epoch") || return 1
	due_iso=$(_dj_epoch_to_iso "$due_epoch") || return 1
	producer_version=$(_dj_producer_version)
	[[ -n "$title" ]] || title="Deferred job: ${_DJ_ARG_NAME}"
	jq -n \
		--argjson schema_version "$_DJ_SCHEMA_VERSION" \
		--arg producer_version "$producer_version" \
		--arg id "$job_id" \
		--arg name "$_DJ_ARG_NAME" \
		--arg created_at "$now_iso" \
		--argjson created_epoch "$now_epoch" \
		--arg due_at "$due_iso" \
		--argjson due_epoch "$due_epoch" \
		--arg session_key "deferred-${job_id}" \
		--arg kind "$dispatch_kind" \
		--arg dir "$_DJ_ARG_DIR" \
		--arg prompt_ref "$prompt_ref" \
		--arg prompt_sha256 "$prompt_digest" \
		--arg issue "$_DJ_ARG_ISSUE" \
		--arg repo "$_DJ_ARG_REPO" \
		--arg worktree "$_DJ_ARG_WORKTREE" \
		--arg branch "$_DJ_ARG_BRANCH" \
		--arg agent "$_DJ_ARG_AGENT" \
		--arg tier "$_DJ_ARG_TIER" \
		--arg model "$_DJ_ARG_MODEL" \
		--arg title "$title" \
		'{schema_version:$schema_version,producer_version:$producer_version,id:$id,name:$name,
		  created_at:$created_at,created_epoch:$created_epoch,due_at:$due_at,due_epoch:$due_epoch,
		  status:"queued",claimed_at:null,started_at:null,finished_at:null,finished_epoch:null,
		  attempt:0,recovery_count:0,lease:{id:null,expires_epoch:null},runner_pid:null,pid:null,
		  session_key:$session_key,outcome:null,error:null,duration_seconds:null,
		  dispatch:{kind:$kind,dir:$dir,prompt_ref:(if $prompt_ref == "" then null else $prompt_ref end),
		    prompt_sha256:(if $prompt_sha256 == "" then null else $prompt_sha256 end),
		    issue:(if $issue == "" then null else ($issue|tonumber) end),
		    repo:(if $repo == "" then null else $repo end),
		    worktree:(if $worktree == "" then null else $worktree end),
		    branch:(if $branch == "" then null else $branch end),agent:$agent,
		    tier:(if $tier == "" then null else $tier end),model:(if $model == "" then null else $model end),title:$title}}'
	return $?
}

cmd_once() {
	local parse_rc=0
	local now_epoch=0
	local due_epoch=0
	local job_id=""
	local dispatch_kind="prompt"
	local prompt_path=""
	local prompt_ref=""
	local prompt_digest=""
	local job_file=""
	local job_json=""
	_dj_parse_once_args "$@" || parse_rc=$?
	[[ "$parse_rc" -ne 100 ]] || return 0
	[[ "$parse_rc" -eq 0 ]] || return "$parse_rc"
	_dj_validate_once_common || return $?
	_dj_validate_once_payload || return $?
	now_epoch=$(_dj_now_epoch)
	due_epoch=$(_dj_resolve_due_time "$now_epoch") || return $?
	if [[ -n "$_DJ_ARG_ISSUE" ]]; then
		if [[ -n "$_DJ_ARG_WORKTREE" ]]; then
			dispatch_kind="issue-worktree"
		else
			dispatch_kind="issue-manual"
		fi
	fi
	_dj_init_storage || return 1
	_dj_acquire_lock || return 1
	job_id="dj-$(date -u '+%Y%m%dT%H%M%SZ')-$$-${RANDOM}"
	job_file=$(_dj_job_file "$job_id")
	if [[ -e "$job_file" ]]; then
		_dj_release_lock
		printf 'ERROR: deferred-job ID collision; retry creation\n' >&2
		return 1
	fi
	prompt_path=$(_dj_prepare_private_prompt "$job_id" "$dispatch_kind") || {
		_dj_release_lock
		return 1
	}
	if [[ -n "$prompt_path" ]]; then
		prompt_ref="prompts/${job_id}.prompt"
		prompt_digest=$(_dj_sha256 "$prompt_path") || {
			rm -f "$prompt_path"
			_dj_release_lock
			return 1
		}
	fi
	job_json=$(_dj_build_job_json "$job_id" "$dispatch_kind" "$due_epoch" "$prompt_ref" "$prompt_digest" "$now_epoch") || {
		rm -f "$prompt_path"
		_dj_release_lock
		return 1
	}
	if ! _dj_atomic_write_json "$job_file" "$job_json"; then
		rm -f "$prompt_path"
		_dj_release_lock
		return 1
	fi
	_dj_append_event "$job_id" "queued" "created" || true
	_dj_release_lock
	printf 'Queued %s | %s | due %s\n' "$job_id" "$_DJ_ARG_NAME" "$(_dj_epoch_to_iso "$due_epoch")"
	return 0
}

_dj_public_job_json() {
	local job_json="$1"
	if ! _dj_schema_supported "$job_json"; then
		printf '%s\n' "$job_json" | jq -c '{id:(.id // "unknown"),schema_version:(.schema_version // 0),status:"unsupported-schema"}'
		return 0
	fi
	printf '%s\n' "$job_json" | jq -c \
		'{id,name,due_at,status,created_at,claimed_at,started_at,finished_at,attempt,recovery_count,duration_seconds,outcome,error}'
	return 0
}

_dj_print_public_job() {
	local public_json="$1"
	printf '%s\n' "$public_json" | jq -r '[.id,.name,.due_at,.status,(.outcome // "-")] | @tsv'
	return 0
}

cmd_status() {
	local job_id=""
	local json_output=0
	local arg=""
	local job_file=""
	local job_json=""
	local public_json=""
	local first=1
	while [[ $# -gt 0 ]]; do
		arg="$1"
		shift
		case "$arg" in
		--json) json_output=1 ;;
		--*)
			printf 'ERROR: unknown status option: %s\n' "$arg" >&2
			return 2
			;;
		*)
			[[ -z "$job_id" ]] || {
				printf 'ERROR: status accepts at most one JOB_ID\n' >&2
				return 2
			}
			job_id="$arg"
			;;
		esac
	done
	_dj_init_storage || return 1
	if [[ -n "$job_id" ]]; then
		_dj_valid_job_id "$job_id" || {
			printf 'ERROR: invalid deferred-job ID\n' >&2
			return 2
		}
		job_file=$(_dj_job_file "$job_id")
		job_json=$(_dj_read_job "$job_file" 2>/dev/null || true)
		[[ -n "$job_json" ]] || {
			printf 'ERROR: deferred job not found: %s\n' "$job_id" >&2
			return 1
		}
		public_json=$(_dj_public_job_json "$job_json")
		if [[ "$json_output" -eq 1 ]]; then
			printf '%s\n' "$public_json"
		else
			printf 'ID\tNAME\tDUE (UTC)\tSTATUS\tOUTCOME\n'
			_dj_print_public_job "$public_json"
		fi
		return 0
	fi
	if [[ "$json_output" -eq 1 ]]; then
		printf '['
	fi
	for job_file in "$_DJ_JOBS_DIR"/*.json; do
		[[ -e "$job_file" ]] || continue
		job_json=$(_dj_read_job "$job_file" 2>/dev/null || true)
		[[ -n "$job_json" ]] || continue
		public_json=$(_dj_public_job_json "$job_json")
		if [[ "$json_output" -eq 1 ]]; then
			[[ "$first" -eq 1 ]] || printf ','
			printf '%s' "$public_json"
			first=0
		else
			if [[ "$first" -eq 1 ]]; then
				printf 'ID\tNAME\tDUE (UTC)\tSTATUS\tOUTCOME\n'
			fi
			_dj_print_public_job "$public_json"
			first=0
		fi
	done
	if [[ "$json_output" -eq 1 ]]; then
		printf ']\n'
	elif [[ "$first" -eq 1 ]]; then
		printf 'No scheduled jobs.\n'
	fi
	return 0
}

main() {
	local command="${1:-help}"
	shift || true
	case "$command" in
	once | create) cmd_once "$@" ;;
	status | list) cmd_status "$@" ;;
	cancel) cmd_cancel "$@" ;;
	run-due) cmd_run_due "$@" ;;
	install) cmd_install_scheduler "$@" ;;
	uninstall) cmd_uninstall_scheduler "$@" ;;
	prune) cmd_prune "$@" ;;
	render-scheduler) cmd_render_scheduler "$@" ;;
	help | --help | -h) print_usage ;;
	*)
		printf 'ERROR: unknown deferred-job command: %s\n' "$command" >&2
		print_usage >&2
		return 2
		;;
	esac
	return $?
}

main "$@"
