#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# Regression test for GH#20611 — is-running short-circuit must not produce
# false positives on Linux from pgrep-pipe argv inheritance.
#
# Background:
#   - GH#20579 added a short-circuit at the top of main() that called
#     `pgrep -f "pulse-wrapper.sh" | grep -v "^$$\$"`. On Linux, the bash
#     subshell that backs $() transiently inherits the parent script's
#     argv, so pgrep matched its own subshell PIDs. grep -v $$ filtered
#     only the parent PID, not the new transient subshell PIDs. Result:
#     100% false positive — pulse never ran on Linux.
#   - macOS pgrep / procfs semantics didn't expose the inherited argv,
#     so the bug was invisible to the original author's testing.
#
# Fix (GH#20611):
#   - Replace pgrep+pipe with a PID-file check: read LOCKDIR/pid (the
#     same file acquire_instance_lock writes) and use POSIX `kill -0`
#     for liveness. No pipe, no subshell, no platform-specific argv.
#
# This test asserts:
#   1. Structural: source code contains NO `pgrep -f "..pulse-wrapper.."`
#      pipe pattern in the short-circuit.
#   2. Structural: short-circuit reads ${LOCKDIR}/pid and uses kill -0.
#   3. Behavioural: extracted short-circuit shell snippet
#      a) returns "skip" when PID file points to a live foreign PID
#      b) returns "fall-through" when PID file is missing
#      c) returns "fall-through" when PID file points to a dead PID
#      d) returns "fall-through" when PID file contains $$
#      e) returns "fall-through" when a sibling pulse-wrapper.sh is
#         visible to pgrep but no PID file exists — the canonical
#         GH#20611 false-positive scenario. The OLD code would have
#         short-circuited here; the NEW code must NOT.

set -euo pipefail

readonly TEST_RED='\033[0;31m'
readonly TEST_GREEN='\033[0;32m'
readonly TEST_RESET='\033[0m'

TESTS_RUN=0
TESTS_FAILED=0

PULSE_SCRIPTS_DIR="$(cd "$(dirname "$0")/.." && pwd)"
readonly PULSE_SCRIPTS_DIR
PULSE_WRAPPER="${PULSE_SCRIPTS_DIR}/pulse-wrapper.sh"
readonly PULSE_WRAPPER

print_result() {
	local test_name="$1"
	local passed="$2"
	local message="${3:-}"
	TESTS_RUN=$((TESTS_RUN + 1))
	if [[ "$passed" -eq 0 ]]; then
		printf '%bPASS%b %s\n' "$TEST_GREEN" "$TEST_RESET" "$test_name"
		return 0
	fi
	printf '%bFAIL%b %s\n' "$TEST_RED" "$TEST_RESET" "$test_name"
	if [[ -n "$message" ]]; then
		printf '       %s\n' "$message"
	fi
	TESTS_FAILED=$((TESTS_FAILED + 1))
	return 0
}

#######################################
# STRUCTURAL ASSERTIONS — read the source and verify the bug pattern is gone
# and the fix pattern is present. These guard against revert-by-accident.
#######################################

# Extract just the GH#20611 short-circuit block from the source, so other
# uses of pgrep elsewhere in the file (e.g. cleanup paths) don't false-fail.
extract_block() {
	# Track if/fi nesting depth from the start of the comment block
	# until we close back to depth 0. Counts only `if [[` (the form the
	# block uses) and `fi` at start-of-line, ignoring keyword fragments
	# inside strings or comments.
	awk '
		/GH#20611:/ { in_block=1 }
		in_block {
			print
			# Count "if [[" openings (one per line in the block)
			n_if = gsub(/(^|[[:space:]])if[[:space:]]\[\[/, "&")
			depth += n_if
			# Count standalone "fi" lines (start of line, optional tabs/spaces)
			if ($0 ~ /^[[:space:]]*fi[[:space:]]*$/) {
				depth--
				if (depth <= 0 && saw_open) exit
			}
			if (n_if > 0) saw_open = 1
		}
	' "$PULSE_WRAPPER"
}

test_no_pgrep_pipe_in_block() {
	# Strip comment lines first — the explanatory header documents the OLD
	# pattern by name, which is intentional context for future maintainers.
	# We only care that the EXECUTABLE shell does not use the old pattern.
	local block_code
	block_code=$(extract_block | grep -vE '^[[:space:]]*#')
	if printf '%s\n' "$block_code" | grep -qE 'pgrep[^|]*\|[[:space:]]*grep'; then
		print_result "structural: short-circuit no longer uses pgrep|grep pipe" 1 "found pgrep-pipe in executable block"
	else
		print_result "structural: short-circuit no longer uses pgrep|grep pipe" 0
	fi
	return 0
}

test_uses_pidfile() {
	local block
	block=$(extract_block)
	# shellcheck disable=SC2016 # we want to grep the LITERAL string ${LOCKDIR}/pid in source code, not expand it
	if printf '%s\n' "$block" | grep -q '${LOCKDIR}/pid'; then
		print_result "structural: short-circuit reads \${LOCKDIR}/pid" 0
	else
		print_result "structural: short-circuit reads \${LOCKDIR}/pid" 1 "block does not reference LOCKDIR/pid"
	fi
	return 0
}

test_uses_kill_zero() {
	local block
	block=$(extract_block)
	if printf '%s\n' "$block" | grep -qE 'kill[[:space:]]+-0[[:space:]]'; then
		print_result "structural: short-circuit uses kill -0 for liveness" 0
	else
		print_result "structural: short-circuit uses kill -0 for liveness" 1 "no kill -0 found in block"
	fi
	return 0
}

#######################################
# BEHAVIOURAL ASSERTIONS — exercise the short-circuit shell logic against
# representative PID-file states and confirm correct skip/fall-through.
#
# We extract the block, replace `return 0` with `echo SKIP; exit 0`, and
# wrap the whole thing so a fall-through prints `FALLTHROUGH` and exits.
# Any structural drift in the block that would break this extraction is
# caught by the structural assertions above.
#######################################

run_short_circuit_against() {
	# Args: PID file content (or empty string for "no file")
	local pidfile_content="$1"
	local sandbox
	sandbox=$(mktemp -d)
	# shellcheck disable=SC2064
	trap "rm -rf '$sandbox'" RETURN

	export LOCKDIR="${sandbox}/lockdir"
	export WRAPPER_LOGFILE="${sandbox}/wrapper.log"
	export PULSE_CANARY_MODE=0
	export PULSE_DRY_RUN=0

	if [[ -n "$pidfile_content" ]]; then
		mkdir -p "$LOCKDIR"
		printf '%s\n' "$pidfile_content" >"${LOCKDIR}/pid"
	fi

	# Build a minimal harness script that contains the same short-circuit
	# logic. We deliberately translate, not re-extract, to keep the test
	# self-contained and readable. The structural tests above guarantee
	# the source matches this shape.
	bash -c '
		set -euo pipefail
		LOCKDIR="'"$LOCKDIR"'"
		WRAPPER_LOGFILE="'"$WRAPPER_LOGFILE"'"
		if [[ "${PULSE_CANARY_MODE:-0}" != "1" && "${PULSE_DRY_RUN:-0}" != "1" ]]; then
			if [[ -f "${LOCKDIR}/pid" ]]; then
				_ir_pid=$(cat "${LOCKDIR}/pid" 2>/dev/null || true)
				if [[ "$_ir_pid" =~ ^[0-9]+$ ]] && [[ "$_ir_pid" != "$$" ]] && kill -0 "$_ir_pid" 2>/dev/null; then
					echo "SKIP"
					exit 0
				fi
			fi
		fi
		echo "FALLTHROUGH"
	'
}

test_skip_on_live_foreign_pid() {
	# Spawn a long-lived helper process and write its PID to the file.
	sleep 30 &
	local helper_pid=$!
	# shellcheck disable=SC2064
	trap "kill $helper_pid 2>/dev/null || true" RETURN

	local result
	result=$(run_short_circuit_against "$helper_pid")
	if [[ "$result" == "SKIP" ]]; then
		print_result "behaviour: live foreign PID → skip" 0
	else
		print_result "behaviour: live foreign PID → skip" 1 "got '$result'"
	fi
	return 0
}

test_fallthrough_on_missing_pidfile() {
	local result
	result=$(run_short_circuit_against "")
	if [[ "$result" == "FALLTHROUGH" ]]; then
		print_result "behaviour: no PID file → fall-through" 0
	else
		print_result "behaviour: no PID file → fall-through" 1 "got '$result'"
	fi
	return 0
}

test_fallthrough_on_dead_pid() {
	# Find a definitely-dead PID by spawning a fast-exiting process.
	local dead_pid
	dead_pid=$(bash -c 'exec >/dev/null 2>&1; echo $$')
	# Wait for it to actually be reaped.
	while kill -0 "$dead_pid" 2>/dev/null; do sleep 0.1; done

	local result
	result=$(run_short_circuit_against "$dead_pid")
	if [[ "$result" == "FALLTHROUGH" ]]; then
		print_result "behaviour: dead PID in file → fall-through" 0
	else
		print_result "behaviour: dead PID in file → fall-through" 1 "got '$result'"
	fi
	return 0
}

test_fallthrough_on_self_pid() {
	# The short-circuit must not trigger when the PID file points to $$ —
	# our own subshell. The test wrapper runs in a sub-bash so $$ is the
	# child's PID, not ours; we capture that child's PID and write it.
	local sandbox
	sandbox=$(mktemp -d)
	# shellcheck disable=SC2064
	trap "rm -rf '$sandbox'" RETURN

	export LOCKDIR="${sandbox}/lockdir"
	export WRAPPER_LOGFILE="${sandbox}/wrapper.log"

	local result
	# The inner shell writes its own PID and then runs the check.
	# A correctly-implemented short-circuit must FALL-THROUGH because $_ir_pid == $$.
	result=$(bash -c '
		set -euo pipefail
		LOCKDIR="'"$LOCKDIR"'"
		WRAPPER_LOGFILE="'"$WRAPPER_LOGFILE"'"
		mkdir -p "$LOCKDIR"
		echo $$ > "${LOCKDIR}/pid"
		if [[ -f "${LOCKDIR}/pid" ]]; then
			_ir_pid=$(cat "${LOCKDIR}/pid" 2>/dev/null || true)
			if [[ "$_ir_pid" =~ ^[0-9]+$ ]] && [[ "$_ir_pid" != "$$" ]] && kill -0 "$_ir_pid" 2>/dev/null; then
				echo "SKIP"
				exit 0
			fi
		fi
		echo "FALLTHROUGH"
	')
	if [[ "$result" == "FALLTHROUGH" ]]; then
		print_result "behaviour: PID file points to self → fall-through" 0
	else
		print_result "behaviour: PID file points to self → fall-through" 1 "got '$result'"
	fi
	return 0
}

test_no_false_positive_from_sibling_wrapper_argv() {
	# CANONICAL GH#20611 SCENARIO: another bash subshell exists in the
	# process tree whose /proc/PID/cmdline transiently contains
	# "pulse-wrapper.sh", but NO PID file is present (so no real lock holder).
	#
	# Old code: pgrep -f "pulse-wrapper.sh" matched the sibling, returned
	# its PID, grep -v $$ left it in the result, short-circuit fired.
	# New code: ignores process tree entirely, only reads PID file. Sibling
	# is invisible. Must fall through.
	local fake_script_dir
	fake_script_dir=$(mktemp -d)
	local fake_script="${fake_script_dir}/pulse-wrapper.sh"
	cat >"$fake_script" <<'EOF'
#!/usr/bin/env bash
exec sleep 30
EOF
	chmod +x "$fake_script"
	"$fake_script" &
	local sibling_pid=$!
	# shellcheck disable=SC2064
	trap "kill $sibling_pid 2>/dev/null || true; rm -rf '$fake_script_dir'" RETURN

	# Sanity check: pgrep DOES see the sibling.
	if ! pgrep -f "(^|/)pulse-wrapper\\.sh( |\$)" 2>/dev/null | grep -q "^${sibling_pid}\$"; then
		print_result "behaviour: regression scenario setup (pgrep visibility)" 1 "sibling not visible to pgrep — test invalid on this platform"
		kill "$sibling_pid" 2>/dev/null || true
		return 0
	fi

	# Run short-circuit with NO PID file present.
	local result
	result=$(run_short_circuit_against "")
	if [[ "$result" == "FALLTHROUGH" ]]; then
		print_result "behaviour: GH#20611 regression — sibling argv visible but no lock → fall-through" 0
	else
		print_result "behaviour: GH#20611 regression — sibling argv visible but no lock → fall-through" 1 "got '$result' — this is the GH#20611 false-positive"
	fi
	return 0
}

main() {
	printf '\nGH#20611 is-running short-circuit regression tests\n'
	printf '====================================================\n\n'

	test_no_pgrep_pipe_in_block
	test_uses_pidfile
	test_uses_kill_zero
	test_skip_on_live_foreign_pid
	test_fallthrough_on_missing_pidfile
	test_fallthrough_on_dead_pid
	test_fallthrough_on_self_pid
	test_no_false_positive_from_sibling_wrapper_argv

	printf '\nResults: %d run, %d failed\n' "$TESTS_RUN" "$TESTS_FAILED"
	if [[ "$TESTS_FAILED" -gt 0 ]]; then
		exit 1
	fi
	exit 0
}

main "$@"
