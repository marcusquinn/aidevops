#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
# Sourced by terminal-blocker-recovery-helper.sh (GH#39539 file split).
# Supervisor pending pass: discovery stages, tiered queue scan and parking.
# Functions moved verbatim; shared TBR_* state lives in the orchestrator.

# Include guard
[[ -n "${_TBR_PENDING_LIB_LOADED:-}" ]] && return 0
_TBR_PENDING_LIB_LOADED=1

# Seed, holds and unclassified discovery stages of a supervisor pending pass.
# Returns 1 when any stage was incomplete. Runs inside tbr_pending's scope.
_tbr_pending_discovery_stages() {
	local rc=0 incomplete=0
	_tbr_run_stage seed tbr_seed || rc=$?
	[[ "$rc" -eq 0 ]] || incomplete=1
	# GH#38311: maintainer replies and unexplained hold-for-review holds,
	# before the six-hourly unclassified stage: a reply wants a fast answer.
	rc=0
	_tbr_run_stage holds tbr_discover_holds || rc=$?
	[[ "$rc" -eq 0 ]] || incomplete=1
	# GH#37978: bare status:blocked holds with no recorded reason.
	rc=0
	_tbr_run_stage unclassified tbr_discover_unclassified || rc=$?
	[[ "$rc" -eq 0 ]] || incomplete=1
	[[ "$incomplete" -eq 0 ]] || return 1
	return 0
}

# GH#39010: classify the queue once per run (tier 1 = standing human_decision).
# When any entry is decided, tier 0 ends early enough to leave tier 1 about a
# quarter of the remaining queue window; tier 1 also gets whatever tier 0 does
# not use. Without this, a tier 0 that never finishes inside the window meant
# tier 1 was never scanned, so replies, policy changes and trusted retries on
# decided holds could never wake them. Two batched jq reads (queue identities,
# then decision wakes) keep the prepass at a constant process count: on a
# 129-entry queue they take ~40ms where per-entry reads took ~1.5s, which the
# old per-tier scan repeated on every traversal. An unreadable file falls back
# to the per-entry check, never to a guessed tier. Runs inside the scope of
# _tbr_pending_scan_queue (decided_set, tier0_deadline); returns 1 when the
# full-window marker cannot be cleared.
_tbr_pending_classify() {
	local file="" share=0 ids="" wakes="" decided_paths=";" i=0
	local name repo issue
	local -a files=() names=() decisions=()
	decided_set=";"
	tier0_deadline="$TBR_QUEUE_DEADLINE"
	for file in "${TBR_ROOT}"/queue/*.json; do
		[[ ! -f "$file" ]] || files+=("$file")
	done
	[[ "${#files[@]}" -gt 0 ]] || return 0
	if ids=$(jq -r '[(input_filename | split("/") | last), (.repo // "" | tostring),
		(.issue // "" | tostring)] | @tsv' "${files[@]}" 2>/dev/null); then
		while IFS=$'\t' read -r name repo issue; do
			[[ -n "$name" && -n "$repo" && -n "$issue" ]] || continue
			# Same key as _tbr_key, without a subshell per entry.
			file="${TBR_ROOT}/decisions/${repo//\//--}--${issue}.json"
			[[ -f "$file" ]] || continue
			names+=("$name")
			decisions+=("$file")
		done <<<"$ids"
	else
		for file in "${files[@]}"; do
			! _tbr_entry_decided "$file" || decided_set+="${file##*/};"
		done
	fi
	if [[ "${#decisions[@]}" -gt 0 ]]; then
		if wakes=$(jq -r 'select(.wake == "human_decision" or .wake == "external_trigger") | input_filename' "${decisions[@]}" 2>/dev/null); then
			while IFS= read -r file; do
				[[ -z "$file" ]] || decided_paths+="${file};"
			done <<<"$wakes"
			for i in "${!names[@]}"; do
				case "$decided_paths" in *";${decisions[$i]};"*) decided_set+="${names[$i]};" ;; esac
			done
		else
			for name in "${names[@]}"; do
				! _tbr_entry_decided "${TBR_ROOT}/queue/${name}" || decided_set+="${name};"
			done
		fi
	fi
	[[ "$decided_set" != ";" ]] || return 0
	_tbr_pending_reserve || return 1
	return 0
}

# Set tier0_deadline for a run with decided entries (scope as above). Each tier
# gets at least one second once two remain; a lone second goes to tier 0. A
# tier-0 entry cut short by the reservation last run parked the rotation just
# before itself, and this run gives tier 0 the whole window so that entry can
# finish (an entry needing more than the tier-0 share would otherwise time out
# on every run). A --count probe only reads the marker, leaving it for the
# pending pass that acts on the entry.
_tbr_pending_reserve() {
	local marker="${TBR_ROOT}/${cursor_name}_full_window" remaining=0 share=0
	if [[ -f "$marker" ]]; then
		[[ "$mode" == --count ]] || rm -f "$marker" || return 1
		printf 'blocker-recovery: queue tier=0 full window (entry cut short by the decided-tier share last run)\n' >&2
		return 0
	fi
	remaining=$((TBR_QUEUE_DEADLINE - SECONDS))
	[[ "$remaining" -ge 2 ]] || return 0
	share=$((remaining / 4))
	[[ "$share" -ge 1 ]] || share=1
	tier0_deadline=$((TBR_QUEUE_DEADLINE - share))
	return 0
}

# Budget stop for _tbr_pending_scan_tier (its scope: incomplete). Returns 4 when
# tier 0 reached the share reserved for tier 1, 3 when the queue window is spent.
_tbr_pending_tier_stop() {
	local deadline="$1" queue_deadline="$2"
	if [[ "$deadline" -lt "$queue_deadline" ]]; then
		printf 'blocker-recovery: incomplete stage=queue reason=budget_exhausted tier=0 (decided-tier share reserved)\n' >&2
		return 4
	fi
	incomplete=1
	printf 'blocker-recovery: incomplete stage=queue reason=budget_exhausted\n' >&2
	return 3
}

# Scan one queue tier for tbr_pending; runs inside its scope (mode, entry_mode,
# cursor_name, count, incomplete, observed, self_resolved, decided_set,
# tier0_deadline). Resume in sorted order, then wrap, skipping entries already
# observed this run. Advance only the scan cursor, never queue ownership or
# decisions, even when a stage times out.
# Returns 0 when scanned, 4 when tier 0 reached its share (continue with tier
# 1; the final unobserved-entry check marks the run incomplete), 3 when the
# queue budget or identity stopped the pass (incomplete is set), 2 when a
# cursor could not be written.
_tbr_pending_scan_tier() {
	local tier="$1"
	local tier_cursor_name="$cursor_name" cursor="" file="" name="" pass=0 decided=0 rc=0 saved="" before="" hold=0
	local queue_deadline="$TBR_QUEUE_DEADLINE" deadline="$TBR_QUEUE_DEADLINE"
	[[ "$tier" -ne 0 ]] || deadline="$tier0_deadline"
	# GH#39010: identity and entry stages read TBR_QUEUE_DEADLINE; shadow it so
	# a tier-0 call cannot run on into the share reserved for tier 1.
	local TBR_QUEUE_DEADLINE="$deadline"
	[[ "$tier" -eq 0 ]] || tier_cursor_name="${cursor_name}_decided"
	[[ ! -f "${TBR_ROOT}/${tier_cursor_name}" ]] || read -r cursor <"${TBR_ROOT}/${tier_cursor_name}" || true
	# GH#39006: --count only probes for the trigger. It shares this cursor
	# with the supervisor's pending pass, so it stops the cursor just before
	# the first entry it counts; that pass then starts with that entry.
	saved="$cursor"
	for pass in 1 2; do
		for file in "${TBR_ROOT}"/queue/*.json; do
			[[ -f "$file" ]] || continue
			name="${file##*/}"
			decided=0
			case "$decided_set" in *";${name};"*) decided=1 ;; esac
			[[ "$decided" -eq "$tier" ]] || continue
			case "$observed" in *";${name};"*) continue ;; esac
			if [[ "$pass" -eq 1 ]]; then
				[[ "${file##*/}" > "$cursor" ]] || continue
			else
				[[ "${file##*/}" > "$cursor" ]] && continue
			fi
			if [[ "$SECONDS" -ge "$deadline" ]]; then
				_tbr_pending_tier_stop "$deadline" "$queue_deadline"
				return $?
			fi
			# GH#33025: resolve once, only when work exists, so this runner's own
			# collaborator-authored circuits stay recognised during recovery.
			if [[ "$self_resolved" -eq 0 && -z "${TERMINAL_BLOCKER_SELF_LOGIN:-}" ]]; then
				TERMINAL_BLOCKER_SELF_LOGIN=$(_tbr_run_stage identity _tbr_self_login) || {
					# A tier-0 budget stop yields to tier 1, which retries identity.
					if [[ "$SECONDS" -ge "$deadline" ]]; then
						_tbr_pending_tier_stop "$deadline" "$queue_deadline"
						return $?
					fi
					incomplete=1
					return 3
				}
				export TERMINAL_BLOCKER_SELF_LOGIN
				# Identity may have spent the rest of this tier's time.
				if [[ "$SECONDS" -ge "$deadline" ]]; then
					_tbr_pending_tier_stop "$deadline" "$queue_deadline"
					return $?
				fi
			fi
			self_resolved=1
			if [[ "$mode" != --rearm-only ]]; then
				_tbr_pending_prefetch "$file"
			fi
			if [[ "$hold" -eq 0 ]]; then
				before="$saved"
				_tbr_save_cursor "$tier_cursor_name" "${file##*/}" || return 2
				saved="${file##*/}"
			fi
			observed+="${file##*/};"
			rc=0
			if [[ "$mode" == "--count" ]]; then
				_tbr_run_stage entry _tbr_check_entry "$file" "" "$issue_batch_file" >/dev/null || rc=$?
				if [[ "$rc" -eq 0 && "$hold" -eq 0 ]]; then
					_tbr_restore_cursor "$tier_cursor_name" "$before" || return 2
					hold=1
				fi
			else
				_tbr_run_stage entry _tbr_check_entry "$file" "$entry_mode" "$issue_batch_file" || rc=$?
			fi
			[[ "$rc" -ne 0 ]] || count=$((count + 1))
			[[ "$rc" -lt 2 ]] || incomplete=1
			# GH#39010: the reservation, not the queue window, cut this entry short.
			if [[ "$rc" -ge 2 && "$deadline" -lt "$queue_deadline" && "$SECONDS" -ge "$deadline" ]]; then
				_tbr_pending_park "$tier_cursor_name" "$before" "$hold" "$name" || return 2
				_tbr_pending_tier_stop "$deadline" "$queue_deadline"
				return $?
			fi
		done
	done
	return 0
}

# Prefetch at most four upcoming entries in this tier's existing rotation. A
# failed or truncated batch falls back to individual reads; it never advances
# a cursor, observes an entry or supplies absence evidence. Dynamic scan scope.
_tbr_pending_prefetch() {
	local current="$1" candidate="" name="" refs="" repo="" issue="" round=0 token=""
	local -a args=()
	[[ -n "$issue_batch_file" && "$issue_batch_failed" -eq 0 ]] || return 0
	if jq -e --arg name "${current##*/}" '
		keys | any(. + ".json" == ($name | ascii_downcase))' "$issue_batch_file" >/dev/null 2>&1; then
		return 0
	fi
	for round in 1 2; do
		for candidate in "${TBR_ROOT}"/queue/*.json; do
			[[ -f "$candidate" ]] || continue
			name="${candidate##*/}"
			if [[ "$round" -eq 1 ]]; then
				[[ "$candidate" < "$current" ]] && continue
			else
				[[ "$candidate" < "$current" ]] || continue
			fi
			token=";${candidate##*/};"
			case "$observed" in *"$token"*) continue ;; esac
			case "$decided_set" in
			*"$token"*) [[ "$tier" -eq 1 ]] || continue ;;
			*) [[ "$tier" -eq 0 ]] || continue ;;
			esac
			refs=$(jq -r '[.repo, (.issue | tostring)] | @tsv' "$candidate" 2>/dev/null) || continue
			IFS=$'\t' read -r repo issue <<<"$refs"
			_tbr_valid_ref "$repo" "$issue" || continue
			args+=("$repo" "$issue")
			[[ "${#args[@]}" -lt 8 ]] || break
		done
		[[ "${#args[@]}" -lt 8 ]] || break
	done
	if [[ "${#args[@]}" -gt 0 ]]; then
		if ! _tbr_run_stage issue_batch terminal_blocker_fetch_issue_batch "${args[@]}" >"$issue_batch_file"; then
			: >"$issue_batch_file"
			issue_batch_failed=1
		fi
	fi
	return 0
}

# Park the tier-0 rotation just before an entry the reservation cut short and
# mark the next run for the whole window (see _tbr_pending_reserve). A held
# --count cursor already sits before an earlier counted entry; leave it. Runs
# inside _tbr_pending_scan_queue's scope (parked); returns 1 on a write failure.
_tbr_pending_park() {
	local tier_cursor_name="$1" before="$2" hold="$3" name="$4"
	if [[ "$hold" -eq 0 ]]; then
		_tbr_restore_cursor "$tier_cursor_name" "$before" || return 1
	fi
	_tbr_save_cursor "${cursor_name}_full_window" "$name" || return 1
	parked=1
	printf 'blocker-recovery: queue tier=0 parked entry=%s for a full window next run\n' "$name" >&2
	return 0
}

# t19170: changed-first rearm. Check the holds discovery listed as changed
# (_tbr_note_changed_entries) before the rotation, so a trusted retry or reply
# applies on the next pass, not hours later when a long queue's rotation
# reaches it. Ordering only: _tbr_check_entry still decides every release. At
# most half the remaining window, so backoff expiry and closed dependencies,
# which leave updated_at unchanged, still advance in the rotation. Moves no
# cursor. Unreached entries and quick read failures stay listed; an entry this
# share cut short returns to the rotation. Runs inside tbr_pending's scope
# (entry_mode, count, incomplete, observed, self_resolved); returns 1 when the
# list cannot be rewritten.
_tbr_pending_scan_changed() {
	local list="${TBR_ROOT}/changed_entries" name="" rc=0 keep="" deadline=0
	[[ "$entry_mode" == rearm && -s "$list" ]] || return 0
	deadline=$((SECONDS + (TBR_QUEUE_DEADLINE - SECONDS) / 2))
	local TBR_QUEUE_DEADLINE="$deadline"
	# Same identity rule as the tier scan; unresolved leaves the list intact.
	if [[ "$self_resolved" -eq 0 && -z "${TERMINAL_BLOCKER_SELF_LOGIN:-}" ]]; then
		TERMINAL_BLOCKER_SELF_LOGIN=$(_tbr_run_stage identity _tbr_self_login) || return 0
		export TERMINAL_BLOCKER_SELF_LOGIN
	fi
	self_resolved=1
	while IFS= read -r name; do
		[[ "$name" =~ ^[A-Za-z0-9_.-]+--[1-9][0-9]*\.json$ && -f "${TBR_ROOT}/queue/${name}" ]] || continue
		# Appends can repeat a name; check each once.
		case "$observed" in *";$name;"*) continue ;; esac
		if [[ "$SECONDS" -ge "$deadline" ]]; then
			keep+="${name}"$'\n'
			continue
		fi
		printf 'blocker-recovery: queue changed-first entry=%s\n' "$name" >&2
		observed+="${name};"
		rc=0
		_tbr_run_stage entry _tbr_check_entry "${TBR_ROOT}/queue/${name}" "$entry_mode" || rc=$?
		[[ "$rc" -ne 0 ]] || count=$((count + 1))
		[[ "$rc" -ge 2 ]] || continue
		incomplete=1
		[[ "$SECONDS" -ge "$deadline" ]] || keep+="${name}"$'\n'
	done <"$list"
	if [[ -z "$keep" ]]; then
		rm -f "$list" || return 1
		return 0
	fi
	printf '%s' "$keep" >"${list}.tmp.$$" || return 1
	mv -f "${list}.tmp.$$" "$list" || return 1
	return 0
}

# GH#38692: tier 0 = entries without a standing human_decision, tier 1 =
# decided ones; each tier rotates with its own cursor. GH#39010: when tier 0
# stops at its share and tier 1 finishes early, tier 0 resumes in the time
# left, so the reservation never idles. A --count probe that already counted
# a tier-0 entry does not resume: its cursor stays held at that entry
# (GH#39006). Nor does a run that parked a cut-short entry: resuming would
# move the cursor past it. Runs inside tbr_pending's scope; returns 1 when a
# cursor or marker could not be written.
_tbr_pending_scan_queue() {
	local issue_batch_file="" issue_batch_failed=0 result=0
	# Per-pass scratch only; no persisted freshness assumption or live decisions.
	issue_batch_file=$(mktemp "${TBR_ROOT}/.issue-batch.XXXXXX") || return 1
	_tbr_pending_scan_queue_inner || result=$?
	rm -f "$issue_batch_file" || return 1
	return "$result"
}

_tbr_pending_scan_queue_inner() {
	local tier=0 scan_rc=0 tier0_rc=0 count_before="$count" tier0_counted=0 decided_set=";" tier0_deadline="" parked=0
	_tbr_pending_scan_changed || return 1
	_tbr_pending_classify || return 1
	for tier in 0 1; do
		scan_rc=0
		_tbr_pending_scan_tier "$tier" || scan_rc=$?
		[[ "$scan_rc" -ne 2 ]] || return 1
		if [[ "$tier" -eq 0 ]]; then
			tier0_rc="$scan_rc"
			tier0_counted=$((count - count_before))
		fi
		[[ "$scan_rc" -eq 0 || "$scan_rc" -eq 4 ]] || return 0
	done
	[[ "$tier0_rc" -eq 4 && "$parked" -eq 0 && "$SECONDS" -lt "$TBR_QUEUE_DEADLINE" ]] || return 0
	[[ "$mode" != --count || "$tier0_counted" -eq 0 ]] || return 0
	tier0_deadline="$TBR_QUEUE_DEADLINE"
	scan_rc=0
	_tbr_pending_scan_tier 0 || scan_rc=$?
	[[ "$scan_rc" -ne 2 ]] || return 1
	return 0
}

tbr_pending() {
	local mode="${1:-}"
	local cursor_name=pending_cursor entry_mode=""
	if [[ "$mode" == --rearm-only ]]; then
		cursor_name=rearm_cursor
		entry_mode=rearm
	fi
	_tbr_init_dirs || return 1
	local TBR_DEADLINE="" TBR_QUEUE_DEADLINE="" TBR_SEED_DEADLINE="" file="" count=0 self_resolved=0 rc=0 incomplete=0 reserve=0 unclassified_reserve=0 observed=";"
	_tbr_start_budget || return 2
	# Retire stale fixtures before any identity/API call, including entries past
	# the remote scan budget. Never retire evidence on an unreadable registry.
	for file in "${TBR_ROOT}"/queue/*.json; do
		[[ -f "$file" ]] || continue
		rc=0
		_tbr_entry_registered "$file" || rc=$?
		[[ "$rc" -lt 2 ]] || return 2
	done
	# GH#38232: reserve one stage cap each for seed and unclassified (still at
	# most half the budget), so a slow seed cannot starve unclassified intake.
	reserve=$((TBR_BUDGET_SECONDS / 2))
	[[ "$reserve" -le $((TBR_STAGE_SECONDS * 2)) ]] || reserve=$((TBR_STAGE_SECONDS * 2))
	unclassified_reserve=$((reserve / 2))
	TBR_QUEUE_DEADLINE=$((TBR_DEADLINE - reserve))
	TBR_SEED_DEADLINE=$((TBR_DEADLINE - unclassified_reserve))
	[[ "$mode" != --rearm-only ]] || TBR_QUEUE_DEADLINE="$TBR_DEADLINE"
	# GH#36114: discover unqueued holds first, so a trusted retry on a hold this
	# runner never queued is applied by the queue pass below in the same run.
	# Its own cap leaves the queue at least half the budget.
	if [[ "$mode" == --rearm-only ]]; then
		rc=0
		_tbr_run_stage discovery tbr_discover || rc=$?
		[[ "$rc" -eq 0 ]] || incomplete=1
	fi
	_tbr_pending_scan_queue || return 2
	# Existing ownership is observed before potentially slow remote discovery.
	# Seed has its own stage cap and cannot consume more than the overall budget.
	if [[ "$mode" != --rearm-only ]]; then
		_tbr_pending_discovery_stages || incomplete=1
	fi
	for file in "${TBR_ROOT}"/queue/*.json; do
		[[ -f "$file" ]] || continue
		case "$observed" in *";${file##*/};"*) continue ;; esac
		printf 'blocker-recovery: incomplete stage=queue reason=unobserved_entries\n' >&2
		incomplete=1
		break
	done
	[[ "$mode" == "--count" ]] && printf '%s\n' "$count"
	[[ "$incomplete" -eq 0 ]] || return 2
	return 0
}
