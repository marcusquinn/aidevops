#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# =============================================================================
# Scheduler template hash -- the one definition of "which scheduler templates
# generated the installed launchd plists" (t2119, t19030).
# =============================================================================
# Both sides of the plist drift contract use this function:
#   - setup (schedulers.sh) hashes the templates it loaded and records the value
#     after a full scheduler pass (_schedulers_record_template_hash);
#   - auto-update (check_launchd_plist_drift) hashes the source checkout and
#     re-runs setup when the values differ.
# Before t19030 each side hashed a different file, so every check reported
# drift and ran a full setup without ever converging.
#
# The template set matches the incremental planner in setup.sh
# (_setup_ai_session_plan_file): setup/modules/schedulers*.sh,
# setup/_scheduler_runtime.sh and runtime-env.sh, which renders every service
# PATH (GH#37888: a PATH-order fix there never reached installed units). This
# file matches that glob, so a change to the hash itself also counts as drift.
#
# Usage: source "${SCRIPT_DIR}/schedulers-template-hash.sh"
#        scheduler_template_hash <setup modules dir>
#
# Part of aidevops framework: https://aidevops.sh

# Apply strict mode only when executed directly (not when sourced)
[[ "${BASH_SOURCE[0]}" == "${0}" ]] && set -euo pipefail

# Include guard
[[ -n "${_SCHEDULERS_TEMPLATE_HASH_LIB_LOADED:-}" ]] && return 0
_SCHEDULERS_TEMPLATE_HASH_LIB_LOADED=1

# Print the SHA-256 hex digest of stdin. Commands are spelled out rather than
# held in a variable: callers may run with IFS=$'\n\t' (schedulers.sh).
_scheduler_template_sha256() {
	if command -v shasum >/dev/null 2>&1; then
		shasum -a 256 | awk '{print $1}'
	elif command -v sha256sum >/dev/null 2>&1; then
		sha256sum | awk '{print $1}'
	else
		return 1
	fi
	return 0
}

# Print one digest covering every scheduler template under a setup modules
# directory. Each file is hashed with its basename and the manifest is sorted
# in the C locale, so glob collation differences between callers cannot
# change the result.
# Args: $1 = setup modules directory (.../.agents/scripts/setup/modules)
# Returns: 0 with the digest on stdout; 1 when no template can be hashed
scheduler_template_hash() {
	local modules_dir="$1"
	local setup_dir="" file="" digest="" manifest=""
	[[ -n "$modules_dir" && -d "$modules_dir" ]] || return 1
	setup_dir="${modules_dir%/*}"
	for file in "$modules_dir"/schedulers*.sh "$setup_dir/_scheduler_runtime.sh" "${setup_dir%/*}/runtime-env.sh"; do
		[[ -f "$file" ]] || continue
		digest=$(_scheduler_template_sha256 <"$file") || return 1
		[[ "$digest" =~ ^[0-9a-f]{64}$ ]] || return 1
		manifest+="${digest}  ${file##*/}"$'\n'
	done
	[[ -n "$manifest" ]] || return 1
	digest=$(printf '%s' "$manifest" | LC_ALL=C sort | _scheduler_template_sha256) || return 1
	[[ "$digest" =~ ^[0-9a-f]{64}$ ]] || return 1
	printf '%s\n' "$digest"
	return 0
}
