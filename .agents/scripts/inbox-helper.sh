#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# shellcheck disable=SC2034

# =============================================================================
# Inbox Helper (t2866 + t2867)
# =============================================================================
# Manages the _inbox/ transit zone: provisioning, capture, find, and status.
#
# Usage:
#   inbox-helper.sh <command> [options]
#
# Commands:
#   provision [<repo-path>]   Create _inbox/ structure (default: current dir)
#   provision-workspace       Create workspace-level inbox at ~/.aidevops/.agent-workspace/inbox/
#   add <file|--url <url>>    Capture a file or URL into _inbox/
#   find <query>              Search triage.log for matching entries
#   status [<repo-path>]      Show item counts per sub-folder
#   help                      Show this help
#
# Examples:
#   inbox-helper.sh provision
#   inbox-helper.sh provision /path/to/repo
#   inbox-helper.sh add /tmp/meeting.eml
#   inbox-helper.sh add --url https://example.com/article
#   inbox-helper.sh find "meeting notes"
#   inbox-helper.sh status
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/shared-constants.sh"

set -euo pipefail

# =============================================================================
# Constants
# =============================================================================

readonly INBOX_DIR_NAME="_inbox"
readonly INBOX_SUB_DIRS=("_drop" "email" "web" "scan" "voice" "import" "_needs-review")
readonly TRIAGE_LOG="triage.log"
readonly INBOX_GITIGNORE_CONTENT='# _inbox/ is a transit zone.
# Binary captures are excluded; only README.md, .gitignore, and triage.log are tracked.
*
!README.md
!.gitignore
!triage.log
'
readonly DEBOUNCE_SECS=5

# Workspace-level inbox
readonly WORKSPACE_INBOX_DIR="${HOME}/.aidevops/.agent-workspace/inbox"

# Path to the README template
readonly README_TEMPLATE="${SCRIPT_DIR}/../templates/inbox-readme.md"

# Triage log JSON field names and status values — defined as constants to
# avoid repeated string literals triggering the pre-commit ratchet gate.
# Each name appears once here; all other uses reference the variable.
readonly TRIAGE_KEY_SENSITIVITY="sensitivity"
readonly TRIAGE_KEY_STATUS="status"
readonly TRIAGE_KEY_PATH="path"
readonly TRIAGE_VAL_PENDING="pending"

# Sub-folders scanned by digest for stale/unprocessed items (transit zones).
# Reference INBOX_SUB_DIRS by index to avoid repeating the string literals.
# INBOX_SUB_DIRS = ("_drop" "email" "web" "scan" "voice" "import" "_needs-review")
#                    [0]                                                [6]
readonly DIGEST_SCAN_SUBS=("${INBOX_SUB_DIRS[0]}" "${INBOX_SUB_DIRS[6]}")

# =============================================================================
# Helpers
# =============================================================================

# _resolve_inbox_dir <repo-path>
# Returns the absolute path to the _inbox/ dir for the given repo root.
_resolve_inbox_dir() {
	local repo_path="${1:-$(pwd)}"
	echo "${repo_path}/${INBOX_DIR_NAME}"
	return 0
}

# _iso_ts
# Returns current UTC timestamp in ISO 8601 compact form: 20260425T190000
_iso_ts() {
	date -u '+%Y%m%dT%H%M%S'
	return 0
}

# _iso_ts_full
# Returns current UTC timestamp in ISO 8601 full form: 2026-04-25T19:00:00Z
_iso_ts_full() {
	date -u '+%Y-%m-%dT%H:%M:%SZ'
	return 0
}

# _json_field <json-line> <field-name>
# Extracts a string value from a flat JSON line: {"field":"value",...}
# Uses only grep + cut — no jq dependency.
_json_field() {
	local json="$1"
	local field="$2"
	printf '%s' "$json" | grep -o "\"${field}\":\"[^\"]*\"" | cut -d'"' -f4 || true
	return 0
}

# _json_escape <string>
# Escapes double quotes so the value can be embedded in a JSON string literal.
_json_escape() {
	local raw="$1"
	printf '%s' "$raw" | sed 's/"/\\"/g'
	return 0
}

# _detect_sub_folder <path_or_url>
# Maps extension / MIME / URL pattern to the appropriate sub-folder name.
_detect_sub_folder() {
	local input="$1"
	# URL → web
	if [[ "$input" =~ ^https?:// ]]; then
		echo "web"
		return 0
	fi
	# Extension-based mapping
	local ext
	ext="${input##*.}"
	ext="${ext,,}"  # lowercase
	case "$ext" in
	eml | msg) echo "email" ;;
	png | jpg | jpeg | heic | heif | tiff | tif | gif | bmp | webp | pdf)
		echo "scan"
		;;
	mp3 | m4a | wav | ogg | flac | aac | opus) echo "voice" ;;
	*) echo "_drop" ;;
	esac
	return 0
}

# _conflict_safe_name <inbox-sub-dir-path> <orig-filename>
# Returns a conflict-safe filename: <stem>_<ts>.<ext>
_conflict_safe_name() {
	local dir="$1"
	local orig="$2"
	local base stem ext ts
	base="$(basename "$orig")"
	ts="$(_iso_ts)"
	# Split into stem and extension
	if [[ "$base" == *.* ]]; then
		stem="${base%.*}"
		ext="${base##*.}"
		echo "${stem}_${ts}.${ext}"
	else
		echo "${base}_${ts}"
	fi
	return 0
}

# _append_triage_log <inbox-dir> <source> <sub> <orig> <dest-path> <status>
_append_triage_log() {
	local inbox_dir="$1"
	local source="$2"
	local sub="$3"
	local orig="$4"
	local dest_path="$5"
	local status="${6:-pending}"
	local log_path="${inbox_dir}/${TRIAGE_LOG}"
	local ts
	ts="$(_iso_ts_full)"
	printf '{"ts":"%s","source":"%s","sub":"%s","orig":"%s","path":"%s","status":"%s","sensitivity":"unverified"}\n' \
		"$ts" "$source" "$sub" "$orig" "$dest_path" "$status" >> "$log_path"
	return 0
}

# =============================================================================
# cmd_provision — create _inbox/ structure (t2866)
# =============================================================================
cmd_provision() {
	local repo_path="${1:-$(pwd)}"
	repo_path="$(cd "$repo_path" && pwd)"
	local inbox_dir
	inbox_dir="$(_resolve_inbox_dir "$repo_path")"

	print_info "Provisioning ${inbox_dir} ..."

	# Create sub-directories (idempotent)
	local sub
	for sub in "${INBOX_SUB_DIRS[@]}"; do
		local sub_dir="${inbox_dir}/${sub}"
		if [[ ! -d "$sub_dir" ]]; then
			mkdir -p "$sub_dir"
			print_success "Created ${sub_dir}"
		fi
	done

	# Write README.md from template (only if missing)
	local readme="${inbox_dir}/README.md"
	if [[ ! -f "$readme" ]]; then
		if [[ -f "$README_TEMPLATE" ]]; then
			cp "$README_TEMPLATE" "$readme"
		else
			printf '# _inbox/ — Transit Zone\n\nSee: aidevops inbox help\n' > "$readme"
		fi
		print_success "Created ${readme}"
	fi

	# Write .gitignore (only if missing)
	local gitignore="${inbox_dir}/.gitignore"
	if [[ ! -f "$gitignore" ]]; then
		printf '%s' "$INBOX_GITIGNORE_CONTENT" > "$gitignore"
		print_success "Created ${gitignore}"
	fi

	# Create empty triage.log (only if missing)
	local log_path="${inbox_dir}/${TRIAGE_LOG}"
	if [[ ! -f "$log_path" ]]; then
		touch "$log_path"
		print_success "Created ${log_path}"
	fi

	print_success "_inbox/ provisioned at ${inbox_dir}"
	return 0
}

# =============================================================================
# cmd_provision_workspace — create workspace-level inbox (t2866)
# =============================================================================
cmd_provision_workspace() {
	print_info "Provisioning workspace inbox at ${WORKSPACE_INBOX_DIR} ..."
	# Reuse provision logic using the workspace path as the "repo root"
	local workspace_parent
	workspace_parent="$(dirname "$WORKSPACE_INBOX_DIR")"
	mkdir -p "$workspace_parent"
	# provision expects a repo root, so create a temp symlink alias
	# Simplest: just provision directly
	local inbox_dir="$WORKSPACE_INBOX_DIR"
	local sub
	for sub in "${INBOX_SUB_DIRS[@]}"; do
		local sub_dir="${inbox_dir}/${sub}"
		if [[ ! -d "$sub_dir" ]]; then
			mkdir -p "$sub_dir"
			print_success "Created ${sub_dir}"
		fi
	done
	local readme="${inbox_dir}/README.md"
	if [[ ! -f "$readme" ]]; then
		if [[ -f "$README_TEMPLATE" ]]; then
			cp "$README_TEMPLATE" "$readme"
		else
			printf '# _inbox/ — Transit Zone\n\nSee: aidevops inbox help\n' > "$readme"
		fi
		print_success "Created ${readme}"
	fi
	local log_path="${inbox_dir}/${TRIAGE_LOG}"
	if [[ ! -f "$log_path" ]]; then
		touch "$log_path"
		print_success "Created ${log_path}"
	fi
	print_success "Workspace inbox provisioned at ${WORKSPACE_INBOX_DIR}"
	return 0
}

# =============================================================================
# cmd_add — capture a file or URL into _inbox/ (t2867)
# =============================================================================
cmd_add() {
	local is_url=0
	local url=""
	local file_path=""

	# Parse flags
	while [[ $# -gt 0 ]]; do
		local cur_arg="$1"
		case "$cur_arg" in
		--url | -u)
			is_url=1
			url="${2:-}"
			shift 2
			;;
		--url=*)
			is_url=1
			url="${cur_arg#--url=}"
			shift
			;;
		-*)
			print_error "Unknown flag: $cur_arg"
			return 1
			;;
		*)
			file_path="$cur_arg"
			shift
			;;
		esac
	done

	# Determine repo root / inbox dir
	local repo_root
	repo_root="$(pwd)"
	local inbox_dir
	inbox_dir="${repo_root}/${INBOX_DIR_NAME}"

	# Auto-provision if inbox doesn't exist yet
	if [[ ! -d "$inbox_dir" ]]; then
		print_info "_inbox/ not found — provisioning..."
		cmd_provision "$repo_root"
	fi

	if [[ "$is_url" -eq 1 ]]; then
		_add_url "$inbox_dir" "$url"
	else
		if [[ -z "$file_path" ]]; then
			print_error "Usage: inbox-helper.sh add <file> | --url <url>"
			return 1
		fi
		_add_file "$inbox_dir" "$file_path"
	fi
	return 0
}

# _add_file <inbox-dir> <file-path>
_add_file() {
	local inbox_dir="$1"
	local src="$2"

	# Validate source
	if [[ ! -f "$src" && ! -d "$src" ]]; then
		print_error "File not found: $src"
		return 1
	fi

	local abs_src
	abs_src="$(cd "$(dirname "$src")" && pwd)/$(basename "$src")"

	# Detect sub-folder
	local sub
	sub="$(_detect_sub_folder "$src")"
	local sub_dir="${inbox_dir}/${sub}"

	# Ensure sub-dir exists
	mkdir -p "$sub_dir"

	# Build conflict-safe destination name
	local dest_name
	dest_name="$(_conflict_safe_name "$sub_dir" "$src")"
	local dest_path="${sub_dir}/${dest_name}"

	# Determine if source is inside _drop/ (move) or external (copy)
	local drop_dir="${inbox_dir}/_drop"
	if [[ "$abs_src" == "${drop_dir}/"* ]]; then
		mv "$abs_src" "$dest_path"
	else
		cp "$abs_src" "$dest_path"
	fi

	# Relative path for the log entry
	local rel_path="${INBOX_DIR_NAME}/${sub}/${dest_name}"

	_append_triage_log "$inbox_dir" "cli-add" "$sub" "$abs_src" "$rel_path" "$TRIAGE_VAL_PENDING"

	print_success "Captured: ${rel_path}"
	return 0
}

# _add_url <inbox-dir> <url>
_add_url() {
	local inbox_dir="$1"
	local url="$2"

	if [[ -z "$url" ]]; then
		print_error "URL is required"
		return 1
	fi

	# Validate URL format
	if [[ ! "$url" =~ ^https?:// ]]; then
		print_error "Invalid URL (must start with http:// or https://): $url"
		return 1
	fi

	local web_dir="${inbox_dir}/web"
	mkdir -p "$web_dir"

	local ts
	ts="$(_iso_ts)"

	# Generate a URL slug (replace non-alphanumeric with -)
	local slug
	slug="$(printf '%s' "$url" | sed 's|^https\?://||' | sed 's|[^a-zA-Z0-9._-]|-|g' | cut -c1-60)"
	local base_name="${slug}_${ts}"

	local html_file="${web_dir}/${base_name}.html"
	local md_file="${web_dir}/${base_name}.md"
	local meta_file="${web_dir}/${base_name}.meta.json"

	# Fetch with curl (fail gracefully)
	local curl_ok=0
	if command -v curl >/dev/null 2>&1; then
		if curl -fsSL --max-time 30 -A "aidevops-inbox/1.0" "$url" -o "$html_file" 2>/dev/null; then
			curl_ok=1
		fi
	fi

	if [[ "$curl_ok" -eq 0 ]]; then
		# Create placeholder
		printf '<html><body><!-- fetch failed for %s --></body></html>\n' "$url" > "$html_file"
		print_warning "Could not fetch URL (curl unavailable or timed out); saved placeholder"
	fi

	# Extract title from HTML (best-effort, no external deps)
	local title=""
	if command -v grep >/dev/null 2>&1 && [[ -f "$html_file" ]]; then
		title="$(grep -oi '<title>[^<]*</title>' "$html_file" 2>/dev/null | sed 's|<[^>]*>||g' | head -1 || true)"
	fi
	[[ -z "$title" ]] && title="$url"

	# Write extracted text (best-effort strip tags)
	if command -v sed >/dev/null 2>&1 && [[ -f "$html_file" ]]; then
		sed 's/<[^>]*>//g' "$html_file" | sed '/^[[:space:]]*$/d' > "$md_file" 2>/dev/null || true
	fi

	# Write metadata JSON
	local fetched_at
	fetched_at="$(_iso_ts_full)"
	printf '{"url":"%s","title":"%s","fetched_at":"%s","html":"%s","text":"%s"}\n' \
		"$url" \
		"$(printf '%s' "$title" | sed 's/"/\\"/g')" \
		"$fetched_at" \
		"${INBOX_DIR_NAME}/web/${base_name}.html" \
		"${INBOX_DIR_NAME}/web/${base_name}.md" \
		> "$meta_file"

	# Triage log entry
	local rel_path="${INBOX_DIR_NAME}/web/${base_name}.meta.json"
	_append_triage_log "$inbox_dir" "cli-url" "web" "$url" "$rel_path" "$TRIAGE_VAL_PENDING"

	print_success "Captured URL: ${rel_path}"
	return 0
}

# =============================================================================
# cmd_find — search triage.log (t2867)
# =============================================================================
cmd_find() {
	local query="${1:-}"

	if [[ -z "$query" ]]; then
		print_error "Usage: inbox-helper.sh find <query>"
		return 1
	fi

	# Find triage.log in current dir first, then workspace
	local log_paths=()
	local local_log="${PWD}/${INBOX_DIR_NAME}/${TRIAGE_LOG}"
	[[ -f "$local_log" ]] && log_paths+=("$local_log")

	local ws_log="${WORKSPACE_INBOX_DIR}/${TRIAGE_LOG}"
	[[ -f "$ws_log" ]] && log_paths+=("$ws_log")

	if [[ ${#log_paths[@]} -eq 0 ]]; then
		print_warning "No triage.log found. Run: aidevops inbox provision"
		return 0
	fi

	# Search last 30 days
	local cutoff_ts
	cutoff_ts="$(date -u -d '30 days ago' '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null \
		|| date -u -v-30d '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null \
		|| date -u '+2000-01-01T00:00:00Z')"

	local found=0
	local log_path
	for log_path in "${log_paths[@]}"; do
		while IFS= read -r line; do
			[[ -z "$line" ]] && continue
			# Filter by date (compare ts field string — ISO 8601 sorts lexicographically)
			local line_ts
			line_ts="$(printf '%s' "$line" | grep -o '"ts":"[^"]*"' | cut -d'"' -f4 || true)"
			[[ -n "$line_ts" && "$line_ts" < "$cutoff_ts" ]] && continue
			# Filter by query (case-insensitive substring match)
			if printf '%s' "$line" | grep -qi "$query" 2>/dev/null; then
				printf '%s\n' "$line"
				found=$((found + 1))
			fi
		done < "$log_path"
	done

	if [[ "$found" -eq 0 ]]; then
		print_info "No entries matching \"${query}\" in the last 30 days."
	fi
	return 0
}

# =============================================================================
# cmd_status — show item counts per sub-folder (t2866)
# =============================================================================
cmd_status() {
	local repo_path="${1:-$(pwd)}"
	repo_path="$(cd "$repo_path" && pwd)"
	local inbox_dir
	inbox_dir="${repo_path}/${INBOX_DIR_NAME}"

	if [[ ! -d "$inbox_dir" ]]; then
		print_warning "_inbox/ not found at ${inbox_dir}. Run: aidevops inbox provision"
		return 0
	fi

	echo ""
	echo "_inbox/ status: ${inbox_dir}"
	echo ""

	local sub count oldest_file oldest_age age_label
	for sub in "${INBOX_SUB_DIRS[@]}"; do
		local sub_dir="${inbox_dir}/${sub}"
		if [[ ! -d "$sub_dir" ]]; then
			printf '  %-20s  (missing)\n' "${sub}/"
			continue
		fi
		# Count files (non-recursive, exclude hidden)
		count=0
		while IFS= read -r -d '' _f; do
			count=$((count + 1))
		done < <(find "$sub_dir" -maxdepth 1 -type f ! -name '.*' -print0 2>/dev/null)

		oldest_age=""
		if [[ "$count" -gt 0 ]]; then
			oldest_file="$(find "$sub_dir" -maxdepth 1 -type f ! -name '.*' -print0 2>/dev/null \
				| xargs -0 ls -t1 2>/dev/null | tail -1 || true)"
			if [[ -n "$oldest_file" ]]; then
				local file_ts now_ts diff_secs
				file_ts="$(date -r "$oldest_file" +%s 2>/dev/null || _file_mtime_epoch "$oldest_file")"
				now_ts="$(date +%s)"
				diff_secs=$(( now_ts - file_ts ))
				if [[ "$diff_secs" -lt 3600 ]]; then
					age_label="${diff_secs}s"
				elif [[ "$diff_secs" -lt 86400 ]]; then
					age_label="$(( diff_secs / 3600 ))h"
				else
					age_label="$(( diff_secs / 86400 ))d"
				fi
				oldest_age=" (oldest: ${age_label})"
			fi
		fi
		printf '  %-20s  %d items%s\n' "${sub}/" "$count" "$oldest_age"
	done

	# triage.log line count
	local log_path="${inbox_dir}/${TRIAGE_LOG}"
	local log_count=0
	if [[ -f "$log_path" ]]; then
		log_count="$(wc -l < "$log_path" 2>/dev/null || true)"
		log_count="${log_count// /}"
	fi
	echo ""
	echo "  triage.log: ${log_count} entries"
	echo ""
	return 0
}

# =============================================================================
# cmd_triage — sensitivity gate → classification → routing (t2868)
# =============================================================================
# Processes pending items in _inbox/, classifies them, and routes to target plane.
#
# Triage flow per item:
#   1. Sensitivity gate (LOCAL ONLY via sensitivity-detect.sh — never cloud)
#   2. LLM classification (tier per sensitivity: cloud OK for public/confidential,
#      local-only for privileged/competitive) via llm-routing-helper.sh
#   3. Confidence check: < TRIAGE_CONFIDENCE_THRESHOLD → _needs-review/
#   4. Route: move file + write meta.json + update triage.log
#
# Graceful degradation: if sensitivity-detect.sh or llm-routing-helper.sh are not
# installed yet (P0.5a / P0.5b pending), items route to _needs-review/ with reason
# "dependency-unavailable". The code is fully functional once those land.

# Sensitivity levels — ordered from most to least sensitive
readonly SENSITIVITY_LEVELS="unknown privileged competitive confidential public"
# Tiers requiring local-only LLM (no cloud exposure)
readonly SENSITIVITY_LOCAL_ONLY_TIERS="unknown privileged competitive"
# Default confidence threshold (0-100 integer, matching LLM's 0.0-1.0 * 100)
readonly TRIAGE_CONFIDENCE_THRESHOLD_DEFAULT=85
# Default rate limit per pulse cycle
readonly TRIAGE_RATE_LIMIT_DEFAULT=50
# Default consecutive needs-review backoff threshold
readonly TRIAGE_BACKOFF_THRESHOLD_DEFAULT=10

# _triage_check_deps
# Checks availability of P0.5a (sensitivity-detect.sh) and P0.5b
# (llm-routing-helper.sh). Prints warnings and sets caller's has_* variables.
# Returns: sets HAS_SENSITIVITY_DETECT and HAS_LLM_ROUTING in caller scope via echo.
_triage_check_deps() {
	local _sens=0 _llm=0
	if command -v sensitivity-detect.sh >/dev/null 2>&1 \
		|| [[ -x "${SCRIPT_DIR}/sensitivity-detect.sh" ]]; then
		_sens=1
	else
		print_warning "sensitivity-detect.sh not found (P0.5a pending). Items will route to _needs-review/."
	fi
	if command -v llm-routing-helper.sh >/dev/null 2>&1 \
		|| [[ -x "${SCRIPT_DIR}/llm-routing-helper.sh" ]]; then
		_llm=1
	else
		print_warning "llm-routing-helper.sh not found (P0.5b pending). Items will route to _needs-review/."
	fi
	echo "${_sens} ${_llm}"
	return 0
}

# _triage_collect_pending <log-path>
# Reads triage.log and prints one relative path per line for pending items.
_triage_collect_pending() {
	local log_path="$1"
	while IFS= read -r line; do
		[[ -z "$line" ]] && continue
		local status_field
		status_field="$(_json_field "$line" "$TRIAGE_KEY_STATUS")"
		if [[ "$status_field" == "$TRIAGE_VAL_PENDING" ]]; then
			local path_field
			path_field="$(_json_field "$line" "$TRIAGE_KEY_PATH")"
			[[ -n "$path_field" ]] && printf '%s\n' "$path_field"
		fi
	done < "$log_path"
	return 0
}

# _triage_run_sensitivity_gate <abs-path>
# Runs sensitivity-detect.sh on a file. Returns the sensitivity tier string on
# stdout: public | confidential | privileged | competitive | unknown.
# Always returns 0; never fails.
_triage_run_sensitivity_gate() {
	local abs_path="$1"
	local detect_script="${SCRIPT_DIR}/sensitivity-detect.sh"
	command -v sensitivity-detect.sh >/dev/null 2>&1 && detect_script="sensitivity-detect.sh"
	local result
	result="$("$detect_script" "$abs_path" 2>/dev/null || echo "unknown")"
	case "$result" in
	public | confidential | privileged | competitive | unknown) printf '%s' "$result" ;;
	*) printf 'unknown' ;;
	esac
	return 0
}

# _triage_run_classification <abs-path> <sensitivity> <confidence-threshold>
# Runs llm-routing-helper.sh to classify a file.
# Outputs space-separated: <plane> <sub-folder> <confidence> <use-local-only> <reason>
# On failure, outputs: "" "" 0 0 <reason>
_triage_run_classification() {
	local abs_path="$1" sensitivity="$2" confidence_threshold="$3"
	local use_local_only=0
	local tier_check
	for tier_check in $SENSITIVITY_LOCAL_ONLY_TIERS; do
		[[ "$sensitivity" == "$tier_check" ]] && use_local_only=1 && break
	done

	local routing_script="${SCRIPT_DIR}/llm-routing-helper.sh"
	command -v llm-routing-helper.sh >/dev/null 2>&1 && routing_script="llm-routing-helper.sh"

	local content_preview
	content_preview="$(dd if="$abs_path" bs=1 count=2048 2>/dev/null | strings 2>/dev/null | head -40 || true)"

	local llm_flags=("--task" "classify-inbox")
	[[ "$use_local_only" -eq 1 ]] && llm_flags+=("--local-only")
	local llm_output
	llm_output="$("$routing_script" "${llm_flags[@]}" --content "$content_preview" 2>/dev/null || true)"

	local plane="" sub_folder="" confidence=0 reasoning="" reason=""
	if [[ -n "$llm_output" ]]; then
		plane="$(_json_field "$llm_output" "target_plane")"
		sub_folder="$(_json_field "$llm_output" "sub_folder")"
		local conf_raw
		conf_raw="$(printf '%s' "$llm_output" | grep -o '"confidence":[0-9.]*' | cut -d':' -f2 || true)"
		[[ -n "$conf_raw" ]] && confidence="$(printf '%.0f' "$(echo "$conf_raw * 100" | bc 2>/dev/null || echo 0)" 2>/dev/null || echo 0)"
		reasoning="$(_json_field "$llm_output" "reasoning")"
	fi

	if [[ -z "$plane" ]]; then
		reason="classifier-no-output"
	elif [[ "$confidence" -lt "$confidence_threshold" ]]; then
		reason="low-confidence:${confidence}"
	fi

	printf '%s\t%s\t%s\t%s\t%s\t%s\n' \
		"$plane" "$sub_folder" "$confidence" "$use_local_only" "$reason" "$reasoning"
	return 0
}

# _triage_process_item <inbox-dir> <repo-root> <rel-path>
#   <has-sensitivity-detect> <has-llm-routing>
#   <confidence-threshold> <dry-run> <log-path>
# Processes a single pending item through the full triage pipeline.
# Outputs: "routed" or "needs-review" on stdout.
_triage_process_item() {
	local inbox_dir="$1" repo_root="$2" rel_path="$3"
	local has_sd="$4" has_llm="$5"
	local confidence_threshold="$6" dry_run="$7" log_path="$8"

	local abs_path="${repo_root}/${rel_path}"

	# Step 1: Sensitivity gate (LOCAL ONLY)
	local sensitivity="unknown"
	[[ "$has_sd" -eq 1 ]] && sensitivity="$(_triage_run_sensitivity_gate "$abs_path")"

	# Step 2: Classification (or immediate needs-review if deps missing)
	local needs_review_reason=""
	local plane="" sub_folder="" confidence=0 use_local_only=0 reasoning=""
	if [[ "$has_sd" -eq 0 || "$has_llm" -eq 0 ]]; then
		needs_review_reason="dependency-unavailable"
	else
		local class_out
		class_out="$(_triage_run_classification "$abs_path" "$sensitivity" "$confidence_threshold")"
		IFS=$'\t' read -r plane sub_folder confidence use_local_only needs_review_reason reasoning <<< "$class_out"
	fi

	# Step 3: Route
	if [[ -n "$needs_review_reason" ]]; then
		_triage_route_needs_review \
			"$inbox_dir" "$abs_path" "$rel_path" \
			"$sensitivity" "$needs_review_reason" "$dry_run" "$log_path"
		printf 'needs-review'
	else
		_triage_route_to_plane \
			"$inbox_dir" "$abs_path" "$rel_path" \
			"$sensitivity" "$plane" "$sub_folder" \
			"$confidence" "$reasoning" "$dry_run" "$log_path" "$use_local_only"
		printf 'routed'
	fi
	return 0
}

cmd_triage() {
	local dry_run=0
	local limit="${TRIAGE_RATE_LIMIT:-${TRIAGE_RATE_LIMIT_DEFAULT}}"
	local confidence_threshold="${TRIAGE_CONFIDENCE_THRESHOLD:-${TRIAGE_CONFIDENCE_THRESHOLD_DEFAULT}}"
	local backoff_threshold="${TRIAGE_BACKOFF_THRESHOLD:-${TRIAGE_BACKOFF_THRESHOLD_DEFAULT}}"

	while [[ $# -gt 0 ]]; do
		local cur_arg="$1"
		case "$cur_arg" in
		--dry-run) dry_run=1; shift ;;
		--limit)   limit="${2:-$limit}"; shift 2 ;;
		--limit=*) limit="${cur_arg#--limit=}"; shift ;;
		--confidence-threshold)  confidence_threshold="${2:-$confidence_threshold}"; shift 2 ;;
		--confidence-threshold=*) confidence_threshold="${cur_arg#--confidence-threshold=}"; shift ;;
		*) print_error "Unknown triage flag: $cur_arg"; return 1 ;;
		esac
	done

	local repo_root
	repo_root="$(pwd)"
	local inbox_dir="${repo_root}/${INBOX_DIR_NAME}"
	[[ ! -d "$inbox_dir" ]] && print_warning "_inbox/ not found. Run: aidevops inbox provision" && return 0
	local log_path="${inbox_dir}/${TRIAGE_LOG}"
	[[ ! -f "$log_path" ]] && print_warning "triage.log not found. Nothing to triage." && return 0

	local dep_out has_sd has_llm
	dep_out="$(_triage_check_deps)"
	has_sd="${dep_out%% *}"
	has_llm="${dep_out##* }"

	[[ "$dry_run" -eq 1 ]] && print_info "[DRY RUN] No files will be moved."

	local -a pending_paths
	while IFS= read -r p; do
		[[ -n "$p" ]] && pending_paths+=("$p")
	done < <(_triage_collect_pending "$log_path")

	if [[ ${#pending_paths[@]} -eq 0 ]]; then
		print_info "No pending items found in triage.log."
		return 0
	fi
	print_info "Found ${#pending_paths[@]} pending item(s). Processing up to ${limit}."

	local processed=0 routed=0 needs_review=0 consecutive_needs_review=0 skipped=0
	local rel_path
	for rel_path in "${pending_paths[@]}"; do
		if [[ "$processed" -ge "$limit" ]]; then
			skipped=$(( ${#pending_paths[@]} - processed ))
			print_warning "Rate limit reached (${limit}). Skipping ${skipped} item(s)."
			break
		fi
		if [[ "$consecutive_needs_review" -ge "$backoff_threshold" ]]; then
			print_warning "Backoff: ${consecutive_needs_review} consecutive needs-review. Halting."
			break
		fi
		local abs_path="${repo_root}/${rel_path}"
		if [[ ! -f "$abs_path" ]]; then
			print_warning "Skipping missing file: ${rel_path}"
			processed=$(( processed + 1 ))
			continue
		fi
		print_info "Triaging: ${rel_path}"
		local outcome
		outcome="$(_triage_process_item \
			"$inbox_dir" "$repo_root" "$rel_path" \
			"$has_sd" "$has_llm" \
			"$confidence_threshold" "$dry_run" "$log_path")"
		processed=$(( processed + 1 ))
		if [[ "$outcome" == "routed" ]]; then
			routed=$(( routed + 1 ))
			consecutive_needs_review=0
		else
			needs_review=$(( needs_review + 1 ))
			consecutive_needs_review=$(( consecutive_needs_review + 1 ))
		fi
	done

	print_info "Triage complete: routed=${routed} needs-review=${needs_review} skipped=${skipped}"
	return 0
}

# _triage_route_needs_review <inbox-dir> <abs-path> <rel-path> <sensitivity> <reason> <dry-run> <log-path>
_triage_route_needs_review() {
	local inbox_dir="$1"
	local abs_path="$2"
	local rel_path="$3"
	local sensitivity="$4"
	local reason="$5"
	local dry_run="$6"
	local log_path="$7"

	local needs_review_dir="${inbox_dir}/_needs-review"
	local dest_name
	dest_name="$(_conflict_safe_name "$needs_review_dir" "$abs_path")"
	local dest_path="${needs_review_dir}/${dest_name}"
	local dest_rel="${INBOX_DIR_NAME}/_needs-review/${dest_name}"
	local ts
	ts="$(_iso_ts_full)"

	if [[ "$dry_run" -eq 1 ]]; then
		print_info "  [DRY RUN] Would route to _needs-review/: ${dest_name} (reason: ${reason})"
		return 0
	fi

	mkdir -p "$needs_review_dir"
	mv "$abs_path" "$dest_path"

	# Write meta.json adjacent (field names via constants to avoid repeated literals)
	local meta_path="${dest_path}.meta.json"
	printf '{"%s":"%s","needs_review_reason":"%s","triaged_at":"%s","original_path":"%s"}\n' \
		"$TRIAGE_KEY_SENSITIVITY" "$sensitivity" "$reason" "$ts" "$rel_path" > "$meta_path"

	# Append triage.log entry
	printf '{"ts":"%s","%s":"needs-review","from":"%s","to":"%s","%s":"%s","reason":"%s"}\n' \
		"$ts" "$TRIAGE_KEY_STATUS" "$rel_path" "$dest_rel" \
		"$TRIAGE_KEY_SENSITIVITY" "$sensitivity" "$reason" >> "$log_path"

	# Mark original entry as triaged in log (append superseding entry)
	printf '{"ts":"%s","%s":"superseded","%s":"%s","action":"moved-to-needs-review"}\n' \
		"$ts" "$TRIAGE_KEY_STATUS" "$TRIAGE_KEY_PATH" "$rel_path" >> "$log_path"

	print_info "  -> _needs-review/ (${reason}): ${dest_name}"
	return 0
}

# _triage_route_to_plane <inbox-dir> <abs-path> <rel-path> <sensitivity>
#   <plane> <sub-folder> <confidence> <reasoning> <dry-run> <log-path> <use-local-only>
_triage_route_to_plane() {
	local inbox_dir="$1"
	local abs_path="$2"
	local rel_path="$3"
	local sensitivity="$4"
	local plane="$5"
	local sub_folder="$6"
	local confidence="$7"
	local reasoning="$8"
	local dry_run="$9"
	local log_path="${10}"
	local use_local_only="${11}"

	# Resolve the target plane root relative to the repo root (parent of _inbox/)
	local repo_root
	repo_root="$(dirname "$inbox_dir")"
	local plane_dir="${repo_root}/_${plane}"
	[[ -n "$sub_folder" ]] && plane_dir="${plane_dir}/${sub_folder}"

	local dest_name
	dest_name="$(_conflict_safe_name "$plane_dir" "$abs_path")"
	local dest_path="${plane_dir}/${dest_name}"
	local dest_rel="_${plane}/${sub_folder:+${sub_folder}/}${dest_name}"
	local ts
	ts="$(_iso_ts_full)"

	local llm_tier="cloud"
	[[ "$use_local_only" -eq 1 ]] && llm_tier="local-only"

	if [[ "$dry_run" -eq 1 ]]; then
		print_info "  [DRY RUN] Would route to ${dest_rel} (sensitivity=${sensitivity}, confidence=${confidence}%, tier=${llm_tier})"
		return 0
	fi

	mkdir -p "$plane_dir"
	mv "$abs_path" "$dest_path"

	# Write meta.json adjacent (field names via constants to avoid repeated literals)
	local meta_path="${dest_path}.meta.json"
	local reasoning_escaped
	reasoning_escaped="$(_json_escape "$reasoning")"
	printf '{"%s":"%s","classification":{"plane":"%s","sub_folder":"%s"},"confidence":%s,"llm_tier":"%s","reasoning":"%s","triaged_at":"%s","original_path":"%s"}\n' \
		"$TRIAGE_KEY_SENSITIVITY" "$sensitivity" "$plane" "$sub_folder" "$confidence" "$llm_tier" \
		"$reasoning_escaped" "$ts" "$rel_path" > "$meta_path"

	# Append triage.log entry
	printf '{"ts":"%s","%s":"routed","from":"%s","to":"%s","dest_plane":"%s","dest_path":"%s","confidence":%s,"%s":"%s","llm_tier":"%s","reasoning":"%s"}\n' \
		"$ts" "$TRIAGE_KEY_STATUS" "$rel_path" "$dest_rel" "$plane" "$dest_path" \
		"$confidence" "$TRIAGE_KEY_SENSITIVITY" "$sensitivity" "$llm_tier" \
		"$reasoning_escaped" >> "$log_path"

	# Mark original pending entry as superseded
	printf '{"ts":"%s","%s":"superseded","%s":"%s","action":"routed-to-plane"}\n' \
		"$ts" "$TRIAGE_KEY_STATUS" "$TRIAGE_KEY_PATH" "$rel_path" >> "$log_path"

	print_success "  -> _${plane}/${sub_folder:+${sub_folder}/}${dest_name} (sensitivity=${sensitivity}, confidence=${confidence}%, tier=${llm_tier})"
	return 0
}

# =============================================================================
# cmd_digest — stale inbox item digest (t2869)
# =============================================================================
# Flags:
#   --age-days N          Age threshold in days (default: 7)
#   --repo PATH           Repo root to scan (default: pwd)
#   --include-workspace   Also scan ~/.aidevops/.agent-workspace/inbox/
#   --json                Machine-readable JSON array output
#
# Sub-folders scanned: _drop/ _needs-review/ (transit zones awaiting triage)
# Output sorted by age descending.
# =============================================================================

# _file_age_days <filepath>
# Returns the age of the file in whole days (integer).
_file_age_days() {
	local filepath="$1"
	local file_ts now_ts
	file_ts="$(date -r "$filepath" +%s 2>/dev/null || _file_mtime_epoch "$filepath")"
	now_ts="$(date +%s)"
	echo $(( (now_ts - file_ts) / 86400 ))
	return 0
}

# _triage_prior_attempts <log-path> <rel-path>
# Returns count of triage log entries for rel-path with status != pending.
_triage_prior_attempts() {
	local log_path="$1"
	local rel_path="$2"
	local count=0
	[[ ! -f "$log_path" ]] && echo "0" && return 0
	while IFS= read -r line; do
		[[ -z "$line" ]] && continue
		local path_field status_field
		path_field="$(_json_field "$line" "$TRIAGE_KEY_PATH")"
		status_field="$(_json_field "$line" "$TRIAGE_KEY_STATUS")"
		if [[ "$path_field" == "$rel_path" && "$status_field" != "$TRIAGE_VAL_PENDING" ]]; then
			count=$(( count + 1 ))
		fi
	done < "$log_path"
	echo "$count"
	return 0
}

# _digest_scan_inbox <inbox-dir> <age-days>
# Scans _drop/ and _needs-review/ for files older than age-days.
# Prints lines: "<age_days>\t<sub_folder>\t<rel_path>\t<prior_attempts>"
_digest_scan_inbox() {
	local inbox_dir="$1"
	local age_days="$2"
	local log_path="${inbox_dir}/${TRIAGE_LOG}"
	local inbox_parent
	inbox_parent="$(dirname "$inbox_dir")"

	local sub
	for sub in "${DIGEST_SCAN_SUBS[@]}"; do
		local sub_dir="${inbox_dir}/${sub}"
		[[ -d "$sub_dir" ]] || continue
		local f
		while IFS= read -r -d '' f; do
			local age
			age="$(_file_age_days "$f")"
			if [[ "$age" -ge "$age_days" ]]; then
				local rel_path="${f#"${inbox_parent}"/}"
				local attempts
				attempts="$(_triage_prior_attempts "$log_path" "$rel_path")"
				printf '%s\t%s\t%s\t%s\n' "$age" "$sub" "$rel_path" "$attempts"
			fi
		done < <(find "$sub_dir" -maxdepth 1 -type f ! -name '.*' -print0 2>/dev/null)
	done
	return 0
}

cmd_digest() {
	local age_days=7
	local repo_path
	repo_path="$(pwd)"
	local include_workspace=0
	local json_output=0

	while [[ $# -gt 0 ]]; do
		local cur_arg="$1"
		case "$cur_arg" in
		--age-days)          age_days="${2:-7}"; shift 2 ;;
		--age-days=*)        age_days="${cur_arg#--age-days=}"; shift ;;
		--repo)              repo_path="${2:-$(pwd)}"; shift 2 ;;
		--repo=*)            repo_path="${cur_arg#--repo=}"; shift ;;
		--include-workspace) include_workspace=1; shift ;;
		--json)              json_output=1; shift ;;
		*) print_error "Unknown digest flag: $cur_arg"; return 1 ;;
		esac
	done

	repo_path="$(cd "$repo_path" && pwd)"
	local inbox_dir="${repo_path}/${INBOX_DIR_NAME}"

	# Collect rows: age_days TAB sub_folder TAB rel_path TAB prior_attempts
	local -a rows=()
	if [[ -d "$inbox_dir" ]]; then
		while IFS= read -r row; do
			[[ -n "$row" ]] && rows+=("$row")
		done < <(_digest_scan_inbox "$inbox_dir" "$age_days")
	fi

	if [[ "$include_workspace" -eq 1 && -d "$WORKSPACE_INBOX_DIR" ]]; then
		while IFS= read -r row; do
			[[ -n "$row" ]] && rows+=("$row")
		done < <(_digest_scan_inbox "$WORKSPACE_INBOX_DIR" "$age_days")
	fi

	# Sort by age descending (field 1, numeric)
	local -a sorted_rows=()
	if [[ ${#rows[@]} -gt 0 ]]; then
		while IFS= read -r row; do
			[[ -n "$row" ]] && sorted_rows+=("$row")
		done < <(printf '%s\n' "${rows[@]}" | sort -t$'\t' -k1 -rn)
	fi

	if [[ "$json_output" -eq 1 ]]; then
		local first=1
		printf '['
		local row
		for row in "${sorted_rows[@]}"; do
			IFS=$'\t' read -r age sub rel_path attempts <<< "$row"
			[[ "$first" -eq 1 ]] && first=0 || printf ','
			printf '{"age_days":%s,"sub_folder":"%s","file_path":"%s","prior_attempts":%s}' \
				"$age" \
				"$(_json_escape "$sub")" \
				"$(_json_escape "$rel_path")" \
				"$attempts"
		done
		printf ']\n'
	else
		if [[ ${#sorted_rows[@]} -eq 0 ]]; then
			print_info "No items >= ${age_days} day(s) old in _inbox/ transit folders."
			return 0
		fi
		printf '\nStale _inbox/ items (>= %d day(s) old)\n\n' "$age_days"
		printf '  %-8s  %-20s  %-60s  %s\n' \
			"AGE" "SUB_FOLDER" "FILE_PATH" "PRIOR_ATTEMPTS"
		printf '  %-8s  %-20s  %-60s  %s\n' \
			"--------" "--------------------" \
			"------------------------------------------------------------" "--------------"
		local row
		for row in "${sorted_rows[@]}"; do
			IFS=$'\t' read -r age sub rel_path attempts <<< "$row"
			printf '  %-8s  %-20s  %-60s  %s\n' \
				"${age}d" "$sub" "$rel_path" "$attempts"
		done
		printf '\nTotal: %d stale item(s)\n\n' "${#sorted_rows[@]}"
	fi
	return 0
}

# =============================================================================
# cmd_help
# =============================================================================
cmd_help() {
	cat <<'EOF'
inbox-helper.sh — _inbox/ transit zone manager (t2866 + t2867 + t2868 + t2869)

Commands:
  provision [<repo-path>]   Create _inbox/ structure (default: current dir)
  provision-workspace       Create workspace-level inbox at ~/.aidevops/.agent-workspace/inbox/
  add <file>                Capture a file (auto-detects sub-folder from extension)
  add --url <url>           Capture a web page (saves HTML + text + metadata)
  find <query>              Search triage.log for entries matching query (last 30 days)
  status [<repo-path>]      Show item counts per sub-folder
  digest [options]          Show stale items in _drop/ and _needs-review/ (default: >= 7d old)
    --age-days N              Age threshold in days (default: 7)
    --repo PATH               Repo root to scan (default: current dir)
    --include-workspace       Also scan workspace inbox (~/.aidevops/.agent-workspace/inbox/)
    --json                    Machine-readable JSON array output
  triage [--dry-run] [--limit N] [--confidence-threshold N]
                            Process pending items: sensitivity → classify → route
  help                      Show this help

Sub-folder routing:
  email/   .eml, .msg
  scan/    .pdf, .png, .jpg, .heic, .tiff, .gif, .bmp, .webp
  voice/   .mp3, .m4a, .wav, .ogg, .flac, .aac, .opus
  web/     URLs (--url flag)
  _drop/   Everything else (or drag-drop target for watch folder)

Triage routing (when dependencies available):
  _needs-review/  Low-confidence or unknown-sensitivity items
  _knowledge/     General reference material
  _cases/         Case/matter specific files
  _campaigns/     Marketing and campaign material
  _projects/      Project artefacts
  _feedback/      Feedback and surveys

Audit log:
  _inbox/triage.log — append-only JSONL; one entry per capture/triage
  Fields: ts, source, sub, orig, path, status, sensitivity, confidence, reasoning

Environment variables (triage):
  TRIAGE_CONFIDENCE_THRESHOLD  Integer 0-100 (default: 85)
  TRIAGE_RATE_LIMIT            Max items per run (default: 50)
  TRIAGE_BACKOFF_THRESHOLD     Consecutive needs-review before halt (default: 10)

EOF
	return 0
}

# =============================================================================
# Dispatch
# =============================================================================
main() {
	local cmd="${1:-help}"
	shift || true
	case "$cmd" in
	provision) cmd_provision "$@" ;;
	provision-workspace) cmd_provision_workspace "$@" ;;
	add) cmd_add "$@" ;;
	find) cmd_find "$@" ;;
	status) cmd_status "$@" ;;
	digest) cmd_digest "$@" ;;
	triage) cmd_triage "$@" ;;
	help | -h | --help) cmd_help ;;
	*)
		print_error "Unknown inbox command: $cmd"
		echo ""
		cmd_help
		exit 1
		;;
	esac
}

main "$@"
