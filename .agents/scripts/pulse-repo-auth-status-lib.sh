#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
# pulse-repo-auth-status-lib.sh — classify per-repo Pulse GitHub App auth
# configuration faults (GH#34552).
#
# Sourced library. `pulse_repo_auth.py status <slug>` is the single classifier:
# it runs the same registry/profile validation the gh shim performs before any
# App-routed read. A failing status means every App-routed gh read for that repo
# fails closed until an operator repairs the configuration. These helpers only
# make that fault visible and correctly classified; they never add a fallback to
# another principal and never print key paths, App IDs or installation IDs.
[[ -n "${_PULSE_REPO_AUTH_STATUS_LIB_LOADED:-}" ]] && return 0
_PULSE_REPO_AUTH_STATUS_LIB_LOADED=1

_PULSE_REPO_AUTH_STATUS_DIR="${BASH_SOURCE[0]%/*}"
[[ "$_PULSE_REPO_AUTH_STATUS_DIR" != "${BASH_SOURCE[0]}" ]] || _PULSE_REPO_AUTH_STATUS_DIR="."

#######################################
# Map pulse_auth_config.py configuration errors to a stable class name.
# Only fixed AuthError texts raised while validating configuration match;
# token, network and API failures stay unclassified (and therefore transient).
# Arguments: $1 - error text (gh/shim stderr summary)
# Output: class name on stdout
# Returns: 0 when the text is a configuration fault, 1 otherwise
#######################################
pulse_repo_auth_error_class() {
	local message="$1"
	case "$message" in
	*"Missing or invalid GitHub App profile"*) printf 'missing_or_invalid_app_profile\n' ;;
	*"Missing key path or installation ID"*) printf 'missing_key_path_or_installation_id\n' ;;
	*"Unsupported Pulse auth provider"*) printf 'unsupported_auth_provider\n' ;;
	*"Local-only repositories cannot use GitHub App auth"*) printf 'local_only_repository\n' ;;
	*"Pulse App profile must request only read permissions"*) printf 'non_read_app_permissions\n' ;;
	*"Repository must have exactly one registry entry"*) printf 'ambiguous_registry_entry\n' ;;
	*"Invalid repository registry"*) printf 'invalid_repository_registry\n' ;;
	*) return 1 ;;
	esac
	return 0
}

#######################################
# Registry path used by pulse_auth_config.py (and therefore the gh shim).
#######################################
_pulse_repo_auth_registry_path() {
	printf '%s\n' "${AIDEVOPS_REPOS_CONFIG:-${HOME}/.config/aidevops/repos.json}"
	return 0
}

#######################################
# List registry slugs that select Pulse GitHub App auth (lower-cased).
# Output: one slug per line; empty when none or the registry is unreadable.
#######################################
pulse_repo_auth_configured_slugs() {
	local registry=""
	registry=$(_pulse_repo_auth_registry_path)
	[[ -f "$registry" ]] || return 0
	jq -r '.initialized_repos[]? | select(.pulse_auth != null) | (.slug // "") | ascii_downcase | select(. != "")' \
		"$registry" 2>/dev/null || true
	return 0
}

#######################################
# Detect an invalid Pulse App auth configuration for one repository.
# Only meaningful while Pulse auth routing is active (AIDEVOPS_PULSE_AUTH=1);
# otherwise gh calls never consult pulse_auth and no fault can apply.
# Arguments: $1 - repo slug (owner/repo)
# Output: fault class on stdout when invalid
# Returns: 0 when the configuration is invalid, 1 when healthy/unconfigured
#######################################
pulse_repo_auth_config_fault() {
	local repo_slug="$1"
	local registry="" configured="" lower_slug="" status_err="" status_rc=0 fault_class=""
	[[ "${AIDEVOPS_PULSE_AUTH:-0}" == "1" ]] || return 1
	[[ "$repo_slug" =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$ ]] || return 1
	registry=$(_pulse_repo_auth_registry_path)
	# Cheap fast path: a readable registry without pulse_auth for this slug can
	# never select App auth. An unreadable registry falls through to Python,
	# which is what the gh shim itself would consult.
	if [[ -f "$registry" ]] && configured=$(jq -r '[.initialized_repos[]? | select(.pulse_auth != null) | (.slug // "") | ascii_downcase] | join("\n")' "$registry" 2>/dev/null); then
		lower_slug=$(printf '%s' "$repo_slug" | tr '[:upper:]' '[:lower:]')
		printf '%s\n' "$configured" | grep -qxF "$lower_slug" || return 1
	elif [[ ! -e "$registry" ]]; then
		return 1
	fi
	# stdout carries App/installation IDs on success: discard it, keep stderr.
	status_err=$(python3 "${_PULSE_REPO_AUTH_STATUS_DIR}/pulse_repo_auth.py" status "$repo_slug" 2>&1 >/dev/null) || status_rc=$?
	[[ "$status_rc" -ne 0 ]] || return 1
	fault_class=$(pulse_repo_auth_error_class "$status_err") || fault_class="auth_config_unreadable"
	printf '%s\n' "$fault_class"
	return 0
}

#######################################
# Operator remedy text (no secrets, IDs or key paths).
# Arguments: $1 - repo reference to embed (slug for local logs, placeholder otherwise)
#######################################
pulse_repo_auth_fault_remedy() {
	local repo_ref="${1:-<owner/repo>}"
	printf 'restore the referenced profile in ~/.config/aidevops/github-app-auth.json, or run pulse_repo_auth.py set %s --profile <name> --installation-id <id> (or clear %s); verify with pulse_repo_auth.py status %s\n' \
		"$repo_ref" "$repo_ref" "$repo_ref"
	return 0
}

#######################################
# Emit the "## Repo Auth Faults" pre-fetch state section (local state only).
# Names repo paths from repos.json, never slugs, key paths or IDs.
# Arguments: $1 - repo entries (slug|path per line)
# Output: markdown section on stdout (empty when no repo uses pulse_auth)
#######################################
prefetch_repo_auth_faults() {
	local repo_entries="$1"
	local configured="" slug="" path="" lower_slug="" fault_class="" faults=""
	[[ "${AIDEVOPS_PULSE_AUTH:-0}" == "1" ]] || return 0
	configured=$(pulse_repo_auth_configured_slugs)
	[[ -n "$configured" ]] || return 0
	while IFS='|' read -r slug path; do
		[[ -n "$slug" ]] || continue
		lower_slug=$(printf '%s' "$slug" | tr '[:upper:]' '[:lower:]')
		printf '%s\n' "$configured" | grep -qxF "$lower_slug" || continue
		fault_class=$(pulse_repo_auth_config_fault "$slug") || continue
		faults="${faults}- \`${path:-<unknown path>}\`: repo auth config invalid (class=${fault_class}); candidates, dispatch metadata and recovery observation for this repo are unavailable until fixed"$'\n'
		printf '[pulse-wrapper] prefetch: repo auth config invalid for %s (class=%s); remedy: %s\n' \
			"$slug" "$fault_class" "$(pulse_repo_auth_fault_remedy "$slug")" >>"${LOGFILE:-/dev/null}" 2>/dev/null || true
	done <<<"$repo_entries"

	echo "## Repo Auth Faults"
	echo ""
	if [[ -z "$faults" ]]; then
		echo "None — every pulse_auth repository configuration validates."
		echo ""
		return 0
	fi
	printf '%s' "$faults"
	echo ""
	echo "Pulse fails closed for these repositories (no personal-token fallback); idle slots are expected until an operator"
	echo "repairs the configuration: $(pulse_repo_auth_fault_remedy '<owner/repo>')"
	echo "Do not copy repository names from this section into public issues or comments."
	echo ""
	return 0
}
