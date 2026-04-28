#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# =============================================================================
# Compare Models — Provider Discovery & Scoring Library
# =============================================================================
# Provider API key detection, probing, model discovery, and the comparison
# scoring framework (SQLite-backed cross-session model comparison results).
#
# Usage: source "${SCRIPT_DIR}/compare-models-scoring-lib.sh"
#
# Dependencies:
#   - shared-constants.sh (print_error, print_warning, print_success)
#   - Orchestrator globals: MODEL_DATA, get_field, format_context, model_id_to_tier, find_model
#
# Part of aidevops framework: https://aidevops.sh

# Apply strict mode only when executed directly (not when sourced)
[[ "${BASH_SOURCE[0]}" == "${0}" ]] && set -euo pipefail

# Include guard
[[ -n "${_COMPARE_MODELS_SCORING_LIB_LOADED:-}" ]] && return 0
_COMPARE_MODELS_SCORING_LIB_LOADED=1

# Defensive SCRIPT_DIR fallback
if [[ -z "${SCRIPT_DIR:-}" ]]; then
	_lib_path="${BASH_SOURCE[0]%/*}"
	[[ "$_lib_path" == "${BASH_SOURCE[0]}" ]] && _lib_path="."
	SCRIPT_DIR="$(cd "$_lib_path" && pwd)"
	unset _lib_path
fi

readonly PROVIDER_ENV_KEYS="Anthropic|ANTHROPIC_API_KEY
OpenAI|OPENAI_API_KEY
Google|GOOGLE_API_KEY,GEMINI_API_KEY
OpenRouter|OPENROUTER_API_KEY
Groq|GROQ_API_KEY
DeepSeek|DEEPSEEK_API_KEY
Together|TOGETHER_API_KEY
Fireworks|FIREWORKS_API_KEY"

# Check if a provider API key is available from any source
# Returns 0 if found, 1 if not. Sets FOUND_SOURCE to the source name.
# Usage: check_provider_key "ANTHROPIC_API_KEY"
check_provider_key() {
	local key_name="$1"
	FOUND_SOURCE=""

	# 1. Check environment variable
	if [[ -n "${!key_name:-}" ]]; then
		FOUND_SOURCE="env"
		return 0
	fi

	# 2. Check gopass (encrypted secrets)
	if command -v gopass &>/dev/null && gopass ls "aidevops/${key_name}" &>/dev/null 2>&1; then
		FOUND_SOURCE="gopass"
		return 0
	fi

	# 3. Check credentials.sh (plaintext fallback)
	local creds_file="${HOME}/.config/aidevops/credentials.sh"
	if [[ -f "$creds_file" ]] &&
		(grep -q "^export ${key_name}=" "$creds_file" 2>/dev/null ||
			grep -q "^${key_name}=" "$creds_file" 2>/dev/null); then
		FOUND_SOURCE="credentials.sh"
		return 0
	fi

	return 1
}

# Probe a provider API to verify the key works
# Returns 0 if API responds successfully, 1 otherwise
# Usage: probe_provider "Anthropic" "ANTHROPIC_API_KEY"
probe_provider() {
	local provider="$1"
	local key_name="$2"

	# Get the key value from the appropriate source
	local key_value=""
	if [[ -n "${!key_name:-}" ]]; then
		key_value="${!key_name}"
	elif command -v gopass &>/dev/null && gopass ls "aidevops/${key_name}" &>/dev/null 2>&1; then
		key_value=$(gopass show "aidevops/${key_name}" 2>/dev/null) || return 1
	else
		return 1
	fi

	[[ -z "$key_value" ]] && return 1

	local http_code=""
	case "$provider" in
	Anthropic)
		http_code=$(curl -s -o /dev/null -w "%{http_code}" \
			-H "x-api-key: ${key_value}" \
			-H "anthropic-version: 2023-06-01" \
			"https://api.anthropic.com/v1/models" 2>/dev/null) || return 1
		;;
	OpenAI)
		http_code=$(curl -s -o /dev/null -w "%{http_code}" \
			-H "Authorization: Bearer ${key_value}" \
			"https://api.openai.com/v1/models" 2>/dev/null) || return 1
		;;
	Google)
		http_code=$(curl -s -o /dev/null -w "%{http_code}" \
			"https://generativelanguage.googleapis.com/v1beta/models?key=${key_value}" 2>/dev/null) || return 1
		;;
	OpenRouter)
		http_code=$(curl -s -o /dev/null -w "%{http_code}" \
			-H "Authorization: Bearer ${key_value}" \
			"https://openrouter.ai/api/v1/models" 2>/dev/null) || return 1
		;;
	Groq)
		http_code=$(curl -s -o /dev/null -w "%{http_code}" \
			-H "Authorization: Bearer ${key_value}" \
			"https://api.groq.com/openai/v1/models" 2>/dev/null) || return 1
		;;
	DeepSeek)
		http_code=$(curl -s -o /dev/null -w "%{http_code}" \
			-H "Authorization: Bearer ${key_value}" \
			"https://api.deepseek.com/v1/models" 2>/dev/null) || return 1
		;;
	*)
		return 1
		;;
	esac

	[[ "$http_code" == "200" ]] && return 0
	return 1
}

# List models available from a provider API
# Outputs model IDs, one per line
# Usage: list_provider_models "Anthropic" "ANTHROPIC_API_KEY"
list_provider_models() {
	local provider="$1"
	local key_name="$2"

	local key_value=""
	if [[ -n "${!key_name:-}" ]]; then
		key_value="${!key_name}"
	elif command -v gopass &>/dev/null && gopass ls "aidevops/${key_name}" &>/dev/null 2>&1; then
		key_value=$(gopass show "aidevops/${key_name}" 2>/dev/null) || return 1
	else
		return 1
	fi

	[[ -z "$key_value" ]] && return 1

	case "$provider" in
	Anthropic)
		curl -s -H "x-api-key: ${key_value}" \
			-H "anthropic-version: 2023-06-01" \
			"https://api.anthropic.com/v1/models" 2>/dev/null |
			jq -r '.data[].id // empty' 2>/dev/null | sort
		;;
	OpenAI)
		curl -s -H "Authorization: Bearer ${key_value}" \
			"https://api.openai.com/v1/models" 2>/dev/null |
			jq -r '.data[].id // empty' 2>/dev/null | sort
		;;
	Google)
		curl -s "https://generativelanguage.googleapis.com/v1beta/models?key=${key_value}" 2>/dev/null |
			jq -r '.models[].name // empty' 2>/dev/null | sed 's|^models/||' | sort
		;;
	OpenRouter)
		curl -s -H "Authorization: Bearer ${key_value}" \
			"https://openrouter.ai/api/v1/models" 2>/dev/null |
			jq -r '.data[].id // empty' 2>/dev/null | sort
		;;
	Groq)
		curl -s -H "Authorization: Bearer ${key_value}" \
			"https://api.groq.com/openai/v1/models" 2>/dev/null |
			jq -r '.data[].id // empty' 2>/dev/null | sort
		;;
	*)
		return 1
		;;
	esac
	return 0
}

# Check if a provider is available (has valid API key)
_discover_check_provider() {
	local provider="$1"
	local _found_var="$2"
	local _source_var="$3"
	local _active_key_var="$4"

	# Bash 3.2 compatible: use printf -v for indirect scalar writes (no local -n namerefs)
	printf -v "$_found_var" '%s' "false"
	printf -v "$_source_var" '%s' ""
	printf -v "$_active_key_var" '%s' ""

	local key_names
	key_names=$(echo "$PROVIDER_ENV_KEYS" | grep "^${provider}|" | cut -d'|' -f2)
	[[ -z "$key_names" ]] && return 1

	local -a keys
	IFS=',' read -ra keys <<<"$key_names"
	for key_name in "${keys[@]}"; do
		if check_provider_key "$key_name"; then
			printf -v "$_found_var" '%s' "true"
			printf -v "$_source_var" '%s' "$FOUND_SOURCE"
			printf -v "$_active_key_var" '%s' "$key_name"
			return 0
		fi
	done
	return 1
}

# Scan all providers and print/collect status.
# Args: arg1=probe_flag arg2=list_flag arg3=json_flag
# Outputs: "total|available|models" on last line for caller to parse.
_discover_scan_providers() {
	local probe_flag="$1"
	local list_flag="$2"
	local json_flag="$3"

	local total_providers=0
	local available_providers=0
	local available_models=0
	local -a json_entries=()

	while IFS= read -r line; do
		local provider
		provider=$(echo "$line" | cut -d'|' -f1)
		total_providers=$((total_providers + 1))
		local found=false source="" active_key=""
		_discover_check_provider "$provider" found source active_key

		if [[ "$found" == "true" ]]; then
			available_providers=$((available_providers + 1))
			local status="configured" status_icon="Y"
			if [[ "$probe_flag" == "true" ]]; then
				if probe_provider "$provider" "$active_key"; then
					status="verified"
					status_icon="V"
				else
					status="key-invalid"
					status_icon="!"
				fi
			fi
			local model_count
			model_count=$(echo "$MODEL_DATA" | grep -c "|${provider}|" || true)
			available_models=$((available_models + model_count))
			if [[ "$json_flag" == "true" ]]; then
				json_entries+=("{\"provider\":\"${provider}\",\"status\":\"${status}\",\"source\":\"${source}\",\"models\":${model_count}}")
			else
				printf "  %s %-12s  %-12s  (source: %s, %d tracked models)\n" \
					"$status_icon" "$provider" "$status" "$source" "$model_count"
			fi
			if [[ "$list_flag" == "true" && "$status" == "verified" ]]; then
				local live_models
				live_models=$(list_provider_models "$provider" "$active_key" 2>/dev/null)
				if [[ -n "$live_models" ]]; then
					local live_count
					live_count=$(echo "$live_models" | wc -l | tr -d ' ')
					echo "    Live models ($live_count):"
					echo "$live_models" | head -20 | while IFS= read -r m; do
						echo "      - $m"
					done
					local remaining=$((live_count - 20))
					[[ "$remaining" -gt 0 ]] && echo "      ... and $remaining more"
				fi
			fi
		else
			if [[ "$json_flag" == "true" ]]; then
				json_entries+=("{\"provider\":\"${provider}\",\"status\":\"not-configured\",\"source\":null,\"models\":0}")
			else
				printf "  - %-12s  not configured\n" "$provider"
			fi
		fi
	done <<<"$PROVIDER_ENV_KEYS"

	if [[ "$json_flag" == "true" ]]; then
		echo "[$(
			IFS=,
			echo "${json_entries[*]}"
		)]"
	fi
	echo "counts=${total_providers}|${available_providers}|${available_models}"
	return 0
}

cmd_discover() {
	local probe_flag=false list_flag=false json_flag=false

	while [[ $# -gt 0 ]]; do
		case "$1" in
		--probe)
			probe_flag=true
			shift
			;;
		--list-models)
			list_flag=true
			probe_flag=true
			shift
			;;
		--json)
			json_flag=true
			shift
			;;
		*) shift ;;
		esac
	done

	echo ""
	echo "Model Provider Discovery"
	echo "========================"
	echo ""

	local scan_output counts_line
	scan_output=$(_discover_scan_providers "$probe_flag" "$list_flag" "$json_flag")
	counts_line=$(echo "$scan_output" | grep '^counts=')
	echo "$scan_output" | grep -v '^counts='

	if [[ "$json_flag" != "true" ]]; then
		local total_providers available_providers available_models
		IFS='|' read -r total_providers available_providers available_models \
			<<<"${counts_line#counts=}"
		echo ""
		echo "Summary: $available_providers/$total_providers providers configured, $available_models tracked models available"
		echo ""
		if [[ "$probe_flag" != "true" ]]; then
			echo "Tip: Use --probe to verify API keys are valid"
			echo "     Use --list-models to enumerate live models from each provider"
		fi
		_discover_print_available_models
		_discover_print_unavailable_models
	fi

	echo ""
	return 0
}

# Print table of models from configured providers.
_discover_print_available_models() {
	echo ""
	echo "Available Models (from configured providers):"
	echo ""
	printf "  %-22s %-10s %-8s %-12s %-12s %-7s\n" \
		"Model" "Provider" "Context" "Input/1M" "Output/1M" "Tier"
	printf "  %-22s %-10s %-8s %-12s %-12s %-7s\n" \
		"-----" "--------" "-------" "--------" "---------" "----"

	echo "$MODEL_DATA" | while IFS= read -r model_line; do
		local model_provider
		model_provider=$(get_field "$model_line" 2)
		local provider_available=false dummy1 dummy2
		_discover_check_provider "$model_provider" provider_available dummy1 dummy2
		if [[ "$provider_available" == "true" ]]; then
			local mid mctx minput moutput mtier ctx_fmt
			mid=$(get_field "$model_line" 1)
			mctx=$(get_field "$model_line" 4)
			minput=$(get_field "$model_line" 5)
			moutput=$(get_field "$model_line" 6)
			mtier=$(get_field "$model_line" 7)
			ctx_fmt=$(format_context "$mctx")
			printf "  %-22s %-10s %-8s %-12s %-12s %-7s\n" \
				"$mid" "$model_provider" "$ctx_fmt" "\$$minput" "\$$moutput" "$mtier"
		fi
	done
	return 0
}

# Print list of models from unconfigured providers.
_discover_print_unavailable_models() {
	echo ""
	echo "Unavailable Models (provider not configured):"
	echo ""
	echo "$MODEL_DATA" | while IFS= read -r model_line; do
		local model_provider
		model_provider=$(get_field "$model_line" 2)
		local provider_available=false dummy1 dummy2
		_discover_check_provider "$model_provider" provider_available dummy1 dummy2
		if [[ "$provider_available" != "true" ]]; then
			local mid
			mid=$(get_field "$model_line" 1)
			echo "  - $mid ($model_provider)"
		fi
	done
	return 0
}

# =============================================================================
# Comparison Scoring Framework
# =============================================================================
# Stores and retrieves model comparison results for cross-session insights.
# Results are stored in SQLite alongside the model registry.

RESULTS_DB="${AIDEVOPS_WORKSPACE_DIR:-$HOME/.aidevops/.agent-workspace}/memory/model-comparisons.db"

init_results_db() {
	local db_dir
	db_dir="$(dirname "$RESULTS_DB")"
	mkdir -p "$db_dir"

	sqlite3 "$RESULTS_DB" <<'SQL'
CREATE TABLE IF NOT EXISTS comparisons (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    task_description TEXT NOT NULL,
    task_type TEXT DEFAULT 'general',
    created_at TEXT DEFAULT (datetime('now')),
    evaluator_model TEXT,
    winner_model TEXT,
    prompt_version TEXT DEFAULT '',
    prompt_file TEXT DEFAULT ''
);

CREATE TABLE IF NOT EXISTS comparison_scores (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    comparison_id INTEGER NOT NULL,
    model_id TEXT NOT NULL,
    correctness INTEGER DEFAULT 0,
    completeness INTEGER DEFAULT 0,
    code_quality INTEGER DEFAULT 0,
    clarity INTEGER DEFAULT 0,
    adherence INTEGER DEFAULT 0,
    overall INTEGER DEFAULT 0,
    latency_ms INTEGER DEFAULT 0,
    tokens_used INTEGER DEFAULT 0,
    strengths TEXT DEFAULT '',
    weaknesses TEXT DEFAULT '',
    response_file TEXT DEFAULT '',
    FOREIGN KEY (comparison_id) REFERENCES comparisons(id)
);

CREATE INDEX IF NOT EXISTS idx_comparisons_task ON comparisons(task_type);
CREATE INDEX IF NOT EXISTS idx_comparisons_winner ON comparisons(winner_model);
CREATE INDEX IF NOT EXISTS idx_scores_model ON comparison_scores(model_id);
CREATE INDEX IF NOT EXISTS idx_comparisons_prompt ON comparisons(prompt_version);
SQL

	# Migrate existing DBs: add prompt_version and prompt_file columns if missing (t1396)
	sqlite3 "$RESULTS_DB" "ALTER TABLE comparisons ADD COLUMN prompt_version TEXT DEFAULT '';" 2>/dev/null || true
	sqlite3 "$RESULTS_DB" "ALTER TABLE comparisons ADD COLUMN prompt_file TEXT DEFAULT '';" 2>/dev/null || true

	return 0
}

# Record a comparison result
# Usage: cmd_score --task "description" --type "code" --evaluator "claude-opus-4-6" \
#        --model "claude-sonnet-4-6" --correctness 9 --completeness 8 --quality 7 \
#        --clarity 8 --adherence 9 --latency 1200 --tokens 500 \
#        --strengths "Fast, accurate" --weaknesses "Verbose" \
#        [--model "gpt-4.1" --correctness 8 ...]

# Flush current model state into entries array (variable name pass-through).
# Args: arg1=varname:entries arg2=model arg3=correct arg4=complete arg5=quality
#       arg6=clarity arg7=adherence arg8=latency arg9=tokens arg10=strengths arg11=weaknesses arg12=response
# Bash 3.2 compatible: uses eval for array append (no local -n namerefs).
_score_flush_model() {
	local _sf_entries_var="$1"
	local model="$2" correct="$3" complete="$4" quality="$5"
	local clarity="$6" adherence="$7" latency="$8" tokens="$9"
	local strengths="${10}" weaknesses="${11}" response="${12}"
	[[ -z "$model" ]] && return 0
	local overall=$(((correct + complete + quality + clarity + adherence) / 5))
	local _sf_entry="${model}|${correct}|${complete}|${quality}|${clarity}|${adherence}|${overall}|${latency}|${tokens}|${strengths}|${weaknesses}|${response}"
	eval "${_sf_entries_var}+=(\"\${_sf_entry}\")"
	return 0
}

# Parse score CLI arguments into named variable refs and entries array.
# Args: arg1...arg7 = variable names (task type eval winner pv pf entries), then remaining argv
# Bash 3.2 compatible: uses printf -v for scalar writes, passes var names for array (no local -n).
_score_parse_args() {
	local _spa_task_var="$1"
	local _spa_type_var="$2"
	local _spa_eval_var="$3"
	local _spa_winner_var="$4"
	local _spa_pv_var="$5"
	local _spa_pf_var="$6"
	local _spa_entries_var="$7"
	shift 7

	local cur_model="" cur_correct=0 cur_complete=0 cur_quality=0
	local cur_clarity=0 cur_adherence=0 cur_latency=0 cur_tokens=0
	local cur_strengths="" cur_weaknesses="" cur_response=""

	while [[ $# -gt 0 ]]; do
		case "$1" in
		--task)
			printf -v "$_spa_task_var" '%s' "$2"
			shift 2
			;;
		--type)
			printf -v "$_spa_type_var" '%s' "$2"
			shift 2
			;;
		--evaluator)
			printf -v "$_spa_eval_var" '%s' "$2"
			shift 2
			;;
		--winner)
			printf -v "$_spa_winner_var" '%s' "$2"
			shift 2
			;;
		--prompt-version)
			printf -v "$_spa_pv_var" '%s' "$2"
			shift 2
			;;
		--prompt-file)
			printf -v "$_spa_pf_var" '%s' "$2"
			shift 2
			;;
		--model)
			_score_flush_model "$_spa_entries_var" "$cur_model" "$cur_correct" "$cur_complete" \
				"$cur_quality" "$cur_clarity" "$cur_adherence" "$cur_latency" "$cur_tokens" \
				"$cur_strengths" "$cur_weaknesses" "$cur_response"
			cur_model="$2" cur_correct=0 cur_complete=0 cur_quality=0
			cur_clarity=0 cur_adherence=0 cur_latency=0 cur_tokens=0
			cur_strengths="" cur_weaknesses="" cur_response=""
			shift 2
			;;
		--correctness)
			cur_correct="$2"
			shift 2
			;;
		--completeness)
			cur_complete="$2"
			shift 2
			;;
		--quality)
			cur_quality="$2"
			shift 2
			;;
		--clarity)
			cur_clarity="$2"
			shift 2
			;;
		--adherence)
			cur_adherence="$2"
			shift 2
			;;
		--latency)
			cur_latency="$2"
			shift 2
			;;
		--tokens)
			cur_tokens="$2"
			shift 2
			;;
		--strengths)
			cur_strengths="$2"
			shift 2
			;;
		--weaknesses)
			cur_weaknesses="$2"
			shift 2
			;;
		--response)
			cur_response="$2"
			shift 2
			;;
		*) shift ;;
		esac
	done
	_score_flush_model "$_spa_entries_var" "$cur_model" "$cur_correct" "$cur_complete" \
		"$cur_quality" "$cur_clarity" "$cur_adherence" "$cur_latency" "$cur_tokens" \
		"$cur_strengths" "$cur_weaknesses" "$cur_response"
	return 0
}

# Parse score arguments and build model entries (orchestrator).
# Bash 3.2 compatible: forwards variable names directly to _score_parse_args (no local -n).
_score_parse_and_build() {
	local _sp_task_var="$1"
	local _sp_type_var="$2"
	local _sp_eval_var="$3"
	local _sp_winner_var="$4"
	local _sp_pv_var="$5"
	local _sp_pf_var="$6"
	local _sp_entries_var="$7"
	shift 7
	_score_parse_args "$_sp_task_var" "$_sp_type_var" "$_sp_eval_var" "$_sp_winner_var" \
		"$_sp_pv_var" "$_sp_pf_var" "$_sp_entries_var" "$@"
	return 0
}

# Sync scores to pattern tracker
_score_sync_pattern_tracker() {
	local task_type="$1"
	shift
	local -a model_entries=("$@")

	local pt_helper="${SCRIPT_DIR}/pattern-tracker-helper.sh"
	[[ ! -x "$pt_helper" ]] && return 0

	for entry in "${model_entries[@]}"; do
		IFS='|' read -r m_id m_cor m_com m_qua m_cla m_adh m_ove m_lat m_tok _ _ _ <<<"$entry"
		local m_tier
		m_tier=$(model_id_to_tier "$m_id")
		[[ -z "$m_tier" ]] && m_tier="$m_id"

		# Normalize 1-10 scores to 1-5 (halve, round)
		local norm_cor norm_com norm_qua norm_cla norm_tok_arg=()
		norm_cor=$(awk "BEGIN{v=int($m_cor/2+0.5); if(v<1)v=1; if(v>5)v=5; print v}")
		norm_com=$(awk "BEGIN{v=int($m_com/2+0.5); if(v<1)v=1; if(v>5)v=5; print v}")
		norm_qua=$(awk "BEGIN{v=int($m_qua/2+0.5); if(v<1)v=1; if(v>5)v=5; print v}")
		norm_cla=$(awk "BEGIN{v=int($m_cla/2+0.5); if(v<1)v=1; if(v>5)v=5; print v}")
		if [[ "$m_tok" =~ ^[0-9]+$ ]] && [[ "$m_tok" -gt 0 ]]; then
			norm_tok_arg=(--tokens-out "$m_tok")
		fi

		"$pt_helper" score \
			--model "$m_tier" \
			--task-type "$task_type" \
			--correctness "$norm_cor" \
			--completeness "$norm_com" \
			--code-quality "$norm_qua" \
			--clarity "$norm_cla" \
			"${norm_tok_arg[@]}" \
			--source "compare-models" \
			>/dev/null 2>&1 || true
	done
	return 0
}

cmd_score() {
	init_results_db || return 1

	local task="" task_type="general" evaluator="" winner=""
	local prompt_version="" prompt_file=""
	local -a model_entries=()

	# Parse arguments and build model entries
	_score_parse_and_build task task_type evaluator winner prompt_version prompt_file model_entries "$@"

	if [[ -z "$task" ]]; then
		echo "Usage: compare-models-helper.sh score --task 'description' --model 'model-id' --correctness N ..."
		echo ""
		echo "Score criteria (1-10 scale):"
		echo "  --correctness   Factual accuracy and correctness"
		echo "  --completeness  Coverage of all requirements"
		echo "  --quality       Code quality (if code task)"
		echo "  --clarity       Response clarity and readability"
		echo "  --adherence     Following instructions precisely"
		echo ""
		echo "Metadata:"
		echo "  --task <desc>       Task description (required)"
		echo "  --type <type>       Task type: code, text, analysis, design (default: general)"
		echo "  --evaluator <model> Model that performed the evaluation"
		echo "  --winner <model>    Overall winner model"
		echo "  --model <id>        Start scoring for a model (repeat for each model)"
		echo "  --latency <ms>      Response latency in milliseconds"
		echo "  --tokens <n>        Tokens used"
		echo "  --strengths <text>  Model strengths for this task"
		echo "  --weaknesses <text> Model weaknesses for this task"
		echo "  --response <file>   Path to response file"
		return 1
	fi

	if [[ ${#model_entries[@]} -eq 0 ]]; then
		print_error "No model scores provided. Use --model <id> --correctness N ..."
		return 1
	fi

	# Resolve prompt_version from git if prompt_file is provided and no explicit version
	if [[ -z "$prompt_version" && -n "$prompt_file" ]] && command -v git &>/dev/null; then
		prompt_version=$(git log -1 --format='%h' -- "$prompt_file" 2>/dev/null) || prompt_version=""
	fi

	# Insert comparison + scores into DB
	local comp_id
	comp_id=$(_score_insert_comparison "$task" "$task_type" "$evaluator" "$winner" \
		"$prompt_version" "$prompt_file" "${model_entries[@]}") || return 1

	print_success "Comparison #$comp_id recorded ($task_type: ${#model_entries[@]} models scored)"

	# Display summary table
	_score_display_table "$winner" "${model_entries[@]}"

	# Sync to unified pattern tracker backbone (t1094)
	_score_sync_pattern_tracker "$task_type" "${model_entries[@]}"

	return 0
}

# Insert a comparison record and its per-model scores into RESULTS_DB.
# Echoes the new comparison ID on success.
# Args: arg1=task arg2=task_type arg3=evaluator arg4=winner arg5=prompt_version arg6=prompt_file arg7+=model_entries
_score_insert_comparison() {
	local task="$1"
	local task_type="$2"
	local evaluator="$3"
	local winner="$4"
	local prompt_version="$5"
	local prompt_file="$6"
	shift 6
	local -a model_entries=("$@")

	local safe_task safe_type safe_eval safe_winner safe_pv safe_pf
	safe_task="${task//\'/\'\'}"
	safe_type="${task_type//\'/\'\'}"
	safe_eval="${evaluator//\'/\'\'}"
	safe_winner="${winner//\'/\'\'}"
	safe_pv="${prompt_version//\'/\'\'}"
	safe_pf="${prompt_file//\'/\'\'}"
	local comp_id
	comp_id=$(sqlite3 "$RESULTS_DB" "INSERT INTO comparisons (task_description, task_type, evaluator_model, winner_model, prompt_version, prompt_file) VALUES ('${safe_task}', '${safe_type}', '${safe_eval}', '${safe_winner}', '${safe_pv}', '${safe_pf}'); SELECT last_insert_rowid();")

	local entry
	for entry in "${model_entries[@]}"; do
		IFS='|' read -r m_id m_cor m_com m_qua m_cla m_adh m_ove m_lat m_tok m_str m_wea m_res <<<"$entry"
		# Validate all numeric fields — reject non-integer values to prevent SQL injection
		local n
		for n in m_cor m_com m_qua m_cla m_adh m_ove m_lat m_tok; do
			if ! [[ "${!n}" =~ ^[0-9]+$ ]]; then
				print_error "Invalid numeric value for ${n}: ${!n}"
				return 1
			fi
		done
		# Clamp score fields to valid 0-10 range
		local s
		for s in m_cor m_com m_qua m_cla m_adh m_ove; do
			if ((${!s} > 10)); then
				printf -v "$s" "10"
			fi
		done
		local safe_id="${m_id//\'/\'\'}"
		local safe_str="${m_str//\'/\'\'}"
		local safe_wea="${m_wea//\'/\'\'}"
		local safe_res="${m_res//\'/\'\'}"
		sqlite3 "$RESULTS_DB" "INSERT INTO comparison_scores (comparison_id, model_id, correctness, completeness, code_quality, clarity, adherence, overall, latency_ms, tokens_used, strengths, weaknesses, response_file) VALUES ($comp_id, '${safe_id}', $m_cor, $m_com, $m_qua, $m_cla, $m_adh, $m_ove, $m_lat, $m_tok, '${safe_str}', '${safe_wea}', '${safe_res}');"
	done

	echo "$comp_id"
	return 0
}

# Display a formatted score summary table for model_entries.
# Args: arg1=winner arg2+=model_entries
_score_display_table() {
	local winner="$1"
	shift
	local -a model_entries=("$@")

	echo ""
	printf "%-22s %5s %5s %5s %5s %5s %7s %8s %6s\n" \
		"Model" "Corr" "Comp" "Qual" "Clar" "Adhr" "Overall" "Latency" "Tokens"
	printf "%-22s %5s %5s %5s %5s %5s %7s %8s %6s\n" \
		"-----" "----" "----" "----" "----" "----" "-------" "-------" "------"

	local entry
	for entry in "${model_entries[@]}"; do
		IFS='|' read -r m_id m_cor m_com m_qua m_cla m_adh m_ove m_lat m_tok _ _ _ <<<"$entry"
		local lat_fmt="${m_lat}ms"
		[[ "$m_lat" -eq 0 ]] && lat_fmt="-"
		[[ "$m_tok" -eq 0 ]] && m_tok="-"
		printf "%-22s %5d %5d %5d %5d %5d %7d %8s %6s\n" \
			"$m_id" "$m_cor" "$m_com" "$m_qua" "$m_cla" "$m_adh" "$m_ove" "$lat_fmt" "$m_tok"
	done

	if [[ -n "$winner" ]]; then
		echo ""
		echo "  Winner: $winner"
	fi
	echo ""
	return 0
}

# View past comparison results
# Display recent comparisons from results
_results_show_recent() {
	local limit="$1"

	sqlite3 -separator '|' "$RESULTS_DB" "
        SELECT c.id, c.created_at, c.task_type, c.task_description, c.winner_model,
               COALESCE(c.prompt_version, ''), COALESCE(c.prompt_file, '')
        FROM comparisons c
        ORDER BY c.created_at DESC
        LIMIT $limit;
    " 2>/dev/null | while IFS='|' read -r cid cdate ctype cdesc cwinner cpv cpf; do
		echo "  #$cid [$ctype] $(echo "$cdesc" | head -c 60) ($cdate)"
		[[ -n "$cwinner" ]] && echo "    Winner: $cwinner"
		if [[ -n "$cpv" ]]; then
			local pv_display="$cpv"
			[[ -n "$cpf" ]] && pv_display="${cpv} (${cpf})"
			echo "    Prompt version: $pv_display"
		fi

		# Show scores for this comparison
		sqlite3 -separator '|' "$RESULTS_DB" "
            SELECT model_id, overall, correctness, completeness, code_quality, clarity, adherence
            FROM comparison_scores
            WHERE comparison_id = $cid
            ORDER BY overall DESC;
        " 2>/dev/null | while IFS='|' read -r mid ov co cm cq cl ca; do
			printf "    %-20s overall:%d (corr:%d comp:%d qual:%d clar:%d adhr:%d)\n" \
				"$mid" "$ov" "$co" "$cm" "$cq" "$cl" "$ca"
		done
		echo ""
	done
	return 0
}

# Display aggregate model rankings
_results_show_rankings() {
	local where_clause="$1"

	echo "Aggregate Model Rankings"
	echo "------------------------"
	sqlite3 -separator '|' "$RESULTS_DB" "
        SELECT model_id,
               COUNT(*) as comparisons,
               ROUND(AVG(overall), 1) as avg_overall,
               SUM(CASE WHEN c.winner_model = cs.model_id THEN 1 ELSE 0 END) as wins
        FROM comparison_scores cs
        JOIN comparisons c ON c.id = cs.comparison_id
        $where_clause
        GROUP BY model_id
        ORDER BY avg_overall DESC;
    " 2>/dev/null | while IFS='|' read -r mid cnt avg wins; do
		printf "  %-22s  avg:%s  wins:%s/%s\n" "$mid" "$avg" "$wins" "$cnt"
	done
	echo ""
	return 0
}

# Build SQL WHERE clause for results filtering
_results_build_where_clause() {
	local model_filter="$1"
	local type_filter="$2"
	local pv_filter="$3"

	# Escape string values for SQL safety
	local safe_model="${model_filter//\'/\'\'}"
	local safe_type="${type_filter//\'/\'\'}"
	local safe_pv="${pv_filter//\'/\'\'}"

	local where_clause=""
	if [[ -n "$safe_model" ]]; then
		where_clause="WHERE cs.model_id LIKE '%${safe_model}%'"
	fi
	if [[ -n "$safe_type" ]]; then
		if [[ -n "$where_clause" ]]; then
			where_clause="$where_clause AND c.task_type = '${safe_type}'"
		else
			where_clause="WHERE c.task_type = '${safe_type}'"
		fi
	fi
	if [[ -n "$safe_pv" ]]; then
		if [[ -n "$where_clause" ]]; then
			where_clause="$where_clause AND c.prompt_version = '${safe_pv}'"
		else
			where_clause="WHERE c.prompt_version = '${safe_pv}'"
		fi
	fi

	echo "$where_clause"
	return 0
}

cmd_results() {
	init_results_db || return 1

	local limit=10
	local model_filter="" type_filter="" pv_filter=""

	while [[ $# -gt 0 ]]; do
		case "$1" in
		--limit)
			limit="$2"
			shift 2
			;;
		--model)
			model_filter="$2"
			shift 2
			;;
		--type)
			type_filter="$2"
			shift 2
			;;
		--prompt-version)
			pv_filter="$2"
			shift 2
			;;
		*) shift ;;
		esac
	done

	# Validate limit is numeric (used in SQL LIMIT clause)
	if ! [[ "$limit" =~ ^[0-9]+$ ]]; then
		print_error "Invalid --limit value: $limit (must be a positive integer)"
		return 1
	fi

	# Build WHERE clause
	local where_clause
	where_clause=$(_results_build_where_clause "$model_filter" "$type_filter" "$pv_filter")

	echo ""
	echo "Model Comparison Results (last $limit)"
	echo "======================================="
	echo ""

	local count
	count=$(sqlite3 "$RESULTS_DB" "SELECT COUNT(DISTINCT c.id) FROM comparisons c LEFT JOIN comparison_scores cs ON c.id = cs.comparison_id $where_clause;" 2>/dev/null || echo "0")

	if [[ "$count" -eq 0 ]]; then
		echo "No comparison results found."
		echo "Run a comparison first: compare-models-helper.sh score --task '...' --model '...' ..."
		echo ""
		return 0
	fi

	# Show recent comparisons and rankings
	_results_show_recent "$limit"
	_results_show_rankings "$where_clause"

	return 0
}

