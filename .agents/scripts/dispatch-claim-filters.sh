#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# Runtime override filters for dispatch-claim-helper.sh.
# Sourced by the helper, which loads configuration and dispatch-override-resolve.sh.

[[ -n "${_DISPATCH_CLAIM_FILTERS_LOADED:-}" ]] && return 0
_DISPATCH_CLAIM_FILTERS_LOADED=1

#######################################
# t2401: Semver comparison — is $1 strictly less than $2?
# Args: $1 = version (e.g., "3.8.78"), $2 = floor (e.g., "3.9.0")
# Returns: exit 0 = version < floor (below), exit 1 = version >= floor
# "unknown" or empty version is always below floor.
#######################################
_version_below() {
	local version="${1:-}"
	local floor="${2:-}"

	# Treat missing/unknown as below any configured floor
	if [[ -z "$version" || "$version" == "unknown" ]]; then
		return 0
	fi

	# Equal versions are not strictly below
	if [[ "$version" == "$floor" ]]; then
		return 1
	fi

	# sort -V puts smaller semver first. If $version is first, it's below $floor.
	local first
	first=$(printf '%s\n%s\n' "$version" "$floor" | sort -V | sed -n '1p')
	if [[ "$first" == "$version" ]]; then
		return 0
	fi
	return 1
}

#######################################
# t2401: Filter out claim entries whose version is below DISPATCH_CLAIM_MIN_VERSION.
# Legacy claims parsed as "unknown" are always filtered out when a floor is set.
#
# Args:
#   $1 = parsed claims JSON array
#   $2 = min version floor (semver)
# Returns:
#   Filtered JSON on stdout. Fails safe — returns input unchanged on jq error.
#######################################
_filter_below_version() {
	local parsed="$1"
	local floor="$2"
	local self_runner="${3:-}"

	# Collect IDs of claims strictly below the floor.
	local below_ids=""
	local claim_rows
	claim_rows=$(printf '%s' "$parsed" | jq -r '.[] | [.id, (.runner // ""), (.version // "unknown")] | @tsv' 2>/dev/null) || return 0

	local id runner version
	while IFS=$'\t' read -r id runner version; do
		[[ -z "$id" ]] && continue
		if [[ -n "$self_runner" && "$runner" == "$self_runner" ]]; then
			continue
		fi
		if _version_below "$version" "$floor"; then
			below_ids+="${id}"$'\n'
		fi
	done <<<"$claim_rows"

	if [[ -z "$below_ids" ]]; then
		printf '%s' "$parsed"
		return 0
	fi

	local below_json
	below_json=$(printf '%s' "$below_ids" | jq -Rsc 'split("\n") | map(select(length > 0)) | map(tonumber)' 2>/dev/null) || {
		printf '%s' "$parsed"
		return 0
	}

	local filtered
	filtered=$(printf '%s' "$parsed" | jq -c --argjson below "$below_json" '
		map(select((.id as $i | $below | index($i)) | not))
	' 2>/dev/null) || {
		printf '%s' "$parsed"
		return 0
	}
	printf '%s' "$filtered"
	return 0
}

#######################################
# t2422: Apply the structured per-runner override filter.
#
# For each claim, consults _override_resolve (from dispatch-override-resolve.sh)
# and strips claims whose action is "ignore". "warn" claims are kept but logged.
# "honour" claims pass through unchanged.
#
# No-op fast paths:
#   - DISPATCH_OVERRIDE_ENABLED != "true"
#   - _override_resolve not sourced (partial deploy of helpers)
#   - No DISPATCH_OVERRIDE_* structured vars set AND no DISPATCH_OVERRIDE_DEFAULT
#
# Args:
#   $1 = parsed claims JSON array
#   $2 = issue number (log context)
#   $3 = repo slug (log context)
# Returns:
#   Filtered claims JSON on stdout. Fails safe — returns input unchanged on
#   any jq error or when resolver is missing.
#######################################
#######################################
# Detect whether any structured override config is currently active.
# Uses compgen -v (in-shell variable enumeration) rather than `env` so both
# exported and non-exported shell variables are detected — callers often set
# overrides via `VAR=value cmd` inline syntax which does NOT export.
# Returns: exit 0 if structured config found (or default set), exit 1 otherwise.
#######################################
_structured_filter_has_config() {
	local var
	for var in $(compgen -v 2>/dev/null | grep '^DISPATCH_OVERRIDE_' 2>/dev/null || true); do
		case "$var" in
		DISPATCH_OVERRIDE_CONF | DISPATCH_OVERRIDE_ENABLED | DISPATCH_OVERRIDE_DEFAULT) continue ;;
		DISPATCH_OVERRIDE_*) return 0 ;;
		esac
	done
	[[ -n "${DISPATCH_OVERRIDE_DEFAULT:-}" ]]
}

#######################################
# Classify claims against the resolver and return a newline-delimited list of
# IDs whose action is `ignore`. Logs `warn` actions once per unique runner.
# Args:
#   $1 = claim rows (TSV: id\trunner\tversion per line, from jq output)
#   $2 = issue number (log context)
#   $3 = repo slug (log context)
# Returns: newline-delimited IDs on stdout, exit 0 always.
#######################################
_structured_filter_classify_claims() {
	local rows="$1"
	local issue_number="$2"
	local repo_slug="$3"
	local self_runner="${4:-}"

	# Iterate via IFS=newline `for` rather than `while read <<<"$rows"` — the
	# complexity-regression scanner's nesting-depth heuristic treats
	# `done <<<"X"` as an unmatched close, inflating the global depth counter
	# (every such pattern permanently bumps the max-depth report by 1).
	local id runner version action warned_runners=""
	local line
	local saved_ifs="${IFS-}"
	IFS=$'\n'
	for line in $rows; do
		IFS="$saved_ifs"
		[[ -z "$line" ]] && { IFS=$'\n'; continue; }
		IFS=$'\t' read -r id runner version <<<"$line"
		[[ -z "$id" ]] && { IFS=$'\n'; continue; }
		if [[ -n "$self_runner" && "$runner" == "$self_runner" ]]; then
			IFS=$'\n'
			continue
		fi
		action=$(_override_resolve "$runner" "$version" 2>/dev/null) || action="honour"
		case "$action" in
		ignore) printf '%s\n' "$id" ;;
		warn)
			if [[ "$warned_runners" != *"|${runner}|"* ]]; then
				printf '[dispatch-claim-helper] structured override: warn action on runner=%s version=%s on #%s in %s (claim kept, audit logged)\n' \
					"$runner" "$version" "$issue_number" "$repo_slug" >&2
				warned_runners+="|${runner}|"
			fi
			;;
		*) ;; # honour or unknown — keep
		esac
		IFS=$'\n'
	done
	IFS="$saved_ifs"
	return 0
}

_apply_structured_filter() {
	local parsed="$1"
	local issue_number="$2"
	local repo_slug="$3"
	local self_runner="${4:-}"

	# No-op fast paths: master switch off, resolver missing, or no config.
	if [[ "${DISPATCH_OVERRIDE_ENABLED:-true}" != "true" ]] \
		|| ! declare -F _override_resolve >/dev/null 2>&1 \
		|| ! _structured_filter_has_config; then
		printf '%s' "$parsed"
		return 0
	fi

	# Walk claims via resolver — "ignore" IDs are collected, "warn" is logged.
	local rows to_strip_newline
	rows=$(printf '%s' "$parsed" | jq -r '.[] | [.id, .runner, .version] | @tsv' 2>/dev/null) || {
		printf '%s' "$parsed"
		return 0
	}
	to_strip_newline=$(_structured_filter_classify_claims "$rows" "$issue_number" "$repo_slug" "$self_runner")

	if [[ -z "$to_strip_newline" ]]; then
		printf '%s' "$parsed"
		return 0
	fi

	local strip_json filtered
	strip_json=$(printf '%s' "$to_strip_newline" | jq -Rsc 'split("\n") | map(select(length > 0)) | map(tonumber)' 2>/dev/null) || {
		printf '%s' "$parsed"
		return 0
	}
	filtered=$(printf '%s' "$parsed" | jq -c --argjson strip "$strip_json" 'map(select((.id as $i | $strip | index($i)) | not))' 2>/dev/null) || {
		printf '%s' "$parsed"
		return 0
	}

	local pre_count post_count
	pre_count=$(printf '%s' "$parsed" | jq 'length' 2>/dev/null || echo 0)
	post_count=$(printf '%s' "$filtered" | jq 'length' 2>/dev/null || echo 0)
	if [[ "$pre_count" -gt "$post_count" ]]; then
		printf '[dispatch-claim-helper] structured override stripped %d claim(s) on #%s in %s\n' \
			"$((pre_count - post_count))" "$issue_number" "$repo_slug" >&2
	fi

	printf '%s' "$filtered"
	return 0
}

#######################################
# t2400/t2401/t2422: Apply runtime override filters to parsed claims.
#
# Composable filters, applied in order:
#   1. Login filter (t2400): DISPATCH_CLAIM_IGNORE_RUNNERS strips named logins.
#      DEPRECATED — use per-runner DISPATCH_OVERRIDE_<SLUG>="ignore" instead.
#   2. Version filter (t2401): DISPATCH_CLAIM_MIN_VERSION strips claims whose
#      version field is below the semver floor (including legacy "unknown").
#      DEPRECATED — use DISPATCH_OVERRIDE_<SLUG>="honour-only-above:V" to scope
#      the floor per runner rather than globally.
#   3. Structured filter (t2422): per-runner DISPATCH_OVERRIDE_<SLUG> vars
#      decide honour/ignore/warn per claim. Auto-sunsets via version gating.
#
# All filters respect DISPATCH_OVERRIDE_ENABLED=false as a global kill switch.
# Emits a stderr summary line when any claims are stripped, for operator audit.
#
# Args:
#   $1 = parsed claims JSON array (from _fetch_claims parse step)
#   $2 = issue number (for log context)
#   $3 = repo slug (for log context)
# Returns:
#   Filtered claims JSON on stdout. Fails safe — returns input unchanged
#   on any jq error.
#######################################
_apply_ignore_filter() {
	local parsed="$1"
	local issue_number="$2"
	local repo_slug="$3"
	local self_runner="${4:-}"

	if [[ "$DISPATCH_OVERRIDE_ENABLED" != "true" ]]; then
		printf '%s' "$parsed"
		return 0
	fi

	# All three filter inputs empty → no-op fast path.
	# Use compgen -v (in-shell variable enumeration) so we see non-exported
	# vars set via the inline `VAR=value cmd` syntax.
	local has_structured=0 var
	for var in $(compgen -v 2>/dev/null | grep '^DISPATCH_OVERRIDE_' 2>/dev/null || true); do
		case "$var" in
		DISPATCH_OVERRIDE_CONF | DISPATCH_OVERRIDE_ENABLED | DISPATCH_OVERRIDE_DEFAULT) continue ;;
		DISPATCH_OVERRIDE_*)
			has_structured=1
			break
			;;
		esac
	done

	if [[ -z "$DISPATCH_CLAIM_IGNORE_RUNNERS" && -z "$DISPATCH_CLAIM_MIN_VERSION" && $has_structured -eq 0 && -z "${DISPATCH_OVERRIDE_DEFAULT:-}" ]]; then
		printf '%s' "$parsed"
		return 0
	fi

	local pre_count
	pre_count=$(printf '%s' "$parsed" | jq 'length' 2>/dev/null || echo 0)

	# Login filter (t2400, deprecated — still supported for backward compat)
	if [[ -n "$DISPATCH_CLAIM_IGNORE_RUNNERS" ]]; then
		local ignored_json
		# Normalise the ignore list (accept space OR comma separators) → JSON array
		ignored_json=$(printf '%s' "$DISPATCH_CLAIM_IGNORE_RUNNERS" | tr ',' ' ' | tr -s ' ' '\n' | jq -Rsc 'split("\n") | map(select(length > 0))' 2>/dev/null) || ignored_json="[]"
		if [[ "$ignored_json" != "[]" ]]; then
			local filtered_login
			filtered_login=$(printf '%s' "$parsed" | jq -c --argjson ignored "$ignored_json" --arg self_runner "$self_runner" '
				map(select((.runner == $self_runner and $self_runner != "") or (.runner as $r | $ignored | index($r) | not)))
			' 2>/dev/null)
			if [[ -n "$filtered_login" ]]; then
				parsed="$filtered_login"
			fi
		fi
	fi

	# Version filter (t2401, deprecated — still supported for backward compat)
	if [[ -n "$DISPATCH_CLAIM_MIN_VERSION" ]]; then
		parsed=$(_filter_below_version "$parsed" "$DISPATCH_CLAIM_MIN_VERSION" "$self_runner")
	fi

	# Structured per-runner filter (t2422)
	parsed=$(_apply_structured_filter "$parsed" "$issue_number" "$repo_slug" "$self_runner")

	local post_count
	post_count=$(printf '%s' "$parsed" | jq 'length' 2>/dev/null || echo 0)
	if [[ "$pre_count" -gt "$post_count" ]]; then
		printf '[dispatch-claim-helper] filtered %d claim(s) on #%s in %s (legacy_ignore=%s legacy_min_version=%s structured=%d)\n' \
			"$((pre_count - post_count))" "$issue_number" "$repo_slug" \
			"${DISPATCH_CLAIM_IGNORE_RUNNERS:-none}" "${DISPATCH_CLAIM_MIN_VERSION:-none}" "$has_structured" >&2
	fi

	printf '%s' "$parsed"
	return 0
}
