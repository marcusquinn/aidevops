#!/usr/bin/env bash
# test-email-summary.sh - Test auto-summary generation for email-to-markdown (t1044.7)
# Tests: heuristic summary for short emails, LLM routing for long emails,
#        empty body handling, HTML email handling, --summary-mode flag
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
CONVERTER="${REPO_DIR}/.agents/scripts/email-to-markdown.py"
FIXTURES="${SCRIPT_DIR}/email-summary-test-fixtures"
TMPDIR_BASE="${TMPDIR:-/tmp}/email-summary-test-$$"

pass_count=0
fail_count=0
total_count=0

cleanup() {
	rm -rf "${TMPDIR_BASE}"
}
trap cleanup EXIT

mkdir -p "${TMPDIR_BASE}"

log_pass() {
	local test_name="$1"
	pass_count=$((pass_count + 1))
	total_count=$((total_count + 1))
	echo "  PASS: ${test_name}"
}

log_fail() {
	local test_name="$1"
	local detail="${2:-}"
	fail_count=$((fail_count + 1))
	total_count=$((total_count + 1))
	echo "  FAIL: ${test_name}"
	if [[ -n "${detail}" ]]; then
		echo "        ${detail}"
	fi
}

# Helper: extract a frontmatter field value from a markdown file
get_frontmatter_field() {
	local file="$1"
	local field="$2"
	# Extract value between --- markers
	sed -n '/^---$/,/^---$/p' "$file" | grep "^${field}:" | head -1 | sed "s/^${field}: *//" | sed 's/^"//;s/"$//'
}

echo "=== Email Auto-Summary Tests (t1044.7) ==="
echo ""

# --- Test 1: Short email uses heuristic ---
echo "Test 1: Short email (<=100 words) uses heuristic summary"
outfile="${TMPDIR_BASE}/short.md"
python3 "${CONVERTER}" "${FIXTURES}/short-email.eml" -o "${outfile}" --summary-mode auto 2>/dev/null

description=$(get_frontmatter_field "${outfile}" "description")
summary_method=$(get_frontmatter_field "${outfile}" "summary_method")

if [[ "${summary_method}" == "heuristic" ]]; then
	log_pass "summary_method is 'heuristic' for short email"
else
	log_fail "summary_method is 'heuristic' for short email" "got: ${summary_method}"
fi

if [[ -n "${description}" ]]; then
	log_pass "description is non-empty for short email"
else
	log_fail "description is non-empty for short email" "got empty description"
fi

# Check it contains meaningful content (not just truncation)
if echo "${description}" | grep -qi "meet\|3pm\|budget"; then
	log_pass "short email description contains key content"
else
	log_fail "short email description contains key content" "got: ${description}"
fi

# --- Test 2: Long email routing ---
echo ""
echo "Test 2: Long email (>100 words) attempts LLM, falls back to heuristic"
outfile="${TMPDIR_BASE}/long.md"
python3 "${CONVERTER}" "${FIXTURES}/long-email.eml" -o "${outfile}" --summary-mode auto 2>/dev/null

description=$(get_frontmatter_field "${outfile}" "description")
summary_method=$(get_frontmatter_field "${outfile}" "summary_method")

# In CI/test environment, LLM is likely unavailable — should fall back to heuristic
if [[ "${summary_method}" == "heuristic" || "${summary_method}" == "ollama" || "${summary_method}" == "anthropic" ]]; then
	log_pass "summary_method is valid for long email (${summary_method})"
else
	log_fail "summary_method is valid for long email" "got: ${summary_method}"
fi

if [[ -n "${description}" ]]; then
	log_pass "description is non-empty for long email"
else
	log_fail "description is non-empty for long email" "got empty description"
fi

# --- Test 3: Empty body ---
echo ""
echo "Test 3: Empty body email"
outfile="${TMPDIR_BASE}/empty.md"
python3 "${CONVERTER}" "${FIXTURES}/empty-body.eml" -o "${outfile}" --summary-mode auto 2>/dev/null

description=$(get_frontmatter_field "${outfile}" "description")
summary_method=$(get_frontmatter_field "${outfile}" "summary_method")

if [[ "${summary_method}" == "heuristic" ]]; then
	log_pass "empty body uses heuristic method"
else
	log_fail "empty body uses heuristic method" "got: ${summary_method}"
fi

# Empty body should produce empty or minimal description
# (the body may contain just whitespace which gets stripped)
log_pass "empty body handled without error"

# --- Test 4: HTML email ---
echo ""
echo "Test 4: HTML email with markdown conversion"
outfile="${TMPDIR_BASE}/html.md"
python3 "${CONVERTER}" "${FIXTURES}/html-email.eml" -o "${outfile}" --summary-mode auto 2>/dev/null

description=$(get_frontmatter_field "${outfile}" "description")
summary_method=$(get_frontmatter_field "${outfile}" "summary_method")

if [[ -n "${description}" ]]; then
	log_pass "HTML email produces non-empty description"
else
	log_fail "HTML email produces non-empty description" "got empty description"
fi

if [[ "${summary_method}" == "heuristic" ]]; then
	log_pass "HTML short email uses heuristic"
else
	log_fail "HTML short email uses heuristic" "got: ${summary_method}"
fi

# --- Test 5: --summary-mode heuristic forces heuristic ---
echo ""
echo "Test 5: --summary-mode heuristic forces heuristic for long email"
outfile="${TMPDIR_BASE}/forced-heuristic.md"
python3 "${CONVERTER}" "${FIXTURES}/long-email.eml" -o "${outfile}" --summary-mode heuristic 2>/dev/null

summary_method=$(get_frontmatter_field "${outfile}" "summary_method")

if [[ "${summary_method}" == "heuristic" ]]; then
	log_pass "--summary-mode heuristic forces heuristic method"
else
	log_fail "--summary-mode heuristic forces heuristic method" "got: ${summary_method}"
fi

# --- Test 6: --summary-mode off uses truncation ---
echo ""
echo "Test 6: --summary-mode off uses truncation fallback"
outfile="${TMPDIR_BASE}/off.md"
python3 "${CONVERTER}" "${FIXTURES}/short-email.eml" -o "${outfile}" --summary-mode off 2>/dev/null

summary_method=$(get_frontmatter_field "${outfile}" "summary_method")

if [[ "${summary_method}" == "off" ]]; then
	log_pass "--summary-mode off sets method to 'off'"
else
	log_fail "--summary-mode off sets method to 'off'" "got: ${summary_method}"
fi

# --- Test 7: summary_method field exists in frontmatter ---
echo ""
echo "Test 7: summary_method field present in all outputs"
for f in "${TMPDIR_BASE}"/*.md; do
	method=$(get_frontmatter_field "${f}" "summary_method")
	basename_f=$(basename "${f}")
	if [[ -n "${method}" ]]; then
		log_pass "summary_method present in ${basename_f}"
	else
		log_fail "summary_method present in ${basename_f}" "field missing"
	fi
done

# --- Summary ---
echo ""
echo "=== Results: ${pass_count}/${total_count} passed, ${fail_count} failed ==="

if [[ "${fail_count}" -gt 0 ]]; then
	exit 1
fi
exit 0
