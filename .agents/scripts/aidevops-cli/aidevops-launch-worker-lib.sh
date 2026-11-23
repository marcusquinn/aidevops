#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# =============================================================================
# aidevops Launch Worker Library
# =============================================================================
# launch-worker command functions, extracted from aidevops.sh.
#
# Usage: source "${AIDEVOPS_CLI_MODULES_DIR}/aidevops-launch-worker-lib.sh"
# Part of aidevops framework: https://aidevops.sh


# Include guard
[[ -n "${_AIDEVOPS_LAUNCH_WORKER_LIB_LOADED:-}" ]] && return 0
_AIDEVOPS_LAUNCH_WORKER_LIB_LOADED=1

_launch_worker_usage() {
	cat <<'EOF'
Usage: aidevops launch-worker <issue|issue,issue> [owner/repo] [options]
       aidevops launch-worker --batch <issue,issue> [owner/repo] [options]
       aidevops launch-worker status <issue> [owner/repo]

Launch one or more headless workers manually without waiting for the pulse.
If owner/repo is omitted, it defaults to the current git repository's origin.

Options:
  --model <id>      Override model (for example, anthropic/claude-opus-4-7).
  --agent <name>    Worker agent name (default: Build+).
  --batch <list>    Comma-separated issue numbers to launch.
  --dry-run         Print the planned dispatch without launching.
  --no-ceremony     Skip status/origin/assignee ceremony (debug only).
  -h, --help        Show this help.

Output includes the worker PID, worktree path, log path, session key, and a
status command for each launched issue.
EOF
	return 0
}

_launch_worker_default_repo() {
	local remote_url=""
	remote_url=$(git remote get-url origin 2>/dev/null || true)
	if [[ "$remote_url" =~ github\.com[:/]([^/]+/[^/.]+)(\.git)?$ ]]; then
		printf '%s\n' "${BASH_REMATCH[1]}"
		return 0
	fi
	return 1
}

_launch_worker_helper_path() {
	local source_dir helper_path
	source_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
	helper_path="$source_dir/.agents/scripts/dispatch-single-issue-helper.sh"
	[[ ! -f "$helper_path" ]] && helper_path="$INSTALL_DIR/.agents/scripts/dispatch-single-issue-helper.sh"
	[[ ! -f "$helper_path" ]] && helper_path="$AGENTS_DIR/scripts/dispatch-single-issue-helper.sh"
	if [[ ! -f "$helper_path" ]]; then
		print_error "dispatch-single-issue-helper.sh not found. Run: aidevops update"
		return 1
	fi
	printf '%s\n' "$helper_path"
	return 0
}

_launch_worker_status() {
	local status_issue="${1:-}"
	local status_repo="${2:-}"
	if [[ -z "$status_issue" ]]; then
		print_error "launch-worker status requires <issue> [owner/repo]"
		return 2
	fi
	if [[ -z "$status_repo" ]]; then
		status_repo=$(_launch_worker_default_repo) || {
			print_error "Could not infer owner/repo from git remote; pass it explicitly"
			return 2
		}
	fi
	local status_helper_path
	status_helper_path=$(_launch_worker_helper_path) || return 1
	bash "$status_helper_path" status "$status_issue" "$status_repo"
	return 0
}

cmd_launch_worker() {
	local sub_or_issue="${1:-}"
	if [[ -z "$sub_or_issue" || "$sub_or_issue" == "help" || "$sub_or_issue" == "--help" || "$sub_or_issue" == "-h" ]]; then
		_launch_worker_usage
		return 0
	fi

	if [[ "$sub_or_issue" == "status" ]]; then
		shift || true
		_launch_worker_status "$@"
		return $?
	fi

	local issue_spec=""
	local repo_slug=""
	local batch_spec=""
	local -a helper_opts=()
	while [[ $# -gt 0 ]]; do
		local arg="$1"
		case "$arg" in
		--batch)
			if [[ $# -lt 2 || -z "${2:-}" || "${2:-}" == --* ]]; then
				print_error "--batch requires a comma-separated issue list"
				return 2
			fi
			batch_spec="${2}"
			shift 2
			;;
		--model | --agent)
			if [[ $# -lt 2 || -z "${2:-}" || "${2:-}" == --* ]]; then
				print_error "$arg requires a value"
				return 2
			fi
			helper_opts+=("$arg" "${2}")
			shift 2
			;;
		--dry-run | --no-ceremony)
			helper_opts+=("$arg")
			shift
			;;
		--help | -h)
			_launch_worker_usage
			return 0
			;;
		--*)
			print_error "Unknown launch-worker flag: $arg"
			return 2
			;;
		*)
			if [[ -z "$issue_spec" ]]; then
				issue_spec="$arg"
			elif [[ -z "$repo_slug" ]]; then
				repo_slug="$arg"
			else
				print_error "Unexpected launch-worker argument: $arg"
				return 2
			fi
			shift
			;;
		esac
	done

	[[ -n "$batch_spec" ]] && issue_spec="$batch_spec"
	if [[ -z "$issue_spec" ]]; then
		print_error "launch-worker requires an issue number or --batch list"
		return 2
	fi
	if [[ -z "$repo_slug" ]]; then
		repo_slug=$(_launch_worker_default_repo) || {
			print_error "Could not infer owner/repo from git remote; pass it explicitly"
			return 2
		}
	fi
	if [[ ! "$repo_slug" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]]; then
		print_error "Repo slug must be owner/repo format: $repo_slug"
		return 2
	fi

	local old_ifs="$IFS"
	IFS=','
	local -a issues=()
	read -r -a issues <<<"$issue_spec"
	IFS="$old_ifs"

	local helper_path
	helper_path=$(_launch_worker_helper_path) || return 1

	local issue rc=0
	for issue in "${issues[@]}"; do
		if [[ ! "$issue" =~ ^[0-9]+$ ]]; then
			print_error "Issue number must be numeric: $issue"
			rc=2
			continue
		fi
		bash "$helper_path" dispatch "$issue" "$repo_slug" "${helper_opts[@]}" || rc=$?
		echo "Status: aidevops launch-worker status $issue $repo_slug"
	done
	return "$rc"
}
