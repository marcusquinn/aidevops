#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# dispatch-override-resolve.sh — Structured per-runner dispatch override resolver (t2422)
#
# Supersedes the flat DISPATCH_CLAIM_IGNORE_RUNNERS / DISPATCH_CLAIM_MIN_VERSION
# model (t2400/t2401) with per-runner, conditional overrides that auto-sunset
# once the peer upgrades past a configurable version floor.
#
# The old flat model has two failure modes the structured model fixes:
#   1. Manual removal after peer recovers — "ignore alex-solovyev" requires an
#      operator to remove the entry once their runner upgrades. Misses
#      auto-sunset.
#   2. Combinatorial explosion with multiple peers — a fleet of N laggy peers
#      ends up with N entries in a space-separated list that's hard to diff
#      against the supervisor dashboard.
#
# Structured format (in ~/.config/aidevops/dispatch-override.conf):
#
#   DISPATCH_OVERRIDE_<LOGIN_SLUG>="<action>[:<min_version>]"
#   DISPATCH_OVERRIDE_DEFAULT="<action>"   # fallback for unlisted runners
#   DISPATCH_OVERRIDE_ENABLED=true
#
# Slug normalisation: uppercase + non-alphanumerics replaced by underscore.
#   "alex-solovyev"   → ALEX_SOLOVYEV   → DISPATCH_OVERRIDE_ALEX_SOLOVYEV
#   "bot.user"        → BOT_USER        → DISPATCH_OVERRIDE_BOT_USER
#   "github-actions"  → GITHUB_ACTIONS  → DISPATCH_OVERRIDE_GITHUB_ACTIONS
#
# Actions:
#   honour                 — respect the claim (safe default).
#   ignore                 — always ignore claims from this runner.
#   honour-only-above:V    — honour ONLY IF the claim's version field is
#                            >= V. Below V (including legacy "unknown"), the
#                            claim is treated as ignore. Auto-sunsets: once
#                            the peer upgrades, their claims pass cleanly.
#   ignore-below:V         — synonym for honour-only-above (clearer phrasing
#                            when the intent is "block during upgrade window").
#   warn                   — honour but emit a stderr log line. Use during
#                            observation windows before escalating to ignore.
#
# Usage:
#   dispatch-override-resolve.sh resolve <runner> [version]
#     Prints one of: honour | ignore | warn. Exit 0 always (safe default is
#     honour). Empty runner or disabled override → honour.
#
#   dispatch-override-resolve.sh check-legacy
#     Exit 0 if DISPATCH_CLAIM_IGNORE_RUNNERS is set (legacy config found —
#     emits migration hint on stderr). Exit 1 otherwise.
#
#   dispatch-override-resolve.sh help
#
# Sourcing: the helper is safe to source — `main` only runs when executed
# directly. Sourcing exposes `_override_resolve` and `_override_login_to_slug`
# to the caller.

set -euo pipefail

DISPATCH_OVERRIDE_CONF="${DISPATCH_OVERRIDE_CONF:-${HOME}/.config/aidevops/dispatch-override.conf}"
DISPATCH_OVERRIDE_ENABLED="${DISPATCH_OVERRIDE_ENABLED:-true}"

if [[ -r "$DISPATCH_OVERRIDE_CONF" ]]; then
	# shellcheck disable=SC1090
	source "$DISPATCH_OVERRIDE_CONF" 2>/dev/null || true
fi

#######################################
# Normalise a GitHub login to an env-var-safe slug.
# Bash 3.2 compatible (uses sed, not ${var^^}).
# Args: $1 = login
# Stdout: UPPERCASE slug with non-alphanumerics replaced by underscore
#######################################
_override_login_to_slug() {
	local login="${1:-}"
	printf '%s' "$login" | tr '[:lower:]' '[:upper:]' | sed 's/[^A-Z0-9]/_/g'
	return 0
}

#######################################
# Is semver $1 strictly less than semver $2?
# Local copy to keep this helper independent of dispatch-claim-helper.sh.
# Args: $1 = version (may be "unknown" or empty), $2 = floor
# Returns: exit 0 = below, exit 1 = not below.
# "unknown"/empty is always below any non-empty floor.
#######################################
_override_version_below() {
	local version="${1:-}"
	local floor="${2:-}"
	# Treat missing/unknown as below any configured floor
	if [[ -z "$version" || "$version" == "unknown" ]]; then
		return 0
	fi
	# Empty floor — nothing is below
	if [[ -z "$floor" ]]; then
		return 1
	fi
	# Equal versions are not strictly below
	if [[ "$version" == "$floor" ]]; then
		return 1
	fi
	# sort -V puts smaller semver first
	local first
	first=$(printf '%s\n%s\n' "$version" "$floor" | sort -V | head -n1)
	if [[ "$first" == "$version" ]]; then
		return 0
	fi
	return 1
}

#######################################
# Resolve the action for a (runner, version) pair.
# Args:
#   $1 = runner login (e.g., "alex-solovyev")
#   $2 = version (optional, default "unknown")
# Stdout: honour | ignore | warn
# Exit 0 always — this is a pure-function lookup; callers use stdout, not exit.
#######################################
_override_resolve() {
	local runner="${1:-}"
	local version="${2:-unknown}"

	# Empty input → safe default
	if [[ -z "$runner" ]]; then
		printf 'honour\n'
		return 0
	fi

	# Disabled master switch → honour everything
	if [[ "${DISPATCH_OVERRIDE_ENABLED:-true}" != "true" ]]; then
		printf 'honour\n'
		return 0
	fi

	# Look up structured per-runner var
	local slug override_var override
	slug=$(_override_login_to_slug "$runner")
	override_var="DISPATCH_OVERRIDE_${slug}"
	override="${!override_var:-}"

	# Fallback to DISPATCH_OVERRIDE_DEFAULT, then "honour"
	if [[ -z "$override" ]]; then
		override="${DISPATCH_OVERRIDE_DEFAULT:-honour}"
	fi

	# Parse "action[:min_version]"
	local action min_ver
	if [[ "$override" == *:* ]]; then
		action="${override%%:*}"
		min_ver="${override#*:}"
	else
		action="$override"
		min_ver=""
	fi

	case "$action" in
	honour | honor)
		printf 'honour\n'
		;;
	ignore)
		printf 'ignore\n'
		;;
	warn)
		printf 'warn\n'
		;;
	honour-only-above | honor-only-above | ignore-below)
		# Version-gated action requires a min_version.
		# Ill-formed (no colon) → safe default of honour.
		if [[ -z "$min_ver" ]]; then
			printf 'honour\n'
			return 0
		fi
		if _override_version_below "$version" "$min_ver"; then
			printf 'ignore\n'
		else
			printf 'honour\n'
		fi
		;;
	*)
		# Unknown action keyword → safe default
		printf 'honour\n'
		;;
	esac
	return 0
}

#######################################
# CLI: resolve
#######################################
cmd_resolve() {
	_override_resolve "$@"
	return 0
}

#######################################
# CLI: detect legacy DISPATCH_CLAIM_IGNORE_RUNNERS and print migration hint.
# Returns exit 0 when legacy config is present; exit 1 when clean.
#######################################
cmd_check_legacy() {
	if [[ -n "${DISPATCH_CLAIM_IGNORE_RUNNERS:-}" ]]; then
		printf '[dispatch-override-resolve] DEPRECATED: DISPATCH_CLAIM_IGNORE_RUNNERS="%s"\n' \
			"$DISPATCH_CLAIM_IGNORE_RUNNERS" >&2
		printf '[dispatch-override-resolve] Migrate to per-runner DISPATCH_OVERRIDE_<LOGIN_SLUG>="honour-only-above:<version>"\n' >&2
		printf '[dispatch-override-resolve] Example: DISPATCH_OVERRIDE_ALEX_SOLOVYEV="honour-only-above:3.8.78"\n' >&2
		printf '[dispatch-override-resolve] See reference/cross-runner-coordination.md section 8 (Structured overrides).\n' >&2
		return 0
	fi
	return 1
}

show_help() {
	cat <<'HELP'
dispatch-override-resolve.sh — Structured per-runner dispatch override resolver (t2422)

Resolves the override action for a (runner, version) pair. Sourceable from
other helpers; safe to exec directly as a CLI.

Usage:
  dispatch-override-resolve.sh resolve <runner> [version]
    Prints one of: honour | ignore | warn
    Exit 0 always. Empty runner or disabled config → honour.

  dispatch-override-resolve.sh check-legacy
    Exit 0 if DISPATCH_CLAIM_IGNORE_RUNNERS is set (emits migration hint).
    Exit 1 if config is clean.

  dispatch-override-resolve.sh help

Configuration (~/.config/aidevops/dispatch-override.conf):
  DISPATCH_OVERRIDE_<LOGIN_SLUG>="<action>[:<min_version>]"
  DISPATCH_OVERRIDE_DEFAULT="honour"          # fallback
  DISPATCH_OVERRIDE_ENABLED=true              # master switch

Slug: uppercase login with non-alphanumerics → underscore.
  "alex-solovyev" → ALEX_SOLOVYEV → DISPATCH_OVERRIDE_ALEX_SOLOVYEV

Actions:
  honour                 Respect the claim (default for all runners)
  ignore                 Always ignore claims from this runner
  honour-only-above:V    Honour ONLY IF claim version >= V (auto-sunsets)
  ignore-below:V         Synonym for honour-only-above
  warn                   Honour but log a stderr warning

Examples:
  DISPATCH_OVERRIDE_ALEX_SOLOVYEV="honour-only-above:3.8.78"
  DISPATCH_OVERRIDE_BOB="ignore"
  DISPATCH_OVERRIDE_DEFAULT="honour"

See also:
  reference/cross-runner-coordination.md (section 8)
  dispatch-claim-helper.sh (consumer)
HELP
	return 0
}

main() {
	local command="${1:-help}"
	shift || true
	case "$command" in
	resolve) cmd_resolve "$@" ;;
	check-legacy) cmd_check_legacy "$@" ;;
	help | --help | -h) show_help ;;
	*)
		echo "Error: Unknown command: $command" >&2
		show_help
		return 1
		;;
	esac
}

# Run main only when executed directly; safe to source otherwise.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
	main "$@"
fi
