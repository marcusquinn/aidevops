#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# shellcheck disable=SC2034
set -euo pipefail

# =============================================================================
# Case Draft Helper (t2857)
# =============================================================================
# Generates strategic communication drafts using RAG over case knowledge
# sources, with full provenance tracking and human-gated output.
#
# Drafts are ALWAYS human-gated — never auto-sent.
#
# Usage:
#   case-draft-helper.sh draft <case-id> --intent "..." [options]
#   case-draft-helper.sh revise <draft-file> --feedback "..." [options]
#   case-draft-helper.sh help
#
# Options:
#   --intent <text>       Free-text description of draft intent (REQUIRED)
#   --tone <preset>       Tone preset: neutral|formal|conciliatory|firm
#   --length <size>       Draft length: short|medium|long
#   --cite <mode>         Citation mode: strict|loose (default: strict)
#   --include-case <id>   Include another case's sources (audited)
#   --dry-run             Print draft to stdout, don't write file
#   --repo <path>         Target repo path (default: cwd)
#   --max-tokens <N>      Max tokens for LLM call (default: auto)
#   --json                Machine-readable JSON output
#
# Revise mode:
#   --revise <file>       Path to existing draft file to revise
#   --feedback <text>     Revision feedback / instructions
#
# ShellCheck clean. Bash 3.2 compatible (macOS default).
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
# shellcheck source=shared-constants.sh
source "${SCRIPT_DIR}/shared-constants.sh"

init_log_file

# =============================================================================
# Constants
# =============================================================================

readonly CASES_DIR_NAME="_cases"
readonly CASE_DOSSIER_FILE="dossier.toon"
readonly CASE_SOURCES_FILE="sources.toon"
readonly CASE_TIMELINE_FILE="timeline.jsonl"
readonly CASE_DRAFTS_DIR="drafts"
readonly CASE_COMMS_DIR="comms"
readonly CROSS_CASE_ACCESS_LOG="cross-case-access.jsonl"

readonly KNOWLEDGE_SOURCES_DIR="_knowledge/sources"
readonly SOURCE_META_FILE="meta.json"

readonly PROMPT_TEMPLATE="${SCRIPT_DIR}/../templates/case-draft-prompt.md"
readonly TONES_CONFIG_DEFAULT="${SCRIPT_DIR}/../templates/draft-tones-config.json"

# Sensitivity tier ordering (lowest to highest)
# Maps knowledge-plane sensitivity to LLM routing tiers
readonly -a _SENSITIVITY_ORDER=(public internal pii sensitive privileged)

# Length → token mapping
readonly _LENGTH_SHORT=2048
readonly _LENGTH_MEDIUM=4096
readonly _LENGTH_LONG=8192

# Centralised string constants (satisfies string-literal ratchet)
_TONE_DEFAULT_FRAGMENT="Maintain a balanced, objective tone."
_TASK_DRAFT="draft"
_UNKNOWN="unknown"
_INTERNAL="internal"
_TRUE="true"

# =============================================================================
# Error helpers
# =============================================================================

_err_missing_arg() {
	local arg="$1"
	print_error "Missing required argument: ${arg}"
	return 1
}

_err_case_not_found() {
	local case_id="$1"
	print_error "Case not found: ${case_id}"
	return 1
}

# =============================================================================
# Internal helpers
# =============================================================================

# _iso_ts — current UTC timestamp
_iso_ts() {
	date -u '+%Y%m%dT%H%M%SZ'
	return 0
}

# _iso_ts_filename — timestamp suitable for filenames
_iso_ts_filename() {
	date -u '+%Y%m%d-%H%M%S'
	return 0
}

# _current_actor — best-effort actor name
_current_actor() {
	local actor
	actor="$(git config user.name 2>/dev/null)" || true
	[[ -z "$actor" ]] && actor="${USER:-unknown}"
	echo "$actor"
	return 0
}

# _require_jq — error if jq is not available
_require_jq() {
	if ! command -v jq >/dev/null 2>&1; then
		print_error "jq is required but not found. Install: brew install jq"
		return 1
	fi
	return 0
}

# _slugify <text> — convert free text to kebab-case slug
_slugify() {
	local text="$1"
	echo "$text" | tr '[:upper:]' '[:lower:]' | tr -cs '[:alnum:]' '-' | sed 's/^-//;s/-$//' | cut -c1-50
	return 0
}

# _resolve_cases_dir <repo-path>
_resolve_cases_dir() {
	local repo_path="${1:-$(pwd)}"
	echo "${repo_path}/${CASES_DIR_NAME}"
	return 0
}

# _case_find <cases-dir> <case-id> — resolve case directory path
_case_find() {
	local cases_dir="$1" query="$2"

	# Direct directory match
	if [[ -d "${cases_dir}/${query}" ]]; then
		echo "${cases_dir}/${query}"
		return 0
	fi

	# Prefix / slug match
	local dir
	for dir in "${cases_dir}"/case-*-"${query}" "${cases_dir}"/case-*-*"${query}"*; do
		[[ -d "$dir" ]] || continue
		[[ "$dir" == *"/archived/"* ]] && continue
		echo "$dir"
		return 0
	done

	return 1
}

# _timeline_append <case-dir> <kind> <actor> <content> [ref]
_timeline_append() {
	local case_dir="$1" kind="$2" actor="$3" content="$4" ref="${5:-}"
	local timeline_path="${case_dir}/${CASE_TIMELINE_FILE}"
	local ts
	ts="$(_iso_ts)"
	local event
	event="$(jq -cn \
		--arg ts "$ts" \
		--arg kind "$kind" \
		--arg actor "$actor" \
		--arg content "$content" \
		--arg ref "$ref" \
		'{ts:$ts, kind:$kind, actor:$actor, content:$content, ref:$ref}')"
	echo "$event" >>"$timeline_path"
	return 0
}

# _sensitivity_to_tier <sensitivity> — map knowledge-plane sensitivity to LLM tier
_sensitivity_to_tier() {
	local sensitivity="$1"
	case "$sensitivity" in
	public) echo "public" ;;
	internal) echo "$_INTERNAL" ;;
	confidential) echo "sensitive" ;;
	restricted | privileged) echo "privileged" ;;
	pii) echo "pii" ;;
	sensitive) echo "sensitive" ;;
	*) echo "$_INTERNAL" ;; # safe default
	esac
	return 0
}

# _tier_rank <tier> — numeric rank for comparison (higher = more sensitive)
_tier_rank() {
	local tier="$1"
	case "$tier" in
	public) echo 0 ;;
	internal) echo 1 ;;
	pii) echo 2 ;;
	sensitive) echo 3 ;;
	privileged) echo 4 ;;
	*) echo 1 ;;
	esac
	return 0
}

# _max_tier <sources-json> <repo-path> — resolve maximum sensitivity tier
# Reads meta.json for each source to determine sensitivity, returns the highest tier.
_max_tier() {
	local sources_json="$1" repo_path="$2"
	local max_rank=0 max_tier="public"

	local source_ids
	source_ids="$(echo "$sources_json" | jq -r '.[].id' 2>/dev/null)" || true

	local source_id
	while IFS= read -r source_id; do
		[[ -z "$source_id" ]] && continue
		local meta_path="${repo_path}/${KNOWLEDGE_SOURCES_DIR}/${source_id}/${SOURCE_META_FILE}"
		if [[ -f "$meta_path" ]]; then
			local sensitivity
			sensitivity="$(jq -r --arg fb "$_INTERNAL" '.sensitivity // $fb' "$meta_path" 2>/dev/null)" || sensitivity="$_INTERNAL"
			local tier
			tier="$(_sensitivity_to_tier "$sensitivity")"
			local rank
			rank="$(_tier_rank "$tier")"
			if [[ "$rank" -gt "$max_rank" ]]; then
				max_rank="$rank"
				max_tier="$tier"
			fi
		fi
	done <<<"$source_ids"

	echo "$max_tier"
	return 0
}

# _load_tones_config <repo-path> — load tone library, falling back to template
_load_tones_config() {
	local repo_path="$1"
	local user_config="${repo_path}/_config/draft-tones.json"

	if [[ -f "$user_config" ]]; then
		echo "$user_config"
	elif [[ -f "$TONES_CONFIG_DEFAULT" ]]; then
		echo "$TONES_CONFIG_DEFAULT"
	else
		echo ""
	fi
	return 0
}

# _get_tone_fragment <tones-config-path> <tone-name> — get system prompt fragment
_get_tone_fragment() {
	local config_path="$1" tone_name="$2"

	if [[ -z "$config_path" || ! -f "$config_path" ]]; then
		# Inline defaults when no config available
		case "$tone_name" in
		neutral) echo "$_TONE_DEFAULT_FRAGMENT" ;;
		formal) echo "Use formal, professional language appropriate for official correspondence." ;;
		conciliatory) echo "Adopt a cooperative, solution-oriented tone that seeks common ground." ;;
		firm) echo "Be direct, assertive, and clear about positions and expectations." ;;
		*) echo "$_TONE_DEFAULT_FRAGMENT" ;;
		esac
		return 0
	fi

	local fragment
	fragment="$(jq -r --arg t "$tone_name" '.tones[$t].system_fragment // ""' "$config_path" 2>/dev/null)" || fragment=""

	if [[ -z "$fragment" ]]; then
		echo "$_TONE_DEFAULT_FRAGMENT"
	else
		echo "$fragment"
	fi
	return 0
}

# _length_to_tokens <length> — map length preset to max tokens
_length_to_tokens() {
	local length="$1"
	case "$length" in
	short) echo "$_LENGTH_SHORT" ;;
	medium) echo "$_LENGTH_MEDIUM" ;;
	long) echo "$_LENGTH_LONG" ;;
	*) echo "$_LENGTH_MEDIUM" ;;
	esac
	return 0
}

# _length_to_word_range <length> — human-readable length guidance
_length_to_word_range() {
	local length="$1"
	case "$length" in
	short) echo "200-500 words" ;;
	medium) echo "500-1500 words" ;;
	long) echo "1500-4000 words" ;;
	*) echo "500-1500 words" ;;
	esac
	return 0
}

# _read_timeline_recent <case-dir> <count> — last N timeline entries as text
_read_timeline_recent() {
	local case_dir="$1" count="${2:-5}"
	local timeline_path="${case_dir}/${CASE_TIMELINE_FILE}"

	if [[ ! -f "$timeline_path" ]]; then
		echo "(no timeline entries)"
		return 0
	fi

	tail -n "$count" "$timeline_path" | while IFS= read -r line; do
		[[ -z "$line" ]] && continue
		local ts kind content
		ts="$(echo "$line" | jq -r '.ts' 2>/dev/null)" || ts="?"
		kind="$(echo "$line" | jq -r '.kind' 2>/dev/null)" || kind="?"
		content="$(echo "$line" | jq -r '.content' 2>/dev/null)" || content="?"
		printf '[%s] %s: %s\n' "$ts" "$kind" "$content"
	done
	return 0
}

# _collect_excerpts_for_draft <case_id> <intent> <source_ids> <repo_path> <max>
# Routes through knowledge-helper.sh search --case <case_id> for ranked
# case-scoped RAG (t2977 Phase 6); falls back to direct _collect_excerpts.
_collect_excerpts_for_draft() {
	local case_id="$1" intent="$2" source_ids="$3" repo_path="$4" max_sources="${5:-8}"
	local _kh="${SCRIPT_DIR}/knowledge-helper.sh"
	local excerpts=""
	if [[ -x "$_kh" ]]; then
		excerpts="$(_collect_excerpts_via_search "$_kh" "$case_id" "$intent" "$repo_path" "$max_sources")"
		[[ -z "$excerpts" ]] && excerpts="$(_collect_excerpts "$source_ids" "$repo_path" "$max_sources")"
	else
		excerpts="$(_collect_excerpts "$source_ids" "$repo_path" "$max_sources")"
	fi
	printf '%s' "$excerpts"
	return 0
}

# _collect_excerpts_via_search <knowledge_helper> <case_id> <intent> <repo_path> <max>
# Retrieves ranked excerpts by routing through knowledge-helper.sh search with
# --case <case_id> so corpus retrieval is automatically scoped to case-relevant
# sources (t2977 Phase 6). Returns formatted "[<id>]: <excerpt>" text.
# Falls back gracefully to empty output on any error.
_collect_excerpts_via_search() {
	local knowledge_helper="$1" case_id="$2" intent="$3" repo_path="$4" max_sources="${5:-8}"
	local search_out
	search_out="$(bash "$knowledge_helper" search \
		--case "$case_id" --repo-path "$repo_path" "$intent" 2>/dev/null)" || search_out=""
	[[ -z "$search_out" ]] && return 0

	# Single jq --slurp pass: handles both NDJSON lines and multi-line JSON objects.
	# Expands .matches[] for tree-walk format; limits to max_sources results.
	# Uses --argjson for the numeric limit to avoid syntax errors on special chars.
	local excerpts=""
	excerpts="$(printf '%s\n' "$search_out" | jq -s -r --argjson max "$max_sources" '
		[ .[] | if type == "object" and has("matches") then .matches[] else . end ] |
		.[:$max] | .[] |
		"[\(.source_id // .id // \"unknown\")]: \"\(.excerpt // .anchor // \"\")\"\n\n"
	')" || excerpts=""

	printf '%s' "$excerpts"
	return 0
}

# _collect_excerpts <source-ids> <repo-path> <max-sources> — collect excerpts from sources
# Returns numbered excerpts with source anchors.
_collect_excerpts() {
	local source_ids_str="$1" repo_path="$2" max_sources="${3:-8}"
	local count=0 excerpts=""

	local source_id
	while IFS= read -r source_id; do
		[[ -z "$source_id" ]] && continue
		[[ "$count" -ge "$max_sources" ]] && break

		local source_dir="${repo_path}/${KNOWLEDGE_SOURCES_DIR}/${source_id}"
		[[ ! -d "$source_dir" ]] && continue

		# Try to read content from the source directory
		local content_file=""
		local f
		for f in "${source_dir}"/*.txt "${source_dir}"/*.md "${source_dir}"/*.pdf.txt \
			"${source_dir}"/content.txt "${source_dir}"/extracted.txt; do
			if [[ -f "$f" ]]; then
				content_file="$f"
				break
			fi
		done

		if [[ -z "$content_file" ]]; then
			# Try any file that isn't meta.json
			for f in "${source_dir}"/*; do
				[[ -f "$f" ]] || continue
				[[ "$(basename "$f")" == "meta.json" ]] && continue
				content_file="$f"
				break
			done
		fi

		if [[ -n "$content_file" ]]; then
			count=$((count + 1))
			# Take first ~2000 chars as excerpt
			local excerpt
			excerpt="$(head -c 2000 "$content_file" 2>/dev/null)" || excerpt="(unable to read)"
			excerpts="${excerpts}[${source_id}]: \"${excerpt}\"

"
		fi
	done <<<"$source_ids_str"

	if [[ -z "$excerpts" ]]; then
		echo "(no source excerpts available)"
	else
		printf '%s' "$excerpts"
	fi
	return 0
}

# _build_provenance_footer <sources-json> <repo-path> <model> <timestamp>
# Returns the provenance footer block.
_build_provenance_footer() {
	local sources_json="$1" repo_path="$2" model="$3" timestamp="$4"
	local cross_case_ids="${5:-}"

	local footer="---

**Drafted with reference to:**
"
	local source_ids
	source_ids="$(echo "$sources_json" | jq -r '.[].id' 2>/dev/null)" || true

	local source_id
	while IFS= read -r source_id; do
		[[ -z "$source_id" ]] && continue
		local meta_path="${repo_path}/${KNOWLEDGE_SOURCES_DIR}/${source_id}/${SOURCE_META_FILE}"
		local kind="$_UNKNOWN" sensitivity="$_UNKNOWN" sha="$_UNKNOWN"
		if [[ -f "$meta_path" ]]; then
			kind="$(jq -r --arg fb "$_UNKNOWN" '.kind // $fb' "$meta_path" 2>/dev/null)" || kind="$_UNKNOWN"
			sensitivity="$(jq -r --arg fb "$_UNKNOWN" '.sensitivity // $fb' "$meta_path" 2>/dev/null)" || sensitivity="$_UNKNOWN"
			sha="$(jq -r --arg fb "$_UNKNOWN" '.sha256 // $fb' "$meta_path" 2>/dev/null)" || sha="$_UNKNOWN"
			# Truncate sha for readability
			[[ ${#sha} -gt 12 ]] && sha="${sha:0:12}..."
		fi
		footer="${footer}- ${source_id} (kind: ${kind}, sensitivity: ${sensitivity}, sha: ${sha})
"
	done <<<"$source_ids"

	# Add cross-case sources if present
	if [[ -n "$cross_case_ids" ]]; then
		footer="${footer}
**Cross-case sources included from:** ${cross_case_ids}
"
	fi

	# Get aidevops version
	local version="$_UNKNOWN"
	local version_file="${SCRIPT_DIR}/../VERSION"
	[[ -f "$version_file" ]] && version="$(cat "$version_file" 2>/dev/null)" || true

	footer="${footer}
**Generated by:** aidevops v${version}, model: ${model}, at: ${timestamp}
"

	printf '%s' "$footer"
	return 0
}

# _log_cross_case_access <case-dir> <included-case-id> <actor> [reason]
_log_cross_case_access() {
	local case_dir="$1" included_case="$2" actor="$3" reason="${4:-}"
	local log_dir="${case_dir}/${CASE_COMMS_DIR}"
	local log_file="${log_dir}/${CROSS_CASE_ACCESS_LOG}"
	local ts
	ts="$(_iso_ts)"

	mkdir -p "$log_dir"
	local entry
	entry="$(jq -cn \
		--arg at "$ts" \
		--arg inc "$included_case" \
		--arg by "$actor" \
		--arg reason "$reason" \
		'{at:$at, included_case:$inc, included_by:$by, reason:$reason}')"
	echo "$entry" >>"$log_file"
	return 0
}

# _compose_prompt <case-id> <intent> <tone-fragment> <length-guidance>
#   <kind> <party-self> <timeline-text> <excerpts> <cite-mode>
# Uses the prompt template if available, else inline composition.
_compose_prompt() {
	local case_id="$1" intent="$2" tone_fragment="$3" length_guidance="$4"
	local kind="$5" party_self="$6" timeline_text="$7" excerpts="$8"
	local cite_mode="${9:-strict}"

	local cite_instruction="Cite every factual claim with [source-id] anchors."
	if [[ "$cite_mode" == "loose" ]]; then
		cite_instruction="Cite key claims with [source-id] anchors where the source is clear."
	fi

	if [[ -f "$PROMPT_TEMPLATE" ]]; then
		local template
		template="$(cat "$PROMPT_TEMPLATE")"
		# Substitute placeholders
		template="${template//\{tone\}/$tone_fragment}"
		template="${template//\{kind\}/$kind}"
		template="${template//\{case-id\}/$case_id}"
		template="${template//\{party-self\}/$party_self}"
		template="${template//\{intent\}/$intent}"
		template="${template//\{timeline\}/$timeline_text}"
		template="${template//\{excerpts\}/$excerpts}"
		template="${template//\{length\}/$length_guidance}"
		template="${template//\{cite-instruction\}/$cite_instruction}"
		printf '%s\n' "$template"
	else
		# Inline fallback
		cat <<PROMPT
You are drafting a ${tone_fragment} ${kind} communication for case ${case_id} on behalf of ${party_self}.

The intent is: ${intent}.

Recent case timeline:
${timeline_text}

Available evidence:
${excerpts}

Produce a draft that:
- ${cite_instruction}
- Stays ${tone_fragment}; avoids speculation beyond the evidence
- Length: ${length_guidance}

At the end, list "Drafted with reference to:" with each consulted source.
PROMPT
	fi
	return 0
}

# =============================================================================
# Extracted helpers for complexity compliance (<100 lines per function)
# =============================================================================

# _validate_tone <tone> <repo-path> — returns 0 if valid, 1 if not
_validate_tone() {
	local tone="$1" repo_path="$2"
	case "$tone" in
	neutral | formal | conciliatory | firm) return 0 ;;
	esac
	local tones_config
	tones_config="$(_load_tones_config "$repo_path")"
	if [[ -n "$tones_config" ]]; then
		local valid
		valid="$(jq -r --arg t "$tone" '.tones | has($t)' "$tones_config" 2>/dev/null)" || valid="false"
		[[ "$valid" == "$_TRUE" ]] && return 0
		print_error "Unknown tone: ${tone}. Available: neutral, formal, conciliatory, firm (or custom)"
	else
		print_error "Unknown tone: ${tone}. Available: neutral, formal, conciliatory, firm"
	fi
	return 1
}

# _call_llm_route <tier> <prompt-text> <max-tokens> — echoes response + model_used (tab-sep)
# Uses LLM_ROUTING_DRY_RUN for testing.
_call_llm_route() {
	local tier="$1" prompt_text="$2" max_tokens="$3"
	local prompt_file response model_used

	prompt_file="$(mktemp)"
	printf '%s\n' "$prompt_text" >"$prompt_file"

	if [[ "${LLM_ROUTING_DRY_RUN:-0}" == "1" ]]; then
		response="[MOCK] Draft content for tier=${tier}."
		model_used="dry-run-mock"
	else
		local routing_helper="${SCRIPT_DIR}/llm-routing-helper.sh"
		response="$(bash "$routing_helper" route \
			--tier "$tier" --task "$_TASK_DRAFT" \
			--prompt-file "$prompt_file" --max-tokens "$max_tokens" 2>/dev/null)" || {
			print_error "LLM routing failed. Tier: ${tier}"
			rm -f "$prompt_file"
			return 1
		}
		model_used="${tier}-default"
	fi
	rm -f "$prompt_file"
	# Output on two lines: line 1=model_used, rest=response
	printf '%s\n%s' "$model_used" "$response"
	return 0
}

# _build_draft_body <frontmatter> <response> <provenance> — compose full markdown
# Pipes <response> through markdoc-render-gh.sh (--annotate) before composing
# so that raw Markdoc tag syntax never appears in the GH comment output.
_build_draft_body() {
	local frontmatter="$1" response="$2" provenance="$3"
	local _render_sh="${SCRIPT_DIR}/markdoc-render-gh.sh"
	local rendered_response
	if [[ -x "$_render_sh" ]]; then
		rendered_response="$(printf '%s' "$response" | "$_render_sh" render - --annotate 2>/dev/null)" \
			|| rendered_response="$response"
	else
		rendered_response="$response"
	fi
	printf '%s\n\n%s\n\n%s\n' "$frontmatter" "$rendered_response" "$provenance"
	return 0
}

# _output_draft_json <args...> — emit JSON for draft result
_output_draft_json() {
	local case_id="$1" intent="$2" tone="$3" length="$4" model="$5"
	local tier="$6" ts="$7" file_or_body="$8" sources="$9"
	shift 9
	local cross_cases="${1:-none}" is_dry_run="${2:-false}"
	if [[ "$is_dry_run" == "$_TRUE" ]]; then
		jq -n --arg cid "$case_id" --arg i "$intent" --arg t "$tone" \
			--arg l "$length" --arg m "$model" --arg tr "$tier" \
			--arg g "$ts" --arg b "$file_or_body" --arg s "$sources" \
			--arg cc "$cross_cases" \
			'{case_id:$cid, intent:$i, tone:$t, length:$l, model:$m,
			  tier:$tr, generated_at:$g, sources_consulted:$s,
			  cross_case_includes:$cc, body:$b, dry_run:true}'
	else
		jq -n --arg cid "$case_id" --arg i "$intent" --arg t "$tone" \
			--arg l "$length" --arg m "$model" --arg tr "$tier" \
			--arg g "$ts" --arg f "$file_or_body" --arg s "$sources" \
			--arg cc "$cross_cases" \
			'{case_id:$cid, intent:$i, tone:$t, length:$l, model:$m,
			  tier:$tr, generated_at:$g, file:$f, sources_consulted:$s,
			  cross_case_includes:$cc, dry_run:false}'
	fi
	return 0
}

# _merge_cross_case_sources <cases-dir> <case-dir> <intent> <include-ids...>
# Echoes: line 1=cross_case_ids, line 2=merged sources JSON
_merge_cross_case_sources() {
	local cases_dir="$1" case_dir="$2" intent="$3"
	shift 3
	local cross_case_ids="" sources_json="$1"
	shift
	local include_id
	for include_id in "$@"; do
		[[ -z "$include_id" ]] && continue
		local inc_dir
		inc_dir="$(_case_find "$cases_dir" "$include_id")" || {
			print_error "Include-case not found: ${include_id}"
			return 1
		}
		local actor
		actor="$(_current_actor)"
		_log_cross_case_access "$case_dir" "$include_id" "$actor" "Draft intent: ${intent}"
		_timeline_append "$case_dir" "cross-case-access" "$actor" \
			"Cross-case access: included ${include_id} for draft" "$include_id"
		local inc_sources_path="${inc_dir}/${CASE_SOURCES_FILE}"
		if [[ -f "$inc_sources_path" ]]; then
			local inc_sources
			inc_sources="$(jq '.' "$inc_sources_path" 2>/dev/null)" || inc_sources="[]"
			sources_json="$(echo "$sources_json" | jq --argjson inc "$inc_sources" '. + $inc')"
		fi
		[[ -n "$cross_case_ids" ]] && cross_case_ids="${cross_case_ids}, "
		cross_case_ids="${cross_case_ids}${include_id}"
	done
	printf '%s\n%s' "$cross_case_ids" "$sources_json"
	return 0
}

# _read_case_dossier <case-dir> — reads dossier, echoes: id\nkind\nparty_self
_read_case_dossier() {
	local case_dir="$1"
	local dossier_path="${case_dir}/${CASE_DOSSIER_FILE}"
	[[ ! -f "$dossier_path" ]] && { print_error "Dossier not found: ${dossier_path}"; return 1; }
	local dossier
	dossier="$(jq '.' "$dossier_path")"
	echo "$dossier" | jq -r '.id'
	echo "$dossier" | jq -r '.kind'
	echo "$dossier" | jq -r '(.parties[] | select(.role == "client") | .name) // (.parties[0].name) // "the client"'
	return 0
}

# _read_case_sources <case-dir> — echo sources JSON
_read_case_sources() {
	local case_dir="$1"
	local sources_path="${case_dir}/${CASE_SOURCES_FILE}"
	if [[ -f "$sources_path" ]]; then
		jq '.' "$sources_path" 2>/dev/null || echo "[]"
	else
		echo "[]"
	fi
	return 0
}

# _build_frontmatter <case-id> <intent> <tone> <length> <model> <ts> <sources> <cross>
_build_frontmatter() {
	local _cid="$1" _int="$2" _ton="$3" _len="$4" _mod="$5" _ts="$6" _src="$7" _cc="$8"
	printf -- '---\ncase_id: %s\nintent: "%s"\ntone: %s\nlength: %s\nmodel: %s\ngenerated_at: %s\nsources_consulted: "%s"\ncross_case_includes: "%s"\n---' \
		"$_cid" "$_int" "$_ton" "$_len" "$_mod" "$_ts" "$_src" "$_cc"
	return 0
}

# =============================================================================
# cmd_draft — generate a strategic communication draft
# =============================================================================

cmd_draft() {
	_require_jq || return 1
	local case_id="" intent="" tone="neutral" length="medium" cite="strict"
	local repo_path="" dry_run=false json_mode=false max_tokens_override=""
	local -a include_cases=()
	while [[ $# -gt 0 ]]; do
		local _cur="${1:-}" _nxt="${2:-}"
		case "$_cur" in
		--intent) intent="$_nxt"; shift 2 ;; --tone) tone="$_nxt"; shift 2 ;;
		--length) length="$_nxt"; shift 2 ;; --cite) cite="$_nxt"; shift 2 ;;
		--include-case) include_cases+=("$_nxt"); shift 2 ;;
		--dry-run) dry_run=true; shift ;; --repo) repo_path="$_nxt"; shift 2 ;;
		--max-tokens) max_tokens_override="$_nxt"; shift 2 ;;
		--json) json_mode=true; shift ;; -*) print_error "Unknown option: $_cur"; return 1 ;;
		*) case_id="$_cur"; shift ;; esac
	done
	[[ -z "$case_id" ]] && { _err_missing_arg "case-id"; return 1; }
	[[ -z "$intent" ]] && { _err_missing_arg "--intent"; return 1; }
	[[ -z "$repo_path" ]] && repo_path="$(pwd)"
	_validate_tone "$tone" "$repo_path" || return 1
	case "$length" in short|medium|long) ;; *) print_error "Unknown length: ${length}"; return 1;; esac

	local cases_dir case_dir
	cases_dir="$(_resolve_cases_dir "$repo_path")"
	case_dir="$(_case_find "$cases_dir" "$case_id")" || { _err_case_not_found "$case_id"; return 1; }

	local dossier_info full_case_id kind party_self
	dossier_info="$(_read_case_dossier "$case_dir")" || return 1
	full_case_id="$(echo "$dossier_info" | sed -n '1p')"
	kind="$(echo "$dossier_info" | sed -n '2p')"
	party_self="$(echo "$dossier_info" | sed -n '3p')"

	local sources_json cross_case_ids=""
	sources_json="$(_read_case_sources "$case_dir")"
	if [[ ${#include_cases[@]} -gt 0 ]]; then
		local merged
		merged="$(_merge_cross_case_sources "$cases_dir" "$case_dir" "$intent" \
			"$sources_json" "${include_cases[@]}")" || return 1
		cross_case_ids="$(echo "$merged" | head -1)"
		sources_json="$(echo "$merged" | tail -n +2)"
	fi

	local tier source_ids excerpts timeline_text tones_config tone_fragment length_guidance
	tier="$(_max_tier "$sources_json" "$repo_path")"
	source_ids="$(echo "$sources_json" | jq -r '.[].id' 2>/dev/null)" || source_ids=""
	# Retrieve excerpts with case-scoped RAG (t2977 Phase 6): automatically
	# scopes corpus retrieval to case-relevant sources via knowledge search.
	excerpts="$(_collect_excerpts_for_draft "$case_id" "$intent" "$source_ids" "$repo_path" 8)"
	timeline_text="$(_read_timeline_recent "$case_dir" 5)"
	tones_config="$(_load_tones_config "$repo_path")"
	tone_fragment="$(_get_tone_fragment "$tones_config" "$tone")"
	length_guidance="$(_length_to_word_range "$length")"

	local prompt max_tokens
	prompt="$(_compose_prompt "$full_case_id" "$intent" "$tone_fragment" \
		"$length_guidance" "$kind" "$party_self" "$timeline_text" "$excerpts" "$cite")"
	max_tokens="${max_tokens_override:-$(_length_to_tokens "$length")}"
	log_info "Routing draft via tier: ${tier}, tone: ${tone}, length: ${length}"

	local llm_result response model_used
	llm_result="$(_call_llm_route "$tier" "$prompt" "$max_tokens")" || return 1
	model_used="$(echo "$llm_result" | head -1)"
	response="$(echo "$llm_result" | tail -n +2)"

	local timestamp provenance intent_slug ts_filename source_list cross_list frontmatter full_draft
	timestamp="$(_iso_ts)"
	provenance="$(_build_provenance_footer "$sources_json" "$repo_path" "$model_used" "$timestamp" "$cross_case_ids")"
	intent_slug="$(_slugify "$intent")"
	ts_filename="$(_iso_ts_filename)"
	source_list="$(echo "$sources_json" | jq -r '[.[].id] | join(", ")' 2>/dev/null)" || source_list=""
	cross_list="${cross_case_ids:-none}"
	frontmatter="$(_build_frontmatter "$full_case_id" "$intent" "$tone" "$length" "$model_used" "$timestamp" "$source_list" "$cross_list")"
	full_draft="$(_build_draft_body "$frontmatter" "$response" "$provenance")"

	if [[ "$dry_run" == true ]]; then
		if [[ "$json_mode" == true ]]; then
			_output_draft_json "$full_case_id" "$intent" "$tone" "$length" "$model_used" "$tier" "$timestamp" "$full_draft" "$source_list" "$cross_list" "$_TRUE"
		else printf '%s\n' "$full_draft"; fi
		return 0
	fi
	local drafts_dir="${case_dir}/${CASE_DRAFTS_DIR}"
	mkdir -p "$drafts_dir"
	local draft_file="${drafts_dir}/${ts_filename}-${intent_slug}.md"
	printf '%s\n' "$full_draft" >"$draft_file"
	local actor; actor="$(_current_actor)"
	_timeline_append "$case_dir" "$_TASK_DRAFT" "$actor" \
		"Draft generated: ${intent} (tone: ${tone}, tier: ${tier})" "${CASE_DRAFTS_DIR}/${ts_filename}-${intent_slug}.md"
	if [[ "$json_mode" == true ]]; then
		_output_draft_json "$full_case_id" "$intent" "$tone" "$length" "$model_used" "$tier" "$timestamp" "$draft_file" "$source_list" "$cross_list" "false"
	else
		print_success "Draft generated: ${draft_file}"
		echo "  Case: ${full_case_id}  Intent: ${intent}  Tone: ${tone}  Tier: ${tier}"
	fi
	return 0
}

# =============================================================================
# cmd_revise — revise an existing draft with feedback
# =============================================================================

cmd_revise() {
	_require_jq || return 1
	local draft_file="" feedback="" repo_path="" dry_run=false json_mode=false max_tokens_override=""
	while [[ $# -gt 0 ]]; do
		local _cur="${1:-}" _nxt="${2:-}"
		case "$_cur" in
		--revise) draft_file="$_nxt"; shift 2 ;; --feedback) feedback="$_nxt"; shift 2 ;;
		--repo) repo_path="$_nxt"; shift 2 ;; --dry-run) dry_run=true; shift ;;
		--max-tokens) max_tokens_override="$_nxt"; shift 2 ;; --json) json_mode=true; shift ;;
		-*) print_error "Unknown option: $_cur"; return 1 ;;
		*) [[ -z "$draft_file" ]] && draft_file="$_cur" || true; shift ;; esac
	done
	[[ -z "$draft_file" ]] && { _err_missing_arg "--revise <file>"; return 1; }
	[[ -z "$feedback" ]] && { _err_missing_arg "--feedback"; return 1; }
	[[ -z "$repo_path" ]] && repo_path="$(pwd)"
	[[ ! -f "$draft_file" ]] && { print_error "Draft file not found: ${draft_file}"; return 1; }

	# Extract metadata from frontmatter
	local existing_draft case_id intent tone length
	existing_draft="$(cat "$draft_file")"
	case_id="$(echo "$existing_draft" | sed -n 's/^case_id: //p' | head -1)" || case_id=""
	intent="$(echo "$existing_draft" | sed -n 's/^intent: //p' | head -1 | tr -d '"')" || intent=""
	tone="$(echo "$existing_draft" | sed -n 's/^tone: //p' | head -1)" || tone="neutral"
	length="$(echo "$existing_draft" | sed -n 's/^length: //p' | head -1)" || length="medium"
	[[ -z "$case_id" ]] && { print_error "Cannot extract case_id from draft frontmatter"; return 1; }

	local cases_dir case_dir
	cases_dir="$(_resolve_cases_dir "$repo_path")"
	case_dir="$(_case_find "$cases_dir" "$case_id")" || { _err_case_not_found "$case_id"; return 1; }
	local sources_json
	sources_json="$(_read_case_sources "$case_dir")"
	local tier; tier="$(_max_tier "$sources_json" "$repo_path")"

	local draft_body
	draft_body="$(echo "$existing_draft" | sed -n '/^---$/,/^---$/!p')"
	draft_body="$(echo "$draft_body" | sed '/./,$!d')"

	local revision_prompt="Revise this draft per the following feedback.

Feedback: ${feedback}

Original draft:
${draft_body}

Preserve citation anchors [source-id]. Apply feedback maintaining factual accuracy. Output revised draft text only."

	local max_tokens="${max_tokens_override:-$(_length_to_tokens "$length")}"
	local llm_result response model_used
	llm_result="$(_call_llm_route "$tier" "$revision_prompt" "$max_tokens")" || return 1
	model_used="$(echo "$llm_result" | head -1)"; response="$(echo "$llm_result" | tail -n +2)"

	local timestamp provenance intent_slug ts_filename source_list
	timestamp="$(_iso_ts)"; intent_slug="$(_slugify "$intent")"; ts_filename="$(_iso_ts_filename)"
	provenance="$(_build_provenance_footer "$sources_json" "$repo_path" "$model_used" "$timestamp" "")"
	local rev_count=2 existing_revs
	existing_revs="$(find "$(dirname "$draft_file")" -name "*-${intent_slug}-rev*" 2>/dev/null | wc -l | tr -d ' ')" || existing_revs=0
	rev_count=$((existing_revs + 2))
	source_list="$(echo "$sources_json" | jq -r '[.[].id] | join(", ")' 2>/dev/null)" || source_list=""
	local draft_basename; draft_basename="$(basename "$draft_file")"
	local frontmatter
	frontmatter="---
case_id: ${case_id}
intent: \"${intent}\"
tone: ${tone}
length: ${length}
model: ${model_used}
generated_at: ${timestamp}
sources_consulted: \"${source_list}\"
cross_case_includes: \"none\"
revision: ${rev_count}
revision_of: \"${draft_basename}\"
feedback: \"${feedback}\"
---"
	local full_revision; full_revision="$(_build_draft_body "$frontmatter" "$response" "$provenance")"

	if [[ "$dry_run" == true ]]; then
		if [[ "$json_mode" == true ]]; then
			jq -n --arg cid "$case_id" --arg fb "$feedback" --arg rev "$rev_count" --arg body "$full_revision" \
				'{case_id:$cid, feedback:$fb, revision:($rev|tonumber), body:$body, dry_run:true}'
		else printf '%s\n' "$full_revision"; fi
		return 0
	fi
	local rev_file; rev_file="$(dirname "$draft_file")/${ts_filename}-${intent_slug}-rev${rev_count}.md"
	printf '%s\n' "$full_revision" >"$rev_file"
	local actor; actor="$(_current_actor)"
	_timeline_append "$case_dir" "draft-revision" "$actor" \
		"Draft revised (rev${rev_count}): ${intent}. Feedback: ${feedback}" "${CASE_DRAFTS_DIR}/$(basename "$rev_file")"
	if [[ "$json_mode" == true ]]; then
		jq -n --arg cid "$case_id" --arg fb "$feedback" --arg rev "$rev_count" --arg f "$rev_file" --arg orig "$draft_basename" \
			'{case_id:$cid, feedback:$fb, revision:($rev|tonumber), file:$f, original:$orig, dry_run:false}'
	else
		print_success "Revision generated: ${rev_file}"
		echo "  Case: ${case_id}  Revision: rev${rev_count}  Original: ${draft_basename}"
	fi
	return 0
}

# =============================================================================
# cmd_help
# =============================================================================

cmd_help() {
	cat <<'HELP'
Case Draft Helper — AI-assisted strategic communication drafting with RAG

Usage:
  case-draft-helper.sh draft <case-id> --intent "..." [options]
  case-draft-helper.sh revise --revise <file> --feedback "..." [options]
  case-draft-helper.sh help

Draft options:
  --intent <text>         Intent / purpose of the draft (REQUIRED)
  --tone <preset>         neutral | formal | conciliatory | firm (default: neutral)
  --length <size>         short | medium | long (default: medium)
  --cite <mode>           strict | loose (default: strict)
  --include-case <id>     Include another case's sources (audited, repeatable)
  --dry-run               Print draft to stdout, don't write file
  --repo <path>           Target repo path (default: cwd)
  --max-tokens <N>        Override max tokens for LLM call
  --json                  Machine-readable JSON output

Revise options:
  --revise <file>         Path to existing draft to revise
  --feedback <text>       Revision instructions (REQUIRED)
  --dry-run               Print revision to stdout, don't write file

Drafts are ALWAYS human-gated — they write to _cases/<id>/drafts/ and never
auto-send. Review every draft before use.

Sensitivity routing:
  - Sources with sensitivity=restricted → privileged tier (local LLM only)
  - Sources with sensitivity=confidential → sensitive tier (local LLM only)
  - The highest sensitivity among all attached sources determines the tier

RAG retrieval (t2977 Phase 6):
  - Drafts automatically scope corpus retrieval to case-relevant sources via
    knowledge-helper.sh search --case <case-id>. This uses intent as the search
    query for ranked, case-scoped excerpts. Falls back to direct file reads.

Cross-case access:
  - Default: only own case's sources
  - --include-case <id>: audited in comms/cross-case-access.jsonl

Examples:
  case-draft-helper.sh draft case-2026-0001-acme --intent "request payment"
  case-draft-helper.sh draft case-2026-0001-acme --intent "settlement offer" \
      --tone formal --length long --cite strict
  case-draft-helper.sh draft case-2026-0001-acme --intent "status update" \
      --include-case case-2026-0002-related --dry-run
  case-draft-helper.sh revise --revise _cases/.../drafts/20260427-draft.md \
      --feedback "soften the language around paragraph 3"
HELP
	return 0
}

# =============================================================================
# Main
# =============================================================================

main() {
	local command="${1:-help}"
	shift || true

	case "$command" in
	draft) cmd_draft "$@" ;;
	revise) cmd_revise "$@" ;;
	help | --help | -h) cmd_help ;;
	*)
		print_error "Unknown command: ${command}"
		cmd_help
		return 1
		;;
	esac
}

main "$@"
