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

assert_not_contains() {
	local _file="$1"
	local _needle="$2"
	local _label="$3"
	if grep -qF -- "$_needle" "$_file"; then
		print_result "$_label" 1 "Found '${_needle}' in ${_file}"
		return 0
	fi
	print_result "$_label" 0
	return 0
}

test_render_markdown_fixture() {
	local _out="${TEST_ROOT}/report.html"
	"$HELPER_SH" render "${FIXTURE_DIR}/llm-visibility-report-sample.md" --template editorial-evidence --output "$_out"
	assert_contains "$_out" "sticky-toc" "Markdown render includes sticky TOC"
	assert_contains "$_out" "list-style: none" "Markdown render removes browser TOC list numbering"
	assert_contains "$_out" "@media print" "Markdown render includes print CSS"
	assert_contains "$_out" "evidence-label" "Markdown render includes plain evidence label"
	assert_contains "$_out" "evidence-badge" "Markdown render groups evidence label and badge"
	assert_contains "$_out" "badge-verified\">Verified</span>" "Markdown render includes verified badge"
	assert_contains "$_out" "badge-partial\">Partial</span>" "Markdown render includes partial badge"
	assert_contains "$_out" "badge-inferred\">Inferred</span>" "Markdown render includes inferred badge"
	assert_contains "$_out" "badge-missing\">Missing</span>" "Markdown render includes missing badge"
	assert_contains "$_out" "source-card" "Markdown render includes source cards"
	assert_contains "$_out" "source-card-link" "Markdown render includes source card link affordances"
	assert_contains "$_out" "report-cover" "Markdown render includes cover component"
	assert_contains "$_out" "stats-strip" "Markdown render includes stats component"
	assert_contains "$_out" "example-card" "Markdown render includes example component"
	assert_contains "$_out" "<code>Question:" "Markdown render includes fenced code blocks"
	assert_contains "$_out" "<a href=\"#evidence-ledger\"" "Markdown render includes safe links"
	assert_contains "$_out" "class=\"accordion\"" "Markdown render includes accordions"
	assert_contains "$_out" "class=\"status-dot\" data-status=\"done\"" "Markdown render includes checklist status"
	assert_contains "$_out" "class=\"mermaid\"" "Markdown render includes Mermaid chart blocks"
	assert_contains "$_out" "class=\"latex-inline\"" "Markdown render includes inline LaTeX"
	assert_contains "$_out" "class=\"appendix-links\"" "Markdown render includes appendix links"
	assert_contains "$_out" "data-filetype=\"pdf\"" "Markdown render includes appendix file types"
	assert_contains "$_out" "class=\"sources-layout\"" "Markdown render includes sources layout"
	assert_contains "$_out" "class=\"source-list\"" "Markdown render includes source lists"
	assert_contains "$_out" "class=\"case-study-card\"" "Markdown render includes case study cards"
	assert_contains "$_out" "class=\"badge-key\"" "Markdown render includes badge key"
	assert_contains "$_out" "Peer-Review" "Markdown render labels peer-review badge clearly"
	assert_contains "$_out" "class=\"block-template\"" "Markdown render includes block templates"
	assert_contains "$_out" "class=\"version-summary\"" "Markdown render includes version summary"
	assert_contains "$_out" "Mermaid source fallback" "Markdown render labels Mermaid fallback"
	assert_contains "$_out" "class=\"mermaid-rendered\"" "Markdown render includes self-contained Mermaid SVG"
	assert_contains "$_out" "class=\"latex-rendered-block\"" "Markdown render includes self-contained LaTeX block"
	assert_contains "$_out" "class=\"code-copy\"" "Markdown render includes copy buttons for code"
	assert_contains "$_out" "code-copy.is-copied" "Markdown render includes copy feedback state"
	assert_contains "$_out" "class=\"accordion action-prompt\"" "Markdown render includes action prompt accordions"
	if python3 - "$_out" <<'PYHTML'
from pathlib import Path
import re
import sys

text = Path(sys.argv[1]).read_text()
match = re.search(r'<section class="(?:action-line|action-panel)"[^>]*>(.*?)</section>', text, re.S)
raise SystemExit(0 if match and 'class="accordion action-prompt"' in match.group(1) else 1)
PYHTML
	then
		print_result "Markdown render places action prompts inside action sections" 0
	else
		print_result "Markdown render places action prompts inside action sections" 1 "Expected action prompt markup before closing action section"
	fi
	assert_contains "$_out" "<details class=\"accordion\" open" "Markdown render opens accordions for PDF output"
	assert_contains "$_out" "class=\"toc-pdf-link\"" "Markdown render includes TOC PDF link"
	assert_contains "$_out" ">A4</a>" "Markdown render labels portrait PDF as A4"
	assert_contains "$_out" "href=\"report-a4.pdf\"" "Markdown render links TOC A4 PDF button"
	assert_contains "$_out" "href=\"report-usletter.pdf\"" "Markdown render links TOC US Letter PDF button"
	assert_contains "$_out" "href=\"report-slides.pdf\"" "Markdown render links TOC slides PDF button"
	assert_contains "$_out" ">US Letter</a>" "Markdown render labels US Letter PDF"
	assert_contains "$_out" ">Slides</a>" "Markdown render labels slides PDF"
	assert_contains "$_out" "display: inline-flex" "Markdown render vertically centers TOC PDF button"
	assert_contains "$_out" ".toc-pdf-actions, .toc-pdf-link { display: none !important; }" "Markdown print hides TOC PDF buttons"
	assert_contains "$_out" ".source-card-link[href]::after" "Markdown print suppresses source link URLs"
	assert_contains "$_out" "text-align: left" "Markdown render left-aligns version summary"
	assert_contains "$_out" "text-wrap: pretty" "Markdown render includes smart text wrapping"
	assert_contains "$_out" "style=\"--bar-value: 64%\"" "Markdown render splits bar chart rows"
	assert_contains "${TEST_ROOT}/llm-visibility-report-sample-action-prompts.md" "Guide me through the tools" "Render writes companion action prompts file"
	assert_contains "$_out" "heading-number\">1.</span> Method" "Markdown render numbers body H2 headings"
	if grep -qF "Chapter 1 /" "$_out"; then
		print_result "Markdown TOC omits Chapter prefix" 1 "Found Chapter prefix in rendered TOC labels"
	else
		print_result "Markdown TOC omits Chapter prefix" 0
	fi
	if python3 - "$_out" <<'PYHTML'
from pathlib import Path
import re
text = Path(__import__('sys').argv[1]).read_text()
nav = re.search(r'<nav class="sticky-toc".*?</nav>', text, re.S)
nav_text = nav.group(0) if nav else ''
raise SystemExit(0 if '1. Executive Summary' not in nav_text and re.search(r'>\s*1\.1\s', nav_text) else 1)
PYHTML
	then
		print_result "Markdown TOC keeps executive unnumbered and H3 decimal" 0
	else
		print_result "Markdown TOC keeps executive unnumbered and H3 decimal" 1 "Expected unnumbered executive summary and decimal H3 entries"
	fi
	if python3 - "$_out" <<'PYHTML'
from pathlib import Path
import re
text = Path(__import__('sys').argv[1]).read_text()
nav = re.search(r'<nav class="sticky-toc".*?</nav>', text, re.S)
raise SystemExit(0 if nav and 'class="badge' not in nav.group(0) else 1)
PYHTML
	then
		print_result "Markdown TOC omits badges" 0
	else
		print_result "Markdown TOC omits badges" 1 "Found badge markup in rendered TOC"
	fi
	assert_contains "$_out" "<footer class=\"report-footer\">" "Markdown render includes copyright footer"
	if grep -q "&lt;!-- SPDX-License-Identifier" "$_out"; then
		print_result "Markdown render suppresses source comments" 1 "SPDX comment leaked into rendered HTML"
	else
		print_result "Markdown render suppresses source comments" 0
	fi
	return 0
}

test_render_markdown_layout_fixture() {
	local _out="${TEST_ROOT}/report-layout.html"
	"$HELPER_SH" render "${FIXTURE_DIR}/llm-visibility-report-sample.md" --template editorial-evidence --output "$_out"
	assert_contains "$_out" "margin-block-start: calc(2rem + var(--report-space-3))" "Markdown render offsets TOC below PDF buttons"
	assert_contains "$_out" "z-index: 2" "Markdown render keeps PDF buttons above TOC panel"
	assert_not_contains "$_out" "style=\"margin-left:" "Markdown TOC uses flat left alignment"
	assert_contains "$_out" "class=\"toc-entry toc-chapter\"" "Markdown TOC marks chapters for separators"
	assert_contains "$_out" "class=\"toc-entry toc-subsection\"" "Markdown TOC marks decimal entries for indent"
	assert_contains "$_out" "class=\"report-title-page\"" "Markdown render wraps PDF title page"
	assert_contains "$_out" "class=\"report-main-flow\"" "Markdown render groups title and front matter for HTML flow"
	assert_contains "$_out" "class=\"report-content report-main report-title-front\"" "Markdown render separates title page from front matter"
	assert_contains "$_out" "class=\"report-content report-main report-rest\"" "Markdown render splits report body after intro"
	assert_contains "$_out" ".report-main-flow {" "Markdown render includes compact title/front HTML flow"
	assert_contains "$_out" "grid-row: 1" "Markdown render keeps title and front matter in a compact HTML row"
	assert_contains "$_out" ".report-rest {" "Markdown render includes report rest grid placement"
	assert_contains "$_out" "grid-row: 2" "Markdown render stacks body content after title and front matter in HTML"
	assert_contains "$_out" "grid-row: 1 / span 2" "Markdown render keeps sticky TOC beside the grouped report flow"
	return 0
}

test_render_json_fixture() {
	local _out="${TEST_ROOT}/sample-json.html"
	"$HELPER_SH" render "${FIXTURE_DIR}/llm-visibility-report-sample.json" --template editorial-evidence --output "$_out"
	assert_contains "$_out" "sticky-toc" "JSON render includes sticky TOC"
	assert_contains "$_out" "@media print" "JSON render includes print CSS"
	assert_contains "$_out" "evidence-label" "JSON render includes plain evidence label"
	assert_contains "$_out" "evidence-badge" "JSON render groups evidence label and badge"
	assert_contains "$_out" "badge-verified\">Verified</span>" "JSON render includes verified badge"
	assert_contains "$_out" "badge-partial\">Partial</span>" "JSON render includes partial badge"
	assert_contains "$_out" "badge-inferred\">Inferred</span>" "JSON render includes inferred badge"
	assert_contains "$_out" "badge-missing\">Missing</span>" "JSON render includes missing badge"
	assert_contains "$_out" "source-card" "JSON render includes source cards"
	if grep -qF "report-section" "$_out" || grep -qF ".report-main h3::before" "$_out"; then
		print_result "Render numbers H2 chapters only" 1 "Found section counter or H3 numbering CSS"
	else
		print_result "Render numbers H2 chapters only" 0
	fi
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

test_python_helper_reads_stdin_by_default() {
	local _out="${TEST_ROOT}/stdin.html"
	printf '# Stdin\n\n{{evidence:verified}}\n' | python3 "${SCRIPT_DIR}/../report-render-helper.py" render >"$_out"
	assert_contains "$_out" "<h1 id=\"stdin\">Stdin</h1>" "Python helper reads stdin when input omitted"
	assert_contains "$_out" "Evidence: Verified" "Python helper renders stdin badges"
	return 0
}

test_style_token_parser_handles_long_headers_and_tabs() {
	local _result=0
	python3 - "$SCRIPT_DIR" "$TEST_ROOT" <<'PY' || _result=$?
from pathlib import Path
import importlib.util
import sys

script_dir = Path(sys.argv[1])
test_root = Path(sys.argv[2])
module_path = script_dir.parent / "report_render_styles.py"
spec = importlib.util.spec_from_file_location("report_render_styles", module_path)
module = importlib.util.module_from_spec(spec)
assert spec.loader is not None
spec.loader.exec_module(module)

design = test_root / "DESIGN.md"
design.write_text(
    "# header\n" * 10
    + "---\n"
    + "colors:\n"
    + "\tbackground: '#123456'\n"
    + "rounded:\n"
    + "\tlg: 20px\n"
    + "typography:\n"
    + "\theadline-display:\n"
    + "\t\tfontSize: 72px\n"
    + "---\n",
    encoding="utf-8",
)
front_matter = module._front_matter(design)
tokens = module._parse_tokens(front_matter)
assert tokens["background"] == "#123456"
assert tokens["rounded.lg"] == "20px"
assert tokens["headline-display.fontSize"] == "72px"
PY
	if [[ "$_result" -ne 0 ]]; then
		print_result "Style token parser handles long headers and tabs" 1 "Expected long preamble and tab-indented tokens to parse"
		return 0
	fi
	print_result "Style token parser handles long headers and tabs" 0
	return 0
}

test_style_css_uses_paper_raised_token() {
	local _result=0
	python3 - "$SCRIPT_DIR" <<'PY' || _result=$?
from pathlib import Path
import importlib.util
import sys

script_dir = Path(sys.argv[1])
module_path = script_dir.parent / "report_render_styles.py"
spec = importlib.util.spec_from_file_location("report_render_styles", module_path)
module = importlib.util.module_from_spec(spec)
assert spec.loader is not None
spec.loader.exec_module(module)

tokens = dict(module.DEFAULT_TOKENS)
tokens["primary-container"] = "#F3DED5"
tokens["paper-raised"] = "#F5F6F4"
css = module._theme_css("signal-agency", tokens)
assert "--report-paper-raised: #F5F6F4;" in css
assert "--report-paper-raised: #F3DED5;" not in css
PY
	if [[ "$_result" -ne 0 ]]; then
		print_result "Style CSS uses paper-raised token" 1 "Expected paper-raised to override primary-container for raised surfaces"
		return 0
	fi
	print_result "Style CSS uses paper-raised token" 0
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
	"$HELPER_SH" render "$_input" --template editorial-evidence --output "$_out"
	assert_contains "$_out" "<thead>" "Markdown table renders thead"
	assert_contains "$_out" "<th>Component</th>" "Markdown table renders header cells"
	assert_contains "$_out" "<td>AIO</td>" "Markdown table renders body cells"
	return 0
}

test_markdown_table_accepts_indented_single_dash_separator() {
	local _input="${TEST_ROOT}/table-indented-single-dash.md"
	local _out="${TEST_ROOT}/table-indented-single-dash.html"
	cat >"$_input" <<'MARKDOWN'
# Table

  | Component | Evidence |
  | - | :-: |
  | AIO | {{evidence:verified}} |
MARKDOWN
	"$HELPER_SH" render "$_input" --template editorial-evidence --output "$_out"
	assert_contains "$_out" "<th>Component</th>" "Markdown table accepts indented table headers"
	assert_contains "$_out" "<td>AIO</td>" "Markdown table accepts indented table body"
	assert_not_contains "$_out" "<td>-</td>" "Markdown table treats single-dash separator as separator"
	return 0
}

test_markdown_table_preserves_escaped_pipes() {
	local _input="${TEST_ROOT}/table-escaped-pipe.md"
	local _out="${TEST_ROOT}/table-escaped-pipe.html"
	cat >"$_input" <<'MARKDOWN'
# Escaped Pipe Table

| Component | Evidence |
|---|---|
| AIO \| CLI | Keeps one cell |
| Literal \\| Separator | Next cell |
MARKDOWN
	"$HELPER_SH" render "$_input" --output "$_out"
	assert_contains "$_out" "<td>AIO | CLI</td>" "Markdown table preserves escaped pipes inside cells"
	assert_contains "$_out" "<td>Separator</td>" "Markdown table keeps even-backslash pipe as separator"
	if grep -qF "<td>CLI</td>" "$_out"; then
		print_result "Markdown table does not split escaped pipe cells" 1 "Escaped pipe created an extra cell"
	else
		print_result "Markdown table does not split escaped pipe cells" 0
	fi
	return 0
}

test_markdown_headings_deduplicate_anchor_ids() {
	local _input="${TEST_ROOT}/duplicate-headings.md"
	local _out="${TEST_ROOT}/duplicate-headings.html"
	cat >"$_input" <<'MARKDOWN'
# Overview

## Repeat

First section.

## Repeat

Second section.

### Repeat

Nested section.
MARKDOWN
	"$HELPER_SH" render "$_input" --output "$_out"
	assert_contains "$_out" "<h2 class=\"chapter-heading\" id=\"repeat\">" "Markdown keeps first duplicate heading anchor unsuffixed"
	assert_contains "$_out" "<h2 class=\"chapter-heading\" id=\"repeat-2\">" "Markdown suffixes second duplicate heading anchor"
	assert_contains "$_out" "<h3 class=\"section-heading\" id=\"repeat-3\">" "Markdown suffixes duplicate heading anchors across levels"
	assert_contains "$_out" "<a href=\"#repeat-2\"" "Markdown TOC targets suffixed duplicate heading anchor"
	return 0
}

test_mermaid_renderer_uses_node_ids() {
	if python3 - "${SCRIPT_DIR}/.." <<'PYHTML'
import sys
from pathlib import Path

sys.path.insert(0, str(Path(sys.argv[1]).resolve()))
from report_render_markdown import render_mermaid_svg

html = render_mermaid_svg("node-1 [Repeat] --> node-2[Repeat]\nnode-2[Repeat] --> node-3[Done]")
if html.count('class="diagram-label">Repeat</text>') != 2:
    raise SystemExit(1)
if "H 104" in html:
    raise SystemExit(1)
PYHTML
	then
		print_result "Mermaid renderer preserves distinct IDs with duplicate labels" 0
	else
		print_result "Mermaid renderer preserves distinct IDs with duplicate labels" 1 "Expected duplicate labels to render as separate nodes"
	fi
	return 0
}

test_mermaid_renderer_supports_chained_arrows() {
	if python3 - "${SCRIPT_DIR}/.." <<'PYHTML'
import sys
from pathlib import Path

sys.path.insert(0, str(Path(sys.argv[1]).resolve()))
from report_render_diagrams import mermaid_graph

nodes, edges = mermaid_graph("A[Start] --> B[Middle] --> C[Done]")
if list(nodes.items()) != [("A", "Start"), ("B", "Middle"), ("C", "Done")]:
    raise SystemExit(1)
if edges != [("A", "B"), ("B", "C")]:
    raise SystemExit(1)
PYHTML
	then
		print_result "Mermaid renderer supports chained arrows" 0
	else
		print_result "Mermaid renderer supports chained arrows" 1 "Expected A --> B --> C to create both edges"
	fi
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
	"$HELPER_SH" render "$_input" --template editorial-evidence --output "$_out"
	assert_contains "$_out" "<p>First line continues onto the next line.</p>" "Markdown joins paragraph lines"
	return 0
}

test_print_keep_with_heading_groups() {
	local _input="${TEST_ROOT}/keep-with-heading.md"
	local _out="${TEST_ROOT}/keep-with-heading.html"
	cat >"$_input" <<'MARKDOWN'
# Keep Together

## Sources

::: sources-layout
::: source-list
### Source A

Evidence summary.
:::
:::

### Render command

```text
render report.md --pdf-profile a4
```
MARKDOWN
	"$HELPER_SH" render "$_input" --template editorial-evidence --output "$_out"
	assert_contains "$_out" "class=\"report-keep-with-heading\"" "Markdown wraps headings with keep-together panels"
	assert_contains "$_out" "report-chapter-page" "Markdown marks wrapped chapters for page breaks"
	assert_contains "$_out" ".report-keep-with-heading > .code-block-wrap" "Print CSS keeps code titles with code panels"
	assert_contains "$_out" "page-break-before: always" "Print CSS starts chapters on new pages"
	assert_contains "$_out" "width: 100%" "Print CSS keeps bordered panels aligned to content width"
	assert_contains "$_out" "margin: 6mm 0 8mm" "Print CSS avoids narrowing full-width panels"
	assert_contains "$_out" "@page { margin: 12mm 0; background: #ffffff; }" "Print CSS restores top and bottom page margins"
	assert_contains "$_out" "@page report-letter { size: Letter portrait; margin: .45in 0;" "Print CSS restores US Letter top and bottom page margins"
	assert_contains "$_out" "html { background: #ffffff !important; }" "Print CSS keeps final-page background neutral"
	assert_contains "$_out" "body.report-body { box-sizing: border-box; padding: 0 12mm;" "Print CSS keeps A4 horizontal inset without left page hairline"
	assert_contains "$_out" "body.report-pdf-profile-letter { page: report-letter; padding: 0 .45in; }" "Print CSS keeps US Letter horizontal inset without left page hairline"
	assert_contains "$_out" ".report-title-page" "Print CSS controls the title page"
	assert_contains "$_out" "page-break-after: auto" "Print CSS avoids duplicate title-page blank pages"
	assert_contains "$_out" "body.report-body::before" "Print CSS controls full-page background pseudo-element"
	assert_contains "$_out" "body.report-body::before { content: none; display: none; }" "Print CSS avoids fixed pseudo-element margin seams"
	assert_contains "$_out" "border: 0 !important" "Print CSS removes outer content borders"
	assert_contains "$_out" ".report-front { display: block; min-height: calc(297mm - 24mm); break-after: auto; page-break-after: auto; }" "Print CSS starts Contents on a new A4 page through normal flow"
	assert_contains "$_out" "body.report-pdf-profile-letter .report-front { min-height: 10.1in; }" "Print CSS starts Contents on a new US Letter page through normal flow"
	assert_contains "$_out" ".sticky-toc-header { break-before: auto; page-break-before: auto; }" "Print CSS lets TOC flow without blank spacer pages"
	assert_contains "$_out" ".sticky-toc { break-before: auto; page-break-before: auto; }" "Print CSS avoids empty TOC spacer pages"
	assert_contains "$_out" "border-top: 0 !important" "Print CSS removes chapter heading rules"
	assert_contains "$_out" "body.report-body:not(.report-theme-dark)" "Print CSS limits colour-matched paper to dark themes"
	assert_contains "$_out" "box-decoration-break: clone" "Print CSS clones box decoration across page fragments"
	assert_contains "$_out" "margin-block: 6mm 8mm" "Print CSS gives split blocks top clearance"
	assert_contains "$_out" "border-radius: var(--report-radius-md) !important" "Print CSS preserves rounded code and table boxes"
	assert_contains "$_out" "border-top-left-radius: calc(var(--report-radius-md) - 1px)" "Print CSS clips rounded top corners"
	assert_contains "$_out" "clip-path: inset(0 round var(--report-radius-md))" "Print CSS clips rounded table wrappers"
	assert_contains "$_out" ".source-list .source-title:not(:first-child)" "Print CSS starts later source groups on new pages"
	assert_contains "$_out" "break-before: page" "Print CSS gives the TOC and title sections page breaks"
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
	"$HELPER_SH" print-css --template editorial-evidence >"$_css"
	assert_contains "$_sample" "{{evidence:verified}}" "Sample command emits Markdown report"
	assert_contains "$_instructional" "LLM Visibility Instructional Toolbox" "Sample command emits instructional SEO/GEO report"
	assert_contains "$_css" "@media print" "print-css emits print stylesheet"
	return 0
}

test_render_template_and_profiles() {
	local _out="${TEST_ROOT}/editorial.html"
	local _dark="${TEST_ROOT}/lottiefiles-dark.html"
	local _basic="${TEST_ROOT}/basic.html"
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
	"$HELPER_SH" render "${FIXTURE_DIR}/llm-visibility-report-sample.md" \
		--template basic \
		--pdf-profile a4 \
		--output "$_basic"
	"$HELPER_SH" print-css --template axel --pdf-profile slides-16-9-2 >"$_slides"
	assert_contains "$_out" "report-template-axel" "Render supports named style template"
	assert_contains "$_out" "Newsreader" "Render includes style-specific fonts"
	assert_contains "$_out" "size: A4 portrait" "Render defaults to A4 portrait profile"
	assert_contains "$_dark" "report-theme-dark" "Render supports forced dark theme"
	assert_contains "$_dark" "--report-info-bg: #161A1C" "Dark theme inverts info panels"
	assert_contains "$_dark" "--report-good-bg: #161A1C" "Dark theme inverts good panels"
	assert_not_contains "$_basic" "<style>" "Basic template emits no CSS style tag"
	assert_contains "$_slides" "size: 16in 9in" "print-css supports 16:9 landscape profile"
	assert_contains "$_slides" "@page { size: 16in 9in; margin: 0;" "print-css removes 16:9 page margin frame"
	assert_contains "$_slides" "html, body.report-body { box-sizing: border-box; padding: 0; }" "print-css avoids one-time-only body padding for 16:9"
	assert_contains "$_slides" ".report-shell { -webkit-box-decoration-break: clone; box-decoration-break: clone; box-sizing: border-box; padding: .45in; }" "print-css repeats shell safe area on 16:9 fragments"
	assert_contains "$_slides" "column-count: auto" "print-css uses single-column presentation profile"
	assert_contains "$_slides" "font-size: 32pt" "print-css enlarges presentation profile text"
	assert_contains "$_slides" "font-size: 26pt" "print-css uses smaller slide table and multi-column text"
	assert_contains "$_slides" "td .evidence-badge" "print-css stacks slide table evidence badges"
	assert_contains "$_slides" "break-before: avoid-page !important" "print-css keeps code panels with their headings"
	return 0
}

test_list_templates() {
	local _templates="${TEST_ROOT}/templates.txt"
	"$HELPER_SH" list-templates >"$_templates"
	assert_contains "$_templates" "arxiv" "Template list includes original arXiv brief style"
	assert_contains "$_templates" "wikipedia" "Template list includes original Wikipedia brief style"
	assert_contains "$_templates" "terminalshop" "Template list includes original Terminal Shop brief style"
	assert_contains "$_templates" "mellowyellow" "Template list includes preserved Mellow Yellow style"
	assert_contains "$_templates" "times" "Template list includes Polymarket Times style"
	"$HELPER_SH" list-dark-templates >"$_templates"
	assert_contains "$_templates" "lottiefiles" "Dark template list includes LottieFiles"
	return 0
}

main() {
	setup_test_env
	trap teardown_test_env EXIT
	test_render_markdown_fixture
	test_render_markdown_layout_fixture
	test_render_json_fixture
	test_validate_rejects_unknown_badge
	test_python_helper_requires_mode
	test_python_helper_reads_stdin_by_default
	test_style_token_parser_handles_long_headers_and_tabs
	test_style_css_uses_paper_raised_token
	test_markdown_table_uses_header_cells
	test_markdown_table_accepts_indented_single_dash_separator
	test_markdown_table_preserves_escaped_pipes
	test_markdown_headings_deduplicate_anchor_ids
	test_mermaid_renderer_uses_node_ids
	test_mermaid_renderer_supports_chained_arrows
	test_multiline_markdown_paragraph
	test_print_keep_with_heading_groups
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
