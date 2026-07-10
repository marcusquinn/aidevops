#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
CRYPTO_HELPER="${SCRIPT_DIR}/vault-crypto-helper.py"
VAULT_AUDIT_HELPER="${SCRIPT_DIR}/vault-audit-helper.sh"
VAULT_RUNTIME_CHECK="${SCRIPT_DIR}/vault-runtime-check.py"
VAULT_RUNTIME_PYTHON="${HOME}/.aidevops/.agent-workspace/python-env/vault/bin/python3"

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
	local python_bin=""
	python_bin=$(resolve_vault_python 2>/dev/null || true)
	local python_path="${PATH}"
	[[ -n "$python_bin" ]] && python_path="${python_bin%/*}:${PATH}"
	if PATH="$python_path" "$VAULT_AUDIT_HELPER" append \
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

resolve_vault_python() {
	local managed_python="$VAULT_RUNTIME_PYTHON"
	if [[ "${AIDEVOPS_VAULT_TEST_MODE:-0}" == "1" && -n "${AIDEVOPS_VAULT_PYTHON:-}" ]]; then
		managed_python="$AIDEVOPS_VAULT_PYTHON"
	fi
	if [[ -x "$managed_python" ]] && vault_python_ready "$managed_python"; then
		printf '%s\n' "$managed_python"
		return 0
	fi
	printf '%s\n' "[ERROR] Vault crypto runtime is unavailable; run aidevops setup" >&2
	return 1
}

vault_python_ready() {
	local python_bin="$1"
	[[ -f "$VAULT_RUNTIME_CHECK" ]] || return 1
	"$python_bin" "$VAULT_RUNTIME_CHECK" >/dev/null 2>&1
	local rc=$?
	return "$rc"
}

vault_path_permissions_safe() {
	local path="$1"
	local mode=""
	local os_name=""
	local group_digit=""
	local other_digit=""

	[[ -e "$path" && ! -L "$path" && -O "$path" ]] || return 1
	os_name="$(/usr/bin/uname -s)"
	if [[ "$os_name" == "Darwin" ]]; then
		mode="$(/usr/bin/stat -f '%Lp' "$path" 2>/dev/null)" || return 1
	else
		mode="$(/usr/bin/stat -c '%a' "$path" 2>/dev/null)" || return 1
	fi
	[[ "$mode" =~ ^[0-7]{3,4}$ ]] || return 1
	mode="${mode:$((${#mode} - 3))}"
	group_digit="${mode:1:1}"
	other_digit="${mode:2:1}"
	case "$group_digit$other_digit" in
	[0145][0145]) return 0 ;;
	esac
	return 1
}

vault_managed_status_python_safe() {
	local python_bin="$1"
	local env_dir="${VAULT_RUNTIME_PYTHON%/bin/python3}"
	local marker="${env_dir}/.aidevops-managed-runtime"
	local marker_value=""
	local path=""

	[[ "$python_bin" == "$VAULT_RUNTIME_PYTHON" && -f "$marker" && ! -L "$marker" ]] || return 1
	marker_value=$(<"$marker")
	[[ "$marker_value" == "aidevops-vault-runtime-v1" ]] || return 1
	for path in \
		"${HOME}/.aidevops" \
		"${HOME}/.aidevops/.agent-workspace" \
		"${HOME}/.aidevops/.agent-workspace/python-env" \
		"$env_dir" \
		"${env_dir}/bin" \
		"$python_bin" \
		"$marker"; do
		vault_path_permissions_safe "$path" || return 1
	done
	for path in "${env_dir}"/lib/python*/site-packages; do
		[[ -e "$path" ]] || continue
		vault_path_permissions_safe "$path" || return 1
	done
	return 0
}

resolve_status_python() {
	local managed_python="$VAULT_RUNTIME_PYTHON"
	if [[ "${AIDEVOPS_VAULT_TEST_MODE:-0}" == "1" && -n "${AIDEVOPS_VAULT_PYTHON:-}" ]]; then
		printf '%s\n' "$AIDEVOPS_VAULT_PYTHON"
		return 0
	fi
	if [[ -x "$managed_python" ]] && vault_managed_status_python_safe "$managed_python"; then
		printf '%s\n' "$managed_python"
		return 0
	fi
	if [[ -x "/usr/bin/python3" ]]; then
		printf '%s\n' "/usr/bin/python3"
		return 0
	fi
	printf '%s\n' "[ERROR] Vault requires Python 3; run aidevops setup" >&2
	return 1
}

run_crypto_command() {
	local command_name="$1"
	shift || true
	local python_bin=""
	python_bin=$(resolve_vault_python) || return 1
	PATH="${python_bin%/*}:${PATH}" "$python_bin" "$CRYPTO_HELPER" "$command_name" "$@"
	local rc=$?
	return "$rc"
}

run_with_audit() {
	local command_name="$1"
	shift || true
	audit_vault_event "$command_name" "attempt" "vault command attempted" || return 1
	set +e
	run_crypto_command "$command_name" "$@"
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
	local python_bin=""
	python_bin=$(resolve_vault_python) || return 1
	PATH="${python_bin%/*}:${PATH}" "$SCRIPT_DIR/vault-sync-helper.sh" "$command_name" "$@"
	local rc=$?
	set -e
	if [[ "$rc" -eq 0 ]]; then
		audit_vault_event "$command_name" "success" "vault sync command completed" || return 1
	else
		audit_vault_event "$command_name" "failure" "vault sync command failed" || true
	fi
	return "$rc"
}

run_read_only() {
	local command_name="$1"
	shift || true
	local python_bin=""
	python_bin=$(resolve_status_python) || return 1
	"$python_bin" "$CRYPTO_HELPER" "$command_name" "$@"
	local rc=$?
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
	status | setup-state)
		shift || true
		require_crypto_helper || return 1
		run_read_only "$command" "$@"
		return $?
		;;
	init | unlock | lock | read | update | change-passphrase | lost-passphrase)
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
		local python_bin=""
		python_bin=$(resolve_vault_python) || return 1
		PATH="${python_bin%/*}:${PATH}" "$VAULT_AUDIT_HELPER" "$@"
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
