#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# Shared GitHub Actions infrastructure-failure signatures (GH#32869).
#
# Sourced by gh-failure-miner-helper.sh (systemic failure mining) and
# pulse-merge-feedback-ci-repair.sh (CI repair routing) so both classify an
# Actions billing/spending block the same way. A job GitHub refused to start
# for billing reasons carries a check-run annotation and no steps or logs;
# it is a repository capability failure, never a code defect.

[[ -n "${_CI_INFRA_SIGNATURE_LIB_LOADED:-}" ]] && return 0
_CI_INFRA_SIGNATURE_LIB_LOADED=1

# Case-insensitive ERE matched against annotation text and failed logs.
CI_BILLING_OUTAGE_PATTERN='account payments have failed|spending limit needs to be increased'
# Qlty's complete no-run message. Anchored so a finding that quotes it never matches.
CI_QLTY_NO_RUN_PATTERN='^\s*Qlty did not run because you are out of minutes[.!]?\s*$'

#######################################
# Return whether a check-run annotations JSON array reports an Actions
# billing or spending-limit block.
#
# Args:
#   $1 - annotations JSON (array of {message,title,raw_details})
#
# Returns: 0=billing block reported, 1=not reported or unparseable.
#######################################
ci_annotations_json_indicate_billing_outage() {
	local annotations_json="${1:-}"

	[[ -n "$annotations_json" ]] || return 1
	if printf '%s\n' "$annotations_json" | jq -e --arg pattern "$CI_BILLING_OUTAGE_PATTERN" '
		type == "array" and
		any(.[]; ([.message // "", .title // "", .raw_details // ""] | join(" ") |
			ascii_downcase | test($pattern)))' >/dev/null 2>&1; then
		return 0
	fi
	return 1
}

#######################################
# Read one check run and classify a provider-specific did-not-run outage.
# Unknown providers and ordinary code findings remain blocking. For Actions the ID
# equals the job ID in `/actions/runs/<run>/job/<id>` URLs. API failures
# return 1 so callers keep their existing behaviour (no silent suppression).
#
# Args:
#   $1 - repo_slug (owner/repo)
#   $2 - check_run_id
#
# Returns: 0=billing block reported, 1=not reported or unavailable.
#######################################
ci_check_run_indicates_billing_outage() {
	local repo_slug="$1"
	local check_run_id="$2"
	local annotations_json="" check_json="" app=""

	[[ -n "$repo_slug" && "$check_run_id" =~ ^[0-9]+$ ]] || return 1
	check_json=$(gh api "repos/${repo_slug}/check-runs/${check_run_id}" 2>/dev/null) || return 1
	app=$(jq -er '.app.slug' <<<"$check_json") || return 1
	case "$app" in
	qlty)
		# Match the provider's complete no-run message, not quota words in findings.
		jq -e --arg pattern "$CI_QLTY_NO_RUN_PATTERN" 'any([.output.title, .output.summary, .output.text][];
			type == "string" and test($pattern; "i"))' \
			<<<"$check_json" >/dev/null 2>&1 || return 1
		return 0
		;;
	github-actions) ;;
	*) return 1 ;;
	esac
	annotations_json=$(gh api "repos/${repo_slug}/check-runs/${check_run_id}/annotations" 2>/dev/null) || return 1
	ci_annotations_json_indicate_billing_outage "$annotations_json"
	return $?
}

#######################################
# Classify one commit status (GitHub statuses API object) as a provider
# did-not-run outage. Qlty reports its quota outage as a commit status on some
# repositories instead of a check run.
#
# Args:
#   $1 - commit status JSON object ({context,state,description,creator})
#
# Returns: 0=provider quota outage, 1=anything else or unparseable.
#######################################
ci_commit_status_indicates_quota_outage() {
	local status_json="${1:-}"

	[[ -n "$status_json" ]] || return 1
	#aidevops:trust-boundary -- any writer can post a commit status with any
	# context, so require the Qlty bot account and its exact no-run message.
	jq -e --arg pattern "$CI_QLTY_NO_RUN_PATTERN" '
		type == "object" and (.state == "error" or .state == "failure")
		and .creator.login == "qltysh[bot]" and .creator.type == "Bot"
		and (.description | type == "string" and test($pattern; "i"))' \
		<<<"$status_json" >/dev/null 2>&1 || return 1
	return 0
}
