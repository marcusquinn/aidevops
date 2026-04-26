#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# =============================================================================
# inbox-helper.sh — _inbox/ directory provisioning, capture, and triage
# =============================================================================
# Implements the transit-zone inbox — files captured here are classified by
# sensitivity BEFORE any cloud LLM sees them.  See t2866 (P2a directory
# contract) and t2868 (P2c triage routine) for design rationale.
#
# Usage:
#   inbox-helper.sh provision <repo-path>   Set up _inbox/ in a repo
#   inbox-helper.sh provision-workspace     Set up workspace-level inbox
#   inbox-helper.sh triage [options]        Classify pending items
#   inbox-helper.sh add <file>              Drop a file into _inbox/_drop/
#   inbox-helper.sh status [options]        Show pending item counts
#   inbox-helper.sh help                    Show this message
#
# Triage options:
#   --dry-run           Print routing decisions without moving files
#   --limit N           Max items per run (default: 50)
#   --inbox-dir <dir>   Override inbox root directory
#
# Status options:
#   --inbox-dir <dir>   Override inbox root directory
#
# Environment:
#   INBOX_CONFIDENCE_THRESHOLD  Min confidence to auto-route (default: 0.85)
#   INBOX_TRIAGE_RATE_LIMIT     Max items per pulse cycle (default: 50)
#   INBOX_BACKOFF_THRESHOLD     Consecutive needs-review before halting (default: 5)
#   INBOX_WORKSPACE_DIR         Workspace inbox root (default: ~/.aidevops/.agent-workspace/inbox)
#   OLLAMA_HOST                 Ollama server host (default: localhost)
#   OLLAMA_PORT                 Ollama server port (default: 11434)
#   INBOX_LOCAL_MODEL           Ollama model for local classification (default: llama3.2)
#   INBOX_SNIPPET_BYTES         Content bytes to send to classifier (default: 2048)
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
# shellcheck source=shared-constants.sh
source "${SCRIPT_DIR}/shared-constants.sh"

# =============================================================================
# Configuration
# =============================================================================

INBOX_CONFIDENCE_THRESHOLD="${INBOX_CONFIDENCE_THRESHOLD:-0.85}"
INBOX_TRIAGE_RATE_LIMIT="${INBOX_TRIAGE_RATE_LIMIT:-50}"
INBOX_BACKOFF_THRESHOLD="${INBOX_BACKOFF_THRESHOLD:-5}"
INBOX_WORKSPACE_DIR="${INBOX_WORKSPACE_DIR:-${HOME}/.aidevops/.agent-workspace/inbox}"
OLLAMA_HOST="${OLLAMA_HOST:-localhost}"
OLLAMA_PORT="${OLLAMA_PORT:-11434}"
OLLAMA_BASE_URL="http://${OLLAMA_HOST}:${OLLAMA_PORT}"
INBOX_LOCAL_MODEL="${INBOX_LOCAL_MODEL:-llama3.2}"
INBOX_SNIPPET_BYTES="${INBOX_SNIPPET_BYTES:-2048}"

# Semantic defaults — used throughout to avoid repeated string literals
readonly INBOX_PLANE_DEFAULT="knowledge"
readonly INBOX_SUB_DEFAULT="unsorted"
readonly INBOX_SENSE_UNKNOWN="unknown"
readonly INBOX_STATUS_NEEDS_REVIEW="needs-review"
readonly INBOX_STATUS_ROUTED="routed"

# Inbox subdirectory names
readonly INBOX_SUBDIRS="_drop email web scan voice import _needs-review"

# =============================================================================
# Internal helpers
# =============================================================================

# _inbox_root_dir: resolve inbox root (base/_inbox or workspace)
_inbox_root_dir() {
	local base="${1:-}"
	if [[ -n "$base" ]]; then
		printf '%s/_inbox' "$base"
	else
		printf '%s' "$INBOX_WORKSPACE_DIR"
	fi
	return 0
}

# _triage_log: path to triage.log for an inbox dir
_triage_log() {
	local inbox_dir="$1"
	printf '%s/triage.log' "$inbox_dir"
	return 0
}

# _iso_ts: current UTC ISO-8601 timestamp
_iso_ts() {
	date -u '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || date '+%Y-%m-%dT%H:%M:%SZ'
	return 0
}

# _json_escape: escape a string for JSON (jq preferred, sed fallback)
_json_escape() {
	local s="$1"
	if command -v jq &>/dev/null; then
		printf '%s' "$s" | jq -Rs '.' | sed 's/^"//;s/"$//'
		return 0
	fi
	printf '%s' "$s" | sed 's/\\/\\\\/g; s/"/\\"/g'
	return 0
}

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

# _detect_sensitivity: call P0.5a detector or return INBOX_SENSE_UNKNOWN
# Outputs one word: public | confidential | privileged | competitive | unknown
_detect_sensitivity() {
	local file_path="$1"
	local detector="${SCRIPT_DIR}/sensitivity-detect.sh"

	if [[ ! -f "$detector" ]]; then
		printf '%s' "$INBOX_SENSE_UNKNOWN"
		return 0
	fi

	local result
	result=$("$detector" "$file_path" 2>/dev/null) || result="$INBOX_SENSE_UNKNOWN"
	case "$result" in
	public | confidential | privileged | competitive)
		printf '%s' "$result"
		;;
	*)
		printf '%s' "$INBOX_SENSE_UNKNOWN"
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

# _build_classify_prompt: emit the plain-text classification prompt
_build_classify_prompt() {
	local snippet="$1"
	local escaped
	escaped=$(_json_escape "$snippet")
	# Field names are unquoted here — the LLM reads intent, not syntax
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
# Outputs: raw JSON string (or empty on failure)
# Returns 0 on success, 1 on failure
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

	[[ -z "$plane" ]] && plane="$INBOX_PLANE_DEFAULT"
	[[ -z "$sub_folder" ]] && sub_folder="$INBOX_SUB_DEFAULT"
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

# _append_triage_log: append one JSONL entry to triage.log
_append_triage_log() {
	local log_path="$1"
	local status_val="$2"
	local from_path="$3"
	local to_path="${4:-}"
	local sensitivity="${5:-$INBOX_SENSE_UNKNOWN}"
	local plane="${6:-}"
	local confidence="${7:-0}"
	local reasoning="${8:-}"
	local llm_tier="${9:-}"
	local reason="${10:-}"

	local ts
	ts=$(_iso_ts)

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

# _write_meta_json: write provenance meta.json adjacent to a routed file
_write_meta_json() {
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
	ts=$(_iso_ts)

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
		# Fallback: printf-based JSON to avoid repeated literal keys
		printf '{"sensitivity":"%s","classification":{"plane":"%s","sub_folder":"%s"}' \
			"$sensitivity" "$plane" "$sub_folder" >"$meta_path"
		printf ',"confidence":%s,"triaged_at":"%s","original_path":"%s","llm_tier":"%s"}\n' \
			"$confidence" "$ts" "$original_path" "$llm_tier" >>"$meta_path"
	fi
	return 0
}

# _ts_suffix: generate a compact timestamp suffix for dedup naming
_ts_suffix() {
	date -u '+%Y%m%dT%H%M%S' 2>/dev/null || date '+%Y%m%dT%H%M%S'
	return 0
}

# _unique_dest: return a unique destination path, appending timestamp if needed
_unique_dest() {
	local target_dir="$1"
	local filename="$2"
	local dest="${target_dir}/${filename}"
	if [[ -e "$dest" ]]; then
		local sfx
		sfx=$(_ts_suffix)
		if [[ "$filename" == *"."* ]]; then
			dest="${target_dir}/${filename%.*}_${sfx}.${filename##*.}"
		else
			dest="${target_dir}/${filename}_${sfx}"
		fi
	fi
	printf '%s' "$dest"
	return 0
}

# _route_to_needs_review: move item to _needs-review, log entry
_route_to_needs_review() {
	local file_path="$1"
	local inbox_dir="$2"
	local reason="$3"
	local sensitivity="${4:-$INBOX_SENSE_UNKNOWN}"
	local dry_run="${5:-0}"

	local filename
	filename=$(basename "$file_path")
	local dest_dir="${inbox_dir}/_needs-review"
	local dest
	dest=$(_unique_dest "$dest_dir" "$filename")

	if [[ "$dry_run" -eq 1 ]]; then
		print_info "[DRY-RUN] needs-review: ${file_path} (${reason})"
		return 0
	fi

	mkdir -p "$dest_dir"
	mv "$file_path" "$dest"
	_append_triage_log "$(_triage_log "$inbox_dir")" \
		"$INBOX_STATUS_NEEDS_REVIEW" "$file_path" "$dest" \
		"$sensitivity" "" "0" "" "" "$reason"
	print_warning "needs-review: $(basename "$file_path") — ${reason}"
	return 0
}

# _route_to_plane: move item to target plane, write meta.json, log entry
_route_to_plane() {
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
	local base_dir="${inbox_dir%/_inbox}"
	[[ "$inbox_dir" == "$INBOX_WORKSPACE_DIR" ]] \
		&& base_dir="${INBOX_WORKSPACE_DIR%/inbox}"
	local plane_dir="${base_dir}/_${plane}/${sub_folder}"
	local filename
	filename=$(basename "$file_path")
	local dest
	dest=$(_unique_dest "$plane_dir" "$filename")

	if [[ "$dry_run" -eq 1 ]]; then
		print_info "[DRY-RUN] route: $(basename "$file_path") → _${plane}/${sub_folder}/ (${confidence})"
		return 0
	fi

	mkdir -p "$plane_dir"
	mv "$file_path" "$dest"
	_write_meta_json "$dest" "$sensitivity" "$plane" "$sub_folder" \
		"$confidence" "$reasoning" "$file_path" "$llm_tier" "$model"
	_append_triage_log "$(_triage_log "$inbox_dir")" \
		"$INBOX_STATUS_ROUTED" "$file_path" "$dest" "$sensitivity" "$plane" \
		"$confidence" "$reasoning" "$llm_tier" ""
	print_success "routed: $(basename "$file_path") → _${plane}/${sub_folder}/"
	return 0
}

# _triage_single_item: full triage pipeline for one item
# Returns 0 on clean disposition (routed or needs-review), 1 on fatal error
_triage_single_item() {
	local file_path="$1"
	local inbox_dir="$2"
	local dry_run="${3:-0}"

	# Step 1: Sensitivity gate — LOCAL ONLY, always first
	local sensitivity
	sensitivity=$(_detect_sensitivity "$file_path")

	if [[ "$sensitivity" == "$INBOX_SENSE_UNKNOWN" ]]; then
		_route_to_needs_review "$file_path" "$inbox_dir" \
			"sensitivity-undetermined" "$INBOX_SENSE_UNKNOWN" "$dry_run"
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
			_route_to_needs_review "$file_path" "$inbox_dir" \
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
			_route_to_needs_review "$file_path" "$inbox_dir" \
				"classifier-unavailable-no-llm" "$sensitivity" "$dry_run"
			return 0
		fi
	fi

	if [[ "$classify_ok" -eq 0 ]] || [[ -z "$classify_json" ]]; then
		_route_to_needs_review "$file_path" "$inbox_dir" \
			"classification-failed" "$sensitivity" "$dry_run"
		return 0
	fi

	# Step 4: Parse and validate confidence
	local fields plane sub_folder confidence reasoning
	fields=$(_parse_classification "$classify_json")
	plane=$(printf '%s' "$fields" | cut -f1)
	sub_folder=$(printf '%s' "$fields" | cut -f2)
	confidence=$(printf '%s' "$fields" | cut -f3)
	reasoning=$(printf '%s' "$fields" | cut -f4)

	if ! _confidence_meets_threshold "$confidence"; then
		_route_to_needs_review "$file_path" "$inbox_dir" \
			"low-confidence-${confidence}" "$sensitivity" "$dry_run"
		return 0
	fi

	# Step 5: Route to target plane
	_route_to_plane "$file_path" "$inbox_dir" "$plane" "$sub_folder" \
		"$sensitivity" "$confidence" "$reasoning" "$llm_tier" "$model_used" "$dry_run"
	return 0
}

# _find_pending_items: list files in inbox pending triage (excludes meta-files)
_find_pending_items() {
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
# Subcommands
# =============================================================================

cmd_provision() {
	local repo_path="${1:-$PWD}"
	local inbox_dir="${repo_path}/_inbox"

	print_info "Provisioning inbox at: ${inbox_dir}"
	mkdir -p "$inbox_dir"

	local d
	for d in $INBOX_SUBDIRS; do
		mkdir -p "${inbox_dir}/${d}"
	done

	if [[ ! -f "${inbox_dir}/README.md" ]]; then
		cat >"${inbox_dir}/README.md" <<'READMEEOF'
# _inbox/ — Transit Zone

Files here are unclassified. **Do not treat them as authoritative storage.**

## How triage works

1. `aidevops inbox triage` runs the sensitivity gate (local LLM) on each file.
2. Items classified as privileged or competitive are NEVER sent to cloud LLMs.
3. Confidently classified items are routed to the appropriate knowledge plane.
4. Uncertain items move to `_needs-review/` for human inspection.
5. Every routing decision is recorded in `triage.log`.

## Sub-folders

| Folder | Purpose |
|--------|---------|
| `_drop/` | General drop zone |
| `email/` | Email messages (.eml) |
| `web/` | Web clips, screenshots |
| `scan/` | Scanned documents |
| `voice/` | Audio recordings |
| `import/` | Bulk imports |
| `_needs-review/` | Items triage could not classify confidently |

## Sensitivity contract

Nothing in `_inbox/` flows to cloud LLMs until the sensitivity gate clears it.
READMEEOF
	fi

	if [[ ! -f "${inbox_dir}/.gitignore" ]]; then
		cat >"${inbox_dir}/.gitignore" <<'GITIGNEOF'
# Exclude captured files — they may contain sensitive content
*
# Keep metadata files
!README.md
!.gitignore
!triage.log
!*.meta.json
GITIGNEOF
	fi

	[[ ! -f "${inbox_dir}/triage.log" ]] && printf '' >"${inbox_dir}/triage.log"

	print_success "Inbox provisioned at: ${inbox_dir}"
	return 0
}

cmd_provision_workspace() {
	cmd_provision "$INBOX_WORKSPACE_DIR"
	return 0
}

cmd_add() {
	local src="${1:-}"
	local inbox_dir="${2:-}"

	if [[ -z "$src" ]]; then
		print_error "Usage: inbox-helper.sh add <file> [--inbox-dir <dir>]"
		return 1
	fi

	if [[ ! -f "$src" ]]; then
		print_error "File not found: ${src}"
		return 1
	fi

	[[ -z "$inbox_dir" ]] && inbox_dir="$INBOX_WORKSPACE_DIR"
	[[ ! -d "${inbox_dir}/_drop" ]] && cmd_provision_workspace

	local filename
	filename=$(basename "$src")
	local dest
	dest=$(_unique_dest "${inbox_dir}/_drop" "$filename")

	cp "$src" "$dest"
	print_success "Added to inbox: ${dest}"
	return 0
}

cmd_triage() {
	local dry_run=0
	local limit="$INBOX_TRIAGE_RATE_LIMIT"
	local inbox_dir=""
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

	[[ -z "$inbox_dir" ]] && inbox_dir="$INBOX_WORKSPACE_DIR"

	if [[ ! -d "$inbox_dir" ]]; then
		print_error "Inbox directory not found: ${inbox_dir}"
		print_info "Run: inbox-helper.sh provision-workspace"
		return 1
	fi

	local log_path
	log_path=$(_triage_log "$inbox_dir")

	print_info "Triaging inbox: ${inbox_dir} (limit=${limit})"
	[[ "$dry_run" -eq 1 ]] && print_info "[DRY-RUN] No files will be moved"

	local processed=0 routed=0 needs_review=0 errors=0 consecutive_nr=0
	local _fallback_status="$INBOX_STATUS_NEEDS_REVIEW"

	local item
	while IFS= read -r item; do
		[[ -z "$item" ]] && continue

		if ! _triage_single_item "$item" "$inbox_dir" "$dry_run"; then
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
			[[ -z "$last_status" ]] && last_status="$_fallback_status"
			case "$last_status" in
			"$INBOX_STATUS_ROUTED")
				routed=$((routed + 1))
				consecutive_nr=0
				;;
			"$INBOX_STATUS_NEEDS_REVIEW")
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
	done < <(_find_pending_items "$inbox_dir" "$limit")

	print_info "Triage complete: processed=${processed} routed=${routed} needs-review=${needs_review} errors=${errors}"
	return 0
}

cmd_status() {
	local inbox_dir=""
	local _opt

	while [[ $# -gt 0 ]]; do
		_opt="${1:-}"
		case "$_opt" in
		--inbox-dir) inbox_dir="${2:-}"; shift 2 ;;
		*) shift ;;
		esac
	done

	[[ -z "$inbox_dir" ]] && inbox_dir="$INBOX_WORKSPACE_DIR"

	if [[ ! -d "$inbox_dir" ]]; then
		print_error "Inbox not provisioned at: ${inbox_dir}"
		return 1
	fi

	print_info "Inbox status: ${inbox_dir}"

	local d count
	for d in $INBOX_SUBDIRS; do
		if [[ -d "${inbox_dir}/${d}" ]]; then
			count=$(find "${inbox_dir}/${d}" -maxdepth 1 -type f \
				! -name "README.md" \
				! -name ".gitignore" \
				! -name "triage.log" \
				! -name "*.meta.json" 2>/dev/null | wc -l) || count=0
			printf '  %-20s %d\n' "${d}/" "$count"
		fi
	done

	local log_path
	log_path=$(_triage_log "$inbox_dir")
	if [[ -f "$log_path" ]]; then
		local log_entries
		log_entries=$(wc -l <"$log_path" 2>/dev/null) || log_entries=0
		print_info "triage.log entries: ${log_entries}"
	fi
	return 0
}

cmd_help() {
	cat <<'HELPEOF'
inbox-helper.sh — _inbox/ directory provisioning and triage

Usage:
  inbox-helper.sh provision <repo-path>   Set up _inbox/ in a repo
  inbox-helper.sh provision-workspace     Set up workspace-level inbox
  inbox-helper.sh triage [options]        Classify pending items
  inbox-helper.sh add <file>              Drop a file into _inbox/_drop/
  inbox-helper.sh status [options]        Show pending item counts
  inbox-helper.sh help                    Show this message

Triage options:
  --dry-run           Print routing decisions without moving files
  --limit N           Max items per run (default: 50)
  --inbox-dir <dir>   Override inbox root directory

Environment:
  INBOX_CONFIDENCE_THRESHOLD  Min confidence to auto-route (default: 0.85)
  INBOX_LOCAL_MODEL           Ollama model for local classification (default: llama3.2)
  INBOX_WORKSPACE_DIR         Workspace inbox root

Dependencies (P0.5 phase — graceful fallback if absent):
  sensitivity-detect.sh   Detects sensitivity tier (local-only)
  llm-routing-helper.sh   Routes classification to correct LLM tier
HELPEOF
	return 0
}

# =============================================================================
# Main dispatcher
# =============================================================================

main() {
	local cmd="${1:-help}"
	shift || true

	case "$cmd" in
	provision) cmd_provision "$@" ;;
	provision-workspace) cmd_provision_workspace "$@" ;;
	triage) cmd_triage "$@" ;;
	add) cmd_add "$@" ;;
	status) cmd_status "$@" ;;
	help | --help | -h) cmd_help ;;
	*)
		print_error "Unknown command: ${cmd}"
		cmd_help
		return 1
		;;
	esac
	return 0
}

main "$@"
