#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# Shared locked-state gates for helpers that read/write Vault-protected data.

[[ -n "${_AIDEVOPS_VAULT_STORAGE_LIB_LOADED:-}" ]] && return 0
_AIDEVOPS_VAULT_STORAGE_LIB_LOADED=1

vault_storage_helper_path() {
	local helper="${AIDEVOPS_VAULT_HELPER:-}"
	if [[ -n "$helper" ]]; then
		printf '%s\n' "$helper"
		return 0
	fi
	printf '%s\n' "${SCRIPT_DIR}/vault-helper.sh"
	return 0
}

vault_storage_dir() {
	local configured="${AIDEVOPS_VAULT_DIR:-}"
	if [[ -n "$configured" ]]; then
		printf '%s\n' "$configured"
		return 0
	fi
	printf '%s\n' "${XDG_CONFIG_HOME:-${HOME:-}/.config}/aidevops/vault"
	return 0
}

vault_storage_active() {
	local vault_dir
	vault_dir=$(vault_storage_dir)
	if [[ "${AIDEVOPS_VAULT_REQUIRE:-0}" == "1" ]]; then
		return 0
	fi
	[[ -f "${vault_dir}/vault.json" ]]
	return $?
}

vault_storage_require_unlocked() {
	local collection="$1"
	local helper status_output status_rc
	if ! vault_storage_active; then
		return 0
	fi
	helper=$(vault_storage_helper_path)
	if ! command -v "$helper" >/dev/null 2>&1; then
		printf '%s\n' "VAULT_LOCKED: Vault helper is unavailable for ${collection}" >&2
		return 6
	fi
	status_output=$("$helper" status 2>/dev/null) && status_rc=0 || status_rc=$?
	if [[ "$status_rc" -ne 0 || "$status_output" != "unlocked" ]]; then
		printf '%s\n' "VAULT_LOCKED: ${collection} requires an unlocked aidevops Vault" >&2
		return 6
	fi
	return 0
}
