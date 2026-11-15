#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
# =============================================================================
# Cloudron release merge guard (GH#37955)
# =============================================================================
# Shared by every merge transport (pulse merge pass and full-loop merge). A PR
# that changes a registered Cloudron package's CloudronManifest.json version
# publishes a catalog release when merged, so it must carry exact-head release
# authority (signed approval or the signed standing release policy) even when
# no release request or label exists yet.
#
# Usage: source "${SCRIPT_DIR}/cloudron-release-merge-guard-lib.sh"
#        cloudron_release_merge_guard <owner/repo> <pr> <head-sha> [",labels,"]
#
# Part of aidevops framework: https://aidevops.sh

[[ -n "${_CLOUDRON_RELEASE_MERGE_GUARD_LIB_LOADED:-}" ]] && return 0
_CLOUDRON_RELEASE_MERGE_GUARD_LIB_LOADED=1
_CLOUDRON_RELEASE_MERGE_GUARD_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || return 1

# Returns 0 when the merge may proceed, 1 when it is blocked. With
# CLOUDRON_RELEASE_GUARD_READ_ONLY=1 (diagnostic preflight) or DRY_RUN=1 the
# decision is identical but no hold labels are written.
cloudron_release_merge_guard() {
	local repo="$1" pr="$2" head="$3" labels_padded="${4:-}"
	local repos_file="${AIDEVOPS_REPOS_FILE:-${HOME}/.config/aidevops/repos.json}"
	#aidevops:trust-boundary — the helper path is fixed beside this library; no
	# environment variable can substitute a different authorizer.
	local helper="${_CLOUDRON_RELEASE_MERGE_GUARD_DIR}/cloudron-release-approval-helper.sh"
	local registered_rc=0

	# A dedicated release hold always requires exact-head authority. On denial,
	# also cancel any pending native auto-merge (authorize itself stays
	# read-only; the cancel step honours DRY_RUN/READ_ONLY).
	if [[ "$labels_padded" == *",release-approval-required,"* ]]; then
		"$helper" authorize "$repo" "$pr" "$head" && return 0
		"$helper" cancel-auto-merge "$repo" "$pr" || true
		return 1
	fi
	# Unregistered repositories make no API calls.
	[[ -f "$repos_file" ]] || return 0
	# GitHub slugs are case-insensitive; a differently cased caller argument
	# must not classify a registered package as unregistered.
	jq -e --arg repo "$repo" \
		'any(.initialized_repos[]?; ((.slug // "") | ascii_downcase) == ($repo | ascii_downcase) and .app_type == "cloudron-package" and .maintenance != false)' \
		"$repos_file" >/dev/null 2>&1 || registered_rc=$?
	[[ "$registered_rc" -ne 1 ]] || return 0
	# An unreadable registry fails closed rather than skipping the gate.
	[[ "$registered_rc" -eq 0 ]] || {
		printf 'ERROR: unable to read %s to classify %s for the Cloudron release gate\n' "$repos_file" "$repo" >&2
		return 1
	}
	"$helper" merge-guard "$repo" "$pr" "$head" || return 1
	return 0
}
