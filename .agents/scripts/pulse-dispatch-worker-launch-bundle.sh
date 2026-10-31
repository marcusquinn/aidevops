#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# Bundle workload classification and agent routing for worker launch.
# Sourced by pulse-dispatch-worker-launch.sh; depends on sibling bundle-helper.sh.
# Function bodies remain unchanged from the launch orchestrator (GH#35810).

[[ "${BASH_SOURCE[0]}" == "${0}" ]] && set -euo pipefail

[[ -n "${_PULSE_DISPATCH_WORKER_LAUNCH_BUNDLE_LOADED:-}" ]] && return 0
_PULSE_DISPATCH_WORKER_LAUNCH_BUNDLE_LOADED=1

# Match the library fallback when sourced without the dispatch core.
if [[ -z "${SCRIPT_DIR:-}" ]]; then
	_dlw_bundle_lib_path="${BASH_SOURCE[0]%/*}"
	[[ "$_dlw_bundle_lib_path" == "${BASH_SOURCE[0]}" ]] && _dlw_bundle_lib_path="."
	SCRIPT_DIR="$(cd "$_dlw_bundle_lib_path" && pwd)"
	unset _dlw_bundle_lib_path
fi

#######################################
# Classify a worker request into a bundle workload type. This is separate from
# agent_routing domains such as seo, content, and infrastructure.
# The title is authoritative because generated worker prompts contain generic
# review and verification instructions that must not affect model selection.
# Only explicit conventional title prefixes select a non-implementation type;
# incidental workload words in implementation titles remain implementation.
# Arguments:
#   $1 - issue_title
#   $2 - prompt (used only when the title is empty)
# Stdout: model_defaults key
#######################################
_dlw_bundle_workload_type() {
	local issue_title="$1"
	local prompt="$2"
	local text="$issue_title"
	if [[ -z "$text" ]]; then
		text="$prompt"
	fi
	text=$(printf '%s' "$text" | tr '[:upper:]' '[:lower:]')

	case "$text" in
	docs:* | docs\(* | documentation:* | documentation\(* | chore\(docs\):*) printf 'documentation\n' ;;
	architecture:* | architecture\(* | architectural:* | architectural\(*) printf 'architecture\n' ;;
	review:* | review\(*) printf 'review\n' ;;
	triage:* | triage\(*) printf 'triage\n' ;;
	verification:* | verification\(* | verify:* | verify\(*) printf 'verification\n' ;;
	*) printf 'implementation\n' ;;
	esac
	return 0
}

#######################################
# Classify a task into a coarse bundle agent_routing domain.
# Arguments:
#   $1 - issue_title
#   $2 - prompt
# Stdout: routing domain key
#######################################
_dlw_bundle_routing_domain() {
	local issue_title="$1"
	local prompt="$2"
	local text
	text=$(printf '%s %s' "$issue_title" "$prompt" | tr '[:upper:]' '[:lower:]')

	case "$text" in
	*seo* | *sitemap* | *schema* | *ranking* | *metadata* | *meta\ tag*)
		printf 'seo\n'
		return 0
		;;
	*content* | *blog* | *newsletter* | *social* | *video* | *copywriting*)
		printf 'content\n'
		return 0
		;;
	*accessibility* | *a11y* | *wcag*)
		printf 'accessibility\n'
		return 0
		;;
	*deploy* | *docker* | *terraform* | *infrastructure* | *cloudflare*)
		printf 'infrastructure\n'
		return 0
		;;
	*document* | *readme* | *docs*)
		printf 'documentation\n'
		return 0
		;;
	*)
		printf 'code\n'
		return 0
		;;
	esac
}

#######################################
# Resolve preferred worker agent from bundle agent_routing.
# Arguments:
#   $1 - repo_path
#   $2 - issue_title
#   $3 - prompt
# Stdout: agent name (empty if unavailable)
#######################################
_dlw_bundle_agent_name() {
	local repo_path="$1"
	local issue_title="$2"
	local prompt="$3"
	local bundle_helper="${_DLW_SCRIPT_DIR:-${BASH_SOURCE[0]%/*}}/bundle-helper.sh"

	if [[ -z "$repo_path" || ! -x "$bundle_helper" ]]; then
		return 0
	fi

	local domain
	domain=$(_dlw_bundle_routing_domain "$issue_title" "$prompt")
	"$bundle_helper" resolve "$repo_path" 2>/dev/null | jq -r --arg domain "$domain" \
		'.agent_routing[$domain] // .agent_routing.code // empty' 2>/dev/null || true
	return 0
}
