#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# report-render-helper.sh — render report-ready Markdown/JSON to portable HTML.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit
SCRIPT_NAME="$(basename "${BASH_SOURCE[0]:-$0}")"
PY_HELPER="${SCRIPT_DIR}/report-render-helper.py"

[[ -z "${RED+x}" ]] && RED='\033[0;31m'
[[ -z "${NC+x}" ]] && NC='\033[0m'

_die() {
	local _message="${1:-usage error}"
	printf '%b[%s] ERROR: %s%b\n' "$RED" "$SCRIPT_NAME" "$_message" "$NC" >&2
	exit 2
	# shellcheck disable=SC2317
	return 1
}

_run_python() {
	local _mode="${1:-render}"
	local _input="${2:-}"
	local _template="${3:-basic}"
	local _pdf_profile="${4:-a4}"
	local _theme="${5:-auto}"
	python3 "$PY_HELPER" "$_mode" "$_input" "$_template" "$_pdf_profile" "$_theme"
	return 0
}

_print_usage() {
	cat <<'USAGE'
Usage:
  report-render-helper.sh render <input.md|input.json|-> [--output report.html] [--template <name>] [--theme auto|light|dark] [--pdf-profile a4|letter|slides-16-9-1|slides-16-9-2|slides-16-9-3]
  report-render-helper.sh action-prompts <input.md|->
  report-render-helper.sh validate <input.md|input.json|->
  report-render-helper.sh sample [markdown|json|instructional-seo-geo]
  report-render-helper.sh print-css [--template <name>] [--theme auto|light|dark] [--pdf-profile a4|letter|slides-16-9-1|slides-16-9-2|slides-16-9-3]
  report-render-helper.sh list-templates
  report-render-helper.sh list-dark-templates

Evidence badges: {{evidence:verified}}, {{evidence:partial}}, {{evidence:inferred}}, {{evidence:missing}}
USAGE
	return 0
}

_action_prompts_path() {
	local _input_path="$1"
	local _directory="${_input_path%/*}"
	local _filename="${_input_path##*/}"
	local _stem="${_filename%.*}"
	if [[ "$_directory" == "$_input_path" ]]; then
		printf '%s-action-prompts.md\n' "$_stem"
		return 0
	fi
	printf '%s/%s-action-prompts.md\n' "$_directory" "$_stem"
	return 0
}

_maybe_write_action_prompts() {
	local _input_path="$1"
	local _output_path="$2"
	[[ "$_input_path" == "-" ]] && return 0
	[[ "$_input_path" != *.md ]] && return 0
	local _output_filename="${_output_path##*/}"
	local _output_stem="${_output_filename%.*}"
	[[ "$_output_stem" != "report" ]] && return 0
	local _output_directory="${_output_path%/*}"
	if [[ "$_output_directory" == "$_output_path" ]]; then
		_output_directory="."
	fi
	local _input_filename="${_input_path##*/}"
	local _input_stem="${_input_filename%.*}"
	local _prompts_path="${_output_directory}/${_input_stem}-action-prompts.md"
	_run_python action-prompts "$_input_path" >"$_prompts_path"
	return 0
}

_parse_render_option() {
	local _arg="$1"
	local _input_ref="$2"
	local _output_ref="$3"
	local _template_ref="$4"
	local _pdf_profile_ref="$5"
	local _theme_ref="$6"
	local _value="${7:-}"
	case "$_arg" in
	--output)
		printf -v "$_output_ref" '%s' "$_value"
		[[ -z "$_value" ]] && _die "--output requires a path"
		return 2
		;;
	--template)
		printf -v "$_template_ref" '%s' "$_value"
		[[ -z "$_value" ]] && _die "--template requires a value"
		return 2
		;;
	--theme)
		printf -v "$_theme_ref" '%s' "$_value"
		[[ -z "$_value" ]] && _die "--theme requires a value"
		return 2
		;;
	--pdf-profile | --profile)
		printf -v "$_pdf_profile_ref" '%s' "$_value"
		[[ -z "$_value" ]] && _die "${_arg} requires a value"
		return 2
		;;
	-)
		[[ -n "${!_input_ref}" ]] && _die "render accepts one input"
		printf -v "$_input_ref" '%s' "$_arg"
		return 1
		;;
	-*)
		_die "unknown option: ${_arg}"
		;;
	*)
		[[ -n "${!_input_ref}" ]] && _die "render accepts one input"
		printf -v "$_input_ref" '%s' "$_arg"
		return 1
		;;
	esac
	return 1
}

cmd_render() {
	local _input=""
	local _output=""
	local _template="basic"
	local _pdf_profile="a4"
	local _theme="auto"
	while [[ $# -gt 0 ]]; do
		local _arg="${1:-}"
		shift
		local _advance=1
		_parse_render_option "$_arg" _input _output _template _pdf_profile _theme "${1:-}" || _advance=$?
		if [[ "$_advance" -eq 2 ]]; then
			shift
		fi
	done
	[[ -z "$_input" ]] && _die "render requires an input path"
	if [[ "$_input" != "-" && ! -f "$_input" ]]; then
		_die "input file not found: ${_input}"
	fi
	if [[ -n "$_output" ]]; then
		local _pdf_href="${_output##*/}"
		_pdf_href="${_pdf_href%.*}.pdf"
		REPORT_PDF_HREF="$_pdf_href" _run_python render "$_input" "$_template" "$_pdf_profile" "$_theme" >"$_output"
		_maybe_write_action_prompts "$_input" "$_output"
	else
		_run_python render "$_input" "$_template" "$_pdf_profile" "$_theme"
	fi
	return 0
}

cmd_action_prompts() {
	local _input="${1:-}"
	[[ -z "$_input" ]] && _die "action-prompts requires an input path"
	[[ "$_input" != "-" && ! -f "$_input" ]] && _die "input file not found: ${_input}"
	_run_python action-prompts "$_input"
	return 0
}

cmd_validate() {
	local _input="${1:-}"
	[[ -z "$_input" ]] && _die "validate requires an input path"
	[[ "$_input" != "-" && ! -f "$_input" ]] && _die "input file not found: ${_input}"
	_run_python validate "$_input"
	return 0
}

cmd_sample() {
	local _format="${1:-markdown}"
	case "$_format" in
	markdown | md)
		cat <<'SAMPLE_MD'
# AI Visibility Report

::: report-cover
**Evidence-first AI visibility reporting** across AIO, Gemini, ChatGPT, AI Mode, and Perplexity.
:::

## Executive summary

Visibility improved across answer engines. {{evidence:verified}}

::: badge-row
{{evidence:verified}} {{evidence:partial}} {{evidence:inferred}} {{evidence:missing}}
:::

::: stats-strip
::: stat-card
**82**

AIO score.
:::
::: stat-card
**5**

Engines tracked.
:::
:::

::: action-line
**Next action:** add stronger source cards to weak pages.
:::

## Scorecard

::: facts-table-wrap

| Component | Score | Evidence |
|---|---:|---|
| AIO | 82 | {{evidence:verified}} |
| Gemini | 74 | {{evidence:partial}} |
| ChatGPT | 68 | {{evidence:inferred}} |
| Perplexity | 0 | {{evidence:missing}} |
:::

::: good-bad
::: good-row
### Good

Visible answer, source ID, and corroborating table.
:::
::: bad-row
### Bad

Unsupported claim hidden behind client-side rendering.
:::
:::

::: tactic-card
### Direct-answer opening

- What: answer plainly in the first paragraph.
- Verify: rerun per-engine prompts.
:::

::: example-card
```text
Evidence ID: S-001
Claim: verified in prompt capture and crawl export.
```
:::

## Sources

Source: SERP capture, crawl export, analytics comparison, and remediation notes.
SAMPLE_MD
		;;
	json)
		_run_python sample-json "-"
		;;
	instructional-seo-geo)
		cat <<'SAMPLE_INSTRUCTIONAL'
# LLM Visibility Instructional Toolbox

::: report-cover
**Markdown-canonical LLM visibility playbook** with Toolbox-style cards, scorecards, source ledgers, and routine handoff.
:::

## Executive summary

LLM visibility work compounds when content engineering, authority signals, and technical crawlability are treated as one evidence system. {{evidence:verified}}

::: badge-row
{{evidence:verified}} {{evidence:partial}} {{evidence:inferred}} {{evidence:missing}}
:::

::: stats-strip
::: stat-card
**5**

Answer engines reported separately.
:::
::: stat-card
**3**

Tactic groups: on-page, technical, authority.
:::
::: stat-card
**1**

Canonical Markdown source.
:::
:::

## Highest impact tactics

::: facts-table-wrap

| Tactic | Evidence | Page-type fit | Verification |
|---|---|---|---|
| Earned third-party mentions | {{evidence:verified}} | SaaS, ecommerce, YMYL, local | Track AIO, Gemini, ChatGPT, AI Mode, and Perplexity separately |
| Direct answer in first paragraph | {{evidence:partial}} | Article, glossary, comparison, research/report | Prompt-run citation and snippet checks |
| Original statistics and source cards | {{evidence:verified}} | Research/report, comparison, use-case | Source ID appears in answer-engine citation |
| FAQPage schema | {{evidence:inferred}} | Hygiene only unless visible FAQ fits intent | Rich-result validation, not visibility lift claim |
:::

## On-page tactic card

::: tactic-card

### Direct-answer opening

- What: answer the query plainly in the first paragraph.
- Why: extractive answer systems need concise, quotable claims with nearby proof.
- How: pair answer, source ID, author/updated date, and supporting table.
- Verify: rerun per-engine prompts and compare cited URL movement.
:::

## Technical tactic card

::: tactic-card

### Bot-friendly first fetch

- What: SSR or pre-render important content, allow relevant AI crawlers, and keep FCP fast.
- Why: invisible content cannot be cited.
- How: crawl rendered and raw HTML, review robots.txt, segmented sitemap, and logs.
- Verify: monthly AI bot log analysis and fetch tests.
:::

## Authority tactic card

::: tactic-card

### Third-party corroboration

- What: make consistent entity facts visible on reputable review, community, video, and industry sites.
- Why: answer engines cross-check claims against external sources.
- How: build a source ledger across owned pages and third-party profiles.
- Verify: source breadth score and per-engine citation lines.
:::

## Myth callout

::: myth-callout

Myth: adding FAQPage schema is a primary GEO tactic. Fact: treat FAQPage as hygiene unless visible FAQ content genuinely matches page type and query fan-out.
:::

::: example-card
```text
Worker brief: update /compare/example with source IDs S-001 through S-004, visible citations, and per-engine retest steps.
```
:::

## Routine handoff

::: checklist-card

- Monthly: run prompt/query sets across AIO, Gemini, ChatGPT, AI Mode, and Perplexity.
- Quarterly: refresh source ledger and page-type weighting.
- Worker task: each remediation must include page path, source IDs, acceptance criteria, and re-test command.
:::
SAMPLE_INSTRUCTIONAL
		;;
	*)
		_die "unknown sample format: ${_format}"
		;;
	esac
	return 0
}

cmd_print_css() {
	local _template="basic"
	local _pdf_profile="a4"
	local _theme="auto"
	while [[ $# -gt 0 ]]; do
		local _arg="${1:-}"
		shift
		case "$_arg" in
		--template)
			_template="${1:-}"
			[[ -z "$_template" ]] && _die "--template requires a value"
			shift
			;;
		--pdf-profile | --profile)
			_pdf_profile="${1:-}"
			[[ -z "$_pdf_profile" ]] && _die "${_arg} requires a value"
			shift
			;;
		--theme)
			_theme="${1:-}"
			[[ -z "$_theme" ]] && _die "--theme requires a value"
			shift
			;;
		*)
			_die "unknown option: ${_arg}"
			;;
		esac
	done
	_run_python print-css "-" "$_template" "$_pdf_profile" "$_theme"
	return 0
}

cmd_list_templates() {
	_run_python list-templates "-"
	return 0
}

cmd_list_dark_templates() {
	_run_python list-dark-templates "-"
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
	action-prompts)
		cmd_action_prompts "$@"
		;;
	sample)
		cmd_sample "$@"
		;;
	print-css)
		cmd_print_css "$@"
		;;
	list-templates)
		cmd_list_templates
		;;
	list-dark-templates)
		cmd_list_dark_templates
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
