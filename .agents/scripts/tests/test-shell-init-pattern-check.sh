#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# test-shell-init-pattern-check.sh — regression tests for the t2053 Phase 2
# shell init pattern lint gate (shell-init-pattern-check.sh).
#
# Failure history motivating this gate: GH#18702 — unguarded GREEN= in
# init-routines-helper.sh collided with readonly GREEN in shared-constants.sh,
# aborting setup.sh under set -Eeuo pipefail. Auto-update broken for 4 days.
#
# Coverage:
#   (a) plain unguarded RED='...' at column 0 → violation (Banned pattern 1)
#   (b) readonly RED='...' outside shared-constants.sh → violation (Banned pattern 2)
#   (c) Pattern A (source shared-constants.sh) → clean
#   (d) Pattern B ([[ -z "${VAR+x}" ]] &&) → clean
#   (e) Pattern C (TEST_RED=...) → clean (prefixed names are not canonical)
#   (f) unguarded BOLD= → clean (not a canonical color per style guide §99)
#   (g) canonical set is RED/GREEN/YELLOW/BLUE/PURPLE/CYAN/WHITE/NC only
#   (h) shared-constants.sh is unconditionally exempt (even with bare assigns)
#   (i) indented assignment (inside function) → clean (not top-level)
#   (j) same-line guard: RED= on same line as [[ -z "${RED+x}" ]] → clean

# NOTE: not using set -e intentionally — negative assertions rely on
# capturing non-zero exits from the scanner. Each assertion explicitly
# checks exit codes via `if ...; then ...; fi`.
set -uo pipefail

TESTS_SCRIPTS_DIR="$(cd "$(dirname "$0")/.." && pwd)"

# Pattern C test colors — prefixed names to avoid collision when this test
# script is sourced by other test runners.
TEST_RED=$'\033[0;31m'
TEST_GREEN=$'\033[0;32m'
TEST_RESET=$'\033[0m'

TESTS_RUN=0
TESTS_FAILED=0

SCANNER="${TESTS_SCRIPTS_DIR}/shell-init-pattern-check.sh"

# ── test infrastructure ────────────────────────────────────────────────────

print_result() {
	local _name="$1"
	local _rc="$2"
	local _extra="${3:-}"
	TESTS_RUN=$((TESTS_RUN + 1))
	if [[ "${_rc}" -eq 0 ]]; then
		printf '%sPASS%s %s\n' "${TEST_GREEN}" "${TEST_RESET}" "${_name}"
	else
		printf '%sFAIL%s %s %s\n' "${TEST_RED}" "${TEST_RESET}" "${_name}" "${_extra}"
		TESTS_FAILED=$((TESTS_FAILED + 1))
	fi
	return 0
}

assert_violation() {
	local _desc="$1"
	local _fixture="$2"
	local _rc
	"${SCANNER}" --scan-files "${_fixture}" >/dev/null 2>&1
	_rc=$?
	if [[ "${_rc}" -eq 1 ]]; then
		print_result "${_desc}" 0
	else
		print_result "${_desc}" 1 "(expected exit 1 for violation, got ${_rc})"
	fi
	return 0
}

assert_clean() {
	local _desc="$1"
	local _fixture="$2"
	local _rc
	"${SCANNER}" --scan-files "${_fixture}" >/dev/null 2>&1
	_rc=$?
	if [[ "${_rc}" -eq 0 ]]; then
		print_result "${_desc}" 0
	else
		print_result "${_desc}" 1 "(expected exit 0 for clean, got ${_rc})"
	fi
	return 0
}

# Create scratch directory for fixture files
SCRATCH=$(mktemp -d)
trap 'rm -rf "${SCRATCH}"' EXIT

# ── fixtures ──────────────────────────────────────────────────────────────

# (a) Banned pattern 1: unguarded plain assignment at column 0
cat >"${SCRATCH}/fixture_a_unguarded_plain.sh" <<'EOF'
#!/usr/bin/env bash
set -uo pipefail
RED='\033[0;31m'
GREEN='\033[0;32m'
echo "hello"
EOF

# (b) Banned pattern 2: readonly on canonical name outside shared-constants.sh
cat >"${SCRATCH}/fixture_b_readonly.sh" <<'EOF'
#!/usr/bin/env bash
set -uo pipefail
readonly RED='\033[0;31m'
echo "hello"
EOF

# (c) Pattern A — source shared-constants.sh (clean)
cat >"${SCRATCH}/fixture_c_pattern_a.sh" <<'EOF'
#!/usr/bin/env bash
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=shared-constants.sh
[[ -f "${SCRIPT_DIR}/shared-constants.sh" ]] && source "${SCRIPT_DIR}/shared-constants.sh"
echo "${GREEN}[OK]${NC} hello"
EOF

# (d) Pattern B — [[ -z "${VAR+x}" ]] guard on previous line (clean)
cat >"${SCRATCH}/fixture_d_pattern_b.sh" <<'EOF'
#!/usr/bin/env bash
set -uo pipefail
[[ -z "${RED+x}" ]]    && RED='\033[0;31m'
[[ -z "${GREEN+x}" ]]  && GREEN='\033[0;32m'
[[ -z "${YELLOW+x}" ]] && YELLOW='\033[1;33m'
[[ -z "${NC+x}" ]]     && NC='\033[0m'
echo "hello"
EOF

# (e) Pattern C — prefixed names like TEST_RED (clean — not canonical names)
cat >"${SCRATCH}/fixture_e_pattern_c.sh" <<'EOF'
#!/usr/bin/env bash
set -uo pipefail
TEST_RED=$'\033[0;31m'
TEST_GREEN=$'\033[0;32m'
TEST_RESET=$'\033[0m'
echo "hello"
EOF

# (f) Non-canonical color BOLD= (clean — not in the banned set)
cat >"${SCRATCH}/fixture_f_bold.sh" <<'EOF'
#!/usr/bin/env bash
set -uo pipefail
BOLD='\033[1m'
DIM='\033[2m'
MAGENTA='\033[0;35m'
echo "hello"
EOF

# (g) All 8 canonical names — each should trigger independently (one violation each)
for _varname in RED GREEN YELLOW BLUE PURPLE CYAN WHITE NC; do
	cat >"${SCRATCH}/fixture_g_${_varname}.sh" <<EOF
#!/usr/bin/env bash
set -uo pipefail
${_varname}='\\033[0;31m'
echo "hello"
EOF
done

# (h) shared-constants.sh is unconditionally exempt (even with bare assigns + readonly)
cat >"${SCRATCH}/shared-constants.sh" <<'EOF'
#!/usr/bin/env bash
# This is a fake shared-constants.sh — exempt from all checks
[[ -n "${_SHARED_CONSTANTS_LOADED:-}" ]] && return 0
_SHARED_CONSTANTS_LOADED=1
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
GREEN='\033[0;32m'
EOF

# (i) Indented assignment inside function body (clean — not top-level)
cat >"${SCRATCH}/fixture_i_indented.sh" <<'EOF'
#!/usr/bin/env bash
set -uo pipefail
setup_colors() {
    RED='\033[0;31m'
    GREEN='\033[0;32m'
}
echo "hello"
EOF

# (j) Same-line guard: [[ -z "${RED+x}" ]] && RED= (clean)
cat >"${SCRATCH}/fixture_j_sameline_guard.sh" <<'EOF'
#!/usr/bin/env bash
set -uo pipefail
[[ -z "${RED+x}" ]] && RED='\033[0;31m'
echo "hello"
EOF

# ── assertions ────────────────────────────────────────────────────────────

printf '\n=== shell-init-pattern-check tests ===\n\n'

# (a) unguarded plain assignment → violation
assert_violation "(a) unguarded plain RED= at column 0 fails" \
	"${SCRATCH}/fixture_a_unguarded_plain.sh"

# (b) readonly on canonical name → violation
assert_violation "(b) readonly RED= outside shared-constants.sh fails" \
	"${SCRATCH}/fixture_b_readonly.sh"

# (c) Pattern A (source shared-constants.sh) → clean
assert_clean "(c) Pattern A (source shared-constants.sh) passes" \
	"${SCRATCH}/fixture_c_pattern_a.sh"

# (d) Pattern B (guarded [[ -z "${VAR+x}" ]]) → clean
assert_clean "(d) Pattern B ([[ -z \\${VAR+x} ]] guard) passes" \
	"${SCRATCH}/fixture_d_pattern_b.sh"

# (e) Pattern C (prefixed TEST_RED) → clean
assert_clean "(e) Pattern C (TEST_RED prefixed names) passes" \
	"${SCRATCH}/fixture_e_pattern_c.sh"

# (f) BOLD= is not in the canonical set → clean
assert_clean "(f) BOLD= (non-canonical) passes" \
	"${SCRATCH}/fixture_f_bold.sh"

# (g) All 8 canonical names individually trigger violations
for _varname in RED GREEN YELLOW BLUE PURPLE CYAN WHITE NC; do
	assert_violation "(g) canonical ${_varname}= at column 0 fails" \
		"${SCRATCH}/fixture_g_${_varname}.sh"
done

# (h) shared-constants.sh exempt even with bare assigns and readonly
assert_clean "(h) shared-constants.sh unconditionally exempt" \
	"${SCRATCH}/shared-constants.sh"

# (i) indented assignment (inside function) → clean
assert_clean "(i) indented assignment inside function passes" \
	"${SCRATCH}/fixture_i_indented.sh"

# (j) same-line guard → clean
assert_clean "(j) same-line [[ -z \\${VAR+x} ]] && VAR= guard passes" \
	"${SCRATCH}/fixture_j_sameline_guard.sh"

# ── scanner self-check (scanner follows Pattern A) ────────────────────────

assert_clean "(self) scanner itself is violation-free (Pattern A compliance)" \
	"${SCANNER}"

# ── --fix-hint flag exits 0 and prints hint ───────────────────────────────

TESTS_RUN=$((TESTS_RUN + 1))
fix_hint_out=$("${SCANNER}" --fix-hint 2>&1)
fix_hint_rc=$?
if [[ "${fix_hint_rc}" -eq 0 ]] && printf '%s' "${fix_hint_out}" | grep -q "Pattern A"; then
	printf '%sPASS%s (fix-hint) --fix-hint exits 0 and prints remediation text\n' \
		"${TEST_GREEN}" "${TEST_RESET}"
else
	printf '%sFAIL%s (fix-hint) --fix-hint expected exit 0 and "Pattern A" text (rc=%d)\n' \
		"${TEST_RED}" "${TEST_RESET}" "${fix_hint_rc}"
	TESTS_FAILED=$((TESTS_FAILED + 1))
fi

# ── --scan-all exits 0 on clean temp dir ─────────────────────────────────

CLEAN_DIR=$(mktemp -d)
trap 'rm -rf "${CLEAN_DIR}" "${SCRATCH}"' EXIT
cat >"${CLEAN_DIR}/clean.sh" <<'EOF'
#!/usr/bin/env bash
[[ -z "${RED+x}" ]] && RED='\033[0;31m'
echo "hello"
EOF

TESTS_RUN=$((TESTS_RUN + 1))
scan_all_rc=0
# Temporarily point scanner's SCRIPT_DIR equivalent to the clean dir
# by creating a fake shared-constants.sh target and scanning the clean dir.
# We scan the clean file directly since --scan-all uses SCRIPT_DIR.
"${SCANNER}" --scan-files "${CLEAN_DIR}/clean.sh" >/dev/null 2>&1
scan_all_rc=$?
if [[ "${scan_all_rc}" -eq 0 ]]; then
	printf '%sPASS%s (scan-all-clean) --scan-files on clean file exits 0\n' \
		"${TEST_GREEN}" "${TEST_RESET}"
else
	printf '%sFAIL%s (scan-all-clean) --scan-files on clean file expected exit 0, got %d\n' \
		"${TEST_RED}" "${TEST_RESET}" "${scan_all_rc}"
	TESTS_FAILED=$((TESTS_FAILED + 1))
fi

rm -rf "${CLEAN_DIR}"

# ── summary ───────────────────────────────────────────────────────────────

printf '\n'
if [[ "${TESTS_FAILED}" -eq 0 ]]; then
	printf '%sAll %d tests passed.%s\n' "${TEST_GREEN}" "${TESTS_RUN}" "${TEST_RESET}"
	exit 0
else
	printf '%s%d of %d tests FAILED.%s\n' "${TEST_RED}" "${TESTS_FAILED}" "${TESTS_RUN}" "${TEST_RESET}"
	exit 1
fi
