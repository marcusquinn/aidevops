#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# sensitivity-detector-helper.sh — Sensitivity classification for knowledge plane sources
#
# Stamps each ingested source's meta.json with a sensitivity tier using:
#   1. Regex/pattern matching (NI, IBAN, payment cards, email, phone, postcode)
#   2. Path/filename heuristics (legal/, privileged/, board-minutes/)
#   3. Maintainer override (--sensitivity flag or override subcommand)
#   4. Precautionary upgrade for ambiguous content (P0.5c local-LLM pending)
#
# Detection runs entirely offline — no network calls, no cloud LLM.
#
# Usage:
#   sensitivity-detector-helper.sh classify <source-id> [--knowledge-root <path>]
#   sensitivity-detector-helper.sh audit-log <source-id> <tier> <evidence> [--knowledge-root <path>]
#   sensitivity-detector-helper.sh override <source-id> <tier> [--reason <reason>] [--knowledge-root <path>]
#   sensitivity-detector-helper.sh show <source-id> [--knowledge-root <path>]
#   sensitivity-detector-helper.sh help
#
# Sensitivity tiers (lowest to highest):
#   public      No restrictions — marketing copy, public docs
#   internal    Internal business docs — not public, not personal
#   pii         Personal data — names, addresses, ID/payment numbers
#   sensitive   Sensitive business — board minutes, strategy, HR
#   competitive Competitive intel — _campaigns/intel/ enforced, local-LLM-only (Ollama), never cloud, retention months not years
#   privileged  Legally privileged — attorney-client, court filings
#
# Audit log: <knowledge-root>/index/sensitivity-audit.log (JSONL)
# Config:    <knowledge-root>/_config/sensitivity.json (falls back to template)
#
# Exit codes:
#   0  Success
#   1  Error (bad args, missing file, malformed JSON)
#   2  Source not found
#   3  Knowledge root not found
#
# t2846 / GH#20899 | competitive tier: t2964 / GH#21252

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=shared-constants.sh
[[ -f "${SCRIPT_DIR}/shared-constants.sh" ]] && source "${SCRIPT_DIR}/shared-constants.sh"

# Guard color fallbacks when shared-constants.sh is absent
[[ -z "${GREEN+x}" ]]  && GREEN='\033[0;32m'
[[ -z "${YELLOW+x}" ]] && YELLOW='\033[1;33m'
[[ -z "${RED+x}" ]]    && RED='\033[0;31m'
[[ -z "${BLUE+x}" ]]   && BLUE='\033[0;34m'
[[ -z "${NC+x}" ]]     && NC='\033[0m'

if ! declare -f print_info >/dev/null 2>&1; then
	print_info()    { local _m="$1"; printf "${BLUE}[INFO]${NC} %s\n" "$_m" >&2; }
fi
if ! declare -f print_success >/dev/null 2>&1; then
	print_success() { local _m="$1"; printf "${GREEN}[OK]${NC} %s\n" "$_m" >&2; }
fi
if ! declare -f print_warning >/dev/null 2>&1; then
	print_warning() { local _m="$1"; printf "${YELLOW}[WARN]${NC} %s\n" "$_m" >&2; }
fi
if ! declare -f print_error >/dev/null 2>&1; then
	print_error()   { local _m="$1"; printf "${RED}[ERROR]${NC} %s\n" "$_m" >&2; }
fi

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------

KNOWLEDGE_ROOT_DEFAULT="_knowledge"
SENSITIVITY_CONFIG_NAME="sensitivity.json"
SENSITIVITY_CONFIG_SUBDIR="_config"
AUDIT_LOG_SUBDIR="index"
AUDIT_LOG_FILE="sensitivity-audit.log"
META_FILE="meta.json"

SCRIPT_TEMPLATES_DIR="${SCRIPT_DIR%/scripts}/templates"
SENSITIVITY_CONFIG_TEMPLATE="${SCRIPT_TEMPLATES_DIR}/sensitivity-config.json"

# Tier precedence order (highest to lowest) — position 0 is strongest
TIER_PRECEDENCE="privileged competitive sensitive pii internal public"
# Tier string constants (avoids repeated literals)
_T_PUBLIC="public"
_T_INTERNAL="internal"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

_require_jq() {
	if ! command -v jq >/dev/null 2>&1; then
		print_error "jq is required but not installed"
		return 1
	fi
	return 0
}

_resolve_knowledge_root() {
	local explicit_root="$1"
	local candidate
	if [[ -n "$explicit_root" ]]; then
		echo "$explicit_root"
		return 0
	fi
	# Walk up from cwd looking for _knowledge/
	candidate="$(pwd)"
	while [[ "$candidate" != "/" ]]; do
		if [[ -d "${candidate}/${KNOWLEDGE_ROOT_DEFAULT}" ]]; then
			echo "${candidate}/${KNOWLEDGE_ROOT_DEFAULT}"
			return 0
		fi
		candidate="$(dirname "$candidate")"
	done
	# Fallback: personal plane
	local personal="${HOME}/.aidevops/.agent-workspace/knowledge/${KNOWLEDGE_ROOT_DEFAULT}"
	if [[ -d "$personal" ]]; then
		echo "$personal"
		return 0
	fi
	print_error "Cannot find knowledge root. Pass --knowledge-root <path> explicitly."
	return 3
}

_load_sensitivity_config() {
	local knowledge_root="$1"
	local config_path="${knowledge_root}/${SENSITIVITY_CONFIG_SUBDIR}/${SENSITIVITY_CONFIG_NAME}"
	if [[ -f "$config_path" ]]; then
		echo "$config_path"
		return 0
	fi
	# Fall back to template
	if [[ -f "$SENSITIVITY_CONFIG_TEMPLATE" ]]; then
		echo "$SENSITIVITY_CONFIG_TEMPLATE"
		return 0
	fi
	print_error "Sensitivity config not found at $config_path and template missing at $SENSITIVITY_CONFIG_TEMPLATE"
	return 1
}

_tier_rank() {
	local tier="$1"
	local rank=0
	local t
	for t in $TIER_PRECEDENCE; do
		if [[ "$t" == "$tier" ]]; then
			echo "$rank"
			return 0
		fi
		rank=$((rank + 1))
	done
	# Unknown tier — treat as internal (rank 3)
	echo "3"
	return 0
}

_higher_tier() {
	local tier_a="$1"
	local tier_b="$2"
	local rank_a rank_b
	rank_a=$(_tier_rank "$tier_a")
	rank_b=$(_tier_rank "$tier_b")
	# Lower rank = higher precedence
	if [[ "$rank_a" -le "$rank_b" ]]; then
		echo "$tier_a"
	else
		echo "$tier_b"
	fi
	return 0
}

_valid_tier() {
	local tier="$1"
	local t
	for t in $TIER_PRECEDENCE; do
		[[ "$t" == "$tier" ]] && return 0
	done
	return 1
}

# ---------------------------------------------------------------------------
# Pattern matching against text content
# ---------------------------------------------------------------------------

_apply_regex_patterns() {
	local content="$1"
	local config_path="$2"
	local detected_tier="$_T_PUBLIC"
	local pattern_name regex tier evidence
	local pattern_count
	_require_jq || return 1
	pattern_count=$(jq '.patterns | length' "$config_path" 2>/dev/null || echo 0)
	local i=0
	while [[ "$i" -lt "$pattern_count" ]]; do
		pattern_name=$(jq -r ".patterns | keys[$i]" "$config_path")
		regex=$(jq -r ".patterns[\"${pattern_name}\"].regex" "$config_path")
		tier=$(jq -r ".patterns[\"${pattern_name}\"].tier" "$config_path")
		if echo "$content" | grep -qE "$regex" 2>/dev/null; then
			evidence="regex:${pattern_name}"
			detected_tier=$(_higher_tier "$detected_tier" "$tier")
			# Short-circuit on highest tier
			if [[ "$detected_tier" == "privileged" ]]; then
				echo "${detected_tier}|${evidence}"
				return 0
			fi
		fi
		i=$((i + 1))
	done
	echo "${detected_tier}|"
	return 0
}

# ---------------------------------------------------------------------------
# Path heuristics
# ---------------------------------------------------------------------------

_apply_path_heuristics() {
	local source_uri="$1"
	local config_path="$2"
	_require_jq || return 1
	local heuristic_count glob_pattern tier matched_tier matched_glob
	matched_tier="$_T_PUBLIC"
	matched_glob=""
	heuristic_count=$(jq '.path_heuristics | length' "$config_path" 2>/dev/null || echo 0)
	local i=0
	while [[ "$i" -lt "$heuristic_count" ]]; do
		glob_pattern=$(jq -r ".path_heuristics[$i].glob" "$config_path")
		tier=$(jq -r ".path_heuristics[$i].tier" "$config_path")
		# Convert glob to grep-compatible pattern (** -> .*, * -> [^/]*)
		local grep_pattern
		grep_pattern=$(echo "$glob_pattern" | sed 's|\*\*|.DSTAR.|g; s|\*|[^/]*|g; s|\.DSTAR\.|.*|g')
		if echo "$source_uri" | grep -qE "$grep_pattern" 2>/dev/null; then
			local candidate
			candidate=$(_higher_tier "$matched_tier" "$tier")
			if [[ "$candidate" != "$matched_tier" ]]; then
				matched_tier="$candidate"
				matched_glob="$glob_pattern"
			fi
		fi
		i=$((i + 1))
	done
	echo "${matched_tier}|${matched_glob}"
	return 0
}

# ---------------------------------------------------------------------------
# Source lookup helpers
# ---------------------------------------------------------------------------

_find_source_dir() {
	local source_id="$1"
	local knowledge_root="$2"
	local sources_dir="${knowledge_root}/sources/${source_id}"
	if [[ -d "$sources_dir" ]]; then
		echo "$sources_dir"
		return 0
	fi
	return 2
}

_read_meta() {
	local source_dir="$1"
	local meta_path="${source_dir}/${META_FILE}"
	if [[ ! -f "$meta_path" ]]; then
		return 2
	fi
	echo "$meta_path"
	return 0
}

_get_source_content() {
	local source_dir="$1"
	local meta_path="$2"
	_require_jq || return 1
	local blob_path source_file content
	# Check blob_path first
	blob_path=$(jq -r '.blob_path // empty' "$meta_path" 2>/dev/null || true)
	if [[ -n "$blob_path" ]] && [[ "$blob_path" != "null" ]]; then
		# Expand ~ if present
		blob_path="${blob_path/#\~/$HOME}"
		if [[ -f "$blob_path" ]]; then
			# Read first 64KB for classification
			content=$(dd if="$blob_path" bs=1024 count=64 2>/dev/null | strings 2>/dev/null || true)
			echo "$content"
			return 0
		fi
	fi
	# Read first content file found in source_dir (excluding meta.json)
	source_file=$(find "$source_dir" -maxdepth 1 -type f ! -name "$META_FILE" | head -1)
	if [[ -n "$source_file" ]]; then
		# Read first 64KB as text; strings handles binary
		content=$(dd if="$source_file" bs=1024 count=64 2>/dev/null | strings 2>/dev/null || true)
		echo "$content"
		return 0
	fi
	echo ""
	return 0
}

# ---------------------------------------------------------------------------
# Audit log
# ---------------------------------------------------------------------------

_append_audit_log() {
	local knowledge_root="$1"
	local source_id="$2"
	local tier="$3"
	local evidence="$4"
	local actor="$5"
	local audit_dir="${knowledge_root}/${AUDIT_LOG_SUBDIR}"
	local audit_log="${audit_dir}/${AUDIT_LOG_FILE}"
	mkdir -p "$audit_dir"
	local ts
	ts=$(date -u +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || date +"%Y-%m-%dT%H:%M:%SZ")
	# Escape double-quotes in evidence for valid JSON
	local evidence_escaped
	evidence_escaped=$(printf '%s' "$evidence" | sed 's/"/\\"/g')
	local actor_escaped
	actor_escaped=$(printf '%s' "$actor" | sed 's/"/\\"/g')
	local log_entry
	log_entry="{\"ts\":\"${ts}\",\"source_id\":\"${source_id}\",\"tier\":\"${tier}\",\"evidence\":\"${evidence_escaped}\",\"actor\":\"${actor_escaped}\"}"
	echo "$log_entry" >>"$audit_log"
	return 0
}

# ---------------------------------------------------------------------------
# meta.json update
# ---------------------------------------------------------------------------

_update_meta_sensitivity() {
	local meta_path="$1"
	local tier="$2"
	_require_jq || return 1
	local tmp_file
	tmp_file=$(mktemp)
	jq --arg tier "$tier" '.sensitivity = $tier' "$meta_path" >"$tmp_file"
	if ! jq . "$tmp_file" >/dev/null 2>&1; then
		print_error "JSON validation failed — meta.json not modified"
		rm -f "$tmp_file"
		return 1
	fi
	mv "$tmp_file" "$meta_path"
	return 0
}

# ---------------------------------------------------------------------------
# Subcommands
# ---------------------------------------------------------------------------

cmd_classify() {
	local source_id=""
	local knowledge_root_explicit=""
	# Parse args
	while [[ $# -gt 0 ]]; do
		local _key="$1"
		shift
		case "$_key" in
		--knowledge-root)
			local _val="$1"
			knowledge_root_explicit="$_val"
			shift
			;;
		-*)
			print_error "Unknown option: $_key"
			return 1
			;;
		*)
			if [[ -z "$source_id" ]]; then
				source_id="$_key"
			fi
			;;
		esac
	done
	if [[ -z "$source_id" ]]; then
		print_error "classify requires <source-id>"
		return 1
	fi
	_require_jq || return 1
	local knowledge_root
	knowledge_root=$(_resolve_knowledge_root "$knowledge_root_explicit") || return 3
	local config_path
	config_path=$(_load_sensitivity_config "$knowledge_root") || return 1
	local source_dir
	if ! source_dir=$(_find_source_dir "$source_id" "$knowledge_root"); then
		print_error "Source not found: ${knowledge_root}/sources/${source_id}"
		return 2
	fi
	local meta_path
	if ! meta_path=$(_read_meta "$source_dir"); then
		print_error "meta.json not found in $source_dir"
		return 2
	fi
	# 1. Check for existing override in meta.json
	local existing_override
	existing_override=$(jq -r '.sensitivity_override // empty' "$meta_path" 2>/dev/null || true)
	if [[ -n "$existing_override" ]] && _valid_tier "$existing_override"; then
		_update_meta_sensitivity "$meta_path" "$existing_override"
		_append_audit_log "$knowledge_root" "$source_id" "$existing_override" "override:meta.json" "sensitivity-detector"
		print_success "[$source_id] tier=${existing_override} (from meta.json override)"
		echo "$existing_override"
		return 0
	fi
	# 2. Path heuristics on source_uri
	local source_uri
	source_uri=$(jq -r '.source_uri // empty' "$meta_path" 2>/dev/null || true)
	local path_result path_tier path_evidence
	path_result=$(_apply_path_heuristics "$source_uri" "$config_path")
	path_tier="${path_result%%|*}"
	path_evidence="${path_result##*|}"
	# 3. Regex patterns on content
	local content
	content=$(_get_source_content "$source_dir" "$meta_path")
	local regex_result regex_tier regex_evidence
	regex_result=$(_apply_regex_patterns "$content" "$config_path")
	regex_tier="${regex_result%%|*}"
	regex_evidence="${regex_result##*|}"
	# 4. Take highest tier from path + regex
	local final_tier evidence_combined
	final_tier=$(_higher_tier "$path_tier" "$regex_tier")
	evidence_combined=""
	[[ -n "$path_evidence" ]] && evidence_combined="path:${path_evidence}"
	if [[ -n "$regex_evidence" ]]; then
		if [[ -n "$evidence_combined" ]]; then
			evidence_combined="${evidence_combined},${regex_evidence}"
		else
			evidence_combined="$regex_evidence"
		fi
	fi
	[[ -z "$evidence_combined" ]] && evidence_combined="default"
	# 5. Precautionary upgrade when no strong signal (public/internal → internal)
	local precautionary
	precautionary=$(jq -r '.precautionary_upgrade // true' "$config_path" 2>/dev/null || echo "true")
	if [[ "$precautionary" == "true" ]] && [[ "$final_tier" == "$_T_PUBLIC" ]] && [[ -z "$source_uri" ]]; then
		final_tier="$_T_INTERNAL"
		evidence_combined="${evidence_combined},precautionary-upgrade"
	fi
	# 6. Write tier to meta.json
	_update_meta_sensitivity "$meta_path" "$final_tier" || return 1
	# 7. Append audit log
	_append_audit_log "$knowledge_root" "$source_id" "$final_tier" "$evidence_combined" "sensitivity-detector"
	print_success "[$source_id] tier=${final_tier} evidence=${evidence_combined}"
	echo "$final_tier"
	return 0
}

cmd_audit_log() {
	local source_id="${1:-}"
	local tier="${2:-}"
	local evidence="${3:-}"
	local knowledge_root_explicit=""
	shift 3 2>/dev/null || true
	while [[ $# -gt 0 ]]; do
		local _key="$1"
		shift
		case "$_key" in
		--knowledge-root)
			local _val="$1"
			knowledge_root_explicit="$_val"
			shift
			;;
		*) ;;
		esac
	done
	if [[ -z "$source_id" ]] || [[ -z "$tier" ]] || [[ -z "$evidence" ]]; then
		print_error "audit-log requires <source-id> <tier> <evidence>"
		return 1
	fi
	if ! _valid_tier "$tier"; then
		print_error "Invalid tier: $tier (must be one of: $TIER_PRECEDENCE)"
		return 1
	fi
	local knowledge_root
	knowledge_root=$(_resolve_knowledge_root "$knowledge_root_explicit") || return 3
	local actor="${USER:-unknown}"
	_append_audit_log "$knowledge_root" "$source_id" "$tier" "$evidence" "$actor"
	print_success "Audit log entry written: source=$source_id tier=$tier"
	return 0
}

cmd_override() {
	local source_id=""
	local tier=""
	local reason="manual override"
	local knowledge_root_explicit=""
	while [[ $# -gt 0 ]]; do
		local _key="$1"
		shift
		case "$_key" in
		--reason)
			local _val="$1"
			reason="$_val"
			shift
			;;
		--knowledge-root)
			local _val="$1"
			knowledge_root_explicit="$_val"
			shift
			;;
		-*)
			print_error "Unknown option: $_key"
			return 1
			;;
		*)
			if [[ -z "$source_id" ]]; then
				source_id="$_key"
			elif [[ -z "$tier" ]]; then
				tier="$_key"
			fi
			;;
		esac
	done
	if [[ -z "$source_id" ]] || [[ -z "$tier" ]]; then
		print_error "override requires <source-id> <tier>"
		return 1
	fi
	if ! _valid_tier "$tier"; then
		print_error "Invalid tier: $tier (must be one of: $TIER_PRECEDENCE)"
		return 1
	fi
	_require_jq || return 1
	local knowledge_root
	knowledge_root=$(_resolve_knowledge_root "$knowledge_root_explicit") || return 3
	local source_dir
	if ! source_dir=$(_find_source_dir "$source_id" "$knowledge_root"); then
		print_error "Source not found: ${knowledge_root}/sources/${source_id}"
		return 2
	fi
	local meta_path
	if ! meta_path=$(_read_meta "$source_dir"); then
		print_error "meta.json not found in $source_dir"
		return 2
	fi
	# Write override fields to meta.json
	local tmp_file
	tmp_file=$(mktemp)
	jq --arg tier "$tier" --arg reason "$reason" \
		'.sensitivity = $tier | .sensitivity_override = $tier | .sensitivity_override_reason = $reason' \
		"$meta_path" >"$tmp_file"
	if ! jq . "$tmp_file" >/dev/null 2>&1; then
		print_error "JSON validation failed — meta.json not modified"
		rm -f "$tmp_file"
		return 1
	fi
	mv "$tmp_file" "$meta_path"
	local actor="${USER:-unknown}"
	_append_audit_log "$knowledge_root" "$source_id" "$tier" "override:manual:${reason}" "$actor"
	print_success "[$source_id] sensitivity overridden to ${tier} (reason: ${reason})"
	return 0
}

cmd_show() {
	local source_id=""
	local knowledge_root_explicit=""
	while [[ $# -gt 0 ]]; do
		local _key="$1"
		shift
		case "$_key" in
		--knowledge-root)
			local _val="$1"
			knowledge_root_explicit="$_val"
			shift
			;;
		*)
			if [[ -z "$source_id" ]]; then
				source_id="$_key"
			fi
			;;
		esac
	done
	if [[ -z "$source_id" ]]; then
		print_error "show requires <source-id>"
		return 1
	fi
	_require_jq || return 1
	local knowledge_root
	knowledge_root=$(_resolve_knowledge_root "$knowledge_root_explicit") || return 3
	local source_dir
	if ! source_dir=$(_find_source_dir "$source_id" "$knowledge_root"); then
		print_error "Source not found: $source_id"
		return 2
	fi
	local meta_path
	if ! meta_path=$(_read_meta "$source_dir"); then
		print_error "meta.json not found"
		return 2
	fi
	local tier override reason
	tier=$(jq -r '.sensitivity // "unclassified"' "$meta_path")
	override=$(jq -r '.sensitivity_override // empty' "$meta_path")
	reason=$(jq -r '.sensitivity_override_reason // empty' "$meta_path")
	echo "source_id: $source_id"
	echo "tier:      $tier"
	[[ -n "$override" ]] && echo "override:  $override (reason: ${reason:-none})"
	# Show recent audit entries
	local audit_log="${knowledge_root}/${AUDIT_LOG_SUBDIR}/${AUDIT_LOG_FILE}"
	if [[ -f "$audit_log" ]]; then
		echo ""
		echo "Recent audit entries:"
		grep "\"${source_id}\"" "$audit_log" 2>/dev/null | tail -5 || true
	fi
	return 0
}

cmd_help() {
	sed -n '4,40p' "$0" | sed 's/^# \{0,1\}//'
	return 0
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

main() {
	local subcommand="${1:-help}"
	shift || true
	case "$subcommand" in
	classify)   cmd_classify "$@" ;;
	audit-log)  cmd_audit_log "$@" ;;
	override)   cmd_override "$@" ;;
	show)       cmd_show "$@" ;;
	help | -h | --help) cmd_help ;;
	*)
		print_error "Unknown subcommand: $subcommand"
		cmd_help
		exit 1
		;;
	esac
	return 0
}

main "$@"
