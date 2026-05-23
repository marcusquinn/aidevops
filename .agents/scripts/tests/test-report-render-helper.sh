#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit
HELPER_SH="${SCRIPT_DIR}/../report-render-helper.sh"
FIXTURE_DIR="${SCRIPT_DIR}/fixtures"

readonly TEST_RED='\033[0;31m'
readonly TEST_GREEN='\033[0;32m'
readonly TEST_RESET='\033[0m'

TESTS_RUN=0
TESTS_FAILED=0
TEST_ROOT=""

print_result() {
	local _test_name="$1"
	local _passed="$2"
	local _message="${3:-}"
	TESTS_RUN=$((TESTS_RUN + 1))
	if [[ "$_passed" -eq 0 ]]; then
		printf '%bPASS%b %s\n' "$TEST_GREEN" "$TEST_RESET" "$_test_name"
		return 0
	fi
	printf '%bFAIL%b %s\n' "$TEST_RED" "$TEST_RESET" "$_test_name"
	if [[ -n "$_message" ]]; then
		printf '       %s\n' "$_message"
	fi
	TESTS_FAILED=$((TESTS_FAILED + 1))
	return 0
}

setup_test_env() {
	TEST_ROOT=$(mktemp -d)
	return 0
}

teardown_test_env() {
	if [[ -n "$TEST_ROOT" && -d "$TEST_ROOT" ]]; then
		rm -rf "$TEST_ROOT"
	fi
	return 0
}

assert_contains() {
	local _file="$1"
	local _needle="$2"
	local _label="$3"
	if grep -qF -- "$_needle" "$_file"; then
		print_result "$_label" 0
		return 0
	fi
	print_result "$_label" 1 "Missing '${_needle}' in ${_file}"
	return 0
}

test_render_markdown_fixture() {
	local _out="${TEST_ROOT}/sample-md.html"
	"$HELPER_SH" render "${FIXTURE_DIR}/llm-visibility-report-sample.md" --output "$_out"
	assert_contains "$_out" "sticky-toc" "Markdown render includes sticky TOC"
	assert_contains "$_out" "@media print" "Markdown render includes print CSS"
	assert_contains "$_out" "Evidence: Verified" "Markdown render includes verified badge"
	assert_contains "$_out" "Evidence: Partial" "Markdown render includes partial badge"
	assert_contains "$_out" "Evidence: Inferred" "Markdown render includes inferred badge"
	assert_contains "$_out" "Evidence: Missing" "Markdown render includes missing badge"
	assert_contains "$_out" "source-card" "Markdown render includes source cards"
	assert_contains "$_out" "report-cover" "Markdown render includes cover component"
	assert_contains "$_out" "stats-strip" "Markdown render includes stats component"
	assert_contains "$_out" "example-card" "Markdown render includes example component"
	assert_contains "$_out" "<pre><code>Question:" "Markdown render includes fenced code blocks"
	assert_contains "$_out" "<a href=\"#evidence-ledger\">source ledger</a>" "Markdown render includes safe links"
	assert_contains "$_out" "class=\"accordion\"" "Markdown render includes accordions"
	assert_contains "$_out" "class=\"status-dot\" data-status=\"done\"" "Markdown render includes checklist status"
	assert_contains "$_out" "<footer class=\"report-footer\">" "Markdown render includes copyright footer"
	if grep -q "&lt;!-- SPDX-License-Identifier" "$_out"; then
		print_result "Markdown render suppresses source comments" 1 "SPDX comment leaked into rendered HTML"
	else
		print_result "Markdown render suppresses source comments" 0
	fi
	return 0
}

test_render_json_fixture() {
	local _out="${TEST_ROOT}/sample-json.html"
	"$HELPER_SH" render "${FIXTURE_DIR}/llm-visibility-report-sample.json" --output "$_out"
	assert_contains "$_out" "sticky-toc" "JSON render includes sticky TOC"
	assert_contains "$_out" "@media print" "JSON render includes print CSS"
	assert_contains "$_out" "Evidence: Verified" "JSON render includes verified badge"
	assert_contains "$_out" "Evidence: Partial" "JSON render includes partial badge"
	assert_contains "$_out" "Evidence: Inferred" "JSON render includes inferred badge"
	assert_contains "$_out" "Evidence: Missing" "JSON render includes missing badge"
	assert_contains "$_out" "source-card" "JSON render includes source cards"
	return 0
}

test_validate_rejects_unknown_badge() {
	local _bad="${TEST_ROOT}/bad.md"
	printf '# Bad\n\n{{evidence:unknown}}\n' >"$_bad"
	local _result=0
	"$HELPER_SH" validate "$_bad" >/dev/null 2>&1 || _result=$?
	if [[ "$_result" -ne 1 ]]; then
		print_result "Validate rejects unknown badge" 1 "Expected exit 1, got ${_result}"
		return 0
	fi
	print_result "Validate rejects unknown badge" 0
	return 0
}

test_python_helper_requires_mode() {
	local _result=0
	python3 "${SCRIPT_DIR}/../report-render-helper.py" >/dev/null 2>&1 || _result=$?
	if [[ "$_result" -ne 1 ]]; then
		print_result "Python helper requires mode argument" 1 "Expected exit 1, got ${_result}"
		return 0
	fi
	print_result "Python helper requires mode argument" 0
	return 0
}

test_markdown_table_uses_header_cells() {
	local _input="${TEST_ROOT}/table.md"
	local _out="${TEST_ROOT}/table.html"
	cat >"$_input" <<'MARKDOWN'
# Table

| Component | Evidence |
|---|---|
| AIO | {{evidence:verified}} |
MARKDOWN
	"$HELPER_SH" render "$_input" --output "$_out"
	assert_contains "$_out" "<thead>" "Markdown table renders thead"
	assert_contains "$_out" "<th>Component</th>" "Markdown table renders header cells"
	assert_contains "$_out" "<td>AIO</td>" "Markdown table renders body cells"
	return 0
}

test_multiline_markdown_paragraph() {
	local _input="${TEST_ROOT}/paragraph.md"
	local _out="${TEST_ROOT}/paragraph.html"
	cat >"$_input" <<'MARKDOWN'
# Paragraph

First line continues
onto the next line.
MARKDOWN
	"$HELPER_SH" render "$_input" --output "$_out"
	assert_contains "$_out" "<p>First line continues onto the next line.</p>" "Markdown joins paragraph lines"
	return 0
}

test_render_json_array_is_resilient() {
	local _input="${TEST_ROOT}/array.json"
	local _out="${TEST_ROOT}/array.html"
	printf '[{"title":"List item","badge":"verified"}]\n' >"$_input"
	"$HELPER_SH" render "$_input" --output "$_out"
	assert_contains "$_out" "<h1 id=\"report\">Report</h1>" "JSON array render falls back to report title"
	return 0
}

test_sample_and_css_commands() {
	local _sample="${TEST_ROOT}/sample.md"
	local _css="${TEST_ROOT}/print.css"
	local _instructional="${TEST_ROOT}/instructional.md"
	"$HELPER_SH" sample markdown >"$_sample"
	"$HELPER_SH" sample instructional-seo-geo >"$_instructional"
	"$HELPER_SH" print-css >"$_css"
	assert_contains "$_sample" "{{evidence:verified}}" "Sample command emits Markdown report"
	assert_contains "$_instructional" "LLM Visibility Instructional Toolbox" "Sample command emits instructional SEO/GEO report"
	assert_contains "$_css" "@media print" "print-css emits print stylesheet"
	return 0
}

test_render_template_and_profiles() {
	local _out="${TEST_ROOT}/editorial.html"
	local _dark="${TEST_ROOT}/lottiefiles-dark.html"
	local _slides="${TEST_ROOT}/slides.css"
	"$HELPER_SH" render "${FIXTURE_DIR}/llm-visibility-report-sample.md" \
		--template axel \
		--pdf-profile a4 \
		--output "$_out"
	"$HELPER_SH" render "${FIXTURE_DIR}/llm-visibility-report-sample.md" \
		--template lottiefiles \
		--theme dark \
		--pdf-profile a4 \
		--output "$_dark"
	"$HELPER_SH" print-css --template axel --pdf-profile slides-16-9-2 >"$_slides"
	assert_contains "$_out" "report-template-axel" "Render supports named style template"
	assert_contains "$_out" "Newsreader" "Render includes style-specific fonts"
	assert_contains "$_out" "size: A4 portrait" "Render defaults to A4 portrait profile"
	assert_contains "$_dark" "report-theme-dark" "Render supports forced dark theme"
	assert_contains "$_dark" "--report-info-bg: #161A1C" "Dark theme inverts info panels"
	assert_contains "$_dark" "--report-good-bg: #161A1C" "Dark theme inverts good panels"
	assert_contains "$_slides" "size: 16in 9in" "print-css supports 16:9 landscape profile"
	assert_contains "$_slides" "column-count: 2" "print-css supports two-column presentation profile"
	return 0
}

test_list_templates() {
	local _templates="${TEST_ROOT}/templates.txt"
	"$HELPER_SH" list-templates >"$_templates"
	assert_contains "$_templates" "arxiv" "Template list includes original arXiv brief style"
	assert_contains "$_templates" "wikipedia" "Template list includes original Wikipedia brief style"
	assert_contains "$_templates" "terminalshop" "Template list includes original Terminal Shop brief style"
	"$HELPER_SH" list-dark-templates >"$_templates"
	assert_contains "$_templates" "lottiefiles" "Dark template list includes LottieFiles"
	return 0
}

main() {
	setup_test_env
	trap teardown_test_env EXIT
	test_render_markdown_fixture
	test_render_json_fixture
	test_validate_rejects_unknown_badge
	test_python_helper_requires_mode
	test_markdown_table_uses_header_cells
	test_multiline_markdown_paragraph
	test_render_json_array_is_resilient
	test_sample_and_css_commands
	test_render_template_and_profiles
	test_list_templates
	printf '\nReport render helper tests: %s run, %s failed\n' "$TESTS_RUN" "$TESTS_FAILED"
	if [[ "$TESTS_FAILED" -ne 0 ]]; then
		return 1
	fi
	return 0
}

main "$@"
