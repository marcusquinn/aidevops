#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# =============================================================================
# approval-helper-commands.sh — Status and help commands for approval-helper.
# =============================================================================
# Sourced by approval-helper.sh to keep command-display concerns separate from
# approval signing, verification, and lifecycle behavior.

[[ "${BASH_SOURCE[0]}" == "${0}" ]] && set -euo pipefail

[[ -n "${_APPROVAL_HELPER_COMMANDS_LOADED:-}" ]] && return 0
_APPROVAL_HELPER_COMMANDS_LOADED=1

if [[ -z "${SCRIPT_DIR:-}" ]]; then
	_approval_commands_lib_path="${BASH_SOURCE[0]%/*}"
	[[ "$_approval_commands_lib_path" == "${BASH_SOURCE[0]}" ]] && _approval_commands_lib_path="."
	SCRIPT_DIR="$(cd "$_approval_commands_lib_path" && pwd)"
	unset _approval_commands_lib_path
fi

# GH#39027: printed approval commands need approval_cli_prefix even when this
# module is sourced without shared-constants.sh.
if ! declare -F approval_cli_prefix >/dev/null 2>&1; then
	# shellcheck source=./shared-approval-cli.sh
	source "$(dirname "${BASH_SOURCE[0]}")/shared-approval-cli.sh"
fi

_approval_commands_blank_line() {
	printf '\n'
	return 0
}

_approval_commands_setup_hint() {
	printf '  Run: %s approve setup\n' "$(approval_cli_prefix)"
	return 0
}

# ── Status ───────────────────────────────────────────────────────────────────

cmd_status() {
	_approval_commands_blank_line
	echo "Approval key status"
	echo "==================="
	_approval_commands_blank_line

	if [[ -f "$APPROVAL_PUB" ]]; then
		_print_ok "Public key exists: $APPROVAL_PUB"
		echo "  Fingerprint: $(ssh-keygen -lf "$APPROVAL_PUB" 2>/dev/null || echo "unknown")"
	else
		_print_warn "No approval public key found"
		_approval_commands_setup_hint
	fi

	_approval_commands_blank_line
	if [[ -d "$APPROVAL_PRIVATE_DIR" ]]; then
		local owner perms
		owner=$(_file_owner "$APPROVAL_PRIVATE_DIR")
		perms=$(_file_perms "$APPROVAL_PRIVATE_DIR")
		if [[ "$owner" == "root" && "$perms" == "700" ]]; then
			_print_ok "Private key directory is root-protected (owner=$owner, mode=$perms)"
		else
			_print_warn "Private key directory permissions may be insecure (owner=$owner, mode=$perms)"
			echo "  Expected: owner=root, mode=700"
			_approval_commands_setup_hint
		fi
	else
		_print_warn "No private key directory found"
		_approval_commands_setup_hint
	fi

	_approval_commands_blank_line
	return 0
}

# ── Help ─────────────────────────────────────────────────────────────────────

cmd_help() {
	local approve_cli
	approve_cli=$(approval_cli_prefix)
	echo "approval-helper.sh — Cryptographic approval gate covering external issues/PRs"
	_approval_commands_blank_line
	echo "Commands (require sudo):"
	echo "  setup                      Generate root-protected approval key pair"
	echo "  issue <number...> [slug]   Approve one or more issues with one confirmation"
	echo "  pr <number...> [slug]      Approve one or more PRs with one confirmation"
	echo "  batch <kind:number...> [slug] Approve mixed issues/PRs with one confirmation"
	echo "  permissions issue|pr <number> [slug] --request perm-<id> [--withdraw]"
	echo "                             --withdraw signs a decline: grants nothing, releases the hold"
	echo "  permissions batch --withdraw [--all-blocked] [kind:number:perm-<id>...] [slug]"
	echo "                             Withdraw many requests with one confirmation (never grants)"
	_approval_commands_blank_line
	echo "Commands (no sudo needed):"
	echo "  verify [issue|pr] <number> [slug] [--expect-head SHA] [--require-authority]"
	echo "  verify-permissions issue|pr <number> [slug]"
	echo "  reconcile issue|pr <number> [slug]"
	echo "  status                     Show approval key setup status"
	echo "  help                       Show this help"
	_approval_commands_blank_line
	echo "Examples:"
	echo "  ${approve_cli} approve setup"
	echo "  ${approve_cli} approve issue 17438 <owner/repo>"
	echo "  ${approve_cli} approve issue 17438 17440 17442 <owner/repo>"
	echo "  ${approve_cli} approve pr 17439 17441 <owner/repo>"
	echo "  ${approve_cli} approve batch issue:17438 pr:17439 pr:17441 <owner/repo>"
	echo "  ${approve_cli} approve permissions issue 17438 <owner/repo> --request perm-0123456789abcdef"
	echo "  ${approve_cli} approve permissions batch --withdraw --all-blocked <owner/repo>"
	echo "  aidevops approve verify 17438"
	echo "  aidevops approve verify pr 17439 <owner/repo> --expect-head <sha>"
	_approval_commands_blank_line
	echo "Security: The approval signing key is stored root-only. Workers run as your"
	echo "user account and cannot access it, even with the same GitHub credentials."
	return 0
}
