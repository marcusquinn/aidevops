#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
CRYPTO_HELPER="${SCRIPT_DIR}/vault-crypto-helper.py"

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
  export|import|rekey     Reserved placeholders; fail safely until sync/rekey ships
  read <name>             Read an entry through the unlocked broker
  update <name>           Read a new entry value from stdin and encrypt it
  change-passphrase       Rewrap the root key through hidden TTY prompts
  help                    Show this help

Passphrases are never accepted in CLI arguments, environment variables, or
non-TTY stdin. Set AIDEVOPS_VAULT_DIR only to relocate Vault files.
EOF
	return 0
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
	init | unlock | lock | status | setup-state | read | update | change-passphrase | lost-passphrase | export | import | rekey)
		shift || true
		require_crypto_helper || return 1
		python3 "$CRYPTO_HELPER" "$command" "$@"
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
