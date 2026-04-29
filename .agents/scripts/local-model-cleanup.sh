#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# =============================================================================
# Local Model Cleanup Library — Stale Models, Usage Stats, Nudge & Inventory
# =============================================================================
# Identify and remove stale GGUF models, display usage statistics from SQLite,
# session-start nudge for large stale models, and model inventory display.
#
# Usage: source "${SCRIPT_DIR}/local-model-cleanup.sh"
#
# Dependencies:
#   - shared-constants.sh (print_error, print_info, print_success, etc.)
#   - local-model-db.sh (sql_escape, sync_model_inventory)
#   - sqlite3 (usage/inventory queries)
#
# Part of aidevops framework: https://aidevops.sh

# Apply strict mode only when executed directly (not when sourced)
[[ "${BASH_SOURCE[0]}" == "${0}" ]] && set -euo pipefail

# Include guard
[[ -n "${_LOCAL_MODEL_CLEANUP_LIB_LOADED:-}" ]] && return 0
_LOCAL_MODEL_CLEANUP_LIB_LOADED=1

if [[ -z "${SCRIPT_DIR:-}" ]]; then
	_lib_path="${BASH_SOURCE[0]%/*}"
	[[ "$_lib_path" == "${BASH_SOURCE[0]}" ]] && _lib_path="."
	SCRIPT_DIR="$(cd "$_lib_path" && pwd)"
	unset _lib_path
fi

# =============================================================================
# Stale Model Helpers
# =============================================================================

# Get days unused for a model (from DB or mtime)
_get_days_unused() {
	local model_path="$1"
	local now_epoch="$2"
	local name
	name="$(basename "$model_path")"
	local days_unused=-1

	# Try DB first
	if suppress_stderr command -v sqlite3 && [[ -f "$LOCAL_USAGE_DB" ]]; then
		local db_last escaped_name
		escaped_name="$(sql_escape "$name")"
		db_last="$(sqlite3 "$LOCAL_USAGE_DB" "SELECT last_used FROM model_inventory WHERE model='${escaped_name}' LIMIT 1;" 2>/dev/null || echo "")"
		if [[ -n "$db_last" ]]; then
			local last_epoch
			last_epoch="$(date -j -f "%Y-%m-%d %H:%M:%S" "$db_last" +%s 2>/dev/null || date -d "$db_last" +%s 2>/dev/null || echo "0")"
			if [[ "$last_epoch" -gt 0 ]]; then
				days_unused="$(((now_epoch - last_epoch) / 86400))"
				echo "$days_unused"
				return 0
			fi
		fi
	fi

	# Fall back to mtime
	local mod_epoch
	mod_epoch="$(_file_mtime_epoch "$model_path")"
	if [[ "$mod_epoch" -gt 0 ]]; then
		days_unused="$(((now_epoch - mod_epoch) / 86400))"
	fi

	echo "$days_unused"
	return 0
}

# Format days unused as human-readable string
_format_days_unused() {
	local days_unused="$1"
	if [[ "$days_unused" == "-" ]] || [[ "$days_unused" -lt 0 ]]; then
		echo "-"
		return 0
	fi
	if [[ "$days_unused" -eq 0 ]]; then
		echo "today"
	elif [[ "$days_unused" -eq 1 ]]; then
		echo "1d ago"
	else
		echo "${days_unused}d ago"
	fi
	return 0
}

# Remove a specific model file and DB entry
_remove_model_file() {
	local model_path="$1"
	local model_name="$2"
	local size_human="$3"

	rm -f "$model_path"
	print_success "Removed: ${model_name} (${size_human})"

	# Clean up database entry
	if suppress_stderr command -v sqlite3 && [[ -f "$LOCAL_USAGE_DB" ]]; then
		local escaped_name
		escaped_name="$(sql_escape "$model_name")"
		sqlite3 "$LOCAL_USAGE_DB" "DELETE FROM model_inventory WHERE model='${escaped_name}';" 2>/dev/null || true
	fi
	return 0
}

# Print cleanup report table row
_print_cleanup_row() {
	local name="$1"
	local size_human="$2"
	local last_used_str="$3"
	local status_str="$4"

	printf "%-40s %10s %12s %10s\n" "$name" "$size_human" "$last_used_str" "$status_str"
	return 0
}

# Process and display all models in cleanup report
_cleanup_report_models() {
	local models="$1"
	local threshold="$2"
	local now_epoch="$3"
	local total_size_bytes=0
	local stale_size_bytes=0
	local stale_count=0

	printf "%-40s %10s %12s %10s\n" "MODEL" "SIZE" "LAST USED" "STATUS"
	printf "%-40s %10s %12s %10s\n" "-----" "----" "---------" "------"

	while IFS= read -r model_path; do
		local name size_bytes size_human last_used_str status_str days_unused
		name="$(basename "$model_path")"

		size_bytes="$(_file_size_bytes "$model_path")"
		total_size_bytes=$((total_size_bytes + size_bytes))

		size_human="$(echo "$size_bytes" | awk '{
			if ($1 >= 1073741824) printf "%.1f GB", $1/1073741824;
			else printf "%.0f MB", $1/1048576;
		}')"

		days_unused="$(_get_days_unused "$model_path" "$now_epoch")"
		last_used_str="$(_format_days_unused "$days_unused")"
		status_str="unknown"

		if [[ "$days_unused" != "-" ]] && [[ "$days_unused" -gt "$threshold" ]]; then
			status_str="stale (>${threshold}d)"
			stale_size_bytes=$((stale_size_bytes + size_bytes))
			stale_count=$((stale_count + 1))
		else
			status_str="active"
		fi

		_print_cleanup_row "$name" "$size_human" "$last_used_str" "$status_str"
	done <<<"$models"

	echo ""
	local total_human stale_human
	total_human="$(echo "$total_size_bytes" | awk '{printf "%.1f GB", $1/1073741824}')"
	stale_human="$(echo "$stale_size_bytes" | awk '{printf "%.1f GB", $1/1073741824}')"
	echo "Total: ${total_human} (${stale_human} stale)"

	# Return stale info via stdout (name=value format)
	echo "stale_count=$stale_count"
	echo "stale_size_bytes=$stale_size_bytes"
	echo "stale_human=$stale_human"
	return 0
}

# Remove all stale models
_cleanup_remove_stale() {
	local models="$1"
	local threshold="$2"
	local now_epoch="$3"

	print_info "Removing stale models..."
	while IFS= read -r model_path; do
		local name days_unused_check
		name="$(basename "$model_path")"
		days_unused_check="$(_get_days_unused "$model_path" "$now_epoch")"

		if [[ "$days_unused_check" -gt "$threshold" ]]; then
			rm -f "$model_path"
			print_success "Removed: ${name}"
			if suppress_stderr command -v sqlite3 && [[ -f "$LOCAL_USAGE_DB" ]]; then
				sqlite3 "$LOCAL_USAGE_DB" "DELETE FROM model_inventory WHERE model='$(sql_escape "$name")';" 2>/dev/null || true
			fi
		fi
	done <<<"$models"
	return 0
}

# =============================================================================
# Command: cleanup
# =============================================================================

cmd_cleanup() {
	local remove_stale=false
	local remove_model=""
	local threshold="$STALE_THRESHOLD_DAYS"

	while [[ $# -gt 0 ]]; do
		case "$1" in
		--remove-stale)
			remove_stale=true
			shift
			;;
		--remove)
			remove_model="$2"
			shift 2
			;;
		--threshold)
			threshold="$2"
			shift 2
			;;
		*) shift ;;
		esac
	done

	# Validate threshold is a non-negative integer
	if ! [[ "$threshold" =~ ^[0-9]+$ ]]; then
		print_error "Invalid --threshold value '${threshold}'. Must be a non-negative integer (days)."
		return 1
	fi

	if [[ ! -d "$LOCAL_MODELS_STORE" ]]; then
		print_info "No models directory found"
		return 0
	fi

	local models
	models="$(find "$LOCAL_MODELS_STORE" -name "*.gguf" -type f 2>/dev/null)"

	if [[ -z "$models" ]]; then
		print_info "No models to clean up"
		return 0
	fi

	# Handle specific model removal
	if [[ -n "$remove_model" ]]; then
		local target="${LOCAL_MODELS_STORE}/${remove_model}"
		if [[ -f "$target" ]]; then
			local size_human size_bytes
			size_bytes="$(_file_size_bytes "$target")"
			size_human="$(echo "$size_bytes" | awk '{printf "%.1f GB", $1/1073741824}')"
			_remove_model_file "$target" "$remove_model" "$size_human"
		else
			print_error "Model not found: ${remove_model}"
			return 3
		fi
		return 0
	fi

	# Show cleanup report
	local now_epoch
	now_epoch="$(date +%s)"

	local report_output
	report_output="$(_cleanup_report_models "$models" "$threshold" "$now_epoch")"
	echo "$report_output" | grep -v "^stale_"

	# Extract stale counts from report
	local stale_count stale_size_bytes stale_human
	stale_count="$(echo "$report_output" | grep "^stale_count=" | cut -d= -f2)"
	stale_size_bytes="$(echo "$report_output" | grep "^stale_size_bytes=" | cut -d= -f2)"
	stale_human="$(echo "$report_output" | grep "^stale_human=" | cut -d= -f2)"

	if [[ "$stale_count" -gt 0 ]]; then
		echo "Recommendation: Remove ${stale_count} stale model(s) to free ${stale_human}"
		echo ""
		if [[ "$remove_stale" == "true" ]]; then
			_cleanup_remove_stale "$models" "$threshold" "$now_epoch"
		else
			echo "Run: local-model-helper.sh cleanup --remove-stale"
		fi
	fi

	return 0
}

# =============================================================================
# Command: usage
# =============================================================================

cmd_usage() {
	local json_output=false
	local since=""

	while [[ $# -gt 0 ]]; do
		case "$1" in
		--json)
			json_output=true
			shift
			;;
		--since)
			since="$2"
			shift 2
			;;
		*) shift ;;
		esac
	done

	if ! suppress_stderr command -v sqlite3; then
		print_error "sqlite3 is required for usage tracking"
		return 2
	fi

	if [[ ! -f "$LOCAL_USAGE_DB" ]]; then
		print_info "No usage data yet. Start using local models to track usage."
		return 0
	fi

	local where_clause=""
	if [[ -n "$since" ]]; then
		# Validate date format (YYYY-MM-DD with optional time) to prevent SQL injection
		if ! [[ "$since" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}([[:space:]][0-9]{2}:[0-9]{2}(:[0-9]{2})?)?$ ]]; then
			print_error "Invalid --since format. Use YYYY-MM-DD or 'YYYY-MM-DD HH:MM:SS'"
			return 1
		fi
		local escaped_since
		escaped_since="$(sql_escape "$since")"
		where_clause="WHERE u.timestamp >= '${escaped_since}'"
	fi

	if [[ "$json_output" == "true" ]]; then
		local json_sql
		json_sql="SELECT model, COUNT(*) as requests, SUM(tokens_in) as total_tokens_in, SUM(tokens_out) as total_tokens_out, ROUND(AVG(tok_per_sec), 1) as avg_tok_per_sec, MAX(timestamp) as last_used FROM model_usage u ${where_clause} GROUP BY model ORDER BY last_used DESC;"
		sqlite3 -json "$LOCAL_USAGE_DB" "$json_sql" 2>/dev/null
		return 0
	fi

	# Table output
	printf "%-35s %8s %10s %10s %10s %12s\n" "MODEL" "REQUESTS" "TOKENS_IN" "TOKENS_OUT" "AVG_TOK/S" "LAST_USED"
	printf "%-35s %8s %10s %10s %10s %12s\n" "-----" "--------" "---------" "----------" "---------" "---------"

	local usage_sql
	usage_sql="SELECT model, COUNT(*) as requests, SUM(tokens_in) as total_tokens_in, SUM(tokens_out) as total_tokens_out, ROUND(AVG(tok_per_sec), 1) as avg_tok_per_sec, MAX(timestamp) as last_used FROM model_usage u ${where_clause} GROUP BY model ORDER BY last_used DESC;"

	sqlite3 -separator $'\t' "$LOCAL_USAGE_DB" "$usage_sql" 2>/dev/null |
		while IFS=$'\t' read -r model requests tokens_in tokens_out avg_tps last_used; do
			# Truncate model name if too long
			local display_model="$model"
			if [[ ${#display_model} -gt 35 ]]; then
				display_model="${display_model:0:32}..."
			fi
			printf "%-35s %8s %10s %10s %10s %12s\n" \
				"$display_model" "$requests" "$tokens_in" "$tokens_out" "$avg_tps" "${last_used%% *}"
		done

	echo ""

	# Summary
	local summary_sql summary
	summary_sql="SELECT COUNT(*) as total_requests, COALESCE(SUM(tokens_in), 0) as total_in, COALESCE(SUM(tokens_out), 0) as total_out FROM model_usage u ${where_clause};"
	summary="$(sqlite3 -separator $'\t' "$LOCAL_USAGE_DB" "$summary_sql" 2>/dev/null)"

	if [[ -n "$summary" ]]; then
		local total_req total_in total_out
		IFS=$'\t' read -r total_req total_in total_out <<<"$summary"
		echo "Total: ${total_req} requests, ${total_in} input tokens, ${total_out} output tokens"

		# Estimate cloud cost savings (haiku: $0.25/MTok in, $1.25/MTok out; sonnet: $3/MTok in, $15/MTok out)
		# Reset IFS before $() subshells — prevents zsh IFS leak corrupting awk PATH lookup
		if [[ "$total_in" -gt 0 ]] || [[ "$total_out" -gt 0 ]]; then
			local haiku_cost sonnet_cost
			haiku_cost="$(IFS= awk -v i="$total_in" -v o="$total_out" 'BEGIN {printf "%.2f", (i * 0.00000025 + o * 0.00000125)}')"
			sonnet_cost="$(IFS= awk -v i="$total_in" -v o="$total_out" 'BEGIN {printf "%.2f", (i * 0.000003 + o * 0.000015)}')"
			echo "Estimated cloud cost saved: \$${haiku_cost} (vs haiku), \$${sonnet_cost} (vs sonnet)"
		fi
	fi

	return 0
}

# =============================================================================
# Nudge Helpers
# =============================================================================

# Calculate stale models count and size
_nudge_calculate_stale() {
	local models="$1"
	local threshold="$2"
	local now_epoch="$3"

	local stale_size_bytes=0
	local stale_count=0

	while IFS= read -r model_path; do
		local name size_bytes days_unused
		name="$(basename "$model_path")"
		days_unused="$(_get_days_unused "$model_path" "$now_epoch")"

		size_bytes="$(_file_size_bytes "$model_path")"

		if [[ "$days_unused" -gt "$threshold" ]]; then
			stale_size_bytes=$((stale_size_bytes + size_bytes))
			stale_count=$((stale_count + 1))
		fi
	done <<<"$models"

	echo "stale_count=$stale_count"
	echo "stale_size_bytes=$stale_size_bytes"
	return 0
}

# =============================================================================
# Command: nudge (t1338.5 — session-start stale model notification)
# =============================================================================
# Called at session start to check if stale models exceed 5 GB.
# Outputs a short message if cleanup is recommended, nothing otherwise.

cmd_nudge() {
	local json_output=false
	local threshold="${STALE_THRESHOLD_DAYS}"

	while [[ $# -gt 0 ]]; do
		case "$1" in
		--json)
			json_output=true
			shift
			;;
		--threshold)
			threshold="$2"
			shift 2
			;;
		*) shift ;;
		esac
	done

	# Validate threshold is a non-negative integer
	if ! [[ "$threshold" =~ ^[0-9]+$ ]]; then
		print_error "Invalid --threshold value '${threshold}'. Must be a non-negative integer (days)."
		return 1
	fi

	# Quick exit if no models directory
	if [[ ! -d "$LOCAL_MODELS_STORE" ]]; then
		return 0
	fi

	local models
	models="$(find "$LOCAL_MODELS_STORE" -name "*.gguf" -type f 2>/dev/null)"
	[[ -z "$models" ]] && return 0

	local now_epoch
	now_epoch="$(date +%s)"

	# Calculate stale models
	local stale_info
	stale_info="$(_nudge_calculate_stale "$models" "$threshold" "$now_epoch")"
	local stale_count
	stale_count="$(echo "$stale_info" | grep "^stale_count=" | cut -d= -f2)"
	local stale_size_bytes
	stale_size_bytes="$(echo "$stale_info" | grep "^stale_size_bytes=" | cut -d= -f2)"

	# Only nudge if stale models exceed threshold (default 5 GB)
	if [[ "$stale_size_bytes" -gt "$STALE_NUDGE_THRESHOLD_BYTES" ]]; then
		local stale_human
		stale_human="$(echo "$stale_size_bytes" | awk '{printf "%.1f GB", $1/1073741824}')"

		if [[ "$json_output" == "true" ]]; then
			cat <<-JSONEOF
				{
				  "stale_count": ${stale_count},
				  "stale_size_bytes": ${stale_size_bytes},
				  "stale_size_human": "${stale_human}",
				  "threshold_days": ${threshold},
				  "action": "local-model-helper.sh cleanup --remove-stale"
				}
			JSONEOF
		else
			echo "Local models: ${stale_count} stale model(s) using ${stale_human} (unused >${threshold}d). Run: local-model-helper.sh cleanup"
		fi
	fi

	return 0
}

# =============================================================================
# Command: inventory (t1338.5 — show model inventory from DB)
# =============================================================================

cmd_inventory() {
	local json_output=false
	local do_sync=false

	while [[ $# -gt 0 ]]; do
		case "$1" in
		--json)
			json_output=true
			shift
			;;
		--sync)
			do_sync=true
			shift
			;;
		*) shift ;;
		esac
	done

	if ! suppress_stderr command -v sqlite3; then
		print_error "sqlite3 is required for inventory"
		return 2
	fi

	if [[ ! -f "$LOCAL_USAGE_DB" ]]; then
		print_info "No inventory data. Run: local-model-helper.sh setup"
		return 0
	fi

	# Sync after precondition checks pass
	if [[ "$do_sync" == "true" ]]; then
		if sync_model_inventory; then
			print_success "Model inventory synced with disk"
		else
			print_error "Failed to sync model inventory"
			return 1
		fi
	fi

	if [[ "$json_output" == "true" ]]; then
		sqlite3 -json "$LOCAL_USAGE_DB" "SELECT model, file_path, repo_source, size_bytes, quantization, first_seen, last_used, total_requests FROM model_inventory ORDER BY last_used DESC;" 2>/dev/null
		return 0
	fi

	printf "%-35s %10s %8s %8s %12s\n" "MODEL" "SIZE" "QUANT" "REQUESTS" "LAST_USED"
	printf "%-35s %10s %8s %8s %12s\n" "-----" "----" "-----" "--------" "---------"

	sqlite3 -separator $'\t' "$LOCAL_USAGE_DB" \
		"SELECT model, size_bytes, quantization, total_requests, last_used FROM model_inventory ORDER BY last_used DESC;" 2>/dev/null |
		while IFS=$'\t' read -r model size_bytes quant requests last_used; do
			local display_model="$model"
			if [[ ${#display_model} -gt 35 ]]; then
				display_model="${display_model:0:32}..."
			fi
			# Reset IFS before $() subshell — prevents zsh IFS leak corrupting awk PATH lookup
			local size_human
			size_human="$(IFS= awk -v b="$size_bytes" 'BEGIN {
				if (b >= 1073741824) printf "%.1f GB", b/1073741824;
				else if (b >= 1048576) printf "%.0f MB", b/1048576;
				else if (b > 0) printf "%.0f KB", b/1024;
				else printf "-";
			}')"
			[[ -z "$quant" ]] && quant="-"
			printf "%-35s %10s %8s %8s %12s\n" \
				"$display_model" "$size_human" "$quant" "$requests" "${last_used%% *}"
		done

	return 0
}
