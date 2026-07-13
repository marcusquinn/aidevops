#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"
TMPDIR_TEST="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_TEST"' EXIT

pass_count=0
fail_count=0

pass() {
	local name="$1"
	printf 'PASS: %s\n' "$name"
	pass_count=$((pass_count + 1))
	return 0
}

fail() {
	local name="$1"
	local detail="${2:-}"
	printf 'FAIL: %s%s\n' "$name" "${detail:+ — $detail}"
	fail_count=$((fail_count + 1))
	return 0
}

assert_contains() {
	local name="$1"
	local needle="$2"
	local haystack="$3"
	if [[ "$haystack" == *"$needle"* ]]; then
		pass "$name"
	else
		fail "$name" "missing ${needle}"
	fi
	return 0
}

assert_not_contains() {
	local name="$1"
	local needle="$2"
	local haystack="$3"
	if [[ "$haystack" == *"$needle"* ]]; then
		fail "$name" "unexpected ${needle}"
	else
		pass "$name"
	fi
	return 0
}

fixture_root="${TMPDIR_TEST}/framework"
mkdir -p "$fixture_root"
ln -s "${REPO_ROOT}/.agents" "${fixture_root}/.agents"

python3 - "${REPO_ROOT}/aidevops.sh" "${TMPDIR_TEST}/update-function.sh" <<'PY'
import sys

source_path, output_path = sys.argv[1:]
capturing = False
with open(source_path, encoding="utf-8") as source, open(output_path, "w", encoding="utf-8") as output:
    for line in source:
        if line.startswith("_run_update_setup() {"):
            capturing = True
        if capturing:
            output.write(line)
            if line.strip() == "}":
                break
PY

# shellcheck disable=SC1090
source "${TMPDIR_TEST}/update-function.sh"

print_error() {
	local message="$1"
	printf 'ERROR: %s\n' "$message" >&2
	return 0
}

cat >"${fixture_root}/setup.sh" <<'SETUP'
#!/usr/bin/env bash
for number in 1 2 3 4 5 6; do
	printf 'verbose setup line %s\n' "$number"
done
printf '[SETUP_COMPLETE] fixture complete\n'
SETUP
chmod +x "${fixture_root}/setup.sh"

INSTALL_DIR="$fixture_root"
export INSTALL_DIR
export AIDEVOPS_OUTPUT_SANDBOX_DIR="${TMPDIR_TEST}/sandbox"

compact_output=$(_run_update_setup compact)
assert_contains "compact update emits evidence receipt" "outcome: succeeded" "$compact_output"
assert_not_contains "compact update suppresses successful setup log" "verbose setup line" "$compact_output"

full_output=$(_run_update_setup full)
assert_contains "verbose update preserves native setup output" "verbose setup line 1" "$full_output"
assert_contains "verbose update preserves completion sentinel" "[SETUP_COMPLETE]" "$full_output"

cat >"${fixture_root}/setup.sh" <<'SETUP'
#!/usr/bin/env bash
printf 'setup returned zero without its sentinel\n'
SETUP
chmod +x "${fixture_root}/setup.sh"

set +e
missing_output=$(_run_update_setup compact)
missing_rc=$?
set -e
[[ "$missing_rc" -eq 1 ]] && pass "compact update verifies completion sentinel" || fail "compact update verifies completion sentinel" "got ${missing_rc}"
assert_contains "missing sentinel remains diagnosable" "basis=missing-expected-text" "$missing_output"

printf '%s passed, %s failed\n' "$pass_count" "$fail_count"
if [[ "$fail_count" -ne 0 ]]; then
	exit 1
fi
