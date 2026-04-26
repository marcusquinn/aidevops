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

# =============================================================================
# Triage configuration (t2868 — P2c)
# =============================================================================

# Tuneable defaults — override via environment before calling inbox-helper.sh
INBOX_CONFIDENCE_THRESHOLD="${INBOX_CONFIDENCE_THRESHOLD:-0.85}"
INBOX_TRIAGE_RATE_LIMIT="${INBOX_TRIAGE_RATE_LIMIT:-50}"
INBOX_BACKOFF_THRESHOLD="${INBOX_BACKOFF_THRESHOLD:-5}"
INBOX_LOCAL_MODEL="${INBOX_LOCAL_MODEL:-llama3.2}"
INBOX_SNIPPET_BYTES="${INBOX_SNIPPET_BYTES:-2048}"
OLLAMA_HOST="${OLLAMA_HOST:-localhost}"
OLLAMA_PORT="${OLLAMA_PORT:-11434}"
OLLAMA_BASE_URL="http://${OLLAMA_HOST}:${OLLAMA_PORT}"

# Semantic status / sensitivity constants — avoids repeated string literals
readonly TRIAGE_PLANE_DEFAULT="knowledge"
readonly TRIAGE_SUB_DEFAULT="unsorted"
readonly TRIAGE_SENSE_UNKNOWN="unknown"
readonly TRIAGE_STATUS_ROUTED="routed"
readonly TRIAGE_STATUS_NEEDS_REVIEW="needs-review"

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
# Triage helpers (t2868 — P2c)
# =============================================================================

# _sed_json_field: extract a single quoted JSON field value via grep+sed
# Used only when jq is unavailable.  Args: $1=json_text $2=field_name
_sed_json_field() {
	local json_text="$1"
	local field_name="$2"
	printf '%s' "$json_text" \
		| grep -o "\"${field_name}\":\"[^\"]*\"" \
		| sed "s/\"${field_name}\":\"//;s/\"$//"
	return 0
}

# _sed_json_num_field: extract a numeric JSON field value via grep+sed
# Used only when jq is unavailable.  Args: $1=json_text $2=field_name
_sed_json_num_field() {
	local json_text="$1"
	local field_name="$2"
	printf '%s' "$json_text" \
		| grep -o "\"${field_name}\":[0-9.]*" \
		| sed "s/\"${field_name}\"://"
	return 0
}

# _ollama_running: check if Ollama server is reachable
_ollama_running() {
	curl -sf "${OLLAMA_BASE_URL}/api/tags" >/dev/null 2>&1
	return $?
}

# _detect_sensitivity: call P0.5a detector or return TRIAGE_SENSE_UNKNOWN if absent
# Outputs one word: public | confidential | privileged | competitive | unknown
_detect_sensitivity() {
	local file_path="$1"
	local detector="${SCRIPT_DIR}/sensitivity-detect.sh"

	if [[ ! -f "$detector" ]]; then
		printf '%s' "$TRIAGE_SENSE_UNKNOWN"
		return 0
	fi

	local result
	result=$("$detector" "$file_path" 2>/dev/null) || result="$TRIAGE_SENSE_UNKNOWN"
	case "$result" in
	public | confidential | privileged | competitive)
		printf '%s' "$result"
		;;
	*)
		printf '%s' "$TRIAGE_SENSE_UNKNOWN"
		;;
	esac
	return 0
}

# _sensitivity_requires_local: returns 0 (true) when sensitivity = local-only tier
_sensitivity_requires_local() {
	local sensitivity="$1"
	case "$sensitivity" in
	privileged | competitive) return 0 ;;
	*) return 1 ;;
	esac
}

# _read_snippet: read up to INBOX_SNIPPET_BYTES bytes from file (safe)
_read_snippet() {
	local file_path="$1"
	dd if="$file_path" bs=1 count="$INBOX_SNIPPET_BYTES" 2>/dev/null || true
	return 0
}

# _json_escape_str: escape a string for JSON (jq preferred, sed fallback)
_json_escape_str() {
	local s="$1"
	if command -v jq &>/dev/null; then
		printf '%s' "$s" | jq -Rs '.' | sed 's/^"//;s/"$//'
		return 0
	fi
	printf '%s' "$s" | sed 's/\\/\\\\/g; s/"/\\"/g'
	return 0
}

# _build_classify_prompt: emit the plain-text classification prompt
_build_classify_prompt() {
	local snippet="$1"
	local escaped
	escaped=$(_json_escape_str "$snippet")
	# Field names are unquoted — the LLM reads intent, not syntax
	cat <<PROMPT
Given the following content snippet, classify it for knowledge management routing.
Respond with ONLY valid JSON (no explanation, no code fences).
Required JSON fields:
- target_plane: one of: knowledge, cases, campaigns, projects, feedback
- sub_folder: a short path within the plane (e.g. reference, active)
- confidence: float 0.0-1.0
- reasoning: one sentence

Content snippet:
${escaped}
PROMPT
	return 0
}

# _classify_via_ollama: call Ollama generate API, return raw classification JSON
# Returns 0 on success (prints JSON), 1 on failure
_classify_via_ollama() {
	local file_path="$1"
	local model="${INBOX_LOCAL_MODEL}"

	if ! _ollama_running; then
		return 1
	fi

	local snippet
	snippet=$(_read_snippet "$file_path")

	local prompt
	prompt=$(_build_classify_prompt "$snippet")

	local prompt_json
	prompt_json=$(printf '%s' "$prompt" | jq -Rs '.' 2>/dev/null) \
		|| prompt_json="\"${prompt}\""

	local request_body
	request_body=$(printf '{"model":"%s","prompt":%s,"stream":false}' \
		"$model" "$prompt_json")

	local raw_response
	raw_response=$(curl -sf -X POST \
		-H "Content-Type: application/json" \
		-d "$request_body" \
		"${OLLAMA_BASE_URL}/api/generate" 2>/dev/null) || return 1

	local model_text
	if command -v jq &>/dev/null; then
		model_text=$(printf '%s' "$raw_response" \
			| jq -r '.response // empty' 2>/dev/null) || model_text=""
	else
		model_text=$(_sed_json_field "$raw_response" "response")
	fi

	[[ -z "$model_text" ]] && return 1

	if command -v jq &>/dev/null; then
		printf '%s' "$model_text" \
			| jq -e '. | select(.target_plane and .confidence)' 2>/dev/null
		return $?
	fi

	printf '%s' "$model_text"
	return 0
}

# _parse_classification: extract fields from classification JSON
# Outputs: plane<TAB>sub_folder<TAB>confidence<TAB>reasoning
_parse_classification() {
	local json="$1"
	local plane sub_folder confidence reasoning

	if command -v jq &>/dev/null; then
		plane=$(printf '%s' "$json" \
			| jq -r '.target_plane // empty' 2>/dev/null) || plane=""
		sub_folder=$(printf '%s' "$json" \
			| jq -r '.sub_folder // empty' 2>/dev/null) || sub_folder=""
		confidence=$(printf '%s' "$json" \
			| jq -r '.confidence // empty' 2>/dev/null) || confidence=""
		reasoning=$(printf '%s' "$json" \
			| jq -r '.reasoning // empty' 2>/dev/null) || reasoning=""
	else
		plane=$(_sed_json_field "$json" "target_plane")
		sub_folder=$(_sed_json_field "$json" "sub_folder")
		confidence=$(_sed_json_num_field "$json" "confidence")
		reasoning=$(_sed_json_field "$json" "reasoning")
	fi

	[[ -z "$plane" ]] && plane="$TRIAGE_PLANE_DEFAULT"
	[[ -z "$sub_folder" ]] && sub_folder="$TRIAGE_SUB_DEFAULT"
	[[ -z "$confidence" ]] && confidence="0"

	printf '%s\t%s\t%s\t%s' "$plane" "$sub_folder" "$confidence" "$reasoning"
	return 0
}

# _confidence_meets_threshold: compare float confidence vs INBOX_CONFIDENCE_THRESHOLD
# Returns 0 if confidence >= threshold, 1 otherwise
_confidence_meets_threshold() {
	local confidence="$1"
	local threshold="$INBOX_CONFIDENCE_THRESHOLD"
	awk "BEGIN { exit ($confidence >= $threshold) ? 0 : 1 }" 2>/dev/null
	return $?
}

# _append_triage_decision: append a routing decision JSONL entry to triage.log
# Extends the capture log schema with sensitivity/plane/confidence/reasoning fields.
_append_triage_decision() {
	local inbox_dir="$1"
	local status_val="$2"
	local from_path="$3"
	local to_path="${4:-}"
	local sensitivity="${5:-$TRIAGE_SENSE_UNKNOWN}"
	local plane="${6:-}"
	local confidence="${7:-0}"
	local reasoning="${8:-}"
	local llm_tier="${9:-}"
	local reason="${10:-}"

	local ts
	ts="$(_iso_ts_full)"
	local log_path="${inbox_dir}/${TRIAGE_LOG}"

	local entry
	if command -v jq &>/dev/null; then
		entry=$(jq -cn \
			--arg ts "$ts" \
			--arg status "$status_val" \
			--arg from "$from_path" \
			--arg to "$to_path" \
			--arg sensitivity "$sensitivity" \
			--arg plane "$plane" \
			--argjson confidence "${confidence:-0}" \
			--arg reasoning "$reasoning" \
			--arg llm_tier "$llm_tier" \
			--arg reason "$reason" \
			'{ts:$ts, status:$status, from:$from, to:$to,
			  sensitivity:$sensitivity, plane:$plane,
			  confidence:$confidence, reasoning:$reasoning,
			  llm_tier:$llm_tier, reason:$reason}' 2>/dev/null) || {
			entry="{\"ts\":\"${ts}\",\"status\":\"${status_val}\",\"from\":\"${from_path}\"}"
		}
	else
		entry="{\"ts\":\"${ts}\",\"status\":\"${status_val}\",\"from\":\"${from_path}\",\"sensitivity\":\"${sensitivity}\"}"
	fi

	printf '%s\n' "$entry" >>"$log_path"
	return 0
}

# _write_triage_meta_json: write provenance meta.json adjacent to a routed file
_write_triage_meta_json() {
	local dest_file="$1"
	local sensitivity="$2"
	local plane="$3"
	local sub_folder="$4"
	local confidence="$5"
	local reasoning="$6"
	local original_path="$7"
	local llm_tier="$8"
	local model="${9:-}"

	local meta_path="${dest_file}.meta.json"
	local ts
	ts="$(_iso_ts_full)"

	if command -v jq &>/dev/null; then
		jq -cn \
			--arg sensitivity "$sensitivity" \
			--arg plane "$plane" \
			--arg sub_folder "$sub_folder" \
			--argjson confidence "${confidence:-0}" \
			--arg reasoning "$reasoning" \
			--arg triaged_at "$ts" \
			--arg original_path "$original_path" \
			--arg llm_tier "$llm_tier" \
			--arg llm_model "$model" \
			'{sensitivity:$sensitivity,
			  classification:{plane:$plane,sub_folder:$sub_folder},
			  confidence:$confidence, reasoning:$reasoning,
			  triaged_at:$triaged_at, original_path:$original_path,
			  llm_tier:$llm_tier, llm_model:$llm_model}' >"$meta_path" 2>/dev/null
	else
		printf '{"sensitivity":"%s","classification":{"plane":"%s","sub_folder":"%s"}' \
			"$sensitivity" "$plane" "$sub_folder" >"$meta_path"
		printf ',"confidence":%s,"triaged_at":"%s","original_path":"%s","llm_tier":"%s"}\n' \
			"$confidence" "$ts" "$original_path" "$llm_tier" >>"$meta_path"
	fi
	return 0
}

# _ts_suffix_compact: compact timestamp suffix for dedup naming
_ts_suffix_compact() {
	date -u '+%Y%m%dT%H%M%S' 2>/dev/null || date '+%Y%m%dT%H%M%S'
	return 0
}

# _unique_dest_path: return a unique destination path (appends timestamp if conflict)
_unique_dest_path() {
	local target_dir="$1"
	local filename="$2"
	local dest="${target_dir}/${filename}"
	if [[ -e "$dest" ]]; then
		local sfx
		sfx=$(_ts_suffix_compact)
		if [[ "$filename" == *"."* ]]; then
			dest="${target_dir}/${filename%.*}_${sfx}.${filename##*.}"
		else
			dest="${target_dir}/${filename}_${sfx}"
		fi
	fi
	printf '%s' "$dest"
	return 0
}

# _route_item_to_needs_review: move item to _needs-review, log decision
_route_item_to_needs_review() {
	local file_path="$1"
	local inbox_dir="$2"
	local reason="$3"
	local sensitivity="${4:-$TRIAGE_SENSE_UNKNOWN}"
	local dry_run="${5:-0}"

	local filename
	filename=$(basename "$file_path")
	local dest_dir="${inbox_dir}/_needs-review"
	local dest
	dest=$(_unique_dest_path "$dest_dir" "$filename")

	if [[ "$dry_run" -eq 1 ]]; then
		print_info "[DRY-RUN] needs-review: ${file_path} (${reason})"
		return 0
	fi

	mkdir -p "$dest_dir"
	mv "$file_path" "$dest"
	_append_triage_decision "$inbox_dir" \
		"$TRIAGE_STATUS_NEEDS_REVIEW" "$file_path" "$dest" \
		"$sensitivity" "" "0" "" "" "$reason"
	print_warning "needs-review: $(basename "$file_path") — ${reason}"
	return 0
}

# _route_item_to_plane: move item to target plane, write meta.json, log decision
_route_item_to_plane() {
	local file_path="$1"
	local inbox_dir="$2"
	local plane="$3"
	local sub_folder="$4"
	local sensitivity="$5"
	local confidence="$6"
	local reasoning="$7"
	local llm_tier="$8"
	local model="${9:-}"
	local dry_run="${10:-0}"

	# Plane root is sibling of _inbox; strip trailing /_inbox segment
	local base_dir="${inbox_dir%/"${INBOX_DIR_NAME}"}"
	[[ "$inbox_dir" == "$WORKSPACE_INBOX_DIR" ]] \
		&& base_dir="${WORKSPACE_INBOX_DIR%/inbox}"
	local plane_dir="${base_dir}/_${plane}/${sub_folder}"
	local filename
	filename=$(basename "$file_path")
	local dest
	dest=$(_unique_dest_path "$plane_dir" "$filename")

	if [[ "$dry_run" -eq 1 ]]; then
		print_info "[DRY-RUN] route: $(basename "$file_path") → _${plane}/${sub_folder}/ (${confidence})"
		return 0
	fi

	mkdir -p "$plane_dir"
	mv "$file_path" "$dest"
	_write_triage_meta_json "$dest" "$sensitivity" "$plane" "$sub_folder" \
		"$confidence" "$reasoning" "$file_path" "$llm_tier" "$model"
	_append_triage_decision "$inbox_dir" \
		"$TRIAGE_STATUS_ROUTED" "$file_path" "$dest" "$sensitivity" "$plane" \
		"$confidence" "$reasoning" "$llm_tier" ""
	print_success "routed: $(basename "$file_path") → _${plane}/${sub_folder}/"
	return 0
}

# _triage_one_item: full triage pipeline for a single pending item
# Returns 0 on clean disposition (routed or needs-review), 1 on fatal error
_triage_one_item() {
	local file_path="$1"
	local inbox_dir="$2"
	local dry_run="${3:-0}"

	# Step 1: Sensitivity gate — LOCAL ONLY, always runs first
	local sensitivity
	sensitivity=$(_detect_sensitivity "$file_path")

	if [[ "$sensitivity" == "$TRIAGE_SENSE_UNKNOWN" ]]; then
		_route_item_to_needs_review "$file_path" "$inbox_dir" \
			"sensitivity-undetermined" "$TRIAGE_SENSE_UNKNOWN" "$dry_run"
		return 0
	fi

	# Step 2: Pick LLM tier based on sensitivity
	local llm_tier
	if _sensitivity_requires_local "$sensitivity"; then
		llm_tier="local"
	else
		llm_tier="cloud"
	fi

	# Step 3: Attempt classification
	local classify_json=""
	local classify_ok=0
	local model_used=""

	if [[ "$llm_tier" == "local" ]]; then
		if ! _ollama_running; then
			_route_item_to_needs_review "$file_path" "$inbox_dir" \
				"classifier-unavailable-ollama-not-running" "$sensitivity" "$dry_run"
			return 0
		fi
		classify_json=$(_classify_via_ollama "$file_path") && classify_ok=1 || classify_ok=0
		model_used="$INBOX_LOCAL_MODEL"
	else
		local router="${SCRIPT_DIR}/llm-routing-helper.sh"
		if [[ -f "$router" ]]; then
			classify_json=$("$router" classify "$file_path" --tier cloud 2>/dev/null) \
				&& classify_ok=1 || classify_ok=0
			model_used="cloud"
		elif _ollama_running; then
			classify_json=$(_classify_via_ollama "$file_path") && classify_ok=1 || classify_ok=0
			model_used="${INBOX_LOCAL_MODEL} (local-fallback)"
			llm_tier="local-fallback"
		else
			_route_item_to_needs_review "$file_path" "$inbox_dir" \
				"classifier-unavailable-no-llm" "$sensitivity" "$dry_run"
			return 0
		fi
	fi

	if [[ "$classify_ok" -eq 0 ]] || [[ -z "$classify_json" ]]; then
		_route_item_to_needs_review "$file_path" "$inbox_dir" \
			"classification-failed" "$sensitivity" "$dry_run"
		return 0
	fi

	# Step 4: Parse and check confidence
	local fields plane sub_folder confidence reasoning
	fields=$(_parse_classification "$classify_json")
	plane=$(printf '%s' "$fields" | cut -f1)
	sub_folder=$(printf '%s' "$fields" | cut -f2)
	confidence=$(printf '%s' "$fields" | cut -f3)
	reasoning=$(printf '%s' "$fields" | cut -f4)

	if ! _confidence_meets_threshold "$confidence"; then
		_route_item_to_needs_review "$file_path" "$inbox_dir" \
			"low-confidence-${confidence}" "$sensitivity" "$dry_run"
		return 0
	fi

	# Step 5: Route to target plane
	_route_item_to_plane "$file_path" "$inbox_dir" "$plane" "$sub_folder" \
		"$sensitivity" "$confidence" "$reasoning" "$llm_tier" "$model_used" "$dry_run"
	return 0
}

# _find_pending_triage_items: list files in inbox pending triage (excludes meta-files)
_find_pending_triage_items() {
	local inbox_dir="$1"
	local limit="${2:-50}"

	[[ ! -d "$inbox_dir" ]] && return 0

	local found=0
	local f
	while IFS= read -r f; do
		case "$f" in
		*/_needs-review/*) continue ;;
		*/README.md) continue ;;
		*/.gitignore) continue ;;
		*/triage.log) continue ;;
		*.meta.json) continue ;;
		esac
		printf '%s\n' "$f"
		found=$((found + 1))
		[[ "$found" -ge "$limit" ]] && break
	done < <(find "$inbox_dir" -maxdepth 3 -type f 2>/dev/null | sort)
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

	_append_triage_log "$inbox_dir" "cli-add" "$sub" "$abs_src" "$rel_path" "pending"

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
	_append_triage_log "$inbox_dir" "cli-url" "web" "$url" "$rel_path" "pending"

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
				file_ts="$(date -r "$oldest_file" +%s 2>/dev/null || stat -c '%Y' "$oldest_file" 2>/dev/null || echo 0)"
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
# cmd_triage — classify pending inbox items (t2868 — P2c)
# =============================================================================
cmd_triage() {
	local dry_run=0
	local limit="$INBOX_TRIAGE_RATE_LIMIT"
	local inbox_dir="$WORKSPACE_INBOX_DIR"
	local _opt

	while [[ $# -gt 0 ]]; do
		_opt="${1:-}"
		case "$_opt" in
		--dry-run) dry_run=1; shift ;;
		--limit) limit="${2:-50}"; shift 2 ;;
		--inbox-dir) inbox_dir="${2:-}"; shift 2 ;;
		*) print_warning "Unknown triage option: ${_opt}"; shift ;;
		esac
	done

	if [[ ! -d "$inbox_dir" ]]; then
		print_error "Inbox directory not found: ${inbox_dir}"
		print_info "Run: inbox-helper.sh provision-workspace"
		return 1
	fi

	print_info "Triaging inbox: ${inbox_dir} (limit=${limit})"
	[[ "$dry_run" -eq 1 ]] && print_info "[DRY-RUN] No files will be moved"

	local processed=0 routed=0 needs_review=0 errors=0 consecutive_nr=0
	local log_path="${inbox_dir}/${TRIAGE_LOG}"
	local _nr_status="$TRIAGE_STATUS_NEEDS_REVIEW"

	local item
	while IFS= read -r item; do
		[[ -z "$item" ]] && continue

		if ! _triage_one_item "$item" "$inbox_dir" "$dry_run"; then
			errors=$((errors + 1))
			print_warning "Error processing: ${item}"
			continue
		fi

		processed=$((processed + 1))

		# Count disposition from the last triage.log entry
		if [[ -f "$log_path" ]] && [[ "$dry_run" -eq 0 ]]; then
			local last_status
			if command -v jq &>/dev/null; then
				last_status=$(tail -1 "$log_path" \
					| jq -r '.status // empty' 2>/dev/null) || last_status=""
			else
				last_status=$(_sed_json_field "$(tail -1 "$log_path")" "status")
			fi
			[[ -z "$last_status" ]] && last_status="$_nr_status"
			case "$last_status" in
			"$TRIAGE_STATUS_ROUTED")
				routed=$((routed + 1))
				consecutive_nr=0
				;;
			"$TRIAGE_STATUS_NEEDS_REVIEW")
				needs_review=$((needs_review + 1))
				consecutive_nr=$((consecutive_nr + 1))
				;;
			esac
		fi

		if [[ "$consecutive_nr" -ge "$INBOX_BACKOFF_THRESHOLD" ]]; then
			print_warning "Halting: ${INBOX_BACKOFF_THRESHOLD} consecutive needs-review — possible classifier issue"
			break
		fi

		[[ "$processed" -ge "$limit" ]] && break
	done < <(_find_pending_triage_items "$inbox_dir" "$limit")

	print_info "Triage complete: processed=${processed} routed=${routed} needs-review=${needs_review} errors=${errors}"
	return 0
}

# =============================================================================
# cmd_help
# =============================================================================
cmd_help() {
	cat <<'EOF'
inbox-helper.sh — _inbox/ transit zone manager (t2866 + t2867 + t2868)

Commands:
  provision [<repo-path>]   Create _inbox/ structure (default: current dir)
  provision-workspace       Create workspace-level inbox at ~/.aidevops/.agent-workspace/inbox/
  add <file>                Capture a file (auto-detects sub-folder from extension)
  add --url <url>           Capture a web page (saves HTML + text + metadata)
  find <query>              Search triage.log for entries matching query (last 30 days)
  triage [options]          Classify pending items via sensitivity gate + LLM
  status [<repo-path>]      Show item counts per sub-folder
  help                      Show this help

Triage options:
  --dry-run           Print routing decisions without moving files
  --limit N           Max items per run (default: 50)
  --inbox-dir <dir>   Override inbox root directory

Sub-folder routing:
  email/   .eml, .msg
  scan/    .pdf, .png, .jpg, .heic, .tiff, .gif, .bmp, .webp
  voice/   .mp3, .m4a, .wav, .ogg, .flac, .aac, .opus
  web/     URLs (--url flag)
  _drop/   Everything else (or drag-drop target for watch folder)

Triage sensitivity rules:
  privileged / competitive  → local Ollama ONLY (never sent to cloud)
  public / confidential     → cloud OK (llm-routing-helper.sh or Ollama fallback)
  unknown                   → routed to _needs-review/ (safe default)

Audit log:
  _inbox/triage.log — append-only JSONL; one entry per capture or triage decision
  Capture fields:  ts, source, sub, orig, path, status, sensitivity
  Triage fields:   ts, status, from, to, sensitivity, plane, confidence, reasoning, llm_tier

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
	triage) cmd_triage "$@" ;;
	status) cmd_status "$@" ;;
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
