#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

# Return a stable, non-identifying key for the current runner. The raw hostname
# stays in runner-local metadata; public recovery markers carry only this key.
runner_identity_key() {
	if [[ -n "${AIDEVOPS_RUNNER_IDENTITY_KEY:-}" ]]; then
		printf '%s\n' "$AIDEVOPS_RUNNER_IDENTITY_KEY"
		return 0
	fi

	local runner_identity="${AIDEVOPS_RUNNER_IDENTITY:-}"
	[[ -n "$runner_identity" ]] || runner_identity=$(hostname 2>/dev/null || printf 'unknown')
	local identity_hash=""
	identity_hash=$(printf '%s' "$runner_identity" | git hash-object --stdin 2>/dev/null || true)
	if [[ -n "$identity_hash" ]]; then
		printf 'runner-%s\n' "${identity_hash:0:12}"
		return 0
	fi

	local identity_checksum=""
	identity_checksum=$(printf '%s' "$runner_identity" | cksum 2>/dev/null | cut -d ' ' -f 1 || true)
	printf 'runner-%s\n' "${identity_checksum:-unknown}"
	return 0
}
