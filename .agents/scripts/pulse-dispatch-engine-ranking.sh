#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# Candidate ranking: per-repository scoring, the cross-repository ranked
# candidate build and order-only dispatch round partitions.
# Sourced by pulse-dispatch-engine.sh after its defaults and dependencies.
# Moved unchanged from pulse-dispatch-engine.sh (GH#39323). No ranking runs
# merely by sourcing this library.

[[ "${BASH_SOURCE[0]}" == "${0}" ]] && set -euo pipefail
[[ -n "${_PULSE_DISPATCH_ENGINE_RANKING_LOADED:-}" ]] && return 0
_PULSE_DISPATCH_ENGINE_RANKING_LOADED=1

#######################################
# Score one repository's dispatch candidates and append JSONL records to the
# shared candidate file. Extracted so the cross-repository orchestrator stays
# below the function-complexity threshold.
# Arguments: candidates JSON, slug, path, priority, bonus/day, bonus cap,
#            current epoch, destination JSONL file
#######################################
_append_ranked_repo_candidates() {
	local repo_candidates_json="$1"
	local repo_slug="$2"
	local repo_path="$3"
	local repo_priority="$4"
	local age_bonus_per_day="$5"
	local age_bonus_cap="$6"
	local current_epoch="$7"
	local tmp_candidates="$8"

	printf '%s' "$repo_candidates_json" | jq -c --arg slug "$repo_slug" --arg path "$repo_path" --arg priority "$repo_priority" --arg debt_label "${QUALITY_DEBT_LABEL:-quality-debt}" --argjson age_bonus_per_day "$age_bonus_per_day" --argjson age_bonus_cap "$age_bonus_cap" --argjson current_epoch "$current_epoch" '
		.[] |
		(try ((.createdAt // "") | fromdateiso8601) catch $current_epoch) as $created_epoch |
		((($current_epoch - $created_epoch) / 86400) | floor | if . < 0 then 0 else . end) as $age_days |
		($age_days * $age_bonus_per_day) as $uncapped_age_bonus |
		(if $uncapped_age_bonus > $age_bonus_cap then $age_bonus_cap else $uncapped_age_bonus end) as $age_bonus |
		((.labels // []) | map(.name? // .)) as $labels |
		(
			(if $priority == "tooling" then 2000 elif $priority == "product" then 1000 else 0 end) +
			# Mission m-20260504-1e325d feature 3.4: when capacity is
			# constrained, rank worker-ready/low-complexity issues above
			# broad raw backlog so pulse fills slots with solvable work first.
			(if (($labels | index("tier:simple")) != null or ($labels | index("low-complexity")) != null) then 2500
			 elif ($labels | index("tier:standard")) != null then 1200
			 else 0 end) +
			(if (($labels | index("worker-ready")) != null or ($labels | index("status:available")) != null) then 1000 else 0 end) +
			(if (($labels | index("good first issue")) != null or ($labels | index("quick-win")) != null) then 800 else 0 end) +
			(if ($labels | index("auto-dispatch")) != null then 300 else 0 end) -
			(if ($labels | index("tier:thinking")) != null then 1200 else 0 end) -
			(if (($labels | index("research")) != null or ($labels | index("needs-design")) != null) then 800 else 0 end) +
			(if (($labels | index($debt_label)) != null and ($labels | index("security")) != null) then 500 else 0 end) +
			(if ($labels | index("priority:critical")) != null then 10000
			 elif ($labels | index("priority:high")) != null then 9000
			 elif ($labels | index("priority:medium")) != null then 8000
			 elif ($labels | index("bug")) != null then 7000
			 elif ($labels | index("enhancement")) != null then 6000
			 elif ($labels | index($debt_label)) != null then 5000
			 elif (($labels | index("file-size-debt")) != null or ($labels | index("function-complexity-debt")) != null) then 4000
			 elif ($labels | index("priority:low")) != null then 3500
			 else 3000 end)
		) as $base_score |
		. + {
			repo_slug: $slug,
			repo_path: $path,
			repo_priority: $priority,
			# GH#32703: urgent labels lead strictly, matching the urgent phase
			# of _dispatch_priority_loop, so tier/age bonuses cannot outrank them.
			priority_rank: (if ($labels | index("priority:critical")) != null then 2
				elif ($labels | index("priority:high")) != null then 1 else 0 end),
			base_score: $base_score,
			age_days: $age_days,
			age_bonus: $age_bonus,
			score: ($base_score + $age_bonus)
		}
	' >>"$tmp_candidates" 2>/dev/null || true
	return 0
}

#######################################
# Build ranked deterministic dispatch candidates across all pulse repos.
# Arguments:
#   $1 - max issues to fetch per repo (optional)
#   $2 - dependency normalization mode (optional: normalize or skip)
# Returns: JSON array sorted by score desc, createdAt asc, updatedAt asc
#######################################
build_ranked_dispatch_candidates_json() {
	local per_repo_limit="${1:-$PULSE_RUNNABLE_ISSUE_LIMIT}"
	local dependency_normalization_mode="${2:-normalize}"
	[[ "$per_repo_limit" =~ ^[0-9]+$ ]] || per_repo_limit="$PULSE_RUNNABLE_ISSUE_LIMIT"
	local age_bonus_per_day="${PULSE_DISPATCH_AGE_BONUS_PER_DAY:-25}"
	local age_bonus_cap="${PULSE_DISPATCH_AGE_BONUS_CAP:-900}"
	local current_epoch
	[[ "$age_bonus_per_day" =~ ^[0-9]+$ ]] || age_bonus_per_day=25
	[[ "$age_bonus_cap" =~ ^[0-9]+$ ]] || age_bonus_cap=900
	current_epoch=$(date +%s)
	[[ "$current_epoch" =~ ^[0-9]+$ ]] || current_epoch=0

	if [[ ! -f "$REPOS_JSON" ]]; then
		printf '[]\n'
		return 0
	fi

	local tmp_candidates scan_dir product_complete=true scan_failed=0 census_flags=0 parallel=1
	local cursor="" cursor_file="${HOME}/.aidevops/cache/pulse-first-wave-cursor" first_wave_bounds=""
	local deadline=0 repo_budget="${PULSE_REPO_ENUMERATION_BUDGET_S:-15}" remaining=0 admit_rc=0 polled=0 stopped_at=""
	[[ "$repo_budget" =~ ^[1-9][0-9]{0,2}$ ]] || repo_budget=15
	repo_budget=$((10#$repo_budget))
	deadline=$(_dispatch_census_deadline)
	parallel=$(_dispatch_census_parallelism)
	if [[ "${_PULSE_FIRST_DISPATCH_WAVE:-0}" == "1" ]]; then
		first_wave_bounds=$(_dispatch_first_wave_bounds)
	else
		cursor_file="${HOME}/.aidevops/cache/pulse-census-cursor"
	fi
	cursor=$(_dispatch_read_census_cursor "$cursor_file")
	tmp_candidates=$(mktemp) || return 1
	scan_dir=$(mktemp -d) || {
		rm -f "$tmp_candidates"
		return 1
	}
	: >"$tmp_candidates"

	while IFS='|' read -r repo_slug repo_path repo_priority ph_start ph_end expires repo_interval repo_lead; do
		[[ -n "$repo_slug" && -n "$repo_path" ]] || continue
		# GH#38730: take a free scan slot before measuring the remainder, so
		# every launched scan's budget stays clamped to the census deadline.
		((parallel == 1 || polled < parallel)) ||
			_dispatch_census_wait_for_slot "$scan_dir" "$polled" "$parallel" "$deadline" || true
		remaining=$((deadline - $(_dispatch_first_wave_now_s)))
		if ((remaining <= 0)); then
			echo "[pulse-wrapper] Candidate census deadline reached; retaining partial candidates and rotation cursor (GH#38226)" >>"$LOGFILE"
			product_complete=false
			stopped_at="$repo_slug"
			break
		fi
		# GH#34331: stop a first wave once it can fill its free slots or its budget elapses.
		if [[ -n "$first_wave_bounds" && -s "$tmp_candidates" ]] &&
			_dispatch_first_wave_enumeration_done "$tmp_candidates" "$first_wave_bounds"; then
			break
		fi
		admit_rc=0
		_dispatch_census_admit_repo "$repo_slug" "$repo_priority" "$ph_start" "$ph_end" "$expires" \
			"$repo_interval" "$repo_budget" "$remaining" "$polled" || admit_rc=$?
		((admit_rc < 2)) || product_complete=false
		((admit_rc != 3)) || { stopped_at="$repo_slug" && break; }
		((admit_rc == 0)) || continue
		polled=$((polled + 1))
		# Record that we are polling this repo now (atomic write, non-fatal)
		update_repo_pulse_timestamp "$repo_slug"
		[[ -z "$first_wave_bounds" ]] || _dispatch_first_wave_note_polled "$repo_slug" "$repo_lead"
		[[ -n "$first_wave_bounds" ]] || _dispatch_first_wave_advance_cursor "$repo_slug" pulse-census-cursor
		_dispatch_census_start_scan "$scan_dir" "$polled" "$parallel" "$repo_slug" "$repo_path" "$repo_priority" \
			"$repo_budget" "$remaining" "$per_repo_limit" "$dependency_normalization_mode"
		# A serial census absorbs each scan at once: first waves count candidates between repositories.
		((parallel > 1)) || _dispatch_census_absorb_scans "$scan_dir" "$polled" "$polled" "$deadline" \
			"$tmp_candidates" "$age_bonus_per_day" "$age_bonus_cap" "$current_epoch" || census_flags=$((census_flags | $?))
	done < <(_dispatch_repository_rows "$cursor")
	if ((parallel > 1 && polled > 0)); then
		_dispatch_census_absorb_scans "$scan_dir" 1 "$polled" "$deadline" "$tmp_candidates" \
			"$age_bonus_per_day" "$age_bonus_cap" "$current_epoch" || census_flags=$((census_flags | $?))
		echo "[pulse-wrapper] Candidate census parallel scans: repos=${polled} max_parallel=${parallel} (GH#38730)" >>"$LOGFILE"
	fi
	rm -rf "$scan_dir"
	(((census_flags & 1) == 0)) || scan_failed=1
	(((census_flags & 2) == 0)) || product_complete=false
	# GH#33647/GH#34331: partial waves never imply complete product discovery.
	(((census_flags & 4) == 0)) || [[ -z "$first_wave_bounds" ]] || product_complete=false
	[[ -z "$stopped_at" || -n "$first_wave_bounds" ]] || _dispatch_census_carry_unreached "$cursor" "$stopped_at" \
		"$tmp_candidates" "$age_bonus_per_day" "$age_bonus_cap" "$current_epoch"

	if [[ ! -s "$tmp_candidates" ]]; then
		rm -f "$tmp_candidates"
		printf '[]\n'
		[[ "$scan_failed" -eq 0 ]]
		return $?
	fi

	_dispatch_finish_ranked_census "$tmp_candidates" "$product_complete"
	return 0
}

#######################################
# Keep trusted review-feedback debt within its fairness share while ordinary
# candidates remain. Excess debt stays at the tail so it can borrow capacity
# only after ordinary candidates have been attempted by the existing gates.
#
# Arguments:
#   $1 - ranked candidate JSON array
#   $2 - available implementation slots
# Returns: reordered JSON array
#######################################
_dispatch_order_idle_borrowing_candidates() {
	local candidates_json="$1"
	local available_slots="$2"
	local debt_cap_pct="${QUALITY_DEBT_CAP_PCT:-30}"

	[[ "$available_slots" =~ ^[0-9]+$ ]] || available_slots=0
	[[ "$debt_cap_pct" =~ ^[0-9]+$ ]] || debt_cap_pct=30
	if [[ "$debt_cap_pct" -gt 100 ]]; then
		debt_cap_pct=100
	fi

	printf '%s' "$candidates_json" | jq -c --argjson cap "$((available_slots * debt_cap_pct / 100))" --arg debt_label "${QUALITY_DEBT_LABEL:-quality-debt}" '
		def trusted_review_debt:
			((.labels // []) | index($debt_label)) != null and
			((.labels // []) | index("source:review-feedback")) != null;
		[.[] | select(trusted_review_debt)] as $debt |
		[.[] | select(trusted_review_debt | not)] as $ordinary |
		($debt[0:$cap] + $ordinary + $debt[$cap:])
	' 2>/dev/null || printf '%s\n' "$candidates_json"
	return 0
}

#######################################
# GH#38333: attempt unclaimed candidates before claimed ones. The candidate
# filter admits assigned, in-progress, in-review and claimed auto-dispatch
# issues so dedup can recover stale claims, but on a 20-slot runner those
# guards rejected ~590 such candidates in 41h at 27-75s each while unclaimed
# ready work waited. Stable partition, order-only: every candidate still passes
# its live gates and claimed ones are attempted once fresh work is exhausted.
# No claimed candidate, or any jq failure, returns the input byte-for-byte.
#
# GH#39030: an assignee alone is not a claim when dedup would treat it as
# passive (_has_active_claim + _is_assigned_compute_blocking): only self, repo
# owner or repo maintainer, no active status label, no interactive hold. Such
# candidates pass the assignee gate cheaply, so they stay in the fresh lane;
# reopened issues healed with a stale maintainer assignee were starving there.
# An unreadable maintainer map keeps the stricter owner/self-only rule.
#
# Arguments:
#   $1 - ranked candidate JSON array
# Returns: reordered JSON array
#######################################
_dispatch_order_claim_state_candidates() {
	local candidates_json="$1" result="" demoted="" kept="" ordered="" maintainers="{}"
	if [[ -n "${REPOS_JSON:-}" && -f "$REPOS_JSON" ]]; then
		maintainers=$(jq -c '[.initialized_repos[]? | select((.slug // "") != "" and (.maintainer // "") != "")
			| {key: .slug, value: .maintainer}] | from_entries' "$REPOS_JSON" 2>/dev/null) || maintainers="{}"
		[[ -n "$maintainers" ]] || maintainers="{}"
	fi
	if ! result=$(jq -c --arg self "${_DISPATCH_SELF_LOGIN:-}" --argjson maintainers "$maintainers" '
		def label_names: (.labels // []) | map(.name? // .);
		def assigned: (.assignees // []) | length > 0;
		def passive_assignees:
			(.repo_slug // "") as $slug |
			([($slug | split("/")[0]), ($maintainers[$slug] // ""), $self] | map(select(. != ""))) as $passive |
			label_names as $labels |
			(any($labels[]; . == "status:queued" or . == "status:in-progress" or . == "status:in-review" or . == "status:claimed") | not) and
			((($labels | index("origin:interactive")) != null and ($labels | index("auto-dispatch")) == null) | not) and
			all((.assignees // [])[] | (.login? // .); . as $login | ($passive | index($login)) != null);
		def claimed:
			(assigned and (passive_assignees | not)) or
			(label_names | any(.[]; . == "status:in-progress" or . == "status:in-review" or . == "status:claimed"));
		([.[] | select(claimed)] | length),
		([.[] | select(assigned and (claimed | not))] | length),
		([.[] | select(claimed | not)] + [.[] | select(claimed)])
	' <<<"$candidates_json" 2>/dev/null) ||
		! { IFS= read -r demoted && IFS= read -r kept && IFS= read -r ordered; } <<<"$result" ||
		[[ ! "$demoted" =~ ^[0-9]+$ || ! "$kept" =~ ^[0-9]+$ || -z "$ordered" ]] ||
		[[ "$demoted" == 0 && "$kept" == 0 ]]; then
		printf '%s\n' "$candidates_json"
		return 0
	fi
	echo "[pulse-wrapper] Dispatch_max: fresh-first lane — ${demoted} claimed candidate(s) (non-passive assignee or in-progress/in-review/claimed) ordered after unclaimed work; ${kept} passive-assignee candidate(s) kept fresh (GH#38333/GH#39030)" >>"$LOGFILE"
	if [[ "$demoted" == 0 ]]; then
		printf '%s\n' "$candidates_json"
		return 0
	fi
	if declare -F _dispatch_stats_increment >/dev/null 2>&1; then
		_dispatch_stats_increment "dispatch_candidate_claimed_demoted"
	fi
	printf '%s\n' "$ordered"
	return 0
}

#######################################
# Order one dispatch round: attempt-recency rotation (GH#34363) when the
# candidate library is loaded, then fresh-first claim state (GH#38333), then
# the trusted review-debt fairness share. The debt cap takes precedence even
# for fresh rank-0 review-debt work; the recency share does not exempt
# candidates from the established debt policy. All are order-only; every
# candidate still passes its live gates.
#
# Arguments:
#   $1 - ranked candidate JSON array
#   $2 - available implementation slots
# Returns: reordered JSON array
#######################################
_dispatch_order_round_candidates() {
	local candidates_json="$1"
	local available_slots="$2"
	if declare -F _dispatch_order_attempt_recency_candidates >/dev/null 2>&1; then
		candidates_json=$(_dispatch_order_attempt_recency_candidates "$candidates_json")
	fi
	candidates_json=$(_dispatch_order_claim_state_candidates "$candidates_json")
	_dispatch_order_idle_borrowing_candidates "$candidates_json" "$available_slots"
	return 0
}
