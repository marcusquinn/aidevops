#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
# Managed enrichment producer. Exec preserves the invocation leader's PID;
# archival runs only in the separate callback after all descendants drain.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=shared-constants.sh
source "${SCRIPT_DIR}/shared-constants.sh"
# shellcheck source=pulse-quality-debt.sh
source "${SCRIPT_DIR}/pulse-quality-debt.sh"

run_enrichment() {
	local prompt_file="$1"
	local issue_number="$2"
	local repo_slug="$3"
	local repo_path="$4"
	local model="$5"
	local session_key="$6"
	local worktree_path=""
	[[ "${AIDEVOPS_MANAGED_WORKTREE_RUN:-0}" == 1 && -n "${INVOCATION_ID:-}" ]] || return 2
	worktree_path=$(_enrichment_prepare_worktree "$repo_path" "$issue_number" "$session_key") || return 2
	exec env WORKER_ISSUE_NUMBER="$issue_number" WORKER_REPO_SLUG="$repo_slug" \
		WORKER_WORKTREE_PATH="$worktree_path" "$HEADLESS_RUNTIME_HELPER" run \
		--role worker --session-key "$session_key" --dir "$worktree_path" \
		--model "$model" --title "Enrichment analysis: Issue #${issue_number}" \
		--prompt-file "$prompt_file"
	return 1
}

main() {
	local action="${1:-}"
	local status=0
	shift || return 2
	case "$action:$#" in
	run:6)
		run_enrichment "$@" || status=$?
		;;
	cleanup:2)
		[[ "${AIDEVOPS_MANAGED_WORKTREE_RUN:-1}" == 0 ]] || return 2
		_enrichment_release_worktree "$@" || status=$?
		;;
	*) status=2 ;;
	esac
	[[ "$status" -eq 0 ]] || return "$status"
	return 0
}

main "$@"
