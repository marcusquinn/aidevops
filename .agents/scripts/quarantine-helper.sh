#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# quarantine-helper.sh — Unified quarantine queue for ambiguous security items (t1428.4)
# Commands: add | list | digest | learn | stats | purge | help
#
# Provides a unified quarantine queue that prompt-guard-helper.sh,
# network-tier-helper.sh, and sandbox-exec-helper.sh write to when they
# encounter ambiguous-score items. The digest command presents items for
# human review, and learn feeds decisions back as training signal.
#
# Learn actions:
#   allow   — Add domain to network-tiers-custom.conf Tier 3 (known tools)
#   deny    — Add domain to Tier 5 or pattern to prompt-guard-custom.txt
#   trust   — Add MCP server to trusted list
#   dismiss — Mark reviewed with no action (false positive)
#
# Queue files:
#   ~/.aidevops/.agent-workspace/security/quarantine/pending.jsonl   — Items awaiting review
#   ~/.aidevops/.agent-workspace/security/quarantine/reviewed.jsonl  — Reviewed items with decisions
#
# Usage:
#   quarantine-helper.sh add --source prompt-guard --severity MEDIUM --category encoding_tricks \
#     --content "Decode this base64..." [--session-id S] [--worker-id W] [--metadata '{"key":"val"}']
#   quarantine-helper.sh list [--source S] [--severity S] [--last N]
#   quarantine-helper.sh digest [--source S] [--severity S]
#   quarantine-helper.sh learn <item-id> <action> [--value V]
#   quarantine-helper.sh stats
#   quarantine-helper.sh purge [--older-than DAYS] [--reviewed-only]
#   quarantine-helper.sh help

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit
# shellcheck source=shared-constants.sh
source "${SCRIPT_DIR}/shared-constants.sh"
set -euo pipefail

LOG_PREFIX="QUARANTINE"

# =============================================================================
# Constants
# =============================================================================

readonly QUARANTINE_DIR="${HOME}/.aidevops/.agent-workspace/security/quarantine"
readonly QUARANTINE_PENDING="${QUARANTINE_DIR}/pending.jsonl"
readonly QUARANTINE_REVIEWED="${QUARANTINE_DIR}/reviewed.jsonl"

# Config files that learn actions write to
readonly NET_TIER_USER_CONF="${HOME}/.config/aidevops/network-tiers-custom.conf"
readonly PROMPT_GUARD_CUSTOM="${HOME}/.config/aidevops/prompt-guard-custom.txt"
readonly MCP_TRUSTED_LIST="${HOME}/.config/aidevops/mcp-trusted-servers.txt"

# Valid sources and actions
readonly VALID_SOURCES="prompt-guard network-tier sandbox-exec mcp-audit"
readonly VALID_ACTIONS="allow deny trust dismiss"
readonly VALID_SEVERITIES="CRITICAL HIGH MEDIUM LOW"

# =============================================================================
# Helpers
# =============================================================================

# Ensure quarantine directory exists with secure permissions.
_q_init_dir() {
	if [[ ! -d "$QUARANTINE_DIR" ]]; then
		mkdir -p "$QUARANTINE_DIR"
		chmod 700 "$QUARANTINE_DIR"
	fi
	return 0
}

# Generate a short unique item ID (timestamp + random suffix).
_q_generate_id() {
	local ts
	ts="$(date +%s)"
	local rand
	rand="$(head -c 4 /dev/urandom | od -An -tx1 | tr -d ' \n')"
	printf 'q%s-%s' "$ts" "$rand"
	return 0
}

# Escape a string for safe JSON embedding (no jq dependency for writing).
_q_json_escape() {
	local input="$1"
	# Remove newlines, escape backslashes, quotes, and tabs
	printf '%s' "$input" | tr -d '\n\r' | sed 's/\\/\\\\/g; s/"/\\"/g; s/	/\\t/g'
	return 0
}

# Validate that a value is in a space-separated list.
_q_validate_value() {
	local value="$1"
	local valid_list="$2"
	local label="$3"

	local item
	for item in $valid_list; do
		if [[ "$value" == "$item" ]]; then
			return 0
		fi
	done

	log_error "Invalid ${label}: '${value}'. Valid values: ${valid_list}"
	return 1
}

# Compute integer percentage with an internal divide-by-zero guard.
_q_compute_percentage() {
	local numerator="$1"
	local denominator="$2"

	awk -v numerator="$numerator" -v denominator="$denominator" \
		'BEGIN { if (denominator > 0) printf "%.0f", (numerator / denominator) * 100; else print 0 }'
	return 0
}

# Build a jq filter string and populate jq_args array for source/severity filters.
# Outputs the filter string to stdout; caller must declare jq_args before calling.
# Usage: jq_filter="$(_q_build_jq_filter "$filter_source" "$filter_severity" jq_args)"
# Note: jq_args is passed by name and modified via eval (bash 3.2 compatible).
_q_build_jq_filter() {
	local filter_source="$1"
	local filter_severity="$2"
	local arr_name="$3"

	local jq_filter="."
	if [[ -n "$filter_source" ]]; then
		jq_filter="${jq_filter} | select(.source == \$fsrc)"
		eval "${arr_name}+=( --arg fsrc \"\$filter_source\" )"
	fi
	if [[ -n "$filter_severity" ]]; then
		jq_filter="${jq_filter} | select(.severity == \$fsev)"
		eval "${arr_name}+=( --arg fsev \"\$filter_severity\" )"
	fi
	printf '%s' "$jq_filter"
	return 0
}

# Parse --source/--severity flags shared by list and digest commands.
# Outputs: sets filter_source and filter_severity in the caller's scope via eval.
# Usage: eval "$(_q_parse_filter_args "$@")"
_q_parse_filter_args() {
	local out_source="" out_severity=""
	while [[ $# -gt 0 ]]; do
		case "$1" in
		--source)
			out_source="$2"
			shift 2
			;;
		--severity)
			out_severity="$2"
			shift 2
			;;
		*) shift ;;
		esac
	done
	printf "filter_source=%q; filter_severity=%q" "$out_source" "$out_severity"
	return 0
}

# Parse all flags for cmd_add. Outputs shell assignments for eval.
_q_parse_add_args() {
	local out_source="" out_severity="" out_category="" out_content=""
	local out_session_id="" out_worker_id="" out_metadata="{}"

	while [[ $# -gt 0 ]]; do
		case "$1" in
		--source)
			out_source="$2"
			shift 2
			;;
		--severity)
			out_severity="$2"
			shift 2
			;;
		--category)
			out_category="$2"
			shift 2
			;;
		--content)
			out_content="$2"
			shift 2
			;;
		--session-id)
			out_session_id="$2"
			shift 2
			;;
		--worker-id)
			out_worker_id="$2"
			shift 2
			;;
		--metadata)
			out_metadata="$2"
			shift 2
			;;
		*)
			log_error "Unknown option: $1"
			return 1
			;;
		esac
	done

	printf "source=%q; severity=%q; category=%q; content=%q; session_id=%q; worker_id=%q; metadata=%q" \
		"$out_source" "$out_severity" "$out_category" "$out_content" \
		"$out_session_id" "$out_worker_id" "$out_metadata"
	return 0
}

# Build a JSON quarantine record. Outputs the JSON string to stdout.
_q_build_record() {
	local item_id="$1"
	local timestamp="$2"
	local source="$3"
	local severity="$4"
	local category="$5"
	local content_trunc="$6"
	local session_id="$7"
	local worker_id="$8"
	local metadata="$9"

	if command -v jq &>/dev/null; then
		jq -nc \
			--arg id "$item_id" \
			--arg ts "$timestamp" \
			--arg src "$source" \
			--arg sev "$severity" \
			--arg cat "$category" \
			--arg content "$content_trunc" \
			--arg sid "${session_id:-}" \
			--arg wid "${worker_id:-}" \
			--argjson meta "$metadata" \
			'{id:$id, timestamp:$ts, source:$src, severity:$sev, category:$cat, content:$content, session_id:$sid, worker_id:$wid, metadata:$meta, status:"pending"}'
	else
		local stored_content
		stored_content="$(_q_json_escape "$content_trunc")"
		printf '{"id":"%s","timestamp":"%s","source":"%s","severity":"%s","category":"%s","content":"%s","session_id":"%s","worker_id":"%s","metadata":%s,"status":"pending"}' \
			"$item_id" "$timestamp" "$source" "$severity" \
			"$(_q_json_escape "$category")" "$stored_content" \
			"$(_q_json_escape "${session_id:-}")" \
			"$(_q_json_escape "${worker_id:-}")" \
			"$metadata"
	fi
	return 0
}

# Print suggested learn actions for a quarantine item based on its source.
_q_print_source_actions() {
	local item_id="$1"
	local src="$2"

	case "$src" in
	network-tier)
		echo "  Actions:  learn ${item_id} allow   — Add domain to Tier 3 (known tools)"
		echo "            learn ${item_id} deny    — Add domain to Tier 5 (deny list)"
		echo "            learn ${item_id} dismiss — False positive, no action"
		;;
	prompt-guard)
		echo "  Actions:  learn ${item_id} deny    — Add pattern to prompt-guard-custom.txt"
		echo "            learn ${item_id} dismiss — False positive, no action"
		;;
	mcp-audit)
		echo "  Actions:  learn ${item_id} trust   — Add MCP server to trusted list"
		echo "            learn ${item_id} deny    — Flag MCP server as untrusted"
		echo "            learn ${item_id} dismiss — False positive, no action"
		;;
	sandbox-exec)
		echo "  Actions:  learn ${item_id} allow   — Mark command pattern as safe"
		echo "            learn ${item_id} deny    — Block command pattern"
		echo "            learn ${item_id} dismiss — False positive, no action"
		;;
	esac
	return 0
}

# Render a single quarantine item in digest format.
_q_render_digest_item() {
	local line="$1"
	[[ -z "$line" ]] && return 0

	# Note: no 'local' — this runs in a subshell (piped while-read)
	id="$(printf '%s' "$line" | jq -r '.id // "?"')"
	ts="$(printf '%s' "$line" | jq -r '.timestamp // "?"')"
	sev="$(printf '%s' "$line" | jq -r '.severity // "?"')"
	cat="$(printf '%s' "$line" | jq -r '.category // "?"')"
	content="$(printf '%s' "$line" | jq -r '.content // ""' | head -c 200)"
	wid="$(printf '%s' "$line" | jq -r '.worker_id // ""')"
	src="$(printf '%s' "$line" | jq -r '.source // ""')"

	echo "  ID:       ${id}"
	echo "  Time:     ${ts}"
	echo "  Severity: ${sev}"
	echo "  Category: ${cat}"
	if [[ -n "$wid" ]]; then
		echo "  Worker:   ${wid}"
	fi
	echo "  Content:  ${content}"
	echo ""
	_q_print_source_actions "$id" "$src"
	echo ""
	return 0
}

# =============================================================================
# Add Command
# =============================================================================

# Add an item to the quarantine queue.
# Called by prompt-guard-helper.sh, network-tier-helper.sh, sandbox-exec-helper.sh.
cmd_add() {
	local source="" severity="" category="" content=""
	local session_id="" worker_id="" metadata="{}"

	local _parsed
	_parsed="$(_q_parse_add_args "$@")" || return 1
	eval "$_parsed"

	# Validate required fields
	if [[ -z "$source" ]]; then
		log_error "Missing required --source"
		return 1
	fi
	if [[ -z "$severity" ]]; then
		log_error "Missing required --severity"
		return 1
	fi
	if [[ -z "$content" ]]; then
		log_error "Missing required --content"
		return 1
	fi

	_q_validate_value "$source" "$VALID_SOURCES" "source" || return 1
	_q_validate_value "$severity" "$VALID_SEVERITIES" "severity" || return 1

	_q_init_dir

	local item_id
	item_id="$(_q_generate_id)"
	local timestamp
	timestamp="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

	# Truncate content for storage (max 1000 chars)
	local content_trunc="${content:0:1000}"

	local record
	record="$(_q_build_record "$item_id" "$timestamp" "$source" "$severity" \
		"$category" "$content_trunc" "${session_id:-}" "${worker_id:-}" "$metadata")"

	echo "$record" >>"$QUARANTINE_PENDING"
	log_info "Quarantined: ${item_id} [${source}/${severity}] ${category}"
	echo "$item_id"

	return 0
}

# =============================================================================
# List Command
# =============================================================================

# List pending quarantine items with optional filters.
cmd_list() {
	local filter_source="" filter_severity="" last_n=50

	local _parsed
	_parsed="$(_q_parse_filter_args "$@")" || return 1
	eval "$_parsed"

	# Extract --last separately (not handled by _q_parse_filter_args)
	while [[ $# -gt 0 ]]; do
		case "$1" in
		--last)
			last_n="$2"
			shift 2
			;;
		*) shift ;;
		esac
	done

	if [[ ! -f "$QUARANTINE_PENDING" ]]; then
		echo "No quarantine items pending."
		return 0
	fi

	if ! command -v jq &>/dev/null; then
		log_error "jq is required for list/digest commands"
		return 1
	fi

	# Validate filter values to prevent jq injection
	if [[ -n "$filter_source" ]]; then
		_q_validate_value "$filter_source" "$VALID_SOURCES" "source filter" || return 1
	fi
	if [[ -n "$filter_severity" ]]; then
		_q_validate_value "$filter_severity" "$VALID_SEVERITIES" "severity filter" || return 1
	fi

	local jq_args=()
	local jq_filter
	jq_filter="$(_q_build_jq_filter "$filter_source" "$filter_severity" jq_args)"

	local count
	count="$(jq -c ${jq_args[@]+"${jq_args[@]}"} "$jq_filter" "$QUARANTINE_PENDING" 2>/dev/null | wc -l | tr -d ' ')"

	echo "Quarantine queue: ${count} item(s) pending"
	echo "---"

	tail -n "$last_n" "$QUARANTINE_PENDING" | jq -c ${jq_args[@]+"${jq_args[@]}"} "$jq_filter" 2>/dev/null | while IFS= read -r line; do
		# Note: no 'local' — this runs in a subshell (piped while-read)
		id="$(printf '%s' "$line" | jq -r '.id // "?"')"
		ts="$(printf '%s' "$line" | jq -r '.timestamp // "?"')"
		src="$(printf '%s' "$line" | jq -r '.source // "?"')"
		sev="$(printf '%s' "$line" | jq -r '.severity // "?"')"
		cat="$(printf '%s' "$line" | jq -r '.category // "?"')"
		content_preview="$(printf '%s' "$line" | jq -r '.content // ""' | head -c 80)"

		printf '  %s  %-14s %-8s %-20s %s\n' "$id" "$src" "$sev" "$cat" "$content_preview"
	done

	return 0
}

# =============================================================================
# Digest Command
# =============================================================================

# Present quarantine items in a formatted digest for human review.
# Groups by source and severity for efficient batch review.
cmd_digest() {
	local filter_source="" filter_severity=""

	local _parsed
	_parsed="$(_q_parse_filter_args "$@")" || return 1
	eval "$_parsed"

	if [[ ! -f "$QUARANTINE_PENDING" ]]; then
		echo "No quarantine items pending review."
		return 0
	fi

	if ! command -v jq &>/dev/null; then
		log_error "jq is required for digest command"
		return 1
	fi

	# Validate filter values to prevent jq injection
	if [[ -n "$filter_source" ]]; then
		_q_validate_value "$filter_source" "$VALID_SOURCES" "source filter" || return 1
	fi
	if [[ -n "$filter_severity" ]]; then
		_q_validate_value "$filter_severity" "$VALID_SEVERITIES" "severity filter" || return 1
	fi

	local jq_args=()
	local jq_filter
	jq_filter="$(_q_build_jq_filter "$filter_source" "$filter_severity" jq_args)"

	local total
	total="$(jq -c ${jq_args[@]+"${jq_args[@]}"} "$jq_filter" "$QUARANTINE_PENDING" 2>/dev/null | wc -l | tr -d ' ')"

	if [[ "$total" -eq 0 ]]; then
		echo "No items match the specified filters."
		return 0
	fi

	echo "Security Quarantine Digest"
	echo "========================="
	echo ""
	echo "Items pending review: ${total}"
	echo ""

	# Group by source
	local src
	for src in prompt-guard network-tier sandbox-exec mcp-audit; do
		local src_items
		src_items="$(jq -c ${jq_args[@]+"${jq_args[@]}"} --arg gsrc "$src" "${jq_filter} | select(.source == \$gsrc)" "$QUARANTINE_PENDING" 2>/dev/null)" || true

		if [[ -z "$src_items" ]]; then
			continue
		fi

		local src_count
		src_count="$(printf '%s\n' "$src_items" | grep -c '.')"

		echo "--- ${src} (${src_count} items) ---"
		echo ""

		printf '%s\n' "$src_items" | while IFS= read -r line; do
			_q_render_digest_item "$line"
		done
	done

	echo "---"
	echo "Usage: quarantine-helper.sh learn <item-id> <action> [--value <domain/pattern>]"

	return 0
}

# =============================================================================
# Learn Command
# =============================================================================

# Apply a review decision to a quarantine item and feed back into config.
# This is the core feedback loop — each decision improves future scoring.
cmd_learn() {
	local item_id="${1:-}"
	local action="${2:-}"
	shift 2 || true

	local value=""
	while [[ $# -gt 0 ]]; do
		case "$1" in
		--value)
			value="$2"
			shift 2
			;;
		*)
			shift
			;;
		esac
	done

	if [[ -z "$item_id" ]]; then
		log_error "Item ID required. Usage: quarantine-helper.sh learn <item-id> <action>"
		return 1
	fi
	if [[ -z "$action" ]]; then
		log_error "Action required. Valid actions: ${VALID_ACTIONS}"
		return 1
	fi

	_q_validate_value "$action" "$VALID_ACTIONS" "action" || return 1

	if [[ ! -f "$QUARANTINE_PENDING" ]]; then
		log_error "No quarantine items found"
		return 1
	fi

	if ! command -v jq &>/dev/null; then
		log_error "jq is required for learn command"
		return 1
	fi

	# Validate item ID format to prevent jq injection (q<timestamp>-<hex>)
	if ! [[ "$item_id" =~ ^q[0-9]+-[0-9a-f]+$ ]]; then
		log_error "Invalid item ID format: ${item_id}"
		return 1
	fi

	# Find the item (using --arg to avoid jq injection)
	local item
	item="$(jq -c --arg id "$item_id" 'select(.id == $id)' "$QUARANTINE_PENDING" 2>/dev/null | head -1)"

	if [[ -z "$item" ]]; then
		log_error "Item not found: ${item_id}"
		return 1
	fi

	local source
	source="$(printf '%s' "$item" | jq -r '.source')"
	local content
	content="$(printf '%s' "$item" | jq -r '.content')"
	local category
	category="$(printf '%s' "$item" | jq -r '.category')"

	# Apply the action
	case "$action" in
	allow)
		_learn_allow "$source" "$content" "$value"
		;;
	deny)
		_learn_deny "$source" "$content" "$category" "$value"
		;;
	trust)
		_learn_trust "$source" "$content" "$value"
		;;
	dismiss)
		log_info "Dismissed: ${item_id} (false positive, no config change)"
		;;
	esac

	# Move item from pending to reviewed
	_q_init_dir
	local timestamp
	timestamp="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

	local reviewed_record
	reviewed_record="$(printf '%s' "$item" | jq -c \
		--arg action "$action" \
		--arg reviewed_at "$timestamp" \
		--arg value "${value:-}" \
		'. + {status:"reviewed", decision:$action, reviewed_at:$reviewed_at, learn_value:$value}')"

	echo "$reviewed_record" >>"$QUARANTINE_REVIEWED"

	# Remove from pending (write all non-matching lines to temp, then replace)
	local tmp_file
	tmp_file="$(mktemp)"
	jq -c --arg id "$item_id" 'select(.id != $id)' "$QUARANTINE_PENDING" >"$tmp_file" 2>/dev/null || true
	mv "$tmp_file" "$QUARANTINE_PENDING"

	log_success "Learned: ${item_id} → ${action}${value:+ (${value})}"

	return 0
}

# Apply "allow" action — add domain to network-tiers-custom.conf Tier 3.
_learn_allow() {
	local source="$1"
	local content="$2"
	local value="$3"

	# Extract domain from content or use explicit value
	local domain="${value:-}"
	if [[ -z "$domain" ]]; then
		# Try to extract domain from content (common patterns)
		domain="$(printf '%s' "$content" | grep -oE '[a-zA-Z0-9]([a-zA-Z0-9_-]*\.)+[a-zA-Z]{2,}' | head -1)" || true
	fi

	if [[ -z "$domain" ]]; then
		log_warn "No domain found in content. Use --value <domain> to specify."
		return 0
	fi

	# Normalize domain to lowercase (matches network-tier-helper.sh parsing)
	domain="$(printf '%s' "$domain" | tr '[:upper:]' '[:lower:]')"

	# Ensure config directory exists
	mkdir -p "$(dirname "$NET_TIER_USER_CONF")" 2>/dev/null || true

	# Add [tier3] section if not present, then add domain
	if [[ ! -f "$NET_TIER_USER_CONF" ]]; then
		printf '# User network tier overrides (managed by quarantine-helper.sh)\n\n' >"$NET_TIER_USER_CONF"
	fi

	# Check if domain already exists in the file (case-insensitive)
	if grep -qiF "$domain" "$NET_TIER_USER_CONF" 2>/dev/null; then
		log_info "Domain already in custom config: ${domain}"
		return 0
	fi

	# Ensure [tier3] section exists
	if ! grep -q '^\[tier3\]' "$NET_TIER_USER_CONF" 2>/dev/null; then
		printf '\n[tier3]\n' >>"$NET_TIER_USER_CONF"
	fi

	# Append domain after [tier3] section
	# Find the line number of [tier3] and insert after it
	local tier3_line
	tier3_line="$(grep -n '^\[tier3\]' "$NET_TIER_USER_CONF" | tail -1 | cut -d: -f1)"
	if [[ -n "$tier3_line" ]]; then
		# Use sed to insert after the [tier3] line
		local tmp_conf
		tmp_conf="$(mktemp)"
		awk -v line="$tier3_line" -v domain="$domain" \
			'NR==line { print; print domain; next } { print }' \
			"$NET_TIER_USER_CONF" >"$tmp_conf"
		mv "$tmp_conf" "$NET_TIER_USER_CONF"
	fi

	log_success "Added to network-tiers-custom.conf Tier 3: ${domain}"

	return 0
}

# Apply "deny" action — add to Tier 5 or prompt-guard-custom.txt.
_learn_deny() {
	local source="$1"
	local content="$2"
	local category="$3"
	local value="$4"

	case "$source" in
	network-tier | sandbox-exec)
		# Add domain to Tier 5 (deny list)
		local domain="${value:-}"
		if [[ -z "$domain" ]]; then
			domain="$(printf '%s' "$content" | grep -oE '[a-zA-Z0-9]([a-zA-Z0-9_-]*\.)+[a-zA-Z]{2,}' | head -1)" || true
		fi

		if [[ -z "$domain" ]]; then
			log_warn "No domain found. Use --value <domain> to specify."
			return 0
		fi

		# Normalize domain to lowercase (matches network-tier-helper.sh parsing)
		domain="$(printf '%s' "$domain" | tr '[:upper:]' '[:lower:]')"

		mkdir -p "$(dirname "$NET_TIER_USER_CONF")" 2>/dev/null || true

		if [[ ! -f "$NET_TIER_USER_CONF" ]]; then
			printf '# User network tier overrides (managed by quarantine-helper.sh)\n\n' >"$NET_TIER_USER_CONF"
		fi

		# Case-insensitive check for existing domain
		if grep -qiF "$domain" "$NET_TIER_USER_CONF" 2>/dev/null; then
			log_info "Domain already in custom config: ${domain}"
			return 0
		fi

		if ! grep -q '^\[tier5\]' "$NET_TIER_USER_CONF" 2>/dev/null; then
			printf '\n[tier5]\n' >>"$NET_TIER_USER_CONF"
		fi

		local tier5_line
		tier5_line="$(grep -n '^\[tier5\]' "$NET_TIER_USER_CONF" | tail -1 | cut -d: -f1)"
		if [[ -n "$tier5_line" ]]; then
			local tmp_conf
			tmp_conf="$(mktemp)"
			awk -v line="$tier5_line" -v domain="$domain" \
				'NR==line { print; print domain; next } { print }' \
				"$NET_TIER_USER_CONF" >"$tmp_conf"
			mv "$tmp_conf" "$NET_TIER_USER_CONF"
		fi

		log_success "Added to network-tiers-custom.conf Tier 5 (deny): ${domain}"
		;;

	prompt-guard | mcp-audit)
		# Add pattern to prompt-guard-custom.txt
		local pattern="${value:-}"
		if [[ -z "$pattern" ]]; then
			# Use the content as a simple pattern (escaped for regex)
			# Single quotes intentional: \\& is sed backreference syntax, not shell expansion
			# shellcheck disable=SC2016
			pattern="$(printf '%s' "$content" | head -c 100 | sed 's/[.[\*^$()+?{|]/\\&/g')"
		fi

		if [[ -z "$pattern" ]]; then
			log_warn "No pattern to add. Use --value <pattern> to specify."
			return 0
		fi

		mkdir -p "$(dirname "$PROMPT_GUARD_CUSTOM")" 2>/dev/null || true

		if [[ ! -f "$PROMPT_GUARD_CUSTOM" ]]; then
			printf '# Custom prompt guard patterns (managed by quarantine-helper.sh)\n# Format: severity|category|description|regex\n' >"$PROMPT_GUARD_CUSTOM"
		fi

		# Build pattern entry
		local severity="HIGH"
		local entry="${severity}|${category:-custom}|Learned from quarantine review|${pattern}"

		if grep -qF "$pattern" "$PROMPT_GUARD_CUSTOM" 2>/dev/null; then
			log_info "Pattern already in custom config"
			return 0
		fi

		echo "$entry" >>"$PROMPT_GUARD_CUSTOM"
		log_success "Added to prompt-guard-custom.txt: ${entry}"
		;;
	esac

	return 0
}

# Apply "trust" action — add MCP server to trusted list.
_learn_trust() {
	local source="$1"
	local content="$2"
	local value="$3"

	local server_name="${value:-}"
	if [[ -z "$server_name" ]]; then
		# Try to extract server name from content
		server_name="$(printf '%s' "$content" | grep -oE '[a-zA-Z0-9_-]+' | head -1)" || true
	fi

	if [[ -z "$server_name" ]]; then
		log_warn "No server name found. Use --value <server-name> to specify."
		return 0
	fi

	mkdir -p "$(dirname "$MCP_TRUSTED_LIST")" 2>/dev/null || true

	if [[ ! -f "$MCP_TRUSTED_LIST" ]]; then
		printf '# Trusted MCP servers (managed by quarantine-helper.sh)\n# One server name per line\n' >"$MCP_TRUSTED_LIST"
	fi

	if grep -qxF "$server_name" "$MCP_TRUSTED_LIST" 2>/dev/null; then
		log_info "Server already trusted: ${server_name}"
		return 0
	fi

	echo "$server_name" >>"$MCP_TRUSTED_LIST"
	log_success "Added to trusted MCP servers: ${server_name}"

	return 0
}

# =============================================================================
# Stats Command
# =============================================================================

# Show quarantine statistics.
cmd_stats() {
	echo "Quarantine Statistics"
	echo "====================="

	local pending_count=0
	local reviewed_count=0

	if [[ -f "$QUARANTINE_PENDING" ]]; then
		pending_count="$(wc -l <"$QUARANTINE_PENDING" | tr -d ' ')"
	fi
	if [[ -f "$QUARANTINE_REVIEWED" ]]; then
		reviewed_count="$(wc -l <"$QUARANTINE_REVIEWED" | tr -d ' ')"
	fi

	echo "  Pending:  ${pending_count}"
	echo "  Reviewed: ${reviewed_count}"
	echo "  Total:    $((pending_count + reviewed_count))"
	echo ""

	if [[ "$pending_count" -gt 0 ]] && command -v jq &>/dev/null; then
		echo "Pending by source:"
		jq -r '.source' "$QUARANTINE_PENDING" 2>/dev/null | sort | uniq -c | sort -rn | while read -r count src; do
			printf '  %-16s %s\n' "$src" "$count"
		done
		echo ""

		echo "Pending by severity:"
		jq -r '.severity' "$QUARANTINE_PENDING" 2>/dev/null | sort | uniq -c | sort -rn | while read -r count sev; do
			printf '  %-10s %s\n' "$sev" "$count"
		done
		echo ""
	fi

	if [[ "$reviewed_count" -gt 0 ]] && command -v jq &>/dev/null; then
		echo "Review decisions:"
		jq -r '.decision' "$QUARANTINE_REVIEWED" 2>/dev/null | sort | uniq -c | sort -rn | while read -r count decision; do
			printf '  %-10s %s\n' "$decision" "$count"
		done
		echo ""

		echo "Learn effectiveness:"
		local allow_count deny_count trust_count dismiss_count
		allow_count="$(jq -r 'select(.decision=="allow") | .id' "$QUARANTINE_REVIEWED" 2>/dev/null | wc -l | tr -d ' ')"
		deny_count="$(jq -r 'select(.decision=="deny") | .id' "$QUARANTINE_REVIEWED" 2>/dev/null | wc -l | tr -d ' ')"
		trust_count="$(jq -r 'select(.decision=="trust") | .id' "$QUARANTINE_REVIEWED" 2>/dev/null | wc -l | tr -d ' ')"
		dismiss_count="$(jq -r 'select(.decision=="dismiss") | .id' "$QUARANTINE_REVIEWED" 2>/dev/null | wc -l | tr -d ' ')"
		local total_decisions
		total_decisions=$((allow_count + deny_count + trust_count + dismiss_count))
		echo "  Allowed (Tier 3):  ${allow_count}"
		echo "  Denied (Tier 5):   ${deny_count}"
		echo "  Trusted (MCP):     ${trust_count}"
		echo "  Dismissed (FP):    ${dismiss_count}"

		local fp_rate
		fp_rate="$(_q_compute_percentage "$dismiss_count" "$total_decisions")"
		echo "  False positive rate: ${fp_rate}%"
	fi

	# Config file status
	echo ""
	echo "Config files:"
	printf '  %-45s %s\n' "$NET_TIER_USER_CONF" "$([ -f "$NET_TIER_USER_CONF" ] && echo "exists" || echo "not created")"
	printf '  %-45s %s\n' "$PROMPT_GUARD_CUSTOM" "$([ -f "$PROMPT_GUARD_CUSTOM" ] && echo "exists" || echo "not created")"
	printf '  %-45s %s\n' "$MCP_TRUSTED_LIST" "$([ -f "$MCP_TRUSTED_LIST" ] && echo "exists" || echo "not created")"

	return 0
}

# =============================================================================
# Purge Command
# =============================================================================

# Purge old quarantine items.
cmd_purge() {
	local older_than_days=30
	local reviewed_only=false

	while [[ $# -gt 0 ]]; do
		case "$1" in
		--older-than)
			older_than_days="$2"
			shift 2
			;;
		--reviewed-only)
			reviewed_only=true
			shift
			;;
		*)
			shift
			;;
		esac
	done

	# Validate older_than_days is a positive integer
	if ! [[ "$older_than_days" =~ ^[0-9]+$ ]] || [[ "$older_than_days" -eq 0 ]]; then
		log_error "Invalid --older-than value: '${older_than_days}' (must be a positive integer)"
		return 1
	fi

	if ! command -v jq &>/dev/null; then
		log_error "jq is required for purge command"
		return 1
	fi

	local cutoff_ts
	cutoff_ts="$(date -u -v-"${older_than_days}"d +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d "${older_than_days} days ago" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null)" || true

	if [[ -z "$cutoff_ts" ]]; then
		log_error "Could not calculate cutoff date"
		return 1
	fi

	local purged=0

	# Purge reviewed items (use --arg to avoid jq injection with cutoff_ts)
	if [[ -f "$QUARANTINE_REVIEWED" ]]; then
		local before_count
		before_count="$(wc -l <"$QUARANTINE_REVIEWED" | tr -d ' ')"
		local tmp_file
		tmp_file="$(mktemp)"
		jq -c --arg cutoff "$cutoff_ts" \
			'select(.reviewed_at > $cutoff or .reviewed_at == null)' \
			"$QUARANTINE_REVIEWED" >"$tmp_file" 2>/dev/null || true
		local after_count
		after_count="$(wc -l <"$tmp_file" | tr -d ' ')"
		mv "$tmp_file" "$QUARANTINE_REVIEWED"
		purged=$((before_count - after_count))
		log_info "Purged ${purged} reviewed items older than ${older_than_days} days"
	fi

	# Purge pending items (unless --reviewed-only)
	if [[ "$reviewed_only" == false ]] && [[ -f "$QUARANTINE_PENDING" ]]; then
		local before_count
		before_count="$(wc -l <"$QUARANTINE_PENDING" | tr -d ' ')"
		local tmp_file
		tmp_file="$(mktemp)"
		jq -c --arg cutoff "$cutoff_ts" \
			'select(.timestamp > $cutoff)' \
			"$QUARANTINE_PENDING" >"$tmp_file" 2>/dev/null || true
		local after_count
		after_count="$(wc -l <"$tmp_file" | tr -d ' ')"
		mv "$tmp_file" "$QUARANTINE_PENDING"
		local pending_purged=$((before_count - after_count))
		purged=$((purged + pending_purged))
		log_info "Purged ${pending_purged} pending items older than ${older_than_days} days"
	fi

	log_success "Total purged: ${purged} items"

	return 0
}

# =============================================================================
# Help
# =============================================================================

show_help() {
	cat <<'HELP'
quarantine-helper.sh — Unified quarantine queue for ambiguous security items (t1428.4)

Commands:
  add [options]              Add an item to the quarantine queue
  list [options]             List pending quarantine items
  digest [options]           Present formatted digest for human review
  learn <id> <action>        Apply review decision and feed back into config
  stats                      Show quarantine statistics
  purge [options]            Purge old quarantine items
  help                       Show this help

Add options:
  --source <name>            Source: prompt-guard, network-tier, sandbox-exec, mcp-audit
  --severity <level>         Severity: CRITICAL, HIGH, MEDIUM, LOW
  --category <name>          Category (e.g., encoding_tricks, unknown_domain)
  --content <text>           Content that triggered the quarantine
  --session-id <id>          Session identifier (optional)
  --worker-id <id>           Worker identifier (optional)
  --metadata <json>          Additional metadata as JSON (optional)

List/Digest options:
  --source <name>            Filter by source
  --severity <level>         Filter by severity
  --last N                   Show last N items (list only, default: 50)

Learn actions:
  allow                      Add domain to network-tiers-custom.conf Tier 3
  deny                       Add domain to Tier 5 or pattern to prompt-guard-custom.txt
  trust                      Add MCP server to trusted list
  dismiss                    Mark as false positive, no config change

Learn options:
  --value <domain|pattern>   Explicit value to learn (auto-extracted from content if omitted)

Purge options:
  --older-than DAYS          Purge items older than N days (default: 30)
  --reviewed-only            Only purge reviewed items, keep pending

Queue files:
  Pending:  ~/.aidevops/.agent-workspace/security/quarantine/pending.jsonl
  Reviewed: ~/.aidevops/.agent-workspace/security/quarantine/reviewed.jsonl

Config files written by learn:
  Network tiers: ~/.config/aidevops/network-tiers-custom.conf
  Prompt guard:  ~/.config/aidevops/prompt-guard-custom.txt
  MCP trusted:   ~/.config/aidevops/mcp-trusted-servers.txt

Examples:
  # Add a quarantine item (called by security scripts)
  quarantine-helper.sh add --source network-tier --severity MEDIUM \
    --category unknown_domain --content "api.suspicious-site.com"

  # View pending items
  quarantine-helper.sh list
  quarantine-helper.sh list --source prompt-guard --severity HIGH

  # Review digest
  quarantine-helper.sh digest

  # Apply decisions
  quarantine-helper.sh learn q1710000000-abc123 allow --value api.legitimate-tool.com
  quarantine-helper.sh learn q1710000000-def456 deny --value evil-domain.com
  quarantine-helper.sh learn q1710000000-ghi789 trust --value my-mcp-server
  quarantine-helper.sh learn q1710000000-jkl012 dismiss

  # Statistics and maintenance
  quarantine-helper.sh stats
  quarantine-helper.sh purge --older-than 60 --reviewed-only

Integration:
  prompt-guard-helper.sh, network-tier-helper.sh, and sandbox-exec-helper.sh
  call 'quarantine-helper.sh add' when they encounter items in the ambiguous
  score range (e.g., MEDIUM severity, Tier 4 unknown domains). The /security-review
  command presents the digest for human review.
HELP
	return 0
}

# =============================================================================
# Main
# =============================================================================

main() {
	local cmd="${1:-help}"
	shift || true

	case "$cmd" in
	add)
		cmd_add "$@"
		;;
	list)
		cmd_list "$@"
		;;
	digest)
		cmd_digest "$@"
		;;
	learn)
		cmd_learn "$@"
		;;
	stats)
		cmd_stats
		;;
	purge)
		cmd_purge "$@"
		;;
	help | --help | -h)
		show_help
		;;
	*)
		log_error "Unknown command: ${cmd}"
		show_help
		return 1
		;;
	esac
}

main "$@"
