#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# test-pre-commit-ratchet.sh — verify ratchet gating for validate_positional_parameters (t2384)
#
# Tests:
#   1. File at baseline count → passes (no block)
#   2. File with NEW violations above baseline → blocks
#   3. File with FEWER violations than baseline → passes (improvement)
#   4. File NOT in baseline (new file) → any violation blocks
#   5. Awk $1 inside single-quoted strings is not a false positive
#   6. Missing baseline file → falls back to absolute gating (baseline=0)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/../shared-constants.sh" 2>/dev/null || true

PASS=0
FAIL=0
TOTAL=0

assert_eq() {
	local description="$1"
	local expected="$2"
	local actual="$3"
	((TOTAL++)) || true
	if [[ "$expected" == "$actual" ]]; then
		echo "  PASS: $description"
		((PASS++)) || true
	else
		echo "  FAIL: $description (expected=$expected, actual=$actual)"
		((FAIL++)) || true
	fi
	return 0
}

# --- Setup temp environment ---
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

# Create a minimal git repo for git rev-parse to work
git init --quiet "$TMP_DIR/repo"
REPO="$TMP_DIR/repo"
mkdir -p "$REPO/.agents/configs"
mkdir -p "$REPO/.agents/scripts"

# Create baseline file: test-file.sh has 3 known violations
cat >"$REPO/.agents/configs/positional-params-baseline.json" <<'BASELINE'
{
  "version": 1,
  "description": "Test baseline",
  "files": {
    "test-file.sh": 3,
    "test-awk.sh": 2
  }
}
BASELINE

# --- Extract validate_positional_parameters for isolated testing ---
# We source the hook in a controlled way. Since the hook sources shared-constants.sh,
# we stub the missing functions.

# Create a test harness that runs validate_positional_parameters in the temp repo context
create_test_harness() {
	cat >"$REPO/test-harness.sh" <<'HARNESS'
#!/usr/bin/env bash
set -uo pipefail

# Stub print functions
print_info()  { echo "[INFO] $1"; return 0; }
print_error() { echo "[ERROR] $1"; return 0; }

# The validate_positional_parameters function (copied from pre-commit-hook.sh
# with the ratchet logic). We inline it here to test in isolation.
validate_positional_parameters() {
	local violations=0
	local repo_root
	repo_root="$(git rev-parse --show-toplevel 2>/dev/null)" || repo_root=""
	local baseline_file="${repo_root}/.agents/configs/positional-params-baseline.json"

	for file in "$@"; do
		if [[ -f "$file" ]]; then
			local violations_output
			# shellcheck disable=SC2016
			violations_output=$(awk '
			{
				line = $0
				gsub(/\047[^\047]*\047/, "", line)
				if (line ~ /^[[:space:]]*#/) next
				sub(/[[:space:]]+#.*/, "", line)
				if (line ~ /local[[:space:]].*=.*\$[1-9]/) next
				if (line ~ /\$[1-9][0-9.,\/]/) next
				if (line ~ /\$[1-9][[:space:]]*\|/) next
				if (line ~ /\$[1-9][[:space:]]+(per|mo(nth)?|year|yr|day|week|hr|hour|flat|each|off|fee|plan|tier|user|seat|unit|addon|setup|trial|credit|annual|quarterly|monthly)/) next
				if (line ~ /\$[1-9]/) print NR ": " $0
			}' "$file") || true

			if [[ -n "$violations_output" ]]; then
				local current_count
				current_count=$(echo "$violations_output" | wc -l | tr -d ' ')
				local baseline_count=0

				if [[ -f "$baseline_file" ]] && command -v jq &>/dev/null; then
					local _bl
					_bl=$(jq -r --arg f "$file" '.files[$f] // 0' "$baseline_file" 2>/dev/null) || _bl=0
					baseline_count="${_bl}"
				fi

				if [[ "$current_count" -gt "$baseline_count" ]]; then
					local new_violations=$((current_count - baseline_count))
					print_error "Positional parameter regression in $file (+${new_violations} new, ${current_count} total vs ${baseline_count} baseline)"
					echo "$violations_output" | head -3
					((++violations))
				elif [[ "$current_count" -lt "$baseline_count" ]]; then
					print_info "Positional parameters improved in $file (${current_count} vs ${baseline_count} baseline — consider updating baseline)"
				else
					print_info "Positional parameters at baseline in $file (${current_count} pre-existing)"
				fi
			fi
		fi
	done

	return $violations
}

# Run the function and capture exit code
validate_positional_parameters "$@"
exit $?
HARNESS
	chmod +x "$REPO/test-harness.sh"
	return 0
}

create_test_harness

echo "=== test-pre-commit-ratchet.sh ==="
echo ""

# --- Test 1: File at baseline count (3 violations, baseline=3) → pass ---
echo "Test 1: File at baseline count → passes"
cat >"$REPO/test-file.sh" <<'SCRIPT'
#!/usr/bin/env bash
foo() {
    echo $1
    echo $2
    echo $3
}
SCRIPT
# Run from within the repo so git rev-parse finds the right root
output=$(cd "$REPO" && bash test-harness.sh test-file.sh 2>&1) || true
exit_code=$(cd "$REPO" && bash test-harness.sh test-file.sh >/dev/null 2>&1; echo $?)
assert_eq "baseline-match passes (exit 0)" "0" "$exit_code"

# --- Test 2: File with MORE violations than baseline → blocks ---
echo "Test 2: File with new violations above baseline → blocks"
cat >"$REPO/test-file.sh" <<'SCRIPT'
#!/usr/bin/env bash
foo() {
    echo $1
    echo $2
    echo $3
    echo $4
    echo $5
}
SCRIPT
exit_code=$(cd "$REPO" && bash test-harness.sh test-file.sh >/dev/null 2>&1; echo $?)
assert_eq "regression blocks (exit 1)" "1" "$exit_code"

# --- Test 3: File with FEWER violations than baseline → passes ---
echo "Test 3: File with fewer violations (improvement) → passes"
cat >"$REPO/test-file.sh" <<'SCRIPT'
#!/usr/bin/env bash
foo() {
    local arg="$1"
    echo $2
}
SCRIPT
exit_code=$(cd "$REPO" && bash test-harness.sh test-file.sh >/dev/null 2>&1; echo $?)
assert_eq "improvement passes (exit 0)" "0" "$exit_code"

# --- Test 4: New file NOT in baseline → any violation blocks ---
echo "Test 4: New file not in baseline → any violation blocks"
cat >"$REPO/new-file.sh" <<'SCRIPT'
#!/usr/bin/env bash
bar() {
    echo $1
}
SCRIPT
exit_code=$(cd "$REPO" && bash test-harness.sh new-file.sh >/dev/null 2>&1; echo $?)
assert_eq "new-file violation blocks (exit 1)" "1" "$exit_code"

# --- Test 5: Awk $1 inside single-quoted strings is NOT a false positive ---
echo "Test 5: Awk field refs inside single quotes → no false positive"
cat >"$REPO/test-awk-clean.sh" <<'SCRIPT'
#!/usr/bin/env bash
process() {
    local input="$1"
    awk '$1 >= 3 { print $2 }' "$input"
    awk '{print $1}' /tmp/file
}
SCRIPT
exit_code=$(cd "$REPO" && bash test-harness.sh test-awk-clean.sh >/dev/null 2>&1; echo $?)
assert_eq "awk single-quote refs ignored (exit 0)" "0" "$exit_code"

# --- Test 6: Missing baseline file → falls back to absolute gating ---
echo "Test 6: Missing baseline file → absolute gating (baseline=0)"
mv "$REPO/.agents/configs/positional-params-baseline.json" "$REPO/.agents/configs/positional-params-baseline.json.bak"
cat >"$REPO/test-file.sh" <<'SCRIPT'
#!/usr/bin/env bash
foo() {
    echo $1
}
SCRIPT
exit_code=$(cd "$REPO" && bash test-harness.sh test-file.sh >/dev/null 2>&1; echo $?)
assert_eq "missing baseline → blocks any violation (exit 1)" "1" "$exit_code"
mv "$REPO/.agents/configs/positional-params-baseline.json.bak" "$REPO/.agents/configs/positional-params-baseline.json"

# --- Test 7: Clean file (no violations) → passes regardless ---
echo "Test 7: Clean file with no violations → passes"
cat >"$REPO/clean-file.sh" <<'SCRIPT'
#!/usr/bin/env bash
baz() {
    local arg="$1"
    local other="$2"
    echo "$arg" "$other"
}
SCRIPT
exit_code=$(cd "$REPO" && bash test-harness.sh clean-file.sh >/dev/null 2>&1; echo $?)
assert_eq "clean file passes (exit 0)" "0" "$exit_code"

# --- Summary ---
echo ""
echo "=== Results: ${PASS}/${TOTAL} passed, ${FAIL} failed ==="

if [[ $FAIL -gt 0 ]]; then
	exit 1
fi
exit 0
