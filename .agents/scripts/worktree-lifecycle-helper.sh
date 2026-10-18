#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
# Rootless entrypoint reusing the existing cleanup lock and scheduler installer.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=shared-constants.sh
source "${SCRIPT_DIR}/shared-constants.sh"

install_lifecycle_scheduler() {
	local deployed="${HOME}/.aidevops/agents/scripts/worktree-lifecycle-helper.sh"
	local log_dir="${AIDEVOPS_LOG_DIR:-${HOME}/.aidevops/logs}"
	local command=""
	if [[ "${EUID}" -eq 0 || ! -f "$deployed" ]]; then
		printf '%s\n' 'Install from the deployed framework as an ordinary user; no sudo is supported.' >&2
		return 1
	fi
	# shellcheck source=setup/modules/schedulers-linux.sh
	source "${SCRIPT_DIR}/setup/modules/schedulers-linux.sh"
	_systemd_user_available || { printf '%s\n' 'User systemd is unavailable; no scheduler installed.' >&2; return 1; }
	mkdir -p "$log_dir"
	printf -v command '%q %q run' "$(command -v bash)" "$deployed"
	_install_scheduler_systemd "aidevops-worktree-lifecycle" "$command" "600" \
		"${log_dir}/cleanup_worktrees.log" "" "false" "true" "" "900" || return 1
	return 0
}

main() {
	local action="${1:-report}"
	case "$action" in
	report)
		shift || true
		python3 "${SCRIPT_DIR}/worktree_lifecycle_status.py" report "$@" || return 1
		;;
	reconcile)
		timeout_sec 90 python3 "${SCRIPT_DIR}/worktree_lifecycle_status.py" reconcile || return 1
		;;
	run)
		# Scheduling cleanup is never implicit authority to expire recovery copies.
		timeout_sec 840 bash "${SCRIPT_DIR}/cleanup-worktrees-async-helper.sh" --lifecycle-only || return 1
		python3 "${SCRIPT_DIR}/worktree_lifecycle_status.py" report --summary || return 1
		;;
	install-scheduler) install_lifecycle_scheduler || return 1 ;;
	*) printf '%s\n' 'Usage: worktree-lifecycle-helper.sh [report [--summary]|reconcile|run|install-scheduler]' >&2; return 1 ;;
	esac
	return 0
}

main "$@"
