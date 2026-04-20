#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# dispatch-override-resolve.sh — structured per-runner dispatch override resolver (t2422)
#
# Replaces the flat DISPATCH_CLAIM_IGNORE_RUNNERS mechanism with structured,
# per-runner, version-aware overrides. The flat format is deprecated with a
# one-release grace period — it still works but emits a warning.
#
# Config file: ~/.config/aidevops/dispatch-override.conf
#
# NEW structured format (t2422):
#   DISPATCH_OVERRIDE_<LOGIN_UPPER>=<action>[:<version>]
#   DISPATCH_OVERRIDE_DEFAULT=<action>
#
#   Actions:
#     honour              — always respect claims from this runner (default)
#     ignore              — always ignore claims (same as flat list)
#     honour-only-above:<version> — ignore claims with version < <version>;
#                           once the peer upgrades, coordination resumes
#     warn                — respect claims but emit a warning
#
#   LOGIN_UPPER is the runner's GitHub login uppercased with hyphens replaced
#   by underscores (e.g., alex-solovyev → ALEX_SOLOVYEV).
#
# LEGACY flat format (t2400, deprecated):
#   DISPATCH_CLAIM_IGNORE_RUNNERS="login1 login2"
#   When any login matches, resolves to "ignore" + emits deprecation warning.
#
# Usage:
#   dispatch-override-resolve.sh resolve <runner-login> <claim-version>
#     Returns: honour | ignore | warn
#     Exit 0 always (fail-safe to "honour" on parse errors).
#
#   dispatch-override-resolve.sh check-deprecated
#     Exit 0 + prints warning if flat DISPATCH_CLAIM_IGNORE_RUNNERS is set.
#     Exit 1 if no deprecation present.
#
#   dispatch-override-resolve.sh help

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"

# Config file path — same as dispatch-claim-helper.sh uses
DISPATCH_OVERRIDE_CONF="${DISPATCH_OVERRIDE_CONF:-${HOME}/.config/aidevops/dispatch-override.conf}"

# Defaults — set before sourcing to allow config to override
DISPATCH_CLAIM_IGNORE_RUNNERS="${DISPATCH_CLAIM_IGNORE_RUNNERS:-}"
DISPATCH_CLAIM_MIN_VERSION="${DISPATCH_CLAIM_MIN_VERSION:-}"
DISPATCH_OVERRIDE_ENABLED="${DISPATCH_OVERRIDE_ENABLED:-true}"
DISPATCH_OVERRIDE_DEFAULT="${DISPATCH_OVERRIDE_DEFAULT:-honour}"

# Source the config if it exists
if [[ -r "$DISPATCH_OVERRIDE_CONF" ]]; then
	# shellcheck disable=SC1090
	source "$DISPATCH_OVERRIDE_CONF" 2>/dev/null || true
fi

#######################################
# Normalise a GitHub login to an env var suffix.
# Uppercases and replaces hyphens/dots with underscores.
# Args: $1 = runner login (e.g., "alex-solovyev")
# Returns: normalised suffix on stdout (e.g., "ALEX_SOLOVYEV")
#######################################
_login_to_var_suffix() {
	local login="$1"
	# Two separate tr calls to avoid BSD tr '-.' range interpretation bug
	printf '%s' "$login" | tr '[:lower:]' '[:upper:]' | tr '-' '_' | tr '.' '_'
	return 0
}

#######################################
# Semver comparison — is $1 strictly less than $2?
# Args: $1 = version, $2 = floor
# Returns: exit 0 = below, exit 1 = at or above
# "unknown" or empty is always below floor.
#######################################
_version_below() {
	local version="${1:-}"
	local floor="${2:-}"

	if [[ -z "$version" || "$version" == "unknown" ]]; then
		return 0
	fi
	if [[ "$version" == "$floor" ]]; then
		return 1
	fi

	local first
	first=$(printf '%s\n%s\n' "$version" "$floor" | sort -V | head -n1)
	if [[ "$first" == "$version" ]]; then
		return 0
	fi
	return 1
}

#######################################
# Look up the structured override for a runner.
# Args: $1 = runner login
# Returns: the raw action string on stdout (e.g., "honour-only-above:3.8.78")
#          or empty string if no override set.
#######################################
_lookup_structured_override() {
	local login="$1"
	local var_suffix
	var_suffix=$(_login_to_var_suffix "$login")
	local var_name="DISPATCH_OVERRIDE_${var_suffix}"

	# Use indirect expansion to read the variable
	local value="${!var_name:-}"
	printf '%s' "$value"
	return 0
}

#######################################
# Check if a login is in the flat DISPATCH_CLAIM_IGNORE_RUNNERS list.
# Args: $1 = runner login
# Returns: exit 0 = in list, exit 1 = not in list
#######################################
_is_in_flat_ignore_list() {
	local login="$1"
	if [[ -z "$DISPATCH_CLAIM_IGNORE_RUNNERS" ]]; then
		return 1
	fi

	# Normalise: accept comma or space separators
	local normalised
	normalised=$(printf '%s' "$DISPATCH_CLAIM_IGNORE_RUNNERS" | tr ',' ' ')
	local entry
	for entry in $normalised; do
		if [[ "$entry" == "$login" ]]; then
			return 0
		fi
	done
	return 1
}

#######################################
# Resolve the action for a given runner+version claim.
#
# Resolution order:
#   1. If DISPATCH_OVERRIDE_ENABLED != true → "honour" (overrides disabled)
#   2. Structured per-runner override (DISPATCH_OVERRIDE_<LOGIN>)
#   3. Legacy flat list (DISPATCH_CLAIM_IGNORE_RUNNERS) with deprecation warning
#   4. Legacy version floor (DISPATCH_CLAIM_MIN_VERSION) with deprecation warning
#   5. DISPATCH_OVERRIDE_DEFAULT (defaults to "honour")
#
# Args:
#   $1 = runner login
#   $2 = claim version (semver or "unknown")
# Returns: "honour" | "ignore" | "warn" on stdout. Exit 0 always.
#######################################
cmd_resolve() {
	local runner_login="${1:-}"
	local claim_version="${2:-unknown}"

	if [[ -z "$runner_login" ]]; then
		printf 'honour'
		return 0
	fi

	# Master switch
	if [[ "$DISPATCH_OVERRIDE_ENABLED" != "true" ]]; then
		printf 'honour'
		return 0
	fi

	# 1. Check structured per-runner override
	local override_value
	override_value=$(_lookup_structured_override "$runner_login")

	if [[ -n "$override_value" ]]; then
		# Parse action:param
		local action param
		action="${override_value%%:*}"
		param="${override_value#*:}"
		# If no colon, param == action (no parameter)
		if [[ "$action" == "$override_value" ]]; then
			param=""
		fi

		case "$action" in
		honour | honor)
			printf 'honour'
			return 0
			;;
		ignore)
			printf 'ignore'
			return 0
			;;
		honour-only-above | honor-only-above)
			if [[ -z "$param" ]]; then
				# No version threshold — treat as honour
				printf 'honour'
				return 0
			fi
			if _version_below "$claim_version" "$param"; then
				printf 'ignore'
			else
				printf 'honour'
			fi
			return 0
			;;
		warn)
			printf 'warn'
			return 0
			;;
		*)
			# Unknown action — fail safe to honour
			printf '[dispatch-override-resolve] Unknown action "%s" for runner %s — defaulting to honour\n' \
				"$action" "$runner_login" >&2
			printf 'honour'
			return 0
			;;
		esac
	fi

	# 2. Legacy flat list (deprecated)
	if _is_in_flat_ignore_list "$runner_login"; then
		printf '[dispatch-override-resolve] DEPRECATED: runner %s matched via flat DISPATCH_CLAIM_IGNORE_RUNNERS. Migrate to structured format: DISPATCH_OVERRIDE_%s="ignore" (or "honour-only-above:<version>")\n' \
			"$runner_login" "$(_login_to_var_suffix "$runner_login")" >&2
		printf 'ignore'
		return 0
	fi

	# 3. Legacy version floor (deprecated)
	if [[ -n "$DISPATCH_CLAIM_MIN_VERSION" ]]; then
		if _version_below "$claim_version" "$DISPATCH_CLAIM_MIN_VERSION"; then
			printf '[dispatch-override-resolve] DEPRECATED: runner %s (version=%s) filtered by flat DISPATCH_CLAIM_MIN_VERSION=%s. Migrate to structured format: DISPATCH_OVERRIDE_%s="honour-only-above:%s"\n' \
				"$runner_login" "$claim_version" "$DISPATCH_CLAIM_MIN_VERSION" \
				"$(_login_to_var_suffix "$runner_login")" "$DISPATCH_CLAIM_MIN_VERSION" >&2
			printf 'ignore'
			return 0
		fi
	fi

	# 4. Default action
	printf '%s' "${DISPATCH_OVERRIDE_DEFAULT:-honour}"
	return 0
}

#######################################
# Check if deprecated flat-list format is in use. Emits a migration hint.
# Exit 0 = deprecation present, exit 1 = clean.
#######################################
cmd_check_deprecated() {
	local found=0

	if [[ -n "$DISPATCH_CLAIM_IGNORE_RUNNERS" ]]; then
		printf '[DEPRECATED] DISPATCH_CLAIM_IGNORE_RUNNERS="%s"\n' "$DISPATCH_CLAIM_IGNORE_RUNNERS"
		printf '  Migrate to: '
		local normalised
		normalised=$(printf '%s' "$DISPATCH_CLAIM_IGNORE_RUNNERS" | tr ',' ' ')
		local entry
		for entry in $normalised; do
			[[ -z "$entry" ]] && continue
			printf 'DISPATCH_OVERRIDE_%s="ignore"  ' "$(_login_to_var_suffix "$entry")"
		done
		printf '\n'
		found=1
	fi

	if [[ -n "$DISPATCH_CLAIM_MIN_VERSION" ]]; then
		printf '[DEPRECATED] DISPATCH_CLAIM_MIN_VERSION="%s"\n' "$DISPATCH_CLAIM_MIN_VERSION"
		printf '  Migrate to per-runner entries: DISPATCH_OVERRIDE_<RUNNER>="honour-only-above:%s"\n' \
			"$DISPATCH_CLAIM_MIN_VERSION"
		found=1
	fi

	if [[ "$found" -eq 1 ]]; then
		return 0
	fi
	return 1
}

#######################################
# Show help
#######################################
show_help() {
	cat <<'HELP'
dispatch-override-resolve.sh — structured per-runner dispatch override resolver (t2422)

Resolves the action (honour|ignore|warn) for a given runner+version claim,
using the structured per-runner config format.

Usage:
  dispatch-override-resolve.sh resolve <runner-login> <claim-version>
    Returns: honour | ignore | warn

  dispatch-override-resolve.sh check-deprecated
    Checks for deprecated flat-list config entries and prints migration hints.
    Exit 0 = deprecated entries found, exit 1 = clean.

  dispatch-override-resolve.sh help

Config format (in ~/.config/aidevops/dispatch-override.conf):
  # Structured per-runner (t2422):
  DISPATCH_OVERRIDE_ALEX_SOLOVYEV="honour-only-above:3.8.78"
  DISPATCH_OVERRIDE_DEFAULT="honour"

  # Legacy flat (deprecated, still works with warning):
  DISPATCH_CLAIM_IGNORE_RUNNERS="alice bob"
  DISPATCH_CLAIM_MIN_VERSION="3.8.78"

Actions:
  honour              — respect claims from this runner
  ignore              — discard claims from this runner
  honour-only-above:V — ignore claims with version < V
  warn                — respect claims but emit a warning
HELP
	return 0
}

#######################################
# Main
#######################################
main() {
	local command="${1:-help}"
	shift || true

	case "$command" in
	resolve)
		cmd_resolve "$@"
		;;
	check-deprecated)
		cmd_check_deprecated
		;;
	help | --help | -h)
		show_help
		;;
	*)
		echo "Error: Unknown command: $command" >&2
		show_help
		return 1
		;;
	esac
}

main "$@"
