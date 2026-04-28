#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# =============================================================================
# Contest Helper — Evaluate Sub-Library
# =============================================================================
# Evaluation pipeline: collect entry summaries, build cross-ranking prompts,
# run judge models, aggregate scores, determine winner, and finalize.
#
# Usage: source "${SCRIPT_DIR}/contest-helper-evaluate.sh"
#
# Dependencies:
#   - shared-constants.sh (print_error, print_info, etc.)
#   - contest-helper.sh orchestrator (db, sql_escape, ensure_contest_tables,
#     log_*, run_ai_scoring, WEIGHT_* constants)
#
# Part of aidevops framework: https://aidevops.sh

# Apply strict mode only when executed directly (not when sourced)
[[ "${BASH_SOURCE[0]}" == "${0}" ]] && set -euo pipefail

# Include guard
[[ -n "${_CONTEST_EVALUATE_LIB_LOADED:-}" ]] && return 0
_CONTEST_EVALUATE_LIB_LOADED=1

# Defensive SCRIPT_DIR fallback
if [[ -z "${SCRIPT_DIR:-}" ]]; then
    _lib_path="${BASH_SOURCE[0]%/*}"
    [[ "$_lib_path" == "${BASH_SOURCE[0]}" ]] && _lib_path="."
    SCRIPT_DIR="$(cd "$_lib_path" && pwd)"
    unset _lib_path
fi

#######################################
# Collect output summaries from completed contest entries
# Usage: _collect_entry_summaries <escaped_cid>
# Populates entry_ids, entry_models, entry_summaries arrays in caller scope
# via a temp file (one line per entry: id<TAB>model<TAB>summary_b64)
# Outputs the temp file path; caller must rm it
#######################################
_collect_entry_summaries() {
	local escaped_cid="$1"

	local entries_data
	entries_data=$(db -separator $'\t' "$SUPERVISOR_DB" "
		SELECT id, model, task_id, worktree, branch, log_file, pr_url
		FROM contest_entries
		WHERE contest_id = '$escaped_cid' AND status = 'complete'
		ORDER BY id;
	")

	local tmpfile
	tmpfile=$(mktemp "${TMPDIR:-/tmp}/contest-summaries-XXXXXX")

	while IFS=$'\t' read -r eid emodel _etask ewt _ebranch elog _epr; do
		[[ -z "$eid" ]] && continue

		# Reset IFS to default before $() calls — prevents zsh IFS leak corrupting PATH lookup
		local summary="" _saved_ifs="$IFS"
		IFS=$' \t\n'
		if [[ -n "$ewt" && -d "$ewt" ]]; then
			summary=$(git -C "$ewt" diff --stat "main..HEAD" 2>/dev/null || echo "No diff available")
			local full_diff
			full_diff=$(git -C "$ewt" diff "main..HEAD" 2>/dev/null | head -500 || echo "")
			summary="${summary}

--- Code Changes ---
${full_diff}"
		elif [[ -n "$elog" && -f "$elog" ]]; then
			summary=$(tail -100 "$elog" 2>/dev/null || echo "No log available")
		fi
		IFS="$_saved_ifs"

		# Store summary in entry
		db "$SUPERVISOR_DB" "
			UPDATE contest_entries SET output_summary = '$(sql_escape "$summary")'
			WHERE id = '$(sql_escape "$eid")';
		"

		# Write to temp file: id<TAB>model<TAB>summary (summary may contain newlines — base64 encode)
		local summary_b64
		summary_b64=$(printf '%s' "$summary" | base64 | tr -d '\n')
		printf '%s\t%s\t%s\n' "$eid" "$emodel" "$summary_b64" >>"$tmpfile"
	done <<<"$entries_data"

	echo "$tmpfile"
	return 0
}

#######################################
# Build the cross-ranking prompt for judges
# Usage: _build_ranking_prompt <num_entries> <summaries_csv_b64>
# Reads summaries from a temp file (one line: label<TAB>summary_b64)
# Outputs the prompt text
#######################################
_build_ranking_prompt() {
	local num_entries="$1"
	local summaries_file="$2"

	local ranking_prompt="You are evaluating ${num_entries} different implementations of the same task. Each implementation is labelled with a letter (A, B, C, etc.). You do NOT know which model produced which output.

Score each implementation on these criteria (1-5 scale):
- Correctness (30%): Does it correctly solve the task? Any bugs or errors?
- Completeness (25%): Does it cover all requirements including edge cases?
- Code Quality (25%): Is it clean, idiomatic, well-structured with error handling?
- Clarity (20%): Is it well-organized and easy to understand?

For each implementation, output EXACTLY this JSON format (one per line):
{\"label\": \"A\", \"correctness\": N, \"completeness\": N, \"code_quality\": N, \"clarity\": N}

Here are the implementations:
"

	local labels=("A" "B" "C" "D" "E")
	local idx=0
	while IFS=$'\t' read -r _eid _emodel summary_b64; do
		[[ -z "$_eid" ]] && continue
		local label="${labels[$idx]:-$(printf '%c' $((65 + idx)))}"
		# Reset IFS to default before $() calls — prevents zsh IFS leak corrupting PATH lookup
		local summary _saved_ifs="$IFS"
		IFS=$' \t\n'
		summary=$(printf '%s' "$summary_b64" | base64 --decode 2>/dev/null || echo "")
		IFS="$_saved_ifs"
		ranking_prompt="${ranking_prompt}
=== Implementation ${label} ===
${summary}
=== End Implementation ${label} ===
"
		idx=$((idx + 1))
	done <"$summaries_file"

	ranking_prompt="${ranking_prompt}

Now score each implementation. Output ONLY the JSON lines, nothing else."

	printf '%s' "$ranking_prompt"
	return 0
}

#######################################
# Run all judge models and collect raw scores
# Usage: _run_judges <judge_models_newline_sep> <ranking_prompt>
# Outputs raw score lines: judge:<model>|<json_score>
#######################################
_run_judges() {
	local judges_file="$1"
	local ranking_prompt="$2"

	local judge_count=0
	local total_judges
	total_judges=$(wc -l <"$judges_file" | tr -d ' ')

	while IFS= read -r judge_model; do
		[[ -z "$judge_model" ]] && continue
		judge_count=$((judge_count + 1))
		log_info "Judge $judge_count/${total_judges}: $judge_model scoring all entries..."

		local score_tmpfile
		score_tmpfile=$(mktemp "${TMPDIR:-/tmp}/contest-score-XXXXXX")
		local score_output=""

		if run_ai_scoring "$judge_model" "$ranking_prompt" "$score_tmpfile"; then
			score_output=$(cat "$score_tmpfile" 2>/dev/null || echo "")
		fi

		if [[ -n "$score_output" ]]; then
			local json_scores
			json_scores=$(echo "$score_output" | grep -oE '\{[^}]*"label"[^}]*\}' || true)
			if [[ -n "$json_scores" ]]; then
				while IFS= read -r score_line; do
					[[ -z "$score_line" ]] && continue
					printf 'judge:%s|%s\n' "$judge_model" "$score_line"
				done <<<"$json_scores"
			else
				log_warn "Judge $judge_model returned no parseable scores"
			fi
		else
			log_warn "Judge $judge_model returned empty output"
		fi

		rm -f "$score_tmpfile"
	done <"$judges_file"

	return 0
}

#######################################
# Aggregate judge scores for a single entry label
# Usage: _aggregate_entry_scores <label> <all_scores_file>
# Outputs: correctness<TAB>completeness<TAB>quality<TAB>clarity<TAB>weighted<TAB>score_count
#######################################
_aggregate_entry_scores() {
	local label="$1"
	local all_scores_file="$2"

	local total_correctness=0 total_completeness=0 total_quality=0 total_clarity=0
	local score_count=0

	while IFS= read -r score_entry; do
		[[ -z "$score_entry" ]] && continue
		local score_json="${score_entry#*|}"
		local score_label
		score_label=$(echo "$score_json" | sed -n 's/.*"label"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' || echo "")

		if [[ "$score_label" == "$label" ]]; then
			local s_correct s_complete s_quality s_clarity
			s_correct=$(echo "$score_json" | sed -n 's/.*"correctness"[[:space:]]*:[[:space:]]*\([0-9]*\).*/\1/p' || echo "0")
			s_complete=$(echo "$score_json" | sed -n 's/.*"completeness"[[:space:]]*:[[:space:]]*\([0-9]*\).*/\1/p' || echo "0")
			s_quality=$(echo "$score_json" | sed -n 's/.*"code_quality"[[:space:]]*:[[:space:]]*\([0-9]*\).*/\1/p' || echo "0")
			s_clarity=$(echo "$score_json" | sed -n 's/.*"clarity"[[:space:]]*:[[:space:]]*\([0-9]*\).*/\1/p' || echo "0")

			total_correctness=$((total_correctness + s_correct))
			total_completeness=$((total_completeness + s_complete))
			total_quality=$((total_quality + s_quality))
			total_clarity=$((total_clarity + s_clarity))
			score_count=$((score_count + 1))
		fi
	done <"$all_scores_file"

	if [[ "$score_count" -gt 0 ]]; then
		local avg_correct avg_complete avg_quality avg_clarity weighted
		avg_correct=$(awk "BEGIN {printf \"%.2f\", $total_correctness / $score_count}")
		avg_complete=$(awk "BEGIN {printf \"%.2f\", $total_completeness / $score_count}")
		avg_quality=$(awk "BEGIN {printf \"%.2f\", $total_quality / $score_count}")
		avg_clarity=$(awk "BEGIN {printf \"%.2f\", $total_clarity / $score_count}")
		weighted=$(awk "BEGIN {printf \"%.2f\", ($avg_correct * $WEIGHT_CORRECTNESS + $avg_complete * $WEIGHT_COMPLETENESS + $avg_quality * $WEIGHT_CODE_QUALITY + $avg_clarity * $WEIGHT_CLARITY) / 100}")
		printf '%s\t%s\t%s\t%s\t%s\t%d' \
			"$avg_correct" "$avg_complete" "$avg_quality" "$avg_clarity" "$weighted" "$score_count"
	else
		printf '0\t0\t0\t0\t0\t0'
	fi
	return 0
}

#######################################
# Store aggregated scores for all entries and determine winner
# Usage: _store_scores_and_find_winner <escaped_cid> <summaries_file> <all_scores_file>
# Outputs: winner_id<TAB>winner_model<TAB>winner_score  (or empty on failure)
#######################################
_store_scores_and_find_winner() {
	local escaped_cid="$1"
	local summaries_file="$2"
	local all_scores_file="$3"

	local labels=("A" "B" "C" "D" "E")
	local idx=0

	while IFS=$'\t' read -r eid emodel _summary_b64; do
		[[ -z "$eid" ]] && continue
		local label="${labels[$idx]:-$(printf '%c' $((65 + idx)))}"

		# Reset IFS to default before $() calls — prevents zsh IFS leak corrupting PATH lookup
		local score_row _saved_ifs="$IFS"
		IFS=$' \t\n'
		score_row=$(_aggregate_entry_scores "$label" "$all_scores_file")
		IFS="$_saved_ifs"
		local avg_correct avg_complete avg_quality avg_clarity weighted score_count
		IFS=$'\t' read -r avg_correct avg_complete avg_quality avg_clarity weighted score_count <<<"$score_row"

		if [[ "$score_count" -gt 0 ]]; then
			local raw_scores
			raw_scores=$(tr '\n' ' ' <"$all_scores_file")
			db "$SUPERVISOR_DB" "
				UPDATE contest_entries SET
					score_correctness = $avg_correct,
					score_completeness = $avg_complete,
					score_code_quality = $avg_quality,
					score_clarity = $avg_clarity,
					weighted_score = $weighted,
					cross_rank_scores = '$(sql_escape "judges:$score_count,raw:$raw_scores")'
				WHERE id = '$(sql_escape "$eid")';
			"
			log_info "Entry $label ($emodel): correctness=$avg_correct completeness=$avg_complete quality=$avg_quality clarity=$avg_clarity weighted=$weighted"
		else
			log_warn "No scores collected for entry $label ($eid)"
		fi

		idx=$((idx + 1))
	done <"$summaries_file"

	# Return winner row
	db -separator $'\t' "$SUPERVISOR_DB" "
		SELECT id, model, weighted_score
		FROM contest_entries
		WHERE contest_id = '$escaped_cid' AND status = 'complete'
		ORDER BY weighted_score DESC
		LIMIT 1;
	"
	return 0
}

#######################################
# Check that a contest is ready for evaluation.
# Returns 0 (ready), 1 (error/not ready), 2 (still running).
# On success, outputs complete_count to stdout.
#######################################
_evaluate_check_readiness() {
	local contest_id="$1"
	local escaped_cid="$2"

	local contest_status
	contest_status=$(db "$SUPERVISOR_DB" "SELECT status FROM contests WHERE id = '$escaped_cid';")
	if [[ "$contest_status" != "running" ]]; then
		log_error "Contest $contest_id is in '$contest_status' state, must be 'running' to evaluate"
		return 1
	fi

	local pending_count
	pending_count=$(db "$SUPERVISOR_DB" "
		SELECT count(*) FROM contest_entries
		WHERE contest_id = '$escaped_cid'
		AND status NOT IN ('complete','failed','cancelled');
	")
	if [[ "$pending_count" -gt 0 ]]; then
		log_info "Contest $contest_id has $pending_count entries still running — not ready for evaluation"
		return 2
	fi

	local complete_count
	complete_count=$(db "$SUPERVISOR_DB" "
		SELECT count(*) FROM contest_entries
		WHERE contest_id = '$escaped_cid' AND status = 'complete';
	")
	if [[ "$complete_count" -lt 2 ]]; then
		log_error "Contest $contest_id has fewer than 2 completed entries ($complete_count) — cannot cross-rank"
		db "$SUPERVISOR_DB" "
			UPDATE contests SET status = 'failed',
				metadata = COALESCE(metadata,'') || ' eval_failed:insufficient_entries'
			WHERE id = '$escaped_cid';
		"
		return 1
	fi

	echo "$complete_count"
	return 0
}

#######################################
# Collect summaries, build ranking prompt, run judges, aggregate scores.
# Outputs winner_row (id<TAB>model<TAB>score) or empty on failure.
#######################################
_evaluate_run_pipeline() {
	local contest_id="$1"
	local escaped_cid="$2"

	local summaries_file
	summaries_file=$(_collect_entry_summaries "$escaped_cid")

	local num_entries
	num_entries=$(wc -l <"$summaries_file" | tr -d ' ')
	if [[ "$num_entries" -lt 2 ]]; then
		log_error "Not enough entries to evaluate"
		rm -f "$summaries_file"
		return 1
	fi

	local ranking_prompt
	ranking_prompt=$(_build_ranking_prompt "$num_entries" "$summaries_file")

	db "$SUPERVISOR_DB" "UPDATE contests SET status = 'scoring' WHERE id = '$escaped_cid';"

	local judges_file
	judges_file=$(mktemp "${TMPDIR:-/tmp}/contest-judges-XXXXXX")
	while IFS=$'\t' read -r _eid emodel _summary_b64; do
		[[ -z "$emodel" ]] && continue
		echo "$emodel" >>"$judges_file"
	done <"$summaries_file"

	local all_scores_file
	all_scores_file=$(mktemp "${TMPDIR:-/tmp}/contest-allscores-XXXXXX")
	_run_judges "$judges_file" "$ranking_prompt" >"$all_scores_file"
	rm -f "$judges_file"

	local judge_count
	judge_count=$(wc -l <"$all_scores_file" | tr -d ' ')
	log_info "Aggregating scores from ${judge_count} score lines..."

	local winner_row
	winner_row=$(_store_scores_and_find_winner "$escaped_cid" "$summaries_file" "$all_scores_file")
	rm -f "$summaries_file" "$all_scores_file"

	printf '%s' "$winner_row"
	return 0
}

#######################################
# Evaluate contest — cross-rank outputs from all completed entries
# Each model scores all outputs (including its own) blindly as A/B/C
# Then aggregate scores and pick winner
#######################################
cmd_evaluate() {
	local contest_id="${1:-}"
	if [[ -z "$contest_id" ]]; then
		log_error "Usage: contest-helper.sh evaluate <contest_id>"
		return 1
	fi

	ensure_contest_tables || return 1

	local escaped_cid
	escaped_cid=$(sql_escape "$contest_id")

	local complete_count
	complete_count=$(_evaluate_check_readiness "$contest_id" "$escaped_cid")
	local readiness_rc=$?
	if [[ "$readiness_rc" -ne 0 ]]; then
		return "$readiness_rc"
	fi

	db "$SUPERVISOR_DB" "UPDATE contests SET status = 'evaluating' WHERE id = '$escaped_cid';"
	log_info "Evaluating contest $contest_id with $complete_count entries..."

	local winner_row
	winner_row=$(_evaluate_run_pipeline "$contest_id" "$escaped_cid") || return 1

	_finalize_contest_winner "$contest_id" "$escaped_cid" "$winner_row"
	return $?
}

#######################################
# Persist winner, record patterns/scores, or mark contest failed
# Usage: _finalize_contest_winner <contest_id> <escaped_cid> <winner_row>
# winner_row format: id<TAB>model<TAB>score  (empty = no winner)
#######################################
_finalize_contest_winner() {
	local contest_id="$1"
	local escaped_cid="$2"
	local winner_row="$3"

	if [[ -n "$winner_row" ]]; then
		local winner_id winner_model winner_score
		IFS=$'\t' read -r winner_id winner_model winner_score <<<"$winner_row"

		db "$SUPERVISOR_DB" "
			UPDATE contests SET
				status = 'complete',
				winner_model = '$(sql_escape "$winner_model")',
				winner_entry_id = '$(sql_escape "$winner_id")',
				winner_score = $winner_score,
				completed_at = strftime('%Y-%m-%dT%H:%M:%SZ','now')
			WHERE id = '$escaped_cid';
		"

		log_success "Contest $contest_id winner: $winner_model (score: $winner_score)"

		# Record results in pattern-tracker
		_record_contest_patterns "$contest_id"

		# Record in response-scoring DB
		_record_contest_scores "$contest_id"
	else
		db "$SUPERVISOR_DB" "
			UPDATE contests SET status = 'failed',
				metadata = COALESCE(metadata,'') || ' eval_failed:no_winner'
			WHERE id = '$escaped_cid';
		"
		log_error "Could not determine winner for contest $contest_id"
		return 1
	fi

	return 0
}
