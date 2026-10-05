#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
# =============================================================================
# SERP Probe Helper
# =============================================================================
# Paced, human-like public search-result collection in a real browser that
# measures how many searches complete before a CAPTCHA. Never solves CAPTCHAs.
# Policy: aidevops/reach-capture.md "Public Search-result Collection".
#
# Usage:
#   serp-probe-helper.sh run --keywords-file kw.txt [--egress-profile NAME] [probe options]
#   serp-probe-helper.sh plan --keywords-file kw.txt [probe options]   # dry run, no browser
#   serp-probe-helper.sh last                                          # latest report summary
#   serp-probe-helper.sh help
#
# Part of aidevops framework: https://aidevops.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit
if [[ -f "${SCRIPT_DIR}/shared-constants.sh" ]]; then
	# shellcheck source=./shared-constants.sh
	# shellcheck disable=SC1091  # resolved at runtime via $SCRIPT_DIR
	source "${SCRIPT_DIR}/shared-constants.sh"
fi

PROBE_SCRIPT="${SCRIPT_DIR}/serp-captcha-probe.mjs"
PROBE_WORKSPACE="${AIDEVOPS_SERP_PROBE_DIR:-${HOME}/.aidevops/.agent-workspace/serp-probe}"

show_help() {
	cat <<'EOF'
serp-probe-helper.sh - measure paced public SERP collection before a CAPTCHA

Commands:
  run  [options]   Open a headed browser and search each keyword with human-like pacing.
                   Stops at the first CAPTCHA/challenge (or waits for you with --on-captcha wait).
  plan [options]   Validate options and print the plan and duration estimate; no browser, no traffic.
  last             Print the newest report summary.
  help             Show this help.

Wrapper options:
  --egress-profile NAME   Use a Reach egress profile (reach-helper.sh egress register); resolves
                          its credential ref from aidevops secrets and applies its locale/timezone.
  --proxy-secret NAME     Use the proxy URL stored as aidevops secret NAME.

Probe options (passed through):
  --keywords-file FILE | --keyword KW (repeatable)
  --engine google|bing  --max N (20)  --min-delay S (45)  --max-delay S (120)
  --gl CC (us)  --hl LANG (en)  --headless  --on-captcha stop|wait  --fresh-profile
  --consent manual|reject (cookie prompt: wait for you, or click "Reject all")
  --no-evidence  --shuffle

Reports and result HTML: ~/.aidevops/.agent-workspace/serp-probe/runs/<run-id>/ (mode 600).
Record evidence with: reach-helper.sh observation record (authorization_basis: public_data).

Example:
  serp-probe-helper.sh plan --keywords-file ~/kw.txt --max 30
  serp-probe-helper.sh run --keywords-file ~/kw.txt --max 30 --min-delay 60 --max-delay 150
EOF
	return 0
}

# Resolve a secret value by name: environment, credentials.sh, then gopass aidevops/NAME.
resolve_secret() {
	local name="$1"
	local value="${!name:-}"
	if [[ -z "$value" ]]; then
		# shellcheck disable=SC1091
		source "${HOME}/.config/aidevops/credentials.sh" 2>/dev/null || true
		value="${!name:-}"
	fi
	if [[ -z "$value" ]] && command -v gopass >/dev/null 2>&1; then
		value="$(gopass show -o "aidevops/${name}" 2>/dev/null || true)"
	fi
	[[ -n "$value" ]] || return 1
	printf '%s' "$value"
	return 0
}

# Print "credential_ref<TAB>locale<TAB>timezone<TAB>country" for a Reach egress profile.
read_egress_profile() {
	local profile_name="$1"
	# shellcheck source=./reach-core-lib.sh
	# shellcheck disable=SC1091
	source "${SCRIPT_DIR}/reach-core-lib.sh"
	local profile_file
	profile_file="$(egress_file_for_profile "$profile_name")"
	if [[ ! -f "$profile_file" ]]; then
		print_error "Egress profile not found: $profile_name (register with reach-helper.sh egress register)"
		return 1
	fi
	jq -r '[.credential_ref // "", .locale // "", .timezone // "", .country // ""] | @tsv' "$profile_file"
	return 0
}

check_runtime() {
	if ! command -v node >/dev/null 2>&1; then
		print_error "Node.js is required"
		return 1
	fi
	if ! node "${SCRIPT_DIR}/playwright-runtime.mjs" check >/dev/null; then
		print_error "Playwright runtime unavailable. Run: node ~/.aidevops/agents/scripts/playwright-runtime.mjs install"
		return 1
	fi
	return 0
}

cmd_probe() {
	local dry_run="$1"
	shift
	local egress_profile="" proxy_secret=""
	local -a probe_args=()
	local has_gl="false" has_hl="false"
	while [[ $# -gt 0 ]]; do
		local option="$1"
		case "$option" in
		--egress-profile)
			egress_profile="${2:-}"
			shift 2
			;;
		--proxy-secret)
			proxy_secret="${2:-}"
			shift 2
			;;
		--gl | --hl)
			[[ "$option" == "--gl" ]] && has_gl="true"
			[[ "$option" == "--hl" ]] && has_hl="true"
			probe_args+=("$option" "${2:-}")
			shift 2
			;;
		*)
			probe_args+=("$option")
			shift
			;;
		esac
	done

	if [[ -n "$egress_profile" ]]; then
		local profile_tsv credential_ref locale timezone country
		profile_tsv="$(read_egress_profile "$egress_profile")" || return 1
		IFS=$'\t' read -r credential_ref locale timezone country <<<"$profile_tsv"
		[[ -z "$proxy_secret" ]] && proxy_secret="$credential_ref"
		[[ -n "$locale" ]] && probe_args+=(--locale "$locale")
		[[ -n "$timezone" ]] && probe_args+=(--timezone "$timezone")
		if [[ -n "$country" && "$has_gl" == "false" ]]; then
			probe_args+=(--gl "$(printf '%s' "$country" | tr '[:upper:]' '[:lower:]')")
		fi
		if [[ -n "$locale" && "$has_hl" == "false" ]]; then
			probe_args+=(--hl "${locale%%-*}")
		fi
	fi

	local proxy_value=""
	if [[ -n "$proxy_secret" ]]; then
		if [[ ! "$proxy_secret" =~ ^[A-Z][A-Z0-9_]{1,127}$ ]]; then
			print_error "--proxy-secret must be an aidevops secret name, not a URL"
			return 1
		fi
		if ! proxy_value="$(resolve_secret "$proxy_secret")"; then
			print_error "Proxy secret not found: set it with: aidevops secret set $proxy_secret"
			return 1
		fi
	fi

	if [[ "$dry_run" == "true" ]]; then
		probe_args+=(--dry-run)
	else
		check_runtime || return 1
	fi

	SERP_PROBE_PROXY="$proxy_value" AIDEVOPS_SERP_PROBE_DIR="$PROBE_WORKSPACE" \
		node "$PROBE_SCRIPT" "${probe_args[@]}"
	return $?
}

cmd_last() {
	local runs_dir="${PROBE_WORKSPACE}/runs"
	local latest=""
	if [[ -d "$runs_dir" ]]; then
		latest="$(find "$runs_dir" -mindepth 2 -maxdepth 2 -name report.json -print | sort | tail -n 1)"
	fi
	if [[ -z "$latest" ]]; then
		print_info "No probe runs yet"
		return 0
	fi
	jq '{run_id, engine, browser, automation_signals, egress, profile, pacing_seconds, started_at, ended_at, planned, attempted, succeeded, first_block, stop_reason, run_dir}' "$latest"
	return 0
}

main() {
	local command="${1:-help}"
	shift || true
	case "$command" in
	run) cmd_probe "false" "$@" ;;
	plan) cmd_probe "true" "$@" ;;
	last) cmd_last ;;
	help | --help | -h) show_help ;;
	*)
		print_error "Unknown command: $command"
		show_help
		return 1
		;;
	esac
	return $?
}

main "$@"
