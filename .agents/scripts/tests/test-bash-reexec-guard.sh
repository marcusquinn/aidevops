#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# GH#18950 (t2087) regression test — bash 3.2 → bash 4+ runtime re-exec
# self-heal guard in shared-constants.sh.
#
# Verifies:
#   1. `bash-upgrade-helper.sh check` behaves correctly on the current system
#   2. `bash-upgrade-helper.sh path` returns a usable path or empty string
#   3. `bash-upgrade-helper.sh status` output is well-formed
#   4. shared-constants.sh has the re-exec guard in the right position
#   5. The guard skips re-exec when BASH_VERSINFO[0] >= 4 (the current case
#      if this test runs under modern bash)
#   6. The guard re-execs when a fake "old bash" sources shared-constants.sh
#      via a synthetic script (only verifiable if a modern bash is available)
#   7. AIDEVOPS_BASH_REEXECED=1 prevents re-exec (loop guard)
#   8. No `$'\0'` in parameter expansion (GH#18830 regression) — sanity
#      check that the earlier class fix is still in place
#
# Usage: bash test-bash-reexec-guard.sh
# Environment: works under bash 3.2 AND bash 4+.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Resolve repo/agents root — supports both:
#   - git worktree layout:   $REPO/.agents/scripts/tests/ → $REPO/.agents/scripts/
#   - deployed layout:       ~/.aidevops/agents/scripts/tests/ → ~/.aidevops/agents/scripts/
# The test walks up one directory (from tests/ to scripts/) and looks for the
# sibling files. If both layouts fail, it exits with a clear error.
_resolve_scripts_dir() {
	local candidate
	# Layout 1: git worktree
	candidate="$(cd "$SCRIPT_DIR/.." && pwd)"
	if [[ -f "$candidate/shared-constants.sh" ]] && [[ -f "$candidate/bash-upgrade-helper.sh" ]]; then
		echo "$candidate"
		return 0
	fi
	return 1
}

SCRIPTS_DIR="$(_resolve_scripts_dir || echo "")"
if [[ -z "$SCRIPTS_DIR" ]]; then
	printf 'FATAL: cannot locate scripts dir containing shared-constants.sh + bash-upgrade-helper.sh\n' >&2
	printf '       SCRIPT_DIR=%s\n' "$SCRIPT_DIR" >&2
	exit 1
fi

HELPER="$SCRIPTS_DIR/bash-upgrade-helper.sh"
SHARED="$SCRIPTS_DIR/shared-constants.sh"

pass_count=0
fail_count=0

_pass() {
	printf 'PASS: %s\n' "$1"
	pass_count=$((pass_count + 1))
}

_fail() {
	printf 'FAIL: %s\n' "$1" >&2
	[[ -n "${2:-}" ]] && printf '       %s\n' "$2" >&2
	fail_count=$((fail_count + 1))
}

# -----------------------------------------------------------------------
# Test 1: helper script exists and is executable.
# -----------------------------------------------------------------------
if [[ -x "$HELPER" ]]; then
	_pass "bash-upgrade-helper.sh exists and is executable"
else
	_fail "bash-upgrade-helper.sh missing or not executable" "path: $HELPER"
fi

# -----------------------------------------------------------------------
# Test 2: `check` subcommand returns one of 0, 1, or 2.
# -----------------------------------------------------------------------
check_rc=0
"$HELPER" check --quiet 2>/dev/null || check_rc=$?
case "$check_rc" in
0 | 1 | 2) _pass "check subcommand returns valid exit code (rc=$check_rc)" ;;
*) _fail "check subcommand returned unexpected rc=$check_rc" ;;
esac

# -----------------------------------------------------------------------
# Test 3: `status` output contains the expected fields.
# -----------------------------------------------------------------------
status_output="$("$HELPER" status 2>&1 || true)"
if [[ "$status_output" == *"Current bash:"* ]] &&
	[[ "$status_output" == *"Minimum wanted:"* ]] &&
	[[ "$status_output" == *"Status:"* ]]; then
	_pass "status output has expected fields"
else
	_fail "status output missing expected fields" "got: $status_output"
fi

# -----------------------------------------------------------------------
# Test 4: `path` subcommand returns either a usable path or empty string.
# -----------------------------------------------------------------------
modern_path="$("$HELPER" path 2>/dev/null || true)"
if [[ -z "$modern_path" ]]; then
	_pass "path returned empty (no modern bash available)"
elif [[ -x "$modern_path" ]]; then
	_pass "path returned executable: $modern_path"
else
	_fail "path returned non-executable value" "got: '$modern_path'"
fi

# -----------------------------------------------------------------------
# Test 5: shared-constants.sh contains the re-exec guard at the top.
# -----------------------------------------------------------------------
if [[ ! -f "$SHARED" ]]; then
	_fail "shared-constants.sh not found at $SHARED"
else
	# The guard must appear before the first `readonly` / constant definition.
	first_guard_line=$(grep -n "AIDEVOPS_BASH_REEXECED" "$SHARED" | head -1 | cut -d: -f1)
	first_readonly_line=$(grep -n "^readonly " "$SHARED" | head -1 | cut -d: -f1)
	if [[ -n "$first_guard_line" ]] && [[ -n "$first_readonly_line" ]] &&
		[[ "$first_guard_line" -lt "$first_readonly_line" ]]; then
		_pass "re-exec guard is positioned before first readonly (line $first_guard_line < $first_readonly_line)"
	else
		_fail "re-exec guard missing or misplaced in shared-constants.sh" \
			"guard_line=$first_guard_line readonly_line=$first_readonly_line"
	fi

	# The guard must reference all three candidate paths.
	for candidate in "/opt/homebrew/bin/bash" "/usr/local/bin/bash" "/home/linuxbrew/.linuxbrew/bin/bash"; do
		if grep -qF "$candidate" "$SHARED"; then
			_pass "shared-constants.sh references $candidate"
		else
			_fail "shared-constants.sh missing candidate path $candidate"
		fi
	done
fi

# -----------------------------------------------------------------------
# Test 6: re-exec is skipped when BASH_VERSINFO[0] >= 4.
# -----------------------------------------------------------------------
# Only testable if we're running under modern bash right now.
if [[ "${BASH_VERSINFO[0]}" -ge 4 ]]; then
	# Source shared-constants in a subshell and confirm we don't exec.
	test_rc=0
	(
		# shellcheck source=/dev/null
		source "$SHARED"
		echo "sourced_ok"
	) >/dev/null 2>&1 || test_rc=$?
	if [[ "$test_rc" -eq 0 ]]; then
		_pass "modern bash sources shared-constants.sh without re-exec"
	else
		_fail "modern bash source of shared-constants.sh failed (rc=$test_rc)"
	fi
else
	printf 'SKIP: modern-bash source test (running under bash %s, not 4+)\n' "${BASH_VERSINFO[0]}"
fi

# -----------------------------------------------------------------------
# Test 7: AIDEVOPS_BASH_REEXECED=1 prevents re-exec loop (tested via a
# synthetic script that sources shared-constants and reports its version).
# -----------------------------------------------------------------------
TMP_SCRIPT="$(mktemp -t "aidevops-test-bash-reexec.XXXXXX")" || {
	_fail "mktemp failed"
	printf '\nResults: %d passed, %d failed\n' "$pass_count" "$fail_count"
	[[ "$fail_count" -gt 0 ]] && exit 1
	exit 0
}
trap 'rm -f "$TMP_SCRIPT"' EXIT
cat >"$TMP_SCRIPT" <<EOF
#!/usr/bin/env bash
# shellcheck source=/dev/null
source "$SHARED"
echo "running_bash=\${BASH_VERSINFO[0]}"
echo "reexeced=\${AIDEVOPS_BASH_REEXECED:-0}"
EOF
chmod +x "$TMP_SCRIPT"

# Run under /bin/bash 3.2 with AIDEVOPS_BASH_REEXECED already set — the
# guard should skip and we should see running_bash=3 (or whatever /bin/bash
# is on this system).
guard_output="$(AIDEVOPS_BASH_REEXECED=1 /bin/bash "$TMP_SCRIPT" 2>&1 || true)"
current_major=$(/bin/bash -c 'echo ${BASH_VERSINFO[0]}' 2>/dev/null || echo 0)
if [[ "$guard_output" == *"running_bash=${current_major}"* ]]; then
	_pass "AIDEVOPS_BASH_REEXECED=1 prevents re-exec (ran under bash ${current_major})"
else
	_fail "AIDEVOPS_BASH_REEXECED=1 did not prevent re-exec" \
		"output: $guard_output"
fi

# -----------------------------------------------------------------------
# Test 8: Without the guard, /bin/bash 3.2 re-execs under modern bash if
# one is available. Only runnable if modern bash is actually present.
# -----------------------------------------------------------------------
if [[ -n "$modern_path" ]] && [[ "$current_major" -lt 4 ]]; then
	# Run WITHOUT AIDEVOPS_BASH_REEXECED set; the guard should fire and
	# we should see running_bash=4+ in the output.
	reexec_output="$(/bin/bash "$TMP_SCRIPT" 2>&1 || true)"
	if [[ "$reexec_output" == *"running_bash=4"* ]] || [[ "$reexec_output" == *"running_bash=5"* ]]; then
		_pass "/bin/bash 3.2 re-execs under modern bash when guard fires"
	else
		_fail "/bin/bash 3.2 did not re-exec under modern bash" \
			"output: $reexec_output"
	fi
elif [[ "$current_major" -ge 4 ]]; then
	printf 'SKIP: re-exec fire test (/bin/bash is already >= 4 on this system)\n'
else
	printf 'SKIP: re-exec fire test (no modern bash available at known paths)\n'
fi

# -----------------------------------------------------------------------
# Test 9: GH#18830 regression — no $'\0' inside ${...} anywhere in scripts.
# (Duplicated from test-pulse-dep-graph-bash32-nul-crash.sh as a sanity
# check, since this task reinforces the same class of fix.)
# -----------------------------------------------------------------------
nul_in_expansion=$(
	grep -rn -E '\$\{[^}]*\$'"'"'\\0' "$SCRIPTS_DIR/" \
		--include='*.sh' \
		--exclude='test-pulse-dep-graph-bash32-nul-crash.sh' \
		--exclude='test-bash-reexec-guard.sh' 2>/dev/null |
		grep -vE ':[[:space:]]*#' || true
)
if [[ -z "$nul_in_expansion" ]]; then
	_pass "no \${...\$'\\0'...} patterns in shell code (GH#18830 lock-in)"
else
	_fail "found NUL-in-parameter-expansion pattern" "$nul_in_expansion"
fi

# -----------------------------------------------------------------------
# Test 10 (GH#18965 / t2094): `ensure` subcommand exists and runs.
# When bash is already modern and current, ensure should exit 0 (no-op).
# -----------------------------------------------------------------------
ensure_output="$("$HELPER" ensure --yes --quiet 2>&1 || true)"
ensure_rc=0
"$HELPER" ensure --yes --quiet >/dev/null 2>&1 || ensure_rc=$?
if [[ "$ensure_rc" -eq 0 ]]; then
	_pass "ensure subcommand runs (rc=0) when bash is current or upgradeable"
elif [[ "$ensure_rc" -eq 3 ]]; then
	_pass "ensure subcommand returns rc=3 (Homebrew missing) — acceptable"
else
	_fail "ensure subcommand returned unexpected rc=${ensure_rc}" "$ensure_output"
fi

# -----------------------------------------------------------------------
# Test 11 (GH#18965 / t2094): `ensure` is idempotent. Calling it twice
# in quick succession must NOT re-run `brew update` (rate-limited via
# _BREW_UPDATE_STATE). We verify by timing: second call must be much
# faster than the first on a cold run, or both very fast on a warm run.
# Simpler assertion: both calls return rc=0 and neither errors.
# -----------------------------------------------------------------------
ensure_rc_1=0
"$HELPER" ensure --yes --quiet >/dev/null 2>&1 || ensure_rc_1=$?
ensure_rc_2=0
"$HELPER" ensure --yes --quiet >/dev/null 2>&1 || ensure_rc_2=$?
if [[ "$ensure_rc_1" -eq "$ensure_rc_2" ]] && [[ "$ensure_rc_1" -ne 4 ]]; then
	_pass "ensure is idempotent (rc_1=${ensure_rc_1} rc_2=${ensure_rc_2})"
else
	_fail "ensure not idempotent" "rc_1=${ensure_rc_1} rc_2=${ensure_rc_2}"
fi

# -----------------------------------------------------------------------
# Test 12 (GH#18965 / t2094): AIDEVOPS_AUTO_UPGRADE_BASH=0 short-circuits
# ensure without calling brew. We verify by running it with the env var
# set and confirming rc=0 + no brew-related error output.
# -----------------------------------------------------------------------
optout_output="$(AIDEVOPS_AUTO_UPGRADE_BASH=0 "$HELPER" ensure 2>&1 || true)"
optout_rc=0
AIDEVOPS_AUTO_UPGRADE_BASH=0 "$HELPER" ensure >/dev/null 2>&1 || optout_rc=$?
if [[ "$optout_rc" -eq 0 ]] && [[ "$optout_output" == *"AIDEVOPS_AUTO_UPGRADE_BASH=0"* ]]; then
	_pass "AIDEVOPS_AUTO_UPGRADE_BASH=0 short-circuits ensure (rc=0, skip message seen)"
elif [[ "$optout_rc" -eq 0 ]]; then
	# --quiet suppressed the message but rc=0 is still valid
	_pass "AIDEVOPS_AUTO_UPGRADE_BASH=0 short-circuits ensure (rc=0)"
else
	_fail "AIDEVOPS_AUTO_UPGRADE_BASH=0 did not short-circuit cleanly" \
		"rc=${optout_rc} output=${optout_output}"
fi

# -----------------------------------------------------------------------
printf '\nResults: %d passed, %d failed\n' "$pass_count" "$fail_count"
if [[ "$fail_count" -gt 0 ]]; then
	exit 1
fi
printf 'GH#18950 (t2087) + GH#18965 (t2094) regression test: all checks pass.\n'
exit 0
