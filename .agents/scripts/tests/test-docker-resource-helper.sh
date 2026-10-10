#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# test-docker-resource-helper.sh — GH#34285 regression coverage for
# docker-resource-helper.sh using a PATH-stubbed `docker` and `gh` (no real
# daemon). Covers owner labels, report-only reaping, the ownership rule and
# its negative cases (unlabelled, worktree present, ref open, ref lookup
# failure, running past TTL, fresh resources, shared networks), post-removal
# teardown, the pulse step and daemon-down/hung exits.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
AGENTS_SCRIPTS_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)" || exit 1
HELPER="${AGENTS_SCRIPTS_DIR}/docker-resource-helper.sh"

TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/docker-resource-test.XXXXXX")"
STATE="${TEST_ROOT}/state"
STUB_BIN="${TEST_ROOT}/bin"
TESTS_RUN=0
TESTS_FAILED=0

cleanup() {
	rm -rf "$TEST_ROOT"
	return 0
}
trap cleanup EXIT

print_result() {
	local name="$1" status="$2" detail="${3:-}"
	TESTS_RUN=$((TESTS_RUN + 1))
	if [[ "$status" -eq 0 ]]; then
		printf 'PASS %s\n' "$name"
	else
		printf 'FAIL %s\n' "$name"
		[[ -z "$detail" ]] || printf '%s\n' "$detail" | sed 's/^/  /'
		TESTS_FAILED=$((TESTS_FAILED + 1))
	fi
	return 0
}

write_stubs() {
	mkdir -p "$STUB_BIN"
	# Minimal docker emulator over pipe-separated fixture files:
	#   containers: id|name|owner|repo|ref|worktree|created|ttl|state|networks|volumes|finished
	#   networks:   id|name|owner|repo|ref|worktree|created|ttl
	#   volumes:    name|owner|repo|ref|worktree|created|ttl
	cat >"${STUB_BIN}/docker" <<'STUB'
#!/usr/bin/env bash
set -u
S="${DOCKER_STUB_STATE:?}"
US=$'\x1f'
printf '%s\n' "$*" >>"${S}/calls.log"
sub="${1:-}"
[[ $# -eq 0 ]] || shift
case "${DOCKER_STUB_MODE:-up}" in
down) printf 'Cannot connect to the Docker daemon\n' >&2; exit 1 ;;
hang) sleep 10; exit 1 ;;
esac

join_us() {
	local IFS="$US"
	printf '%s\n' "$*"
	return 0
}

# Parse ls/ps style flags into globals.
parse_flags() {
	ALL=0; QUIET=0; FILTERS=""
	while [[ $# -gt 0 ]]; do
		case "$1" in
		-a | --all) ALL=1 ;;
		-q | --quiet) QUIET=1 ;;
		--no-trunc) ;;
		--filter | -f) FILTERS="${FILTERS}${2}"$'\n'; shift ;;
		--format) shift ;;
		esac
		shift
	done
	return 0
}

container_matches() {
	local owner="$1" state="$2" networks="$3" volumes="$4" id="$5" f
	[[ "$ALL" -eq 1 || "$state" == running ]] || return 1
	while IFS= read -r f; do
		[[ -n "$f" ]] || continue
		case "$f" in
		label=sh.aidevops.owner=1) [[ "$owner" == 1 ]] || return 1 ;;
		network=*) [[ ",${networks}," == *",${f#network=},"* ]] || return 1 ;;
		volume=*) [[ ",${volumes}," == *",${f#volume=},"* ]] || return 1 ;;
		status=*) [[ "$state" == "${f#status=}" ]] || return 1 ;;
		id=*) [[ "$id" == "${f#id=}" ]] || return 1 ;;
		esac
	done <<<"$FILTERS"
	return 0
}

do_ps() {
	parse_flags "$@"
	local id name owner repo ref wt created ttl state nets vols fin
	while IFS='|' read -r id name owner repo ref wt created ttl state nets vols fin; do
		[[ -n "$id" ]] || continue
		container_matches "$owner" "$state" "$nets" "$vols" "$id" || continue
		if [[ "$QUIET" -eq 1 ]]; then printf '%s\n' "$id"; else join_us "$id" "$name" "$owner" "$repo" "$ref" "$wt" "$created" "$ttl" "$state"; fi
	done <"${S}/containers"
	return 0
}

referenced() {
	local kind="$1" key="$2" id name owner repo ref wt created ttl state nets vols fin
	while IFS='|' read -r id name owner repo ref wt created ttl state nets vols fin; do
		if [[ "$kind" == network && ",${nets}," == *",${key},"* ]]; then return 0; fi
		if [[ "$kind" == volume && ",${vols}," == *",${key},"* ]]; then return 0; fi
	done <"${S}/containers"
	return 1
}

delete_row() {
	local file="$1" key="$2"
	awk -F'|' -v k="$key" '$1 != k' "$file" >"${file}.new" || return 1
	mv "${file}.new" "$file" || return 1
	return 0
}

has_row() {
	local file="$1" key="$2"
	awk -F'|' -v k="$key" '$1 == k { found = 1 } END { exit found ? 0 : 1 }' "$file" || return 1
	return 0
}

do_network() {
	local action="$1" id name owner repo ref wt created ttl f
	shift
	case "$action" in
	ls)
		parse_flags "$@"
		while IFS='|' read -r id name owner repo ref wt created ttl; do
			[[ -n "$id" ]] || continue
			if [[ "$FILTERS" == *"label=sh.aidevops.owner=1"* && "$owner" != 1 ]]; then continue; fi
			if [[ "$QUIET" -eq 1 ]]; then printf '%s\n' "$id"; else join_us "$id" "$name" "$owner" "$repo" "$ref" "$wt" "$created" "$ttl"; fi
		done <"${S}/networks"
		;;
	rm)
		f="$1"
		has_row "${S}/networks" "$f" || { printf 'Error response from daemon: network %s not found\n' "$f" >&2; exit 1; }
		referenced network "$f" && { printf 'Error response from daemon: network %s has active endpoints\n' "$f" >&2; exit 1; }
		delete_row "${S}/networks" "$f"
		printf 'network rm %s\n' "$f" >>"${S}/actions.log"
		;;
	esac
	return 0
}

do_volume() {
	local action="$1" name owner repo ref wt created ttl f
	shift
	case "$action" in
	ls)
		parse_flags "$@"
		while IFS='|' read -r name owner repo ref wt created ttl; do
			[[ -n "$name" ]] || continue
			if [[ "$FILTERS" == *"label=sh.aidevops.owner=1"* && "$owner" != 1 ]]; then continue; fi
			if [[ "$FILTERS" == *"dangling=true"* ]] && referenced volume "$name"; then continue; fi
			if [[ "$QUIET" -eq 1 ]]; then printf '%s\n' "$name"; else join_us "$name" "$name" "$owner" "$repo" "$ref" "$wt" "$created" "$ttl"; fi
		done <"${S}/volumes"
		;;
	rm)
		f="$1"
		has_row "${S}/volumes" "$f" || { printf 'Error: No such volume: %s\n' "$f" >&2; exit 1; }
		referenced volume "$f" && { printf 'Error response from daemon: volume is in use\n' >&2; exit 1; }
		delete_row "${S}/volumes" "$f"
		printf 'volume rm %s\n' "$f" >>"${S}/actions.log"
		;;
	esac
	return 0
}

do_inspect() {
	local format="" id row
	[[ "${1:-}" == --format ]] && { format="$2"; shift 2; }
	for id in "$@"; do
		row=$(awk -F'|' -v k="$id" '$1 == k' "${S}/containers")
		[[ -n "$row" ]] || { printf 'Error: No such object: %s\n' "$id" >&2; exit 1; }
		IFS='|' read -r cid name owner repo ref wt created ttl state nets vols fin <<<"$row"
		if [[ "$format" == *FinishedAt* ]]; then join_us "$cid" "/${name}" "$fin" "$owner"; else printf '%s\n' "$state"; fi
	done
	return 0
}

case "$sub" in
info) printf '27.0.0\n' ;;
ps) do_ps "$@" ;;
rm)
	[[ "${1:-}" == -f ]] && shift
	has_row "${S}/containers" "$1" || { printf 'Error: No such container: %s\n' "$1" >&2; exit 1; }
	delete_row "${S}/containers" "$1"
	printf 'rm %s\n' "$1" >>"${S}/actions.log"
	;;
inspect) do_inspect "$@" ;;
network) do_network "$@" ;;
volume) do_volume "$@" ;;
system) join_us Images 3 1 1.2GB "600MB (50%)"; join_us "Local Volumes" 4 1 2GB "1.5GB (75%)" ;;
*) exit 1 ;;
esac
exit 0
STUB
	cat >"${STUB_BIN}/gh" <<'STUB'
#!/usr/bin/env bash
S="${DOCKER_STUB_STATE:?}"
printf '%s\n' "$*" >>"${S}/gh.log"
path="${2:-}"
key="${path#repos/}"
key="${key/\/issues\//#}"
state=$(awk -F'|' -v k="$key" '$1 == k { print $2 }' "${S}/refs")
[[ -n "$state" && "$state" != fail ]] || exit 1
printf '%s\n' "$state"
STUB
	chmod +x "${STUB_BIN}/docker" "${STUB_BIN}/gh"
	return 0
}

# Fixture: see the expectations in test_reap_* below.
write_fixture() {
	local now old ancient fresh finished gone present td
	now=$(date +%s)
	old=$((now - 4 * 3600))
	ancient=$((now - 100 * 3600))
	fresh=$((now - 600))
	finished="2020-01-01T00:00:00.123456789Z"
	gone="${TEST_ROOT}/gone-wt"
	present="${TEST_ROOT}/present-wt"
	td="${TEST_ROOT}/teardown-wt"
	rm -rf "$STATE" "$gone" "$td"
	mkdir -p "$STATE" "$present"
	: >"${STATE}/calls.log"
	: >"${STATE}/actions.log"
	: >"${STATE}/gh.log"
	cat >"${STATE}/refs" <<EOF
ex/repo#1|closed
ex/repo#2|open
ex/repo#3|fail
EOF
	cat >"${STATE}/containers" <<EOF
c1|closed-gone|1|ex/repo|GH#1|${gone}|${old}|72|running|n1|v1|
c2|unlabelled-old|||||||exited|n3||${finished}
c3|present-closed|1|ex/repo|GH#1|${present}|${old}|72|exited|||${finished}
c4|gone-open|1|ex/repo|GH#2|${gone}|${old}|72|exited|||${finished}
c5|gone-lookup-fail|1|ex/repo|GH#3|${gone}|${old}|72|exited|||${finished}
c6|ttl-running|1|ex/repo|GH#2|${present}|${ancient}|72|running|||
c7|ttl-stopped|1|ex/repo|GH#2|${present}|${ancient}|72|exited|||${finished}
c8|fresh-closed|1|ex/repo|GH#1|${gone}|${fresh}|72|exited|||${finished}
c9|teardown-site|1|ex/repo|GH#2|${td}|${old}|72|running|n4|v4|
c10|unlabelled-shared|||||||running|n5||
EOF
	cat >"${STATE}/networks" <<EOF
n1|net-closed-gone|1|ex/repo|GH#1|${gone}|${old}|72
n3|net-shared-unlabelled|1|ex/repo|GH#1|${gone}|${old}|72
n4|net-teardown|1|ex/repo|GH#2|${td}|${old}|72
n5|net-teardown-shared|1|ex/repo|GH#2|${td}|${old}|72
nU|net-unlabelled||||||
EOF
	cat >"${STATE}/volumes" <<EOF
v1|1|ex/repo|GH#1|${gone}|${old}|72
v4|1|ex/repo|GH#2|${td}|${old}|72
vU||||||
EOF
	return 0
}

has_id() {
	local file="$1" id="$2"
	awk -F'|' -v k="$id" '$1 == k { found = 1 } END { exit found ? 0 : 1 }' "${STATE}/${file}"
	return $?
}

run_helper() {
	PATH="${STUB_BIN}:${PATH}" DOCKER_STUB_STATE="$STATE" "$HELPER" "$@"
	return $?
}

test_labels() {
	local out rc=0 compose
	out=$(run_helper labels --repo ex/repo --ref GH#7 --worktree /tmp/wt/ --ttl-hours 12) || rc=1
	[[ "$(printf '%s\n' "$out" | grep -c '^--label=sh\.aidevops\.')" == 6 ]] || rc=1
	[[ "$out" == *"--label=sh.aidevops.owner=1"* && "$out" == *"--label=sh.aidevops.repo=ex/repo"* ]] || rc=1
	[[ "$out" == *"--label=sh.aidevops.ref=GH#7"* && "$out" == *"--label=sh.aidevops.worktree=/tmp/wt"$'\n'* ]] || rc=1
	[[ "$out" == *"--label=sh.aidevops.ttl-hours=12"* ]] || rc=1
	[[ "$out" =~ (^|$'\n')--label=sh\.aidevops\.created=[0-9]+($'\n'|$) ]] || rc=1
	compose=$(run_helper compose-labels --repo ex/repo --ref PR#9 --worktree /tmp/wt --indent 2) || rc=1
	[[ "$compose" == *"  labels:"* && "$compose" == *'    sh.aidevops.ref: "PR#9"'* ]] || rc=1
	run_helper labels --ref bogus >/dev/null 2>&1 && rc=1
	print_result "labels prints the six owner labels and a compose snippet; invalid ref rejected" "$rc" "$out"
	return 0
}

test_inventory() {
	local out rc=0
	write_fixture
	out=$(run_helper inventory) || rc=1
	[[ "$out" == *"container"$'\t'"c1"$'\t'"closed-gone"* ]] || rc=1
	[[ "$out" == *"network"$'\t'"n4"* && "$out" == *"volume"$'\t'"v1"* ]] || rc=1
	[[ "$out" != *$'\tc2\t'* && "$out" != *$'\tc10\t'* ]] || rc=1
	[[ "$out" != *$'\tnU\t'* && "$out" != *$'\tvU\t'* ]] || rc=1
	print_result "inventory lists labelled containers, networks and volumes only" "$rc" "$out"
	return 0
}

test_reap_report_only() {
	local out rc=0
	write_fixture
	out=$(run_helper reap) || rc=1
	[[ ! -s "${STATE}/actions.log" ]] || rc=1
	[[ "$out" == *"would-remove container closed-gone"* && "$out" == *"would-remove container ttl-stopped"* ]] || rc=1
	[[ "$out" == *"would-remove network net-closed-gone"* && "$out" == *"would-remove volume v1"* ]] || rc=1
	[[ "$out" == *"kept network net-shared-unlabelled"*"attached_containers=1"* ]] || rc=1
	[[ "$out" == *"reap mode=dry-run"* ]] || rc=1
	[[ "$(grep -c . "${STATE}/gh.log")" -eq 3 ]] || rc=1
	print_result "reap without --apply removes nothing, lists candidates, one gh lookup per ref" "$rc" "$out"
	return 0
}

test_reap_apply() {
	local out rc=0 id
	write_fixture
	out=$(run_helper reap --apply --verbose) || rc=1
	for id in c1 c7; do has_id containers "$id" && rc=1; done
	has_id networks n1 && rc=1
	has_id volumes v1 && rc=1
	for id in c2 c3 c4 c5 c6 c8 c9 c10; do has_id containers "$id" || rc=1; done
	for id in n3 n4 n5 nU; do has_id networks "$id" || rc=1; done
	for id in v4 vU; do has_id volumes "$id" || rc=1; done
	[[ "$out" == *"reason=worktree-present"* && "$out" == *"reason=ref-open"* ]] || rc=1
	[[ "$out" == *"reason=ref-unknown"* && "$out" == *"reason=ttl-expired-but-running"* ]] || rc=1
	[[ "$out" == *"reason=created-within-30m"* ]] || rc=1
	# Containers are removed before networks and volumes.
	[[ "$(head -1 "${STATE}/actions.log")" == "rm c1" ]] || rc=1
	print_result "reap --apply removes only closed+gone or stopped TTL-expired labelled resources" "$rc" "$out"
	return 0
}

test_reap_budget() {
	local out rc=0
	write_fixture
	out=$(run_helper reap --apply --max-seconds abc 2>&1) && rc=1
	out=$(run_helper reap --apply --max-seconds 0) || rc=1
	[[ "$out" == *"budget_s=0 budget_exhausted=0"* ]] || rc=1
	print_result "reap validates --max-seconds and reports its budget" "$rc" "$out"
	return 0
}

test_teardown() {
	local out rc=0
	write_fixture
	out=$(run_helper teardown --worktree "${TEST_ROOT}/present-wt" 2>&1) && rc=1
	[[ ! -s "${STATE}/actions.log" ]] || rc=1
	out=$(run_helper teardown --worktree "${TEST_ROOT}/teardown-wt/") || rc=1
	has_id containers c9 && rc=1
	has_id networks n4 && rc=1
	has_id volumes v4 && rc=1
	has_id networks n5 || rc=1
	has_id containers c10 || rc=1
	has_id containers c1 || rc=1
	[[ "$out" == *"teardown mode=apply"*"matched=4 removed=3 kept=1"* ]] || rc=1
	out=$(run_helper teardown --worktree "${TEST_ROOT}/teardown-wt") || rc=1
	[[ -z "$out" || "$out" == *"matched=1"* ]] || rc=1
	print_result "teardown removes the removed worktree's labelled stack, keeps shared and existing-worktree resources" "$rc" "$out"
	return 0
}

test_worktree_hook() {
	local rc=0
	write_fixture
	(
		export PATH="${STUB_BIN}:${PATH}" DOCKER_STUB_STATE="$STATE"
		SCRIPT_DIR="$AGENTS_SCRIPTS_DIR"
		# shellcheck source=../shared-constants.sh
		source "${AGENTS_SCRIPTS_DIR}/shared-constants.sh"
		# shellcheck source=../worktree-helper-integration.sh
		source "${AGENTS_SCRIPTS_DIR}/worktree-helper-integration.sh"
		AIDEVOPS_DOCKER_TEARDOWN=0 docker_resource_auto_teardown "${TEST_ROOT}/teardown-wt"
		has_id containers c9 || exit 1
		docker_resource_auto_teardown "${TEST_ROOT}/teardown-wt" 2>/dev/null
	) >"${TEST_ROOT}/hook.out" || rc=1
	[[ ! -s "${TEST_ROOT}/hook.out" ]] || rc=1
	has_id containers c9 && rc=1
	has_id volumes v4 && rc=1
	print_result "worktree removal hook tears down labelled resources with empty stdout; opt-out honoured" "$rc"
	return 0
}

test_pulse_step() {
	local rc=0 dir="${TEST_ROOT}/pulse-scripts"
	write_fixture
	mkdir -p "$dir"
	printf '#!/usr/bin/env bash\nexit 0\n' >"${dir}/system-cleanup.sh"
	printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$*" >>"%s/pulse-args.log"\nexec "%s" "$@"\n' "$STATE" "$HELPER" >"${dir}/docker-resource-helper.sh"
	chmod +x "${dir}/system-cleanup.sh" "${dir}/docker-resource-helper.sh"
	(
		export PATH="${STUB_BIN}:${PATH}" DOCKER_STUB_STATE="$STATE" HOME="${TEST_ROOT}/home" LOGFILE="${TEST_ROOT}/pulse.log"
		mkdir -p "$HOME"
		unset AIDEVOPS_DOCKER_REAP PULSE_DOCKER_CLEANUP_MAX_SECONDS
		# shellcheck source=../shared-constants.sh
		source "${AGENTS_SCRIPTS_DIR}/shared-constants.sh"
		# shellcheck source=../worker-lifecycle-common.sh
		source "${AGENTS_SCRIPTS_DIR}/worker-lifecycle-common.sh"
		# shellcheck source=../pulse-cleanup.sh
		source "${AGENTS_SCRIPTS_DIR}/pulse-cleanup.sh"
		_PULSE_CLEANUP_SCRIPT_DIR="$dir"
		cleanup_stale_opencode || exit 1
		[[ ! -s "${STATE}/actions.log" ]] || exit 1
		AIDEVOPS_DOCKER_REAP=1 cleanup_stale_opencode || exit 1
	) || rc=1
	[[ "$(sed -n 1p "${STATE}/pulse-args.log")" == "reap --max-seconds 30" ]] || rc=1
	[[ "$(sed -n 2p "${STATE}/pulse-args.log")" == "reap --apply --max-seconds 30" ]] || rc=1
	has_id containers c1 && rc=1
	has_id containers c2 || rc=1
	grep -q 'reap mode=dry-run' "${TEST_ROOT}/pulse.log" || rc=1
	print_result "pulse step is report-only unless AIDEVOPS_DOCKER_REAP=1 and never touches unlabelled" "$rc" \
		"$(cat "${STATE}/pulse-args.log" 2>/dev/null)"
	return 0
}

test_report() {
	local out rc=0
	write_fixture
	out=$(run_helper report) || rc=1
	[[ ! -s "${STATE}/actions.log" ]] || rc=1
	[[ "$out" == *"containers: labelled=8 unlabelled=2"* ]] || rc=1
	[[ "$out" == *"networks (custom): labelled=4 unlabelled=1"* ]] || rc=1
	[[ "$out" == *"volumes: labelled=2 unlabelled=1"* ]] || rc=1
	[[ "$out" == *"Unused volumes (no container references them): 1"* ]] || rc=1
	[[ "$out" == *"net-unlabelled"* && "$out" == *"docker network prune"* ]] || rc=1
	[[ "$out" == *"unlabelled-old stopped_days="* ]] || rc=1
	print_result "report counts labelled/unlabelled pressure and deletes nothing" "$rc" "$out"
	return 0
}

test_daemon_unavailable() {
	local rc=0 out start elapsed
	write_fixture
	out=$(DOCKER_STUB_MODE=down run_helper reap --apply) || rc=1
	[[ "$out" == *"docker daemon not reachable"* ]] || rc=1
	DOCKER_STUB_MODE=down run_helper report >/dev/null || rc=1
	DOCKER_STUB_MODE=down run_helper teardown --worktree "${TEST_ROOT}/teardown-wt" >/dev/null || rc=1
	start=$SECONDS
	out=$(DOCKER_STUB_MODE=hang AIDEVOPS_DOCKER_TIMEOUT_SECONDS=1 run_helper reap --apply) || rc=1
	elapsed=$((SECONDS - start))
	[[ "$elapsed" -le 4 ]] || rc=1
	[[ ! -s "${STATE}/actions.log" ]] || rc=1
	print_result "daemon down or hung: entry points exit 0 within the short probe timeout" "$rc" "elapsed=${elapsed}s ${out}"
	return 0
}

main() {
	write_stubs
	test_labels
	test_inventory
	test_reap_report_only
	test_reap_apply
	test_reap_budget
	test_teardown
	test_worktree_hook
	test_pulse_step
	test_report
	test_daemon_unavailable
	printf '\n%d/%d tests passed\n' "$((TESTS_RUN - TESTS_FAILED))" "$TESTS_RUN"
	[[ "$TESTS_FAILED" -eq 0 ]] || return 1
	return 0
}

main "$@"
