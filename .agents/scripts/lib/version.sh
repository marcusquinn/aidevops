#!/usr/bin/env bash
# =============================================================================
# aidevops Version Library
# =============================================================================
# Shared version-finding logic used by aidevops-update-check.sh and
# log-issue-helper.sh. Source this file rather than duplicating the logic.
#
# Usage: source "$(dirname "${BASH_SOURCE[0]}")/lib/version.sh"
#        local ver; ver=$(aidevops_find_version)

# VERSION file locations - checked in order of preference:
# 1. Deployed agents directory (setup.sh copies here for all install methods)
# 2. Legacy location (some older installs)
# 3. Source repo for developers working from a Git clone
AIDEVOPS_VERSION_FILE_AGENTS="${HOME}/.aidevops/agents/VERSION"
AIDEVOPS_VERSION_FILE_LEGACY="${HOME}/.aidevops/VERSION"
AIDEVOPS_VERSION_FILE_DEV="${HOME}/Git/aidevops/VERSION"

# aidevops_find_version - print the local aidevops version string, or "unknown"
#
# Checks three locations in priority order. Uses -r (readable) rather than -f
# (exists) so that cat never fails under set -e on permission-denied files.
aidevops_find_version() {
	if [[ -r "$AIDEVOPS_VERSION_FILE_AGENTS" ]]; then
		cat "$AIDEVOPS_VERSION_FILE_AGENTS"
	elif [[ -r "$AIDEVOPS_VERSION_FILE_LEGACY" ]]; then
		cat "$AIDEVOPS_VERSION_FILE_LEGACY"
	elif [[ -r "$AIDEVOPS_VERSION_FILE_DEV" ]]; then
		cat "$AIDEVOPS_VERSION_FILE_DEV"
	else
		echo "unknown"
	fi
	return 0
}

# aidevops_signature_footer - generate the signature footer for GitHub content
#
# Usage: body="${body}$(aidevops_signature_footer)"
#        body="${body}$(aidevops_signature_footer --issue owner/repo#42)"
#        body="${body}$(aidevops_signature_footer --issue owner/repo#42 --solved)"
#
# Passes all arguments through to gh-signature-helper.sh footer.
# Auto-detects model from ANTHROPIC_MODEL / CLAUDE_MODEL env vars.
# Returns empty string if the helper is not available (graceful degradation).
aidevops_signature_footer() {
	local helper_dir
	helper_dir="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/.." 2>/dev/null && pwd)"
	local helper="${helper_dir}/gh-signature-helper.sh"

	# Fallback to deployed location
	if [[ ! -x "$helper" ]]; then
		helper="${HOME}/.aidevops/agents/scripts/gh-signature-helper.sh"
	fi

	if [[ ! -x "$helper" ]]; then
		return 0
	fi

	# Auto-detect model from environment
	local model_arg=""
	local model="${ANTHROPIC_MODEL:-${CLAUDE_MODEL:-}}"
	if [[ -n "$model" ]]; then
		model_arg="--model ${model}"
	fi

	# shellcheck disable=SC2086
	"$helper" footer $model_arg "$@" 2>/dev/null || true
	return 0
}
