#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
# shellcheck source=.agents/scripts/runtime-registry.sh
source "${SCRIPT_DIR}/runtime-registry.sh"

usage() {
	cat <<'EOF'
Usage: vault-managed-session-history-helper.sh <command> <runtime>

Commands:
  mode <runtime>          Print managed, unmanaged, external, or none
  path <runtime>          Print the Vault-managed session/history path
  require-read <runtime>  Gate a managed session/history read

Set AIDEVOPS_VAULT_MANAGED_SESSION_HISTORY=1 to require the Vault boundary.
Passphrases are never accepted here; unlock must happen through vault-helper.sh.
EOF
	return 0
}

vault_history_enabled() {
	[[ "${AIDEVOPS_VAULT_MANAGED_SESSION_HISTORY:-}" == "1" || "${AIDEVOPS_VAULT_MANAGED_SESSION_HISTORY:-}" == "true" ]]
	return $?
}

vault_status() {
	local helper="${AIDEVOPS_VAULT_HELPER:-${SCRIPT_DIR}/vault-helper.sh}"
	if [[ -n "${AIDEVOPS_VAULT_STATUS_OVERRIDE:-}" ]]; then
		printf '%s\n' "$AIDEVOPS_VAULT_STATUS_OVERRIDE"
		return 0
	fi
	if [[ ! -x "$helper" ]]; then
		printf '%s\n' "missing"
		return 1
	fi
	"$helper" status 2>/dev/null
	return $?
}

require_managed_read() {
	local runtime="$1"
	local mode status path
	mode=$(rt_vault_session_history_mode "$runtime") || {
		printf '%s\n' "VAULT_UNSUPPORTED_RUNTIME: unknown runtime '$runtime'" >&2
		return 2
	}
	if ! vault_history_enabled; then
		rt_session_db "$runtime"
		return 0
	fi
	case "$mode" in
	managed)
		status=$(vault_status || true)
		if [[ "$status" != "unlocked" ]]; then
			printf '%s\n' "VAULT_LOCKED: managed session/history for '$runtime' requires an unlocked Vault" >&2
			return 1
		fi
		path=$(rt_vault_session_history_path "$runtime") || return 1
		printf '%s\n' "$path"
		return 0
		;;
	unmanaged | external | none)
		printf '%s\n' "VAULT_UNSUPPORTED_RUNTIME: '$runtime' session/history is ${mode}; Vault cannot guarantee protection for this cache" >&2
		return 2
		;;
	*)
		printf '%s\n' "VAULT_UNSUPPORTED_RUNTIME: '$runtime' has unknown Vault mode '$mode'" >&2
		return 2
		;;
	esac
}

main() {
	local command="${1:-help}"
	local runtime="${2:-}"
	case "$command" in
	help | --help | -h)
		usage
		return 0
		;;
	mode)
		if [[ -z "$runtime" ]]; then
			usage >&2
			return 2
		fi
		rt_vault_session_history_mode "$runtime"
		return $?
		;;
	path)
		if [[ -z "$runtime" ]]; then
			usage >&2
			return 2
		fi
		rt_vault_session_history_path "$runtime"
		return $?
		;;
	require-read)
		if [[ -z "$runtime" ]]; then
			usage >&2
			return 2
		fi
		require_managed_read "$runtime"
		return $?
		;;
	*)
		usage >&2
		return 2
		;;
	esac
}

main "$@"
