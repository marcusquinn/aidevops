#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# =============================================================================
# Compare Models — Scoring Library
# =============================================================================
# The comparison scoring framework (SQLite-backed cross-session model
# comparison results), used by compare-models-cross-review-lib.sh's optional
# --score judge pipeline.
#
# Usage: source "${SCRIPT_DIR}/compare-models-scoring-lib.sh"
#
# Dependencies:
#   - shared-constants.sh (print_error, print_warning, print_success)
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
#        --model "claude-sonnet-5-5" --correctness 9 --completeness 8 --quality 7 \
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
