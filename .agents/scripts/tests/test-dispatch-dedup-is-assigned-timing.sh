#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# GH#38180: layer-6 assignee guard latency contract.
#
#   1. A complete ISSUE_META_JSON snapshot skips the issue-metadata read in
#      is-assigned; a missing or incomplete snapshot falls back to the read.
#      Both paths return identical verdicts for the unassigned, owner-passive,
#      assigned and stale-recovered fixtures. The stale-assignment ownership
#      read stays live either way.
#   2. Under a dispatcher stage context, is-assigned records dedup.layer6.*
#      sub-gate rows; without that context it records nothing.
#   3. AIDEVOPS_DDH_BLOCKER_REASON_FILE receives the same reason that
#      classify-blocker prints, only for a private regular file.
#   4. _dedup_layer6_assignee_and_stale uses that reason instead of starting
#      a second helper process, and falls back to classify-blocker without it.

set -uo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
SCRIPTS_DIR="$(cd "${TEST_DIR}/.." && pwd)" || exit 1
HELPER="${SCRIPTS_DIR}/dispatch-dedup-helper.sh"

TESTS_RUN=0
TESTS_FAILED=0

pass() {
	local name="$1"
	TESTS_RUN=$((TESTS_RUN + 1))
	printf 'PASS %s\n' "$name"
	return 0
}

fail() {
	local name="$1"
	local detail="${2:-}"
	TESTS_RUN=$((TESTS_RUN + 1))
	TESTS_FAILED=$((TESTS_FAILED + 1))
	printf 'FAIL %s\n' "$name"
	[[ -n "$detail" ]] && printf '  %s\n' "$detail"
	return 0
}

TMP_DIR="$(mktemp -d -t is-assigned-timing.XXXXXX)" || exit 1
trap 'rm -rf "$TMP_DIR"' EXIT

export HOME="${TMP_DIR}/home"
mkdir -p "${HOME}/.config/aidevops" "${HOME}/.aidevops/logs" "${TMP_DIR}/bin" "${TMP_DIR}/stub"
export PATH="${TMP_DIR}/bin:${PATH}"
export REPOS_JSON="${HOME}/.config/aidevops/repos.json"
printf '%s\n' '{"initialized_repos":[{"slug":"owner/repo","maintainer":"owner"}]}' >"$REPOS_JSON"
export AIDEVOPS_DISPATCH_STAGES_LOG="${TMP_DIR}/stages.tsv"
export GH_STUB_DIR="${TMP_DIR}/stub"
export GH_STUB_CALLS="${TMP_DIR}/gh-calls.log"
export LOGFILE="${TMP_DIR}/pulse.log"
unset ISSUE_META_JSON AIDEVOPS_DISPATCH_STAGE_ISSUE AIDEVOPS_DISPATCH_STAGE_REPO AIDEVOPS_DDH_BLOCKER_REASON_FILE

# Static gh stub: serves issue metadata and comments from fixture files and
# logs every invocation so the test can count issue-metadata reads.
cat >"${TMP_DIR}/bin/gh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$GH_STUB_CALLS"
meta="${GH_STUB_DIR}/meta.json"
comments="${GH_STUB_DIR}/comments.json"
if [[ "${1:-}" == "issue" && "${2:-}" == "view" ]]; then
	cat "$meta"
	exit 0
fi
if [[ "${1:-}" == "issue" || "${1:-}" == "label" ]]; then
	exit 0
fi
if [[ "${1:-}" == "pr" ]]; then
	printf '[]\n'
	exit 0
fi
if [[ "${1:-}" == "api" ]]; then
	shift
	endpoint="" jq_expr=""
	while [[ "$#" -gt 0 ]]; do
		case "$1" in
		--jq | -q) jq_expr="${2:-}"; shift 2 ;;
		-X | --method | -f | -F | --field | --raw-field | -H | --header | --input) shift 2 ;;
		-*) shift ;;
		*) [[ -z "$endpoint" ]] && endpoint="$1"; shift ;;
		esac
	done
	endpoint="${endpoint#/}"
	endpoint="${endpoint%%\?*}"
	out=""
	case "$endpoint" in
	rate_limit) out='{"resources":{"core":{"remaining":5000,"limit":5000,"reset":0},"graphql":{"remaining":5000,"limit":5000,"reset":0}}}' ;;
	repos/*/issues/*/comments) out="[$(cat "$comments")]" ;;
	repos/*/issues/*/timeline) out='[[]]' ;;
	repos/*/issues/[0-9]*)
		out=$(jq -c '{state: (.state | ascii_downcase), title: "", body: "",
			labels: .labels, assignees: .assignees,
			created_at: .createdAt, updated_at: (.updatedAt // .createdAt)}' "$meta") ;;
	*) out='[]' ;;
	esac
	if [[ -n "$jq_expr" ]]; then
		printf '%s\n' "$out" | jq -c "$jq_expr" 2>/dev/null || printf '%s\n' "$out"
	else
		printf '%s\n' "$out"
	fi
	exit 0
fi
exit 0
EOF
chmod +x "${TMP_DIR}/bin/gh"

iso_ago() {
	local seconds="$1"
	date -u -d "@$(($(date -u +%s) - seconds))" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null ||
		date -u -r "$(($(date -u +%s) - seconds))" +%Y-%m-%dT%H:%M:%SZ
	return 0
}

OLD_TS="$(iso_ago 864000)"
RECENT_TS="$(iso_ago 60)"
STALE_TS="$(iso_ago 86400)"

# Args: fixture name. Writes meta.json and comments.json.
write_fixture() {
	local fixture="$1"
	local assignees='[]' labels='[{"name":"auto-dispatch"}]' comments='[]'
	case "$fixture" in
	unassigned) ;;
	owner_passive) assignees='[{"login":"owner"}]' ;;
	assigned)
		assignees='[{"login":"peer1"}]'
		labels='[{"name":"auto-dispatch"},{"name":"status:in-progress"}]'
		comments=$(jq -nc --arg ts "$RECENT_TS" '[{id: 1, created_at: $ts, user: {login: "peer1"},
			author_association: "MEMBER", body: "Dispatching worker (PID 12345)"}]')
		;;
	stale)
		assignees='[{"login":"peer1"}]'
		labels='[{"name":"auto-dispatch"},{"name":"status:in-progress"}]'
		comments=$(jq -nc --arg ts "$STALE_TS" '[{id: 1, created_at: $ts, user: {login: "peer1"},
			author_association: "MEMBER", body: "Dispatching worker (PID 12345)"}]')
		;;
	hold) labels='[{"name":"auto-dispatch"},{"name":"hold-for-review"}]' ;;
	esac
	jq -nc --argjson a "$assignees" --argjson l "$labels" --arg c "$OLD_TS" --arg u "$STALE_TS" \
		'{state: "OPEN", assignees: $a, labels: $l, createdAt: $c, updatedAt: $u}' >"${GH_STUB_DIR}/meta.json"
	printf '%s\n' "$comments" >"${GH_STUB_DIR}/comments.json"
	return 0
}

# Count issue-metadata reads (GraphQL view or REST issue object) in the log.
metadata_reads() {
	local count=0
	[[ -f "$GH_STUB_CALLS" ]] || {
		printf '0'
		return 0
	}
	count=$(grep -cE '^issue view|^api /?repos/[^/]+/[^/]+/issues/[0-9]+($|[ ?])' "$GH_STUB_CALLS" 2>/dev/null) || count=0
	printf '%s' "$count"
	return 0
}

RUN_RC=0
RUN_OUT=""
RUN_READS=0
# Args: fixture, snapshot mode (complete|incomplete|none)
run_is_assigned() {
	local fixture="$1" mode="$2" snapshot=""
	write_fixture "$fixture"
	: >"$GH_STUB_CALLS"
	case "$mode" in
	complete) snapshot=$(cat "${GH_STUB_DIR}/meta.json") ;;
	incomplete) snapshot=$(jq -c 'del(.assignees)' "${GH_STUB_DIR}/meta.json") ;;
	esac
	RUN_RC=0
	if [[ -n "$snapshot" ]]; then
		RUN_OUT=$(ISSUE_META_JSON="$snapshot" "$HELPER" is-assigned 123 owner/repo runner 2>/dev/null) || RUN_RC=$?
	else
		RUN_OUT=$("$HELPER" is-assigned 123 owner/repo runner 2>/dev/null) || RUN_RC=$?
	fi
	RUN_READS=$(metadata_reads)
	return 0
}

# Strip volatile ages so two runs of the same fixture compare equal.
normalize_signal() {
	local signal="$1"
	printf '%s' "$signal" | sed -E 's/[0-9]+s old/Ns old/g'
	return 0
}

test_snapshot_skips_metadata_read() {
	local fixture expected_rc snap_rc snap_out snap_reads live_rc live_out live_reads
	for fixture in unassigned:1 owner_passive:1 assigned:0 stale:1; do
		expected_rc="${fixture#*:}"
		fixture="${fixture%%:*}"
		run_is_assigned "$fixture" complete
		snap_rc="$RUN_RC" snap_out="$RUN_OUT" snap_reads="$RUN_READS"
		run_is_assigned "$fixture" none
		live_rc="$RUN_RC" live_out="$RUN_OUT" live_reads="$RUN_READS"
		if [[ "$snap_rc" != "$expected_rc" || "$live_rc" != "$expected_rc" ]]; then
			fail "verdict for ${fixture}" "expected rc=${expected_rc} snapshot rc=${snap_rc} live rc=${live_rc} snapshot=${snap_out} live=${live_out}"
			continue
		fi
		if [[ "$(normalize_signal "$snap_out")" != "$(normalize_signal "$live_out")" ]]; then
			fail "signal for ${fixture} matches with and without snapshot" "snapshot=${snap_out} live=${live_out}"
			continue
		fi
		# The snapshot replaces exactly the load_meta read. Fixtures with a
		# blocking assignee keep the stale-assignment ownership read live.
		if [[ "$live_reads" -ne $((snap_reads + 1)) ]]; then
			fail "snapshot skips only the load_meta read for ${fixture}" "snapshot reads=${snap_reads} live reads=${live_reads}"
			continue
		fi
		case "$fixture" in
		unassigned | owner_passive)
			if [[ "$snap_reads" -ne 0 ]]; then
				fail "snapshot makes no metadata read for ${fixture}" "reads=${snap_reads}"
				continue
			fi
			;;
		esac
		pass "${fixture}: rc=${expected_rc}, same signal, snapshot skips the metadata read"
	done
	return 0
}

# The static stub cannot reflect recovery writes, so the post-write
# verification fails closed (STALE_RECOVERY_UNCERTAIN). Reaching that path
# proves the snapshot run made the same staleness decision as the live run;
# recovery semantics are covered by test-dispatch-dedup-stale-no-worker.sh.
test_stale_fixture_recovers() {
	run_is_assigned stale complete
	if [[ "$RUN_RC" -ne 1 || "$RUN_OUT" != STALE_* ]]; then
		fail "stale fixture reaches stale recovery" "rc=${RUN_RC} output=${RUN_OUT}"
		return 0
	fi
	pass "stale fixture reaches stale recovery from the snapshot"
	return 0
}

test_incomplete_snapshot_falls_back() {
	run_is_assigned unassigned incomplete
	if [[ "$RUN_RC" -ne 1 || "$RUN_READS" -lt 1 ]]; then
		fail "incomplete snapshot falls back to the metadata read" "rc=${RUN_RC} reads=${RUN_READS}"
		return 0
	fi
	pass "incomplete snapshot falls back to the metadata read"
	return 0
}

test_substage_rows() {
	local snapshot=""
	write_fixture assigned
	snapshot=$(cat "${GH_STUB_DIR}/meta.json")
	rm -f "$AIDEVOPS_DISPATCH_STAGES_LOG"
	ISSUE_META_JSON="$snapshot" "$HELPER" is-assigned 123 owner/repo runner >/dev/null 2>&1 || true
	if [[ -s "$AIDEVOPS_DISPATCH_STAGES_LOG" ]]; then
		fail "no stage rows without dispatcher context" "$(tr '\n' ' ' <"$AIDEVOPS_DISPATCH_STAGES_LOG")"
		return 0
	fi
	AIDEVOPS_DISPATCH_STAGE_ISSUE=123 AIDEVOPS_DISPATCH_STAGE_REPO=owner/repo ISSUE_META_JSON="$snapshot" \
		"$HELPER" is-assigned 123 owner/repo runner >/dev/null 2>&1 || true
	local gate missing=""
	for gate in load_meta metadata_guards dispatch_cooldown cost_budget stale_check; do
		grep -qE "	#123	owner/repo	dedup\.layer6\.${gate}	[0-9]+	complete	" "$AIDEVOPS_DISPATCH_STAGES_LOG" 2>/dev/null ||
			missing="${missing} ${gate}"
	done
	if [[ -n "$missing" ]]; then
		fail "dispatcher context records dedup.layer6 sub-gates" "missing:${missing}"
		return 0
	fi
	pass "dispatcher context records dedup.layer6 sub-gate rows"
	return 0
}

test_reason_file() {
	local snapshot="" reason_file="" output="" expected=""
	write_fixture hold
	snapshot=$(cat "${GH_STUB_DIR}/meta.json")
	reason_file=$(mktemp "${TMP_DIR}/reason.XXXXXX")
	output=$(AIDEVOPS_DDH_BLOCKER_REASON_FILE="$reason_file" ISSUE_META_JSON="$snapshot" \
		"$HELPER" is-assigned 123 owner/repo runner 2>/dev/null) || true
	expected=$("$HELPER" classify-blocker "$output" 2>/dev/null)
	if [[ "$output" != *HOLD_FOR_REVIEW_BLOCKED* || -z "$expected" || "$(cat "$reason_file")" != "$expected" ]]; then
		fail "reason file matches classify-blocker" "output=${output} expected=${expected} file=$(cat "$reason_file")"
		return 0
	fi
	local target="${TMP_DIR}/reason-target" link="${TMP_DIR}/reason-link"
	: >"$target"
	ln -s "$target" "$link"
	AIDEVOPS_DDH_BLOCKER_REASON_FILE="$link" ISSUE_META_JSON="$snapshot" \
		"$HELPER" is-assigned 123 owner/repo runner >/dev/null 2>&1 || true
	if [[ -s "$target" ]]; then
		fail "reason file is not written through a symlink"
		return 0
	fi
	write_fixture unassigned
	snapshot=$(cat "${GH_STUB_DIR}/meta.json")
	: >"$reason_file"
	AIDEVOPS_DDH_BLOCKER_REASON_FILE="$reason_file" ISSUE_META_JSON="$snapshot" \
		"$HELPER" is-assigned 123 owner/repo runner >/dev/null 2>&1 || true
	if [[ -s "$reason_file" ]]; then
		fail "reason file stays empty when dispatch is allowed" "file=$(cat "$reason_file")"
		return 0
	fi
	pass "reason file matches classify-blocker, only for a private regular file on a block"
	return 0
}

# Layer-6 wiring with a fixture helper that logs classify-blocker calls.
test_layer6_uses_reason_file() {
	local fixture_dir="${TMP_DIR}/layer6"
	mkdir -p "$fixture_dir"
	cat >"${fixture_dir}/dispatch-dedup-helper.sh" <<'EOF'
#!/usr/bin/env bash
cmd="${1:-}"
if [[ "$cmd" == "is-assigned" ]]; then
	printf 'stage=%s/%s\n' "${AIDEVOPS_DISPATCH_STAGE_ISSUE:-}" "${AIDEVOPS_DISPATCH_STAGE_REPO:-}" >>"${LAYER6_TRACE}"
	if [[ "${LAYER6_WRITE_REASON:-1}" == "1" && -n "${AIDEVOPS_DDH_BLOCKER_REASON_FILE:-}" ]]; then
		printf 'dedup_hold_for_review\n' >"$AIDEVOPS_DDH_BLOCKER_REASON_FILE"
	fi
	printf 'HOLD_FOR_REVIEW_BLOCKED (label=hold-for-review)\n'
	exit 0
fi
if [[ "$cmd" == "classify-blocker" ]]; then
	printf 'classify\n' >>"${LAYER6_TRACE}"
	printf 'dedup_from_subprocess\n'
	exit 0
fi
exit 1
EOF
	chmod +x "${fixture_dir}/dispatch-dedup-helper.sh"
	export LAYER6_TRACE="${TMP_DIR}/layer6-trace.log"
	export AIDEVOPS_TEMP_DIR="${TMP_DIR}/agent-tmp"
	mkdir -p "$AIDEVOPS_TEMP_DIR"
	: >"$LOGFILE"
	: >"$LAYER6_TRACE"
	local result=""
	result=$(
		# shellcheck source=../pulse-dispatch-dedup-layers.sh
		source "${SCRIPTS_DIR}/pulse-dispatch-dedup-layers.sh" >/dev/null 2>&1
		SCRIPT_DIR="$fixture_dir"
		_dedup_layer_timed() {
			local _issue="$1" _repo="$2" _stage="$3"
			shift 3
			"$@"
			return $?
		}
		_ds_record() { return 0; }
		out=$(_dedup_layer6_assignee_and_stale 123 owner/repo runner) && printf 'rc=0 out=%s\n' "$out"
		LAYER6_WRITE_REASON=0
		export LAYER6_WRITE_REASON
		out=$(_dedup_layer6_assignee_and_stale 123 owner/repo runner) && printf 'rc=0 out=%s\n' "$out"
	)
	local classify_calls leftover
	classify_calls=$(grep -c '^classify$' "$LAYER6_TRACE" 2>/dev/null) || classify_calls=0
	leftover=$(find "$AIDEVOPS_TEMP_DIR" -name 'layer6-reason.*' 2>/dev/null | wc -l | tr -d ' ')
	if [[ "$(grep -c '^rc=0 out=HOLD_FOR_REVIEW_BLOCKED' <<<"$result")" -ne 2 ]]; then
		fail "layer 6 still blocks and returns the signal" "result=${result}"
		return 0
	fi
	if ! grep -q 'reason=dedup_hold_for_review signal=HOLD_FOR_REVIEW_BLOCKED' "$LOGFILE" ||
		! grep -q 'reason=dedup_from_subprocess signal=HOLD_FOR_REVIEW_BLOCKED' "$LOGFILE"; then
		fail "layer 6 logs the in-process reason, then the fallback reason" "log=$(tr '\n' ' ' <"$LOGFILE")"
		return 0
	fi
	if [[ "$classify_calls" -ne 1 ]]; then
		fail "layer 6 starts classify-blocker only when no reason was written" "classify calls=${classify_calls}"
		return 0
	fi
	if ! grep -q '^stage=123/owner/repo$' "$LAYER6_TRACE"; then
		fail "layer 6 hands the helper its stage context" "trace=$(tr '\n' ' ' <"$LAYER6_TRACE")"
		return 0
	fi
	if [[ "$leftover" -ne 0 ]]; then
		fail "layer 6 removes its reason file" "leftover=${leftover}"
		return 0
	fi
	pass "layer 6 uses the in-process reason, falls back to classify-blocker, passes stage context"
	return 0
}

test_snapshot_skips_metadata_read
test_stale_fixture_recovers
test_incomplete_snapshot_falls_back
test_substage_rows
test_reason_file
test_layer6_uses_reason_file

printf '\n%s tests, %s failed\n' "$TESTS_RUN" "$TESTS_FAILED"
[[ "$TESTS_FAILED" -eq 0 ]] || exit 1
exit 0
