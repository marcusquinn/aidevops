#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# report-render-helper.sh — render report-ready Markdown/JSON to portable HTML.

set -euo pipefail

SCRIPT_NAME="$(basename "${BASH_SOURCE[0]:-$0}")"

[[ -z "${RED+x}" ]] && RED='\033[0;31m'
[[ -z "${NC+x}" ]] && NC='\033[0m'

_die() {
	local _message="${1:-usage error}"
	printf '%b[%s] ERROR: %s%b\n' "$RED" "$SCRIPT_NAME" "$_message" "$NC" >&2
	exit 2
	# shellcheck disable=SC2317
	return 1
}

_python_render() {
	local _mode="${1:-render}"
	local _input="${2:-}"
	python3 - "$_mode" "$_input" <<'PYEOF'
import html
import json
import os
import re
import sys

MODE = sys.argv[1]
INPUT = sys.argv[2] if len(sys.argv) > 2 else ""
BADGE_VERIFIED = "verified"
BADGE_PARTIAL = "partial"
BADGE_INFERRED = "inferred"
BADGE_MISSING = "missing"
BADGE_KEY = "evidence_badge"
TITLE_KEY = "title"
DETAIL_KEY = "detail"
SUMMARY_KEY = "summary"
ALLOWED_BADGES = (BADGE_VERIFIED, BADGE_PARTIAL, BADGE_INFERRED, BADGE_MISSING)
BADGE_LABELS = {
    BADGE_VERIFIED: "Evidence: Verified",
    BADGE_PARTIAL: "Evidence: Partial",
    BADGE_INFERRED: "Evidence: Inferred",
    BADGE_MISSING: "Evidence: Missing",
}

CSS = """
:root { color-scheme: light; --ink: #1f2937; --muted: #6b7280; --line: #d1d5db; --panel: #f9fafb; }
body { margin: 0; font: 16px/1.55 -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif; color: var(--ink); }
.report-shell { display: grid; grid-template-columns: minmax(14rem, 18rem) minmax(0, 1fr); gap: 2rem; max-width: 1180px; margin: 0 auto; padding: 2rem; }
.sticky-toc { position: sticky; top: 1rem; align-self: start; max-height: calc(100vh - 2rem); overflow: auto; border: 1px solid var(--line); border-radius: 12px; padding: 1rem; background: var(--panel); }
.sticky-toc a { display: block; color: inherit; text-decoration: none; margin: .35rem 0; }
.report-content { min-width: 0; }
.badge { display: inline-block; border-radius: 999px; padding: .15rem .55rem; font-size: .78rem; font-weight: 700; border: 1px solid var(--line); }
.badge-verified { background: #dcfce7; color: #166534; }
.badge-partial { background: #fef9c3; color: #854d0e; }
.badge-inferred { background: #dbeafe; color: #1e40af; }
.badge-missing { background: #fee2e2; color: #991b1b; }
.source-card { border: 1px solid var(--line); border-left: 4px solid #111827; border-radius: 10px; padding: .85rem 1rem; margin: .75rem 0; background: #fff; }
table { border-collapse: collapse; width: 100%; margin: 1rem 0; }
th, td { border: 1px solid var(--line); padding: .5rem; text-align: left; }
@media print { .report-shell { display: block; padding: 0; } .sticky-toc { position: static; page-break-after: always; } a { color: inherit; } }
""".strip()


def read_input(path):
    if path == "-":
        return sys.stdin.read()
    with open(path, "r", encoding="utf-8") as handle:
        return handle.read()


def slug(text):
    value = re.sub(r"[^a-z0-9]+", "-", text.lower()).strip("-")
    return value or "section"


def badge_html(value):
    key = str(value).strip().lower()
    if key not in ALLOWED_BADGES:
        raise ValueError("unknown evidence badge value: {}".format(value))
    return '<span class="badge badge-{0}">{1}</span>'.format(key, BADGE_LABELS[key])


def validate_json_badges(node):
    if isinstance(node, dict):
        for key, value in node.items():
            if key in (BADGE_KEY, "evidenceBadge"):
                badge_html(value)
            validate_json_badges(value)
    elif isinstance(node, list):
        for item in node:
            validate_json_badges(item)


def validate_markdown_badges(text):
    for match in re.finditer(r"\{\{\s*evidence\s*:\s*([^}]+?)\s*\}\}", text, re.I):
        badge_html(match.group(1))


def inline_markup(text):
    escaped = html.escape(text)
    escaped = re.sub(
        r"\{\{\s*evidence\s*:\s*([^}]+?)\s*\}\}",
        lambda match: badge_html(html.unescape(match.group(1))),
        escaped,
        flags=re.I,
    )
    escaped = re.sub(r"`([^`]+)`", r"<code>\1</code>", escaped)
    escaped = re.sub(r"\*\*([^*]+)\*\*", r"<strong>\1</strong>", escaped)
    return escaped


def render_markdown(text):
    validate_markdown_badges(text)
    headings = []
    body = []
    in_list = False
    in_table = False

    def close_blocks():
        nonlocal in_list, in_table
        if in_list:
            body.append("</ul>")
            in_list = False
        if in_table:
            body.append("</tbody></table>")
            in_table = False

    for raw_line in text.splitlines():
        line = raw_line.rstrip()
        if not line:
            close_blocks()
            continue
        heading = re.match(r"^(#{1,3})\s+(.+)$", line)
        if heading:
            close_blocks()
            level = len(heading.group(1))
            title = heading.group(2).strip()
            anchor = slug(title)
            headings.append((level, title, anchor))
            body.append('<h{0} id="{1}">{2}</h{0}>'.format(level, anchor, inline_markup(title)))
            continue
        if line.startswith("|") and line.endswith("|"):
            cells = [inline_markup(cell.strip()) for cell in line.strip("|").split("|")]
            if all(re.match(r"^:?-{3,}:?$", cell) for cell in [html.unescape(c) for c in cells]):
                continue
            if not in_table:
                close_blocks()
                body.append("<table><tbody>")
                in_table = True
            body.append("<tr>{}</tr>".format("".join("<td>{}</td>".format(cell) for cell in cells)))
            continue
        if line.startswith(("- ", "* ")):
            if not in_list:
                close_blocks()
                body.append("<ul>")
                in_list = True
            body.append("<li>{}</li>".format(inline_markup(line[2:].strip())))
            continue
        close_blocks()
        if line.lower().startswith("source:") or line.lower().startswith("source card:"):
            body.append('<aside class="source-card">{}</aside>'.format(inline_markup(line)))
        else:
            body.append("<p>{}</p>".format(inline_markup(line)))
    close_blocks()
    return headings, "\n".join(body)


def render_json(text):
    data = json.loads(text)
    validate_json_badges(data)
    headings = []
    body = []
    title = data.get(TITLE_KEY, "Report") if isinstance(data, dict) else "Report"
    headings.append((1, title, slug(title)))
    body.append('<h1 id="{}">{}</h1>'.format(slug(title), inline_markup(title)))
    for section in data.get("sections", []):
        section_title = section.get(TITLE_KEY, "Section")
        headings.append((2, section_title, slug(section_title)))
        body.append('<h2 id="{}">{}</h2>'.format(slug(section_title), inline_markup(section_title)))
        if section.get(SUMMARY_KEY):
            body.append("<p>{}</p>".format(inline_markup(str(section[SUMMARY_KEY]))))
        for item in section.get("items", []):
            badge = ""
            if item.get(BADGE_KEY):
                badge = " " + badge_html(item[BADGE_KEY])
            body.append('<div class="source-card"><strong>{}</strong>{}<p>{}</p></div>'.format(
                inline_markup(str(item.get(TITLE_KEY, "Item"))),
                badge,
                inline_markup(str(item.get(DETAIL_KEY, ""))),
            ))
    return headings, "\n".join(body)


def wrap_document(headings, body):
    toc_items = []
    for level, title, anchor in headings:
        indent = " style=\"margin-left:{}rem\"".format(max(level - 1, 0))
        toc_items.append('<a href="#{0}"{1}>{2}</a>'.format(anchor, indent, html.escape(title)))
    return """<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Report</title>
<style>{css}</style>
</head>
<body>
<div class="report-shell">
<nav class="sticky-toc" aria-label="Report table of contents">
<strong>Contents</strong>
{toc}
</nav>
<main class="report-content">
{body}
</main>
</div>
</body>
</html>
""".format(css=CSS, toc="\n".join(toc_items), body=body)


def main():
    if MODE == "print-css":
        print(CSS)
        return 0
    if MODE == "sample-json":
        print(json.dumps({
            TITLE_KEY: "AI Visibility Report",
            "sections": [{
                TITLE_KEY: "Executive summary",
                SUMMARY_KEY: "Visibility improved across answer engines.",
                "items": [
                    {TITLE_KEY: "AIO", DETAIL_KEY: "Cited with source card.", BADGE_KEY: BADGE_VERIFIED},
                    {TITLE_KEY: "Gemini", DETAIL_KEY: "Partial coverage found.", BADGE_KEY: BADGE_PARTIAL},
                    {TITLE_KEY: "ChatGPT", DETAIL_KEY: "Inference from comparable prompts.", BADGE_KEY: BADGE_INFERRED},
                    {TITLE_KEY: "Perplexity", DETAIL_KEY: "No citation found.", BADGE_KEY: BADGE_MISSING},
                ],
            }],
        }, indent=2))
        return 0
    text = read_input(INPUT)
    if MODE == "validate":
        stripped = text.lstrip()
        if stripped.startswith("{") or stripped.startswith("["):
            validate_json_badges(json.loads(text))
        else:
            validate_markdown_badges(text)
        return 0
    stripped = text.lstrip()
    if stripped.startswith("{"):
        headings, body = render_json(text)
    else:
        headings, body = render_markdown(text)
    sys.stdout.write(wrap_document(headings, body))
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Exception as exc:
        sys.stderr.write("{}\n".format(exc))
        sys.exit(1)
PYEOF
	return 0
}

_print_usage() {
	cat <<'USAGE'
Usage:
  report-render-helper.sh render <input.md|input.json|-> [--output output.html]
  report-render-helper.sh validate <input.md|input.json|->
  report-render-helper.sh sample [markdown|json]
  report-render-helper.sh print-css

Evidence badges: {{evidence:verified}}, {{evidence:partial}}, {{evidence:inferred}}, {{evidence:missing}}
USAGE
	return 0
}

cmd_render() {
	local _input=""
	local _output=""
	while [[ $# -gt 0 ]]; do
		local _arg="${1:-}"
		shift
		case "$_arg" in
		--output)
			_output="${1:-}"
			[[ -z "$_output" ]] && _die "--output requires a path"
			shift
			;;
		-*)
			[[ "$_arg" == "-" && -z "$_input" ]] && _input="$_arg" && continue
			_die "unknown option: ${_arg}"
			;;
		*)
			[[ -n "$_input" ]] && _die "render accepts one input"
			_input="$_arg"
			;;
		esac
	done
	[[ -z "$_input" ]] && _die "render requires an input path"
	if [[ "$_input" != "-" && ! -f "$_input" ]]; then
		_die "input file not found: ${_input}"
	fi
	if [[ -n "$_output" ]]; then
		_python_render render "$_input" >"$_output"
	else
		_python_render render "$_input"
	fi
	return 0
}

cmd_validate() {
	local _input="${1:-}"
	[[ -z "$_input" ]] && _die "validate requires an input path"
	[[ "$_input" != "-" && ! -f "$_input" ]] && _die "input file not found: ${_input}"
	_python_render validate "$_input"
	return 0
}

cmd_sample() {
	local _format="${1:-markdown}"
	case "$_format" in
	markdown | md)
		cat <<'SAMPLE_MD'
# AI Visibility Report

## Executive summary

Visibility improved across answer engines. {{evidence:verified}}

## Scorecard

| Component | Score | Evidence |
|---|---:|---|
| AIO | 82 | {{evidence:verified}} |
| Gemini | 74 | {{evidence:partial}} |
| ChatGPT | 68 | {{evidence:inferred}} |
| Perplexity | 0 | {{evidence:missing}} |

## Sources

Source: SERP capture, crawl export, analytics comparison, and remediation notes.
SAMPLE_MD
		;;
	json)
		_python_render sample-json "-"
		;;
	*)
		_die "unknown sample format: ${_format}"
		;;
	esac
	return 0
}

cmd_print_css() {
	_python_render print-css "-"
	return 0
}

main() {
	local _command="${1:-help}"
	[[ $# -gt 0 ]] && shift
	case "$_command" in
	render)
		cmd_render "$@"
		;;
	validate)
		cmd_validate "$@"
		;;
	sample)
		cmd_sample "$@"
		;;
	print-css)
		cmd_print_css
		;;
	help | --help | -h)
		_print_usage
		;;
	*)
		_die "unknown command: ${_command}"
		;;
	esac
	return 0
}

main "$@"
