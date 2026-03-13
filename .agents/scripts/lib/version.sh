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
}
