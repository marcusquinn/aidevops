#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# Candidate census: first-wave bounds, per-repository enumeration budgets,
# limits and costs, last-good carry-over and bounded parallel repository scans.
# Sourced by pulse-dispatch-engine.sh after its defaults and dependencies.
# Moved unchanged from pulse-dispatch-engine.sh (GH#39323). No census runs
# merely by sourcing this library.

[[ "${BASH_SOURCE[0]}" == "${0}" ]] && set -euo pipefail
[[ -n "${_PULSE_DISPATCH_ENGINE_CENSUS_LOADED:-}" ]] && return 0
_PULSE_DISPATCH_ENGINE_CENSUS_LOADED=1

_dispatch_first_wave_advance_cursor() {
	local slug="$1" cursor_dir="${HOME}/.aidevops/cache" temporary=""
	local name="${2:-pulse-first-wave-cursor}"
	mkdir -p "$cursor_dir" 2>/dev/null || return 0
	temporary=$(mktemp "${cursor_dir}/${name}.XXXXXX") || return 0
	printf '%s\n' "$slug" >"$temporary"
	mv -f "$temporary" "${cursor_dir}/${name}" 2>/dev/null || rm -f "$temporary"
	return 0
}

# GH#33647/GH#34331: rotate the first-wave cursor past every polled
# repository, even if its candidates later fail live dispatch gates, so one
# repository's backlog cannot monopolize every first wave. Lead repositories
# (GH#38022/GH#38200) were polled out of rotation order; they leave the
# cursor where the plain rotation reached. Args: slug, lead field.
_dispatch_first_wave_note_polled() {
	local slug="$1" lead="${2:-}"
	case "$lead" in
	"") _dispatch_first_wave_advance_cursor "$slug" ;;
	arrival:*)
		echo "[pulse-wrapper] First-wave new-arrival lead: repo=${slug} launchable=${lead#arrival:} (GH#38200)" >>"$LOGFILE"
		_dispatch_stats_increment "first_wave_new_arrival_lead"
		;;
	esac
	return 0
}

# GH#34331: whole-second clock for first-wave bounds. Reuses the dispatch
# millisecond clock when loaded so the enumeration budget shares its source.
_dispatch_first_wave_now_s() {
	local now_ms=""
	if declare -F _dispatch_now_ms >/dev/null 2>&1; then
		now_ms=$(_dispatch_now_ms 2>/dev/null) || now_ms=""
	fi
	if [[ "$now_ms" =~ ^[0-9]{1,16}$ ]]; then
		printf '%s\n' "$((now_ms / 1000))"
	else
		date +%s
	fi
	return 0
}

# GH#34331: first-wave census bounds as "<candidate target> <deadline epoch>".
# The target is the free-slot count supplied by _dispatch_enumerate_ranked_round
# (default 1: the GH#33647 first-nonempty-repository behaviour). The budget
# (PULSE_FIRST_WAVE_ENUMERATION_BUDGET_S, default 180s) stays below the 300s
# enumeration estimate floor that first-wave admission already reserves; 0
# restores the GH#33647 first-nonempty-repository scope.
_dispatch_first_wave_bounds() {
	local target="${_PULSE_FIRST_WAVE_CANDIDATE_TARGET:-1}" budget="${PULSE_FIRST_WAVE_ENUMERATION_BUDGET_S:-180}"
	[[ "$target" =~ ^[1-9][0-9]{0,3}$ ]] || target=1
	[[ "$budget" =~ ^[0-9]{1,5}$ ]] || budget=180
	printf '%s %s\n' "$target" "$(($(_dispatch_first_wave_now_s) + 10#$budget))"
	return 0
}

# GH#34331: return 0 when a first-wave census may stop polling repositories:
# it holds fresh candidates for every free slot, or its enumeration budget elapsed.
# Recent failed attempts alone must not hide unscanned fresh work (GH#36712).
# Args: JSONL candidate file (one candidate per line), bounds from above
_dispatch_first_wave_enumeration_done() {
	local candidate_file="$1" bounds="$2" target=1 deadline=0 count=0
	local stamps="" dir=""
	read -r target deadline <<<"$bounds"
	[[ "$target" =~ ^[0-9]+$ && "$deadline" =~ ^[0-9]+$ ]] || return 0
	(($(_dispatch_first_wave_now_s) >= deadline)) && return 0
	count=$(wc -l <"$candidate_file" 2>/dev/null) || count=0
	count="${count//[[:space:]]/}"
	[[ "$count" =~ ^[0-9]+$ ]] || count=0
	if ((count >= target)) && declare -F _dispatch_attempt_recency_stamps >/dev/null 2>&1 &&
		((${_DISPATCH_ATTEMPT_RECENCY_WINDOW_SECONDS:-0} > 0)); then
		dir=$(_dispatch_attempt_recency_dir)
		stamps=$(_dispatch_attempt_recency_stamps "$dir" "$(date +%s)")
		if [[ -n "$stamps" ]]; then
			count=$(jq -s --arg stamps "$stamps" '
				($stamps | split("\n") | map(split("\t")[0])) as $attempted |
				map(select(("\((.repo_slug // "") | sub("/"; "--"))--\(.number // "")") as $key |
					$attempted | index($key) | not)) | length
			' "$candidate_file" 2>/dev/null) || count=0
		fi
	fi
	((count >= target)) && return 0
	(($(_dispatch_first_wave_now_s) >= deadline)) && return 0
	return 1
}

# GH#38274: per-repository adaptive enumeration budget. The fixed GH#38226
# bound (15s) killed every census of large repositories (700+ open issues,
# 500+ auto-dispatch locks), so they contributed zero candidates while
# workers sat idle. A timeout yields nothing, so it raises that repository's
# budget straight to the cap; a completed scan decays it to 1.5x its observed
# cost, never below the base. The census deadline still clamps every scan.
# GH#38543: a repository that times out at the cap escalates above it.
_dispatch_repo_enumeration_budget_file() {
	local repo_slug="$1"
	printf '%s/pulse-repo-enumeration-budget/%s\n' "${HOME}/.aidevops/cache" "${repo_slug//\//--}"
	return 0
}

# Args: base budget seconds. Stdout: cap (PULSE_REPO_ENUMERATION_BUDGET_MAX_S).
_dispatch_repo_enumeration_budget_cap() {
	local base="$1" cap="${PULSE_REPO_ENUMERATION_BUDGET_MAX_S:-60}"
	[[ "$cap" =~ ^[1-9][0-9]{0,2}$ ]] || cap=60
	cap=$((10#$cap))
	((cap >= base)) || cap="$base"
	printf '%s\n' "$cap"
	return 0
}

# GH#38543: a repository whose scans need slightly more than the cap was killed
# at the cap on about half its passes and, once its last-good list expired,
# contributed zero candidates. Such a repository may earn up to this ceiling
# (PULSE_REPO_ENUMERATION_BUDGET_ESCALATED_MAX_S, default 120; a value at or
# below the cap disables escalation). The census remainder still clamps it.
# Args: base budget seconds. Stdout: escalated ceiling (>= cap).
_dispatch_repo_enumeration_budget_escalated_cap() {
	local base="$1" cap=0 ceiling="${PULSE_REPO_ENUMERATION_BUDGET_ESCALATED_MAX_S:-120}"
	cap=$(_dispatch_repo_enumeration_budget_cap "$base")
	[[ "$ceiling" =~ ^[1-9][0-9]{0,2}$ ]] || ceiling=120
	ceiling=$((10#$ceiling))
	((ceiling >= cap)) || ceiling="$cap"
	printf '%s\n' "$ceiling"
	return 0
}

# Stdout: "<stored seconds> <mode>" from the budget file ("0 " when absent).
# Mode "escalated" marks a budget earned above the cap (GH#38543).
_dispatch_repo_enumeration_budget_stored() {
	local file="$1" stored="" mode=""
	if [[ -f "$file" && ! -L "$file" ]]; then
		read -r stored mode <"$file" 2>/dev/null || true
	fi
	[[ "$stored" =~ ^[1-9][0-9]{0,2}$ ]] || stored=0
	[[ "$mode" == escalated ]] || mode=""
	printf '%s %s\n' "$((10#$stored))" "$mode"
	return 0
}

# Args: repo slug, base budget seconds. Stdout: this repository's budget.
_dispatch_repo_enumeration_budget() {
	local repo_slug="$1" base="$2" stored=0 mode="" ceiling=0 file="" limit_file="" limit="" successes=""
	local marker=""
	file=$(_dispatch_repo_enumeration_budget_file "$repo_slug")
	read -r stored mode <<<"$(_dispatch_repo_enumeration_budget_stored "$file")"
	# GH#38548: admission and execution must agree on the reduced-work budget;
	# otherwise the census could defer a retry using an obsolete 120s estimate.
	# GH#38690: a retained snapshot (floor or fixed cost) may escalate again.
	limit_file=$(_dispatch_repo_enumeration_limit_file "$repo_slug")
	if [[ -f "$limit_file" && ! -L "$limit_file" ]]; then
		read -r limit successes marker <"$limit_file" 2>/dev/null || true
		[[ ! "$limit" =~ ^[1-9][0-9]{0,8}$ || "$marker" == retained ]] || mode=""
	fi
	if ((stored > base)); then
		if [[ "$mode" == escalated ]]; then
			ceiling=$(_dispatch_repo_enumeration_budget_escalated_cap "$base")
		else
			ceiling=$(_dispatch_repo_enumeration_budget_cap "$base")
		fi
		((stored <= ceiling)) || stored="$ceiling"
		printf '%s\n' "$stored"
		return 0
	fi
	printf '%s\n' "$base"
	return 0
}

# Args: repo slug, base budget, budget used, scan rc, elapsed seconds.
# Other failures (source unavailable, auth) leave the stored budget unchanged.
# GH#38543: a timeout after the full cap escalates to the escalated ceiling
# (reason=timeout_at_cap). A completed scan that ended within 5s of the cap,
# or ran under an escalated budget, may keep a 1.5x budget up to that ceiling.
_dispatch_record_repo_enumeration_outcome() {
	local repo_slug="$1" base="$2" used="$3" rc="$4" elapsed="$5"
	local file="" cap=0 ceiling=0 next=0 temporary="" stored=0 mode="" next_mode="" reason=timeout limit=0
	[[ "$base" =~ ^[0-9]+$ && "$used" =~ ^[0-9]+$ && "$rc" =~ ^[0-9]+$ && "$elapsed" =~ ^-?[0-9]+$ ]] || return 0
	((elapsed >= 0)) || elapsed=0
	file=$(_dispatch_repo_enumeration_budget_file "$repo_slug")
	cap=$(_dispatch_repo_enumeration_budget_cap "$base")
	ceiling=$(_dispatch_repo_enumeration_budget_escalated_cap "$base")
	read -r stored mode <<<"$(_dispatch_repo_enumeration_budget_stored "$file")"
	if ((rc == 124)); then
		# GH#38483: a scan clamped below the base by the census remainder
		# proves nothing (live: from=1s to=60s); escalating it would make
		# later censuses defer a fast repository.
		((used >= base)) || return 0
		next="$cap"
		if ((used >= cap && ceiling > cap)); then
			next="$ceiling"
			next_mode=escalated
			reason=timeout_at_cap
		fi
		# A timeout clamped by the census remainder never lowers an
		# escalated budget.
		if [[ "$mode" == escalated ]] && ((stored > next)); then
			next="$stored"
			((next <= ceiling)) || next="$ceiling"
			next_mode=escalated
		fi
		((next > used && next != stored)) &&
			echo "[pulse-wrapper] Candidate repository enumeration budget raised: repo=${repo_slug} from=${used}s to=${next}s reason=${reason} (GH#38274)" >>"$LOGFILE"
	elif ((rc == 0)); then
		next=$(((elapsed * 3 + 1) / 2))
		((next >= base)) || next="$base"
		limit="$cap"
		if [[ "$mode" == escalated ]] || ((used >= cap && elapsed + 5 >= cap)); then
			limit="$ceiling"
		fi
		((next <= limit)) || next="$limit"
		((next <= cap)) || next_mode=escalated
		((elapsed <= base)) ||
			echo "[pulse-wrapper] Candidate repository enumeration slow: repo=${repo_slug} elapsed=${elapsed}s budget=${used}s next=${next}s (GH#38274)" >>"$LOGFILE"
	else
		return 0
	fi
	if ((next <= base)); then
		rm -f "$file" 2>/dev/null || true
		return 0
	fi
	mkdir -p "${file%/*}" 2>/dev/null || return 0
	temporary=$(mktemp "${file}.XXXXXX" 2>/dev/null) || return 0
	printf '%s%s\n' "$next" "${next_mode:+ $next_mode}" >"$temporary"
	mv -f "$temporary" "$file" 2>/dev/null || rm -f "$temporary"
	return 0
}

# GH#38226: cap a repository's whole enumeration tree, not just individual
# API calls. Follow _gh_run_bounded_function's portable process-group cleanup
# pattern so a timed-out child cannot retain the command-substitution pipe.
# Args: budget seconds, then the candidate adapter's arguments.
_dispatch_enumerate_repo_bounded() {
	local seconds="$1"
	shift
	local monitor_was_enabled=false pid="" process_group="" remaining=0 rc=0
	[[ $- != *m* ]] || monitor_was_enabled=true
	set -m
	(
		set +m
		pulse_campaign_shadow_candidates_json "$@"
	) &
	pid=$!
	process_group="-${pid}"
	$monitor_was_enabled && set -m || set +m
	remaining=$((seconds * 2))
	# A completed adapter may leave a descendant holding stdout open.
	while kill -0 -- "$process_group" 2>/dev/null; do
		if ((remaining <= 0)); then
			kill -TERM -- "$process_group" 2>/dev/null || true
			sleep 0.2
			kill -KILL -- "$process_group" 2>/dev/null || true
			wait "$pid" 2>/dev/null || true
			return 124
		fi
		sleep 0.5
		remaining=$((remaining - 1))
	done
	wait "$pid" 2>/dev/null || rc=$?
	return "$rc"
}

# GH#38483: a repository's last completed candidate list. A timed-out scan of a
# large backlog otherwise contributed nothing (1-4 fleet candidates instead of
# 120+ while slots idled). Candidates are hints: every one still passes the
# live dispatch gates, and a reused list never proves absence or completeness.
_dispatch_census_last_good_file() {
	local repo_slug="$1"
	printf '%s/pulse-repo-census-last-good/%s.json\n' "${HOME}/.aidevops/cache" "${repo_slug//\//--}"
	return 0
}

# Best effort: an unwritable cache only disables reuse for this repository.
# Args: repo slug, candidate JSON array (passed on stdin to jq, never argv).
_dispatch_census_store_last_good() {
	local repo_slug="$1" candidates="$2" file="" temporary="" now=0
	file=$(_dispatch_census_last_good_file "$repo_slug")
	now=$(_dispatch_first_wave_now_s)
	[[ "$now" =~ ^[0-9]+$ ]] || return 0
	mkdir -p "${file%/*}" 2>/dev/null || return 0
	temporary=$(mktemp "${file}.XXXXXX" 2>/dev/null) || return 0
	# -e fails on non-array input: `arrays` then emits nothing.
	if jq -ce --argjson now "$now" 'arrays | {stored_at: $now, candidates: .}' \
		<<<"$candidates" >"$temporary" 2>/dev/null; then
		mv -f "$temporary" "$file" 2>/dev/null || rm -f "$temporary"
	else
		rm -f "$temporary"
	fi
	return 0
}

# Stdout: PULSE_CENSUS_LAST_GOOD_MAX_AGE_S in seconds (default 3600; 0 disables).
_dispatch_census_last_good_max_age() {
	local max_age="${PULSE_CENSUS_LAST_GOOD_MAX_AGE_S:-3600}"
	[[ "$max_age" =~ ^[0-9]{1,6}$ ]] || max_age=3600
	printf '%s\n' "$((10#$max_age))"
	return 0
}

# Stdout: the fresh stored candidate array, or '[]' when missing, malformed,
# future-dated or older than PULSE_CENSUS_LAST_GOOD_MAX_AGE_S (0 disables).
_dispatch_census_last_good_candidates() {
	local repo_slug="$1" file="" now=0 max_age=0 summary="" age="" count=""
	max_age=$(_dispatch_census_last_good_max_age)
	file=$(_dispatch_census_last_good_file "$repo_slug")
	now=$(_dispatch_first_wave_now_s)
	if ((max_age > 0)) && [[ "$now" =~ ^[0-9]+$ && -f "$file" && ! -L "$file" ]] &&
		summary=$(jq -r --argjson now "$now" --argjson max "$max_age" '
			select((.candidates | arrays | length > 0)
				and (.stored_at | numbers | . <= $now and ($now - .) <= $max))
			| "\($now - .stored_at) \(.candidates | length)"' "$file" 2>/dev/null) && [[ -n "$summary" ]]; then
		read -r age count <<<"$summary"
		echo "[pulse-wrapper] Candidate census reused last-good candidates: repo=${repo_slug} count=${count} age=${age}s (GH#38483)" >>"$LOGFILE"
		jq -c '.candidates' "$file" 2>/dev/null && return 0
	fi
	printf '[]\n'
	return 0
}

# GH#38727: a full census that stops early (deadline or slow-repository
# deferral) contributed nothing for the repositories it did not reach, though
# their last completed lists were minutes old: rounds alternated between 130+
# and 1-5 candidates while slots idled. Unreached repositories now offer their
# fresh last-good candidates without being polled (no poll stamp, no cursor
# advance, no source API read; product discovery stays incomplete). The
# GH#38483 contract holds: every candidate still passes the live dispatch
# gates, and a carried list never proves absence or completeness.
#
# Stdout: a file holding one JSON object that maps "<slug>#<number>" to the
# latest local dispatch epoch from the dispatch ledger ({} when unreadable;
# carried lists are then unfiltered and the live gates still apply).
_dispatch_census_dispatched_index() {
	local ledger="${AIDEVOPS_DISPATCH_LEDGER_FILE:-${AIDEVOPS_DISPATCH_LEDGER_DIR:-${HOME}/.aidevops/.agent-workspace/tmp}/dispatch-ledger.jsonl}"
	local index=""
	index=$(mktemp) || return 1
	if ! [[ -f "$ledger" && ! -L "$ledger" ]] || ! jq -nRc '
		reduce (inputs | fromjson? | objects
			| select((.repo_slug | strings | length > 0) and ((.issue_number // "") | tostring | test("^[0-9]+$")))
			| {key: "\(.repo_slug)#\(.issue_number)", at: (try (.dispatched_at | fromdateiso8601) catch 0)}) as $entry
		({}; .[$entry.key] = ([(.[$entry.key] // 0), $entry.at] | max))' "$ledger" >"$index" 2>/dev/null; then
		printf '{}\n' >"$index"
	fi
	printf '%s\n' "$index"
	return 0
}

# One unreached repository's carried candidates: its fresh last-good list,
# minus issues launched since the list was stored (the snapshot predates
# their claim), with the PR-backlog and capability-cooldown filters reapplied.
# Args: slug, path, pulse-hours start/end, expiry, dispatched index file.
# Stdout: candidate JSON array ('[]' when nothing can be carried).
_dispatch_census_carry_repo() {
	local repo_slug="$1" repo_path="$2" ph_start="$3" ph_end="$4" expires="$5" index="$6"
	local file="" now=0 max_age=0 candidates="[]"
	file=$(_dispatch_census_last_good_file "$repo_slug")
	max_age=$(_dispatch_census_last_good_max_age)
	now=$(_dispatch_first_wave_now_s)
	if ((max_age > 0)) && [[ "$now" =~ ^[0-9]+$ && -f "$file" && ! -L "$file" && -f "$index" ]] &&
		check_repo_pulse_schedule "$repo_slug" "$ph_start" "$ph_end" "$expires" "$REPOS_JSON"; then
		candidates=$(jq -c --argjson now "$now" --argjson max "$max_age" --arg slug "$repo_slug" \
			--slurpfile dispatched "$index" '
			select((.candidates | arrays | length > 0)
				and (.stored_at | numbers | . <= $now and ($now - .) <= $max))
			| .stored_at as $stored | ($dispatched[0] // {}) as $launched
			| [.candidates[] | select(($launched["\($slug)#\(.number)"] // 0) < $stored)]' "$file" 2>/dev/null) || candidates="[]"
	fi
	[[ -n "$candidates" ]] || candidates="[]"
	if [[ "$candidates" != "[]" ]] && declare -F _dispatch_filter_repo_pr_backlog_candidates >/dev/null 2>&1; then
		candidates=$(_dispatch_filter_repo_pr_backlog_candidates "$repo_slug" "$candidates") || candidates="[]"
	fi
	if [[ -n "$candidates" && "$candidates" != "[]" ]] && declare -F _dispatch_filter_capability_cooled_candidates >/dev/null 2>&1; then
		candidates=$(_dispatch_filter_capability_cooled_candidates "$repo_slug" "$repo_path" "$candidates")
	fi
	printf '%s\n' "${candidates:-[]}"
	return 0
}

# Append carried candidates for every repository row from the first one the
# census did not poll to the end of its rotation. Full censuses only: first
# waves have their own bounds, leads and durable remainder.
# Args: census start cursor, first unpolled slug, destination JSONL file,
#   age bonus/day, age bonus cap, current epoch.
_dispatch_census_carry_unreached() {
	local cursor="$1" stopped_at="$2" tmp_candidates="$3" age_bonus_per_day="$4" age_bonus_cap="$5" current_epoch="$6"
	local index="" reached=0 repos=0 count=0 carried="" carried_count=0
	local repo_slug="" repo_path="" repo_priority="" ph_start="" ph_end="" expires="" repo_interval="" repo_lead=""
	index=$(_dispatch_census_dispatched_index) || return 0
	while IFS='|' read -r repo_slug repo_path repo_priority ph_start ph_end expires repo_interval repo_lead; do
		[[ "$reached" == 1 || "$repo_slug" == "$stopped_at" ]] || continue
		reached=1
		[[ -n "$repo_slug" && -n "$repo_path" ]] || continue
		carried=$(_dispatch_census_carry_repo "$repo_slug" "$repo_path" "$ph_start" "$ph_end" "$expires" "$index")
		[[ -n "$carried" && "$carried" != "[]" ]] || continue
		carried_count=$(jq 'length' <<<"$carried" 2>/dev/null) || carried_count=0
		[[ "$carried_count" =~ ^[0-9]+$ ]] || carried_count=0
		repos=$((repos + 1))
		count=$((count + carried_count))
		_append_ranked_repo_candidates "$carried" "$repo_slug" "$repo_path" \
			"$repo_priority" "$age_bonus_per_day" "$age_bonus_cap" "$current_epoch" "$tmp_candidates"
	done < <(_dispatch_repository_rows "$cursor")
	rm -f "$index"
	((count == 0)) ||
		echo "[pulse-wrapper] Candidate census carried last-good candidates: repos=${repos} count=${count} from=${stopped_at} (GH#38727)" >>"$LOGFILE"
	return 0
}

# GH#38548: learn a smaller source snapshot after a full-cap timeout. Successful
# scans retain it briefly, then probe larger snapshots to avoid prefix starvation.
_dispatch_repo_enumeration_limit_file() {
	local repo_slug="$1"
	printf '%s/pulse-repo-enumeration-limit/%s\n' "${HOME}/.aidevops/cache" "${repo_slug//\//--}"
	return 0
}

# GH#38690: the smallest snapshot a reduction may reach. Halving to 1-2 left
# only the newest (claimed or held) issues in the snapshot, so a large backlog
# contributed zero candidates while its scans still timed out. Floor:
# max(requested/8, PULSE_REPO_ENUMERATION_LIMIT_FLOOR (default 25)), never
# above the requested limit.
# Args: requested per-repo limit. Stdout: floor.
_dispatch_repo_enumeration_limit_floor() {
	local requested="$1" floor="${PULSE_REPO_ENUMERATION_LIMIT_FLOOR:-25}" share=0
	[[ "$requested" =~ ^[0-9]{1,9}$ ]] || requested=1
	requested=$((10#$requested))
	[[ "$floor" =~ ^[1-9][0-9]{0,8}$ ]] || floor=25
	floor=$((10#$floor))
	share=$((requested / 8))
	((floor >= share)) || floor="$share"
	((floor <= requested)) || floor="$requested"
	((floor >= 1)) || floor=1
	printf '%s\n' "$floor"
	return 0
}

# A stored limit below the floor (written before GH#38690) is raised to it.
_dispatch_repo_enumeration_limit() {
	local repo_slug="$1" requested="$2" file="" stored="" successes="" floor=0
	file=$(_dispatch_repo_enumeration_limit_file "$repo_slug")
	if [[ -f "$file" && ! -L "$file" ]]; then
		read -r stored successes <"$file" 2>/dev/null || true
	fi
	if [[ "$stored" =~ ^[1-9][0-9]{0,8}$ ]] && ((10#$stored < requested)); then
		floor=$(_dispatch_repo_enumeration_limit_floor "$requested")
		requested=$((10#$stored))
		((requested >= floor)) || requested="$floor"
	fi
	printf '%s\n' "$requested"
	return 0
}

# GH#38690: completed-scan cost per snapshot limit, so a reduction can tell
# limit-proportional cost from fixed cost. One "limit elapsed stored_at" line
# per limit, newest first, at most four limits.
_dispatch_repo_enumeration_cost_file() {
	local repo_slug="$1"
	printf '%s/pulse-repo-enumeration-cost/%s\n' "${HOME}/.aidevops/cache" "${repo_slug//\//--}"
	return 0
}

# Best effort. Args: repo slug, snapshot limit, elapsed seconds.
_dispatch_record_repo_enumeration_cost() {
	local repo_slug="$1" limit="$2" elapsed="$3" now=0 file="" content=""
	local temporary=""
	local sample_limit="" sample_cost="" sample_at="" kept=0
	[[ "$limit" =~ ^[1-9][0-9]{0,8}$ && "$elapsed" =~ ^[0-9]{1,9}$ ]] || return 0
	limit=$((10#$limit))
	now=$(_dispatch_first_wave_now_s)
	[[ "$now" =~ ^[0-9]+$ ]] || return 0
	file=$(_dispatch_repo_enumeration_cost_file "$repo_slug")
	content="${limit} $((10#$elapsed)) ${now}"$'\n'
	if [[ -f "$file" && ! -L "$file" ]]; then
		while read -r sample_limit sample_cost sample_at && ((kept < 3)); do
			[[ "$sample_limit" =~ ^[1-9][0-9]{0,8}$ && "$sample_cost" =~ ^[0-9]{1,9}$ && "$sample_at" =~ ^[0-9]{1,12}$ ]] || continue
			((10#$sample_limit != limit)) || continue
			content+="${sample_limit} ${sample_cost} ${sample_at}"$'\n'
			kept=$((kept + 1))
		done <"$file"
	fi
	mkdir -p "${file%/*}" 2>/dev/null || return 0
	temporary=$(mktemp "${file}.XXXXXX" 2>/dev/null) || return 0
	printf '%s' "$content" >"$temporary"
	mv -f "$temporary" "$file" 2>/dev/null || rm -f "$temporary"
	return 0
}

# GH#38690: succeeds when fresh completed scans show that a timeout at this
# limit is not caused by the snapshot size, so halving it cannot end the
# timeouts. Evidence is a completed scan at this limit or larger that either
# took under three quarters of the timed-out budget (the timeout was variance),
# or took a measurable cost (>= 4s) that a scan at half its limit or less
# matched within a quarter (fixed cost). Samples older than
# PULSE_REPO_ENUMERATION_COST_MAX_AGE_S (default 86400) are ignored.
# Args: repo slug, timed-out limit, budget seconds used by the timed-out scan.
_dispatch_repo_enumeration_cost_is_fixed() {
	local repo_slug="$1" limit="$2" used="$3" file="" now=0 max_age="${PULSE_REPO_ENUMERATION_COST_MAX_AGE_S:-86400}"
	local sample_limit="" sample_cost="" sample_at="" i=0 j=0
	local -a limits=() costs=()
	[[ "$limit" =~ ^[1-9][0-9]{0,8}$ && "$used" =~ ^[0-9]{1,9}$ ]] || return 1
	limit=$((10#$limit))
	used=$((10#$used))
	[[ "$max_age" =~ ^[0-9]{1,7}$ ]] || max_age=86400
	max_age=$((10#$max_age))
	file=$(_dispatch_repo_enumeration_cost_file "$repo_slug")
	[[ -f "$file" && ! -L "$file" ]] || return 1
	now=$(_dispatch_first_wave_now_s)
	[[ "$now" =~ ^[0-9]+$ ]] || return 1
	while read -r sample_limit sample_cost sample_at; do
		[[ "$sample_limit" =~ ^[1-9][0-9]{0,8}$ && "$sample_cost" =~ ^[0-9]{1,9}$ && "$sample_at" =~ ^[0-9]{1,12}$ ]] || continue
		((10#$sample_at <= now && now - 10#$sample_at <= max_age)) || continue
		limits+=("$((10#$sample_limit))")
		costs+=("$((10#$sample_cost))")
	done <"$file"
	for ((i = 0; i < ${#limits[@]}; i++)); do
		((limits[i] >= limit)) || continue
		((costs[i] * 4 >= used * 3)) || return 0
		((costs[i] >= 4)) || continue
		for ((j = 0; j < ${#limits[@]}; j++)); do
			if ((limits[j] * 2 <= limits[i] && costs[j] * 4 >= costs[i] * 3)); then
				return 0
			fi
		done
	done
	return 1
}

# GH#38690: a snapshot kept at the floor or for fixed cost is not newly reduced
# work, so its limit file carries a "retained" marker that lets the budget
# escalate again (_dispatch_repo_enumeration_budget). Only an existing reduced
# limit is marked; an unreduced repository has no limit file to mark.
_dispatch_mark_repo_enumeration_limit_retained() {
	local repo_slug="$1" limit="$2" file=""
	local stored=""
	local successes=""
	local marker=""
	local temporary=""
	file=$(_dispatch_repo_enumeration_limit_file "$repo_slug")
	[[ -f "$file" && ! -L "$file" ]] || return 0
	read -r stored successes marker <"$file" 2>/dev/null || true
	[[ "$marker" != retained || "$stored" != "$limit" ]] || return 0
	[[ "$successes" =~ ^[0-7]$ ]] || successes=0
	temporary=$(mktemp "${file}.XXXXXX" 2>/dev/null) || return 0
	printf '%s %s retained\n' "$limit" "$successes" >"$temporary"
	mv -f "$temporary" "$file" 2>/dev/null || rm -f "$temporary"
	return 0
}

# Args: repo slug, limit that timed out, requested per-repo limit (defaults to
# the timed-out limit), budget seconds the timed-out scan used (default 0).
# GH#38690: never below the floor, and not at all when recorded costs show the
# timeout is not size-driven; the snapshot is then retained.
_dispatch_reduce_repo_enumeration_limit() {
	local repo_slug="$1" limit="$2" requested="${3:-$2}" used="${4:-0}" file="" next=0 floor=0 reason=""
	local temporary=""
	[[ "$limit" =~ ^[1-9][0-9]{0,8}$ ]] || return 0
	limit=$((10#$limit))
	floor=$(_dispatch_repo_enumeration_limit_floor "$requested")
	if ((limit <= floor)); then
		reason=at_floor
	elif _dispatch_repo_enumeration_cost_is_fixed "$repo_slug" "$limit" "$used"; then
		reason=fixed_cost
	fi
	if [[ -n "$reason" ]]; then
		echo "[pulse-wrapper] Candidate repository enumeration limit retained: repo=${repo_slug} limit=${limit} floor=${floor} reason=${reason} (GH#38690)" >>"$LOGFILE"
		_dispatch_mark_repo_enumeration_limit_retained "$repo_slug" "$limit"
		return 0
	fi
	next=$(((limit + 1) / 2))
	((next >= floor)) || next="$floor"
	file=$(_dispatch_repo_enumeration_limit_file "$repo_slug")
	mkdir -p "${file%/*}" 2>/dev/null || return 0
	temporary=$(mktemp "${file}.XXXXXX" 2>/dev/null) || return 0
	printf '%s\n' "$next" >"$temporary"
	if mv -f "$temporary" "$file" 2>/dev/null; then
		echo "[pulse-wrapper] Candidate repository enumeration limit reduced: repo=${repo_slug} from=${limit} to=${next} reason=timeout_at_cap (GH#38548)" >>"$LOGFILE"
	else
		rm -f "$temporary"
	fi
	return 0
}

# Every eight completed reduced scans, double the next snapshot (never beyond
# the caller's limit). The normal time cap still applies; a failed probe halves
# it again and resets this counter. GH#38690: a completed reduced scan that
# yields no candidates has exhausted its prefix, so it doubles immediately.
# Args: repo slug, limit used, requested limit, candidate count (optional).
_dispatch_recover_repo_enumeration_limit() {
	local repo_slug="$1" used="$2" requested="$3" count="${4:-}" file="" stored=""
	local temporary=""
	local successes="" marker=""
	((used < requested)) || return 0
	file=$(_dispatch_repo_enumeration_limit_file "$repo_slug")
	[[ -f "$file" && ! -L "$file" ]] || return 0
	read -r stored successes marker <"$file" 2>/dev/null || true
	[[ "$stored" =~ ^[1-9][0-9]{0,8}$ ]] || return 0
	# A stored limit below the floor was raised to it for this scan.
	((10#$stored <= used)) || return 0
	[[ "$marker" == retained && "$stored" == "$used" ]] || marker=""
	stored="$used"
	[[ "$successes" =~ ^[0-7]$ ]] || successes=0
	successes=$((successes + 1))
	if ((successes == 8)) || [[ "$count" == 0 ]]; then
		stored=$((used * 2))
		((stored <= requested)) || stored="$requested"
		successes=0
		# A larger probe is new reduced work again.
		marker=""
		[[ "$count" != 0 ]] ||
			echo "[pulse-wrapper] Candidate repository enumeration limit probed: repo=${repo_slug} from=${used} to=${stored} reason=empty_prefix (GH#38690)" >>"$LOGFILE"
	fi
	temporary=$(mktemp "${file}.XXXXXX" 2>/dev/null) || return 0
	printf '%s %s%s\n' "$stored" "$successes" "${marker:+ $marker}" >"$temporary"
	mv -f "$temporary" "$file" 2>/dev/null || rm -f "$temporary"
	return 0
}

# GH#38274: scan one repository with its adaptive budget, clamped to the
# remaining census time per call so one escalated budget never leaks.
# GH#38483: a completed scan refreshes the last-good list; a timeout reuses it.
# Args: slug, path, base budget, remaining census seconds, per-repo limit,
#   dependency normalization mode, completeness file.
# Stdout: candidate JSON ('[]' on failure). Returns the scan status.
_dispatch_census_enumerate_repo() {
	local repo_slug="$1" repo_path="$2" base="$3" remaining="$4" per_repo_limit="$5"
	local normalization_mode="$6" completeness_file="$7"
	local budget=0 started=0 rc=0 candidates="" source_limit=0 cap=0 elapsed=0 count=""
	# GH#38825: a configured path that no longer exists defers every candidate
	# with a misleading capability signal. Skip the repo once per pass; no
	# per-issue cooldowns are recorded. Operator: re-clone or set pulse:false.
	if [[ -n "$repo_path" && ! -d "$repo_path" ]]; then
		echo "[pulse-wrapper] repo_path_missing slug=${repo_slug} (configured path absent; re-clone or set pulse:false in repos.json) (GH#38825)" >>"$LOGFILE"
		# An absent path has nothing dispatchable; mark discovery complete so a
		# product repo's held reservation is released to other repositories.
		[[ -z "$completeness_file" ]] || printf '1\n' >"$completeness_file"
		printf '[]\n'
		return 0
	fi
	source_limit=$(_dispatch_repo_enumeration_limit "$repo_slug" "$per_repo_limit")
	cap=$(_dispatch_repo_enumeration_budget_cap "$base")
	budget=$(_dispatch_repo_enumeration_budget "$repo_slug" "$base")
	((remaining >= budget)) || budget="$remaining"
	started=$(_dispatch_first_wave_now_s)
	candidates=$(_dispatch_enumerate_repo_bounded "$budget" "$repo_slug" "$repo_path" "$source_limit" \
		"$normalization_mode" "$completeness_file") || rc=$?
	elapsed=$(($(_dispatch_first_wave_now_s) - started))
	_dispatch_record_repo_enumeration_outcome "$repo_slug" "$base" "$budget" "$rc" "$elapsed"
	if ((rc == 124 && budget >= cap)); then
		_dispatch_reduce_repo_enumeration_limit "$repo_slug" "$source_limit" "$per_repo_limit" "$budget"
	fi
	# A reduced snapshot cannot establish absence across the original scope.
	if ((source_limit < per_repo_limit)) && [[ -n "$completeness_file" ]]; then
		printf '0\n' >"$completeness_file"
	fi
	if ((rc == 0)); then
		# GH#38690: cost per limit tells fixed cost from proportional cost.
		_dispatch_record_repo_enumeration_cost "$repo_slug" "$source_limit" "$elapsed"
		if ((source_limit < per_repo_limit)); then
			count=$(jq -r 'arrays | length' <<<"$candidates" 2>/dev/null) || count=""
		fi
		_dispatch_recover_repo_enumeration_limit "$repo_slug" "$source_limit" "$per_repo_limit" "$count"
		_dispatch_census_store_last_good "$repo_slug" "$candidates"
	else
		echo "[pulse-wrapper] Candidate repository enumeration unavailable: repo=${repo_slug} rc=${rc} budget=${budget}s (GH#38226)" >>"$LOGFILE"
		candidates='[]'
		# Only a timeout: auth, source or rate-limit failures stay empty. The
		# stored list passed the PR-backlog guardrail at scan time; the
		# backlog may have grown since, so reapply it (cached PR list).
		if ((rc == 124)); then
			candidates=$(_dispatch_census_last_good_candidates "$repo_slug")
			if [[ "$candidates" != '[]' ]] && declare -F _dispatch_filter_repo_pr_backlog_candidates >/dev/null 2>&1; then
				candidates=$(_dispatch_filter_repo_pr_backlog_candidates "$repo_slug" "$candidates") || candidates='[]'
			fi
		fi
	fi
	printf '%s\n' "$candidates"
	return "$rc"
}

#######################################
# GH#38483: decide whether the census polls one repository row.
# A known-slow repository (learned budget above the base) reached with less
# census time than it needs stops the census before it is polled: its poll
# stamp and the rotation cursor stay put, so the next census starts with it
# and its full budget instead of a clamped scan that times out. The first
# repository of a census is never deferred, so every census makes progress.
# Full censuses only: first waves order arrival/backlog leads ahead of the
# cursor, so a deferral there could repeat; their clamped scan falls back to
# the fresh last-good list instead.
# Args: slug, priority, pulse-hours start/end, expiry, interval, base budget,
#   remaining census seconds, repositories already polled this census.
# Returns: 0 poll, 1 skip, 2 skip and mark product discovery incomplete,
#   3 stop the census here (product discovery incomplete).
#######################################
_dispatch_census_admit_repo() {
	local repo_slug="$1" repo_priority="$2" ph_start="$3" ph_end="$4" expires="$5"
	local repo_interval="$6" base="$7" remaining="$8" polled="$9" need=0
	check_repo_pulse_schedule "$repo_slug" "$ph_start" "$ph_end" "$expires" "$REPOS_JSON" || return 1
	# Per-repo interval throttle (GH#20660): skip if polled too recently
	if ! check_repo_pulse_interval "$repo_slug" "$repo_interval"; then
		[[ "$repo_priority" != product ]] || return 2
		return 1
	fi
	[[ "${_PULSE_FIRST_DISPATCH_WAVE:-0}" != 1 ]] || return 0
	need=$(_dispatch_repo_enumeration_budget "$repo_slug" "$base")
	if [[ "$polled" =~ ^[0-9]+$ && "$need" =~ ^[0-9]+$ ]] && ((polled > 0 && need > base && remaining < need)); then
		echo "[pulse-wrapper] Candidate census deferred slow repository to the next census: repo=${repo_slug} budget=${need}s remaining=${remaining}s (GH#38483)" >>"$LOGFILE"
		return 3
	fi
	return 0
}

# Total budget applies even to an empty census. Full rounds rotate separately
# from first waves, preventing a slow registry prefix from starving its tail.
_dispatch_census_deadline() {
	local budget="${PULSE_CENSUS_ENUMERATION_BUDGET_S:-180}" first="${PULSE_FIRST_WAVE_ENUMERATION_BUDGET_S:-180}"
	[[ "$budget" =~ ^[1-9][0-9]{0,3}$ ]] || budget=180
	if [[ "${_PULSE_FIRST_DISPATCH_WAVE:-0}" == 1 && "$first" =~ ^[0-9]{1,5}$ ]] && ((10#$first > 0 && 10#$first < budget)); then
		budget=$((10#$first))
	fi
	printf '%s\n' "$(($(_dispatch_first_wave_now_s) + budget))"
	return 0
}

# GH#38730: a repository scan spends most of its time waiting on 5-6
# sequential GitHub reads, so a serial full census of ~25 awake repositories
# reached its 180s deadline in most cycles while slots idled. Full censuses
# now overlap up to PULSE_CENSUS_MAX_PARALLEL scans (default 4, 1 = serial,
# at most 16); bounded because unbounded fan-out (t19041) timed out reads.
# First waves stay serial: they stop as soon as they can fill free slots.
_dispatch_census_parallelism() {
	local parallel="${PULSE_CENSUS_MAX_PARALLEL:-4}"
	[[ "${_PULSE_FIRST_DISPATCH_WAVE:-0}" != 1 ]] || parallel=1
	[[ "$parallel" =~ ^[1-9][0-9]?$ ]] || parallel=4
	parallel=$((10#$parallel))
	((parallel <= 16)) || parallel=16
	printf '%s\n' "$parallel"
	return 0
}

# One census repository scan: enumerate, then apply the pre-ranking filters.
# Results go to <prefix>.json (candidates), <prefix>.complete (product
# completeness) and <prefix>.rc (scan status, written last), so the scan can
# run in the background. Its caches are keyed by slug and replaced atomically.
# Args: output prefix, slug, path, base budget, remaining census seconds,
#   per-repo limit, dependency normalization mode.
_dispatch_census_scan_repo() {
	local prefix="$1" repo_slug="$2" repo_path="$3" base="$4" remaining="$5" limit="$6" mode="$7"
	local candidates="" rc=0
	printf '0\n' >"${prefix}.complete"
	candidates=$(_dispatch_census_enumerate_repo "$repo_slug" "$repo_path" "$base" "$remaining" \
		"$limit" "$mode" "${prefix}.complete") || rc=$?
	# GH#33743: drop unchanged runner_capability_unmet candidates before
	# they count toward the first-wave candidate target.
	if declare -F _dispatch_filter_capability_cooled_candidates >/dev/null 2>&1 &&
		[[ -n "$candidates" && "$candidates" != "[]" ]]; then
		candidates=$(_dispatch_filter_capability_cooled_candidates "$repo_slug" "$repo_path" "$candidates")
	fi
	printf '%s\n' "${candidates:-[]}" >"${prefix}.json"
	printf '%s\n' "$rc" >"${prefix}.rc"
	return 0
}

# Start census scan <index> under <dir>; in the background when parallel.
# <index>.row records "pid|slug|path|priority" for the slot wait and absorb.
# Args: dir, index, parallelism, slug, path, priority, then the scan's base
#   budget, remaining census seconds, per-repo limit and normalization mode.
_dispatch_census_start_scan() {
	local dir="$1" index="$2" parallel="$3" repo_slug="$4" repo_path="$5" repo_priority="$6"
	local pid=""
	shift 6
	if ((parallel > 1)); then
		_dispatch_census_scan_repo "${dir}/${index}" "$repo_slug" "$repo_path" "$@" </dev/null >/dev/null &
		pid="$!"
	else
		_dispatch_census_scan_repo "${dir}/${index}" "$repo_slug" "$repo_path" "$@" </dev/null >/dev/null
	fi
	printf '%s|%s|%s|%s\n' "$pid" "$repo_slug" "$repo_path" "$repo_priority" >"${dir}/${index}.row"
	return 0
}

# Wait until fewer than <parallel> of census scans 1..<launched> still run.
# Returns 1 when the census deadline passes first.
_dispatch_census_wait_for_slot() {
	local dir="$1" launched="$2" parallel="$3" deadline="$4" index=0 live=0 pid="" rest=""
	while true; do
		live=0
		for ((index = 1; index <= launched; index++)); do
			IFS='|' read -r pid rest 2>/dev/null <"${dir}/${index}.row" || continue
			if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
				live=$((live + 1))
			fi
		done
		((live >= parallel)) || return 0
		(($(_dispatch_first_wave_now_s) < deadline)) || return 1
		sleep 0.2
	done
}

# Wait for one background scan. Its clamped budget ends it by the census
# deadline; one still running 30s later is terminated (its missing status
# then counts as a failed scan), so a census can never wait unbounded.
_dispatch_census_await_scan() {
	local pid="$1" deadline="$2"
	while kill -0 "$pid" 2>/dev/null; do
		if (($(_dispatch_first_wave_now_s) >= deadline + 30)); then
			echo "[pulse-wrapper] Candidate census scan outlived the deadline; terminated pid=${pid} (GH#38730)" >>"$LOGFILE"
			kill -TERM "$pid" 2>/dev/null || true
			break
		fi
		sleep 0.2
	done
	wait "$pid" 2>/dev/null || true
	return 0
}

# Absorb census scans <first>..<last> in launch order (waiting for each), so
# ranking input never depends on completion order.
# Args: dir, first, last, census deadline, destination JSONL, bonus/day,
#   bonus cap, epoch.
# Returns flag bits: 1 a scan failed, 2 product discovery incomplete,
#   4 candidates appended.
_dispatch_census_absorb_scans() {
	local dir="$1" first="$2" last="$3" deadline="$4" tmp_candidates="$5" bonus_day="$6" bonus_cap="$7" epoch="$8"
	local index=0 flags=0 pid="" repo_slug="" repo_path="" repo_priority="" rc="" complete="" candidates=""
	for ((index = first; index <= last; index++)); do
		IFS='|' read -r pid repo_slug repo_path repo_priority 2>/dev/null <"${dir}/${index}.row" || continue
		[[ -z "$pid" ]] || _dispatch_census_await_scan "$pid" "$deadline"
		read -r rc 2>/dev/null <"${dir}/${index}.rc" || rc=1
		read -r complete 2>/dev/null <"${dir}/${index}.complete" || complete=0
		[[ "$rc" =~ ^[0-9]+$ ]] || rc=1
		((rc == 0)) || flags=$((flags | 1))
		if [[ "$repo_priority" == product ]] && { ((rc != 0)) || [[ "$complete" != 1 ]]; }; then
			flags=$((flags | 2))
		fi
		candidates='[]'
		[[ ! -f "${dir}/${index}.json" ]] || candidates=$(<"${dir}/${index}.json")
		[[ -n "$candidates" && "$candidates" != "[]" ]] || continue
		_append_ranked_repo_candidates "$candidates" "$repo_slug" "$repo_path" \
			"$repo_priority" "$bonus_day" "$bonus_cap" "$epoch" "$tmp_candidates"
		flags=$((flags | 4))
	done
	return "$flags"
}
