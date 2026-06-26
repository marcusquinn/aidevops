#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
CRYPTO_HELPER="${SCRIPT_DIR}/vault-crypto-helper.py"
VAULT_AUDIT_HELPER="${SCRIPT_DIR}/vault-audit-helper.sh"

usage() {
	cat <<'EOF'
Usage: vault-helper.sh <command> [options]

Commands:
  init [--force]          Create local Vault metadata and harmless restart test
  unlock                  Unlock into an in-memory local broker through a hidden TTY prompt
  lock                    Stop the local broker and forget in-memory keys
  status                  Print uninitialized, locked, unlocked, or corrupted
  setup-state             Print the first-use setup state
  lost-passphrase         Show safe recovery options
  lost-passphrase archive-and-start-fresh
                          Archive encrypted Vault files intact and reset setup
  export|import|rekey     Encrypted sync export/import and local passphrase rekey
  read <name>             Read an entry through the unlocked broker
  update <name>           Read a new entry value from stdin and encrypt it
  change-passphrase       Rewrap the root key through hidden TTY prompts
  audit <subcommand>       Manage tamper-evident encrypted Vault audit events
  help                    Show this help

Passphrases are never accepted in CLI arguments, environment variables, or
non-TTY stdin. Set AIDEVOPS_VAULT_DIR only to relocate Vault files.
EOF
	return 0
}

audit_vault_event() {
	local action="$1"
	local result="$2"
	local reason="$3"
	local safe_action="$action"
	case "$safe_action" in
		change-passphrase) safe_action="change-credential" ;;
		lost-passphrase) safe_action="recovery-guidance" ;;
	esac
	if [[ ! -x "$VAULT_AUDIT_HELPER" ]]; then
		printf '%s\n' "[WARN] Vault audit helper is unavailable" >&2
		[[ "${AIDEVOPS_VAULT_AUDIT_REQUIRE:-0}" == "1" ]] && return 1
		return 0
	fi
	if "$VAULT_AUDIT_HELPER" append \
		--actor "${USER:-local}" \
		--action "vault.$safe_action" \
		--target-collection "vault" \
		--result "$result" \
		--session-id "${AIDEVOPS_SESSION_ID:-none}" \
		--reason "$reason" >/dev/null; then
		return 0
	fi
	printf '%s\n' "[WARN] Vault audit event could not be written" >&2
	[[ "${AIDEVOPS_VAULT_AUDIT_REQUIRE:-0}" == "1" ]] && return 1
	return 0
}

run_with_audit() {
	local command_name="$1"
	shift || true
	audit_vault_event "$command_name" "attempt" "vault command attempted" || return 1
	set +e
	python3 "$CRYPTO_HELPER" "$command_name" "$@"
	local rc=$?
	set -e
	if [[ "$rc" -eq 0 ]]; then
		audit_vault_event "$command_name" "success" "vault command completed" || return 1
	else
		audit_vault_event "$command_name" "failure" "vault command failed" || true
	fi
	return "$rc"
}

run_sync_with_audit() {
	local command_name="$1"
	shift || true
	audit_vault_event "$command_name" "attempt" "vault sync command attempted" || return 1
	set +e
	"$SCRIPT_DIR/vault-sync-helper.sh" "$command_name" "$@"
	local rc=$?
	set -e
	if [[ "$rc" -eq 0 ]]; then
		audit_vault_event "$command_name" "success" "vault sync command completed" || return 1
	else
		audit_vault_event "$command_name" "failure" "vault sync command failed" || true
	fi
	return "$rc"
}

require_crypto_helper() {
	if [[ ! -x "$CRYPTO_HELPER" ]]; then
		printf '%s\n' "[ERROR] Missing executable crypto helper: $CRYPTO_HELPER" >&2
		return 1
	fi
	return 0
}

main() {
	local command="${1:-help}"
	case "$command" in
	help | --help | -h)
		usage
		return 0
		;;
	init | unlock | lock | status | setup-state | read | update | change-passphrase | lost-passphrase)
		shift || true
		require_crypto_helper || return 1
		run_with_audit "$command" "$@"
		return $?
		;;
	export | import | rekey)
		shift || true
		run_sync_with_audit "$command" "$@"
		return $?
		;;
	audit)
		shift || true
		"$VAULT_AUDIT_HELPER" "$@"
		return $?
		;;
	*)
		printf '%s\n' "[ERROR] Unknown Vault command: $command" >&2
		usage >&2
		return 2
		;;
	esac
}

main "$@"
