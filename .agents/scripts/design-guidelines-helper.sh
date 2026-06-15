#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# design-guidelines-helper.sh — DESIGN.md detection, scaffolding, and brand guideline exports.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
SCRIPT_NAME="$(basename "${BASH_SOURCE[0]:-$0}")"
AGENTS_DIR="${AIDEVOPS_AGENTS_DIR:-$HOME/.aidevops/agents}"
REPOS_FILE="${AIDEVOPS_REPOS_FILE:-$HOME/.config/aidevops/repos.json}"

# shellcheck source=shared-constants.sh
[[ -f "${SCRIPT_DIR}/shared-constants.sh" ]] && source "${SCRIPT_DIR}/shared-constants.sh"

[[ -z "${RED+x}" ]] && RED='\033[0;31m'
[[ -z "${GREEN+x}" ]] && GREEN='\033[0;32m'
[[ -z "${BLUE+x}" ]] && BLUE='\033[0;34m'
[[ -z "${YELLOW+x}" ]] && YELLOW='\033[1;33m'
[[ -z "${NC+x}" ]] && NC='\033[0m'

DG_TRUE=true
DG_FALSE=false

_dg_info() {
	local message="$1"
	printf '%b[INFO]%b %s\n' "$BLUE" "$NC" "$message" >&2
	return 0
}

_dg_success() {
	local message="$1"
	printf '%b[OK]%b %s\n' "$GREEN" "$NC" "$message" >&2
	return 0
}

_dg_warn() {
	local message="$1"
	printf '%b[WARN]%b %s\n' "$YELLOW" "$NC" "$message" >&2
	return 0
}

_dg_die() {
	local message="${1:-usage error}"
	printf '%b[%s] ERROR: %s%b\n' "$RED" "$SCRIPT_NAME" "$message" "$NC" >&2
	exit 2
	# shellcheck disable=SC2317
	return 1
}

usage() {
	cat <<'USAGE'
Usage:
  design-guidelines-helper.sh detect [repo-path]
  design-guidelines-helper.sh scaffold [repo-path] [--force] [--dry-run]
  design-guidelines-helper.sh guidelines [repo-path|DESIGN.md] [--output-dir DIR] [--template NAME] [--theme auto|light|dark] [--pdf|--no-pdf] [--pdf-profile all|a4|letter|slides]
  design-guidelines-helper.sh survey [--json]
  design-guidelines-helper.sh issues [--apply]

Commands:
  detect       Exit 0 and print "interface" when repo markers indicate a GUI/interface.
  scaffold     Create a root DESIGN.md skeleton when missing and the repo has an interface.
  guidelines   Generate brand-guidelines.md, brand-guidelines.html, and optional PDFs from DESIGN.md.
  survey       List initialized owned repos with detected interfaces and DESIGN.md/guidelines status.
  issues       File worker-ready auto-dispatch issues for survey repos missing DESIGN.md/guides.

Examples:
  aidevops design detect .
  aidevops design scaffold .
  aidevops design guidelines . --pdf
  aidevops design survey --json
  aidevops design issues --apply
USAGE
	return 0
}

_dg_abs_path() {
	local input_path="$1"
	local base_name=""
	local dir_name=""
	if [[ -d "$input_path" ]]; then
		(cd "$input_path" 2>/dev/null && pwd -P) || return 1
		return 0
	fi
	dir_name="$(dirname "$input_path")"
	base_name="$(basename "$input_path")"
	(cd "$dir_name" 2>/dev/null && printf '%s/%s\n' "$(pwd -P)" "$base_name") || return 1
	return 0
}

_dg_glob_exists() {
	local pattern="$1"
	compgen -G "$pattern" >/dev/null
	return $?
}

_dg_repo_config_interface_value() {
	local repo_path="$1"
	local explicit=""
	if command -v jq >/dev/null 2>&1 && [[ -f "$repo_path/.aidevops.json" ]]; then
		explicit=$(jq -r 'if has("has_interface") then .has_interface elif has("interface") then .interface else empty end' "$repo_path/.aidevops.json" 2>/dev/null || printf '')
		case "$explicit" in
		true | false)
			printf '%s\n' "$explicit"
			return 0
			;;
		esac
	fi
	return 1
}

_dg_repos_json_interface_value() {
	local repo_path="$1"
	local explicit=""
	[[ -f "$REPOS_FILE" ]] || return 1
	command -v jq >/dev/null 2>&1 || return 1

	local canonical_path
	canonical_path=$(_dg_abs_path "$repo_path" 2>/dev/null || printf '%s' "$repo_path")
	explicit=$(jq -r --arg path "$canonical_path" --arg raw_path "$repo_path" '
		.initialized_repos // []
		| map(select(.path == $path or .path == $raw_path))
		| if length == 0 then empty else (.[0].has_interface // .[0].interface // empty) end
	' "$REPOS_FILE" 2>/dev/null || printf '')
	case "$explicit" in
	true | false)
		printf '%s\n' "$explicit"
		return 0
		;;
	esac
	return 1
}

repo_has_interface() {
	local repo_path="${1:-.}"
	[[ -d "$repo_path" ]] || return 1

	local explicit=""
	explicit=$(_dg_repo_config_interface_value "$repo_path" 2>/dev/null || printf '')
	case "$explicit" in
	true) return 0 ;;
	false) return 1 ;;
	esac
	explicit=$(_dg_repos_json_interface_value "$repo_path" 2>/dev/null || printf '')
	case "$explicit" in
	true) return 0 ;;
	false) return 1 ;;
	esac

	local marker
	for marker in \
		"next.config.js" "next.config.mjs" "next.config.ts" \
		"vite.config.js" "vite.config.mjs" "vite.config.ts" \
		"nuxt.config.js" "nuxt.config.ts" "astro.config.mjs" "astro.config.ts" \
		"svelte.config.js" "svelte.config.ts" "angular.json" "tailwind.config.js" "tailwind.config.ts" \
		"index.html" "src/App.jsx" "src/App.tsx" "src/App.vue" "src/main.jsx" "src/main.tsx" \
		"src/routes" "src/pages" "src/components" "app/page.jsx" "app/page.tsx" "pages/_app.jsx" "pages/_app.tsx" \
		"resources/views" "app/views" "public/index.html" "frontend" "client" "web" "ui"; do
		[[ -e "$repo_path/$marker" ]] && return 0
	done

	local pattern
	for pattern in \
		"$repo_path/templates/*.html" \
		"$repo_path/templates/*.twig" \
		"$repo_path/templates/*.liquid" \
		"$repo_path/views/*.html" \
		"$repo_path/views/*.erb" \
		"$repo_path/views/*.php"; do
		_dg_glob_exists "$pattern" && return 0
	done

	if git -C "$repo_path" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
		local ui_file=""
		while IFS= read -r ui_file; do
			[[ -n "$ui_file" ]] && return 0
		done < <(git -C "$repo_path" ls-files '*.tsx' '*.jsx' '*.vue' '*.svelte' 2>/dev/null)
	fi

	local package_json="$repo_path/package.json"
	if [[ -f "$package_json" ]]; then
		if command -v jq >/dev/null 2>&1; then
			local dep_count="0"
			dep_count=$(jq '[((.dependencies // {}) + (.devDependencies // {}) + (.peerDependencies // {})) | keys[] | select(test("^(next|react|react-dom|vue|svelte|astro|@angular/core|@remix-run/react|@vitejs/plugin-react|@vitejs/plugin-vue|tailwindcss|@mui/material|@chakra-ui/react|@mantine/core|framer-motion)$"))] | length' "$package_json" 2>/dev/null || printf '0')
			case "$dep_count" in
			'' | *[!0-9]*) dep_count=0 ;;
			esac
			[[ "$dep_count" -gt 0 ]] && return 0
		elif grep -Eq '"(next|react|react-dom|vue|svelte|astro|@angular/core|@remix-run/react|tailwindcss)"[[:space:]]*:' "$package_json" 2>/dev/null; then
			return 0
		fi
	fi

	return 1
}

_dg_repo_name() {
	local repo_path="$1"
	local remote_url=""
	remote_url=$(git -C "$repo_path" remote get-url origin 2>/dev/null || printf '')
	if [[ -n "$remote_url" ]]; then
		basename "$remote_url" .git
		return 0
	fi
	basename "$repo_path"
	return 0
}

_dg_template_path() {
	local candidate="$AGENTS_DIR/templates/DESIGN.md.template"
	if [[ -f "$candidate" ]]; then
		printf '%s\n' "$candidate"
		return 0
	fi
	candidate="$SCRIPT_DIR/../templates/DESIGN.md.template"
	if [[ -f "$candidate" ]]; then
		printf '%s\n' "$candidate"
		return 0
	fi
	return 1
}

_dg_write_design_template() {
	local template_path="$1"
	local output_path="$2"
	local repo_name="$3"
	python3 - "$template_path" "$output_path" "$repo_name" <<'PY'
from pathlib import Path
import sys

template = Path(sys.argv[1])
output = Path(sys.argv[2])
repo_name = sys.argv[3]

text = template.read_text(encoding="utf-8")
text = text.replace("{Project Name}", repo_name)
text = text.replace("{one-line description of the design system}", f"{repo_name} interface design system")
output.write_text(text, encoding="utf-8")
PY
	return 0
}

cmd_detect() {
	local repo_path="${1:-.}"
	if repo_has_interface "$repo_path"; then
		printf 'interface\n'
		return 0
	fi
	printf 'non-interface\n'
	return 1
}

cmd_scaffold() {
	local repo_path="."
	local force="$DG_FALSE"
	local dry_run="$DG_FALSE"
	while [[ $# -gt 0 ]]; do
		local arg="$1"
		case "$arg" in
		--force)
			force="$DG_TRUE"
			shift
			;;
		--dry-run)
			dry_run="$DG_TRUE"
			shift
			;;
		-h | --help)
			usage
			return 0
			;;
		-*)
			_dg_die "unknown scaffold option: $arg"
			;;
		*)
			repo_path="$arg"
			shift
			;;
		esac
	done

	[[ -d "$repo_path" ]] || _dg_die "repo path not found: $repo_path"
	local design_path="$repo_path/DESIGN.md"
	if [[ -f "$design_path" ]]; then
		_dg_info "DESIGN.md already exists: $design_path"
		printf '%s\n' "$design_path"
		return 0
	fi

	if [[ "$force" != "$DG_TRUE" ]] && ! repo_has_interface "$repo_path"; then
		_dg_info "No interface markers detected; use --force to scaffold DESIGN.md anyway"
		return 0
	fi

	local template_path
	template_path=$(_dg_template_path) || _dg_die "DESIGN.md template not found"
	local repo_name
	repo_name=$(_dg_repo_name "$repo_path")
	if [[ "$dry_run" == "$DG_TRUE" ]]; then
		printf 'would-create %s from %s\n' "$design_path" "$template_path"
		return 0
	fi
	_dg_write_design_template "$template_path" "$design_path" "$repo_name"
	_dg_success "Created $design_path"
	printf '%s\n' "$design_path"
	return 0
}

_dg_design_path_from_arg() {
	local input_path="$1"
	if [[ -d "$input_path" ]]; then
		printf '%s/DESIGN.md\n' "$input_path"
		return 0
	fi
	printf '%s\n' "$input_path"
	return 0
}

_dg_generate_markdown() {
	local design_path="$1"
	local output_path="$2"
	python3 "$SCRIPT_DIR/design_guidelines_render.py" "$design_path" "$output_path"
	return 0
}

_dg_report_helper() {
	local candidate="$AGENTS_DIR/scripts/report-render-helper.sh"
	if [[ -x "$candidate" ]]; then
		printf '%s\n' "$candidate"
		return 0
	fi
	candidate="$SCRIPT_DIR/report-render-helper.sh"
	if [[ -x "$candidate" ]]; then
		printf '%s\n' "$candidate"
		return 0
	fi
	return 1
}

_dg_browser_bin() {
	local candidate=""
	for candidate in \
		"${AIDEVOPS_CHROME_BIN:-}" \
		"$(command -v chromium 2>/dev/null || printf '')" \
		"$(command -v chromium-browser 2>/dev/null || printf '')" \
		"$(command -v google-chrome 2>/dev/null || printf '')" \
		"$(command -v google-chrome-stable 2>/dev/null || printf '')" \
		"/Applications/Google Chrome.app/Contents/MacOS/Google Chrome" \
		"/Applications/Chromium.app/Contents/MacOS/Chromium" \
		"/Applications/Microsoft Edge.app/Contents/MacOS/Microsoft Edge"; do
		[[ -n "$candidate" && -x "$candidate" ]] && { printf '%s\n' "$candidate"; return 0; }
	done
	return 1
}

_dg_render_pdf() {
	local html_path="$1"
	local pdf_path="$2"
	local browser_bin="$3"
	local abs_html
	abs_html=$(_dg_abs_path "$html_path") || return 1
	"$browser_bin" --headless --disable-gpu --no-pdf-header-footer --print-to-pdf="$pdf_path" "file://${abs_html}" >/dev/null 2>&1
	return $?
}

_dg_profile_pdf_name() {
	local output_dir="$1"
	local profile="$2"
	case "$profile" in
	a4)
		printf '%s/brand-guidelines-a4.pdf\n' "$output_dir"
		;;
	letter)
		printf '%s/brand-guidelines-usletter.pdf\n' "$output_dir"
		;;
	slides-16-9-*)
		printf '%s/brand-guidelines-slides.pdf\n' "$output_dir"
		;;
	*)
		printf '%s/brand-guidelines-%s.pdf\n' "$output_dir" "$profile"
		;;
	esac
	return 0
}

_dg_expand_profiles() {
	local requested="$1"
	case "$requested" in
	all)
		printf '%s\n' "a4" "letter" "slides-16-9-2"
		;;
	slides)
		printf '%s\n' "slides-16-9-2"
		;;
	a4 | letter | slides-16-9-1 | slides-16-9-2 | slides-16-9-3)
		printf '%s\n' "$requested"
		;;
	*)
		_dg_die "unknown PDF profile: $requested"
		;;
	esac
	return 0
}

_dg_render_one_guidelines_pdf() {
	local profile="$1"
	local output_dir="$2"
	local html_path="$3"
	local markdown_path="$4"
	local report_helper="$5"
	local template="$6"
	local theme="$7"
	local browser_bin="$8"
	local profile_html="$html_path"
	local remove_profile_html="$DG_FALSE"
	if [[ "$profile" != "a4" ]]; then
		profile_html="$output_dir/.brand-guidelines-${profile}.html"
		"$report_helper" render "$markdown_path" --template "$template" --theme "$theme" --pdf-profile "$profile" --output "$profile_html"
		remove_profile_html="$DG_TRUE"
	fi
	local pdf_path
	pdf_path=$(_dg_profile_pdf_name "$output_dir" "$profile")
	if _dg_render_pdf "$profile_html" "$pdf_path" "$browser_bin"; then
		_dg_success "Generated $pdf_path"
	else
		_dg_warn "PDF export failed for profile $profile"
	fi
	[[ "$remove_profile_html" == "$DG_TRUE" ]] && rm -f "$profile_html"
	return 0
}

_dg_render_guidelines_pdfs() {
	local render_pdf="$1"
	local requested_profile="$2"
	local output_dir="$3"
	local html_path="$4"
	local markdown_path="$5"
	local report_helper="$6"
	local template="$7"
	local theme="$8"
	[[ "$render_pdf" == "$DG_TRUE" ]] || return 0
	local browser_bin=""
	browser_bin=$(_dg_browser_bin 2>/dev/null || printf '')
	if [[ -z "$browser_bin" ]]; then
		_dg_warn "No Chrome/Chromium binary found; skipped PDF export"
		return 0
	fi
	local profile
	while IFS= read -r profile; do
		[[ -z "$profile" ]] && continue
		_dg_render_one_guidelines_pdf "$profile" "$output_dir" "$html_path" "$markdown_path" "$report_helper" "$template" "$theme" "$browser_bin"
	done < <(_dg_expand_profiles "$requested_profile")
	return 0
}

cmd_guidelines() {
	local input_path="."
	local output_dir=""
	local template="signal-agency"
	local theme="auto"
	local render_pdf="$DG_TRUE"
	local requested_profile="all"
	while [[ $# -gt 0 ]]; do
		local arg="$1"
		case "$arg" in
		--output-dir)
			output_dir="${2:-}"
			[[ -n "$output_dir" ]] || _dg_die "--output-dir requires a value"
			shift 2
			;;
		--template)
			template="${2:-}"
			[[ -n "$template" ]] || _dg_die "--template requires a value"
			shift 2
			;;
		--theme)
			theme="${2:-}"
			[[ -n "$theme" ]] || _dg_die "--theme requires a value"
			shift 2
			;;
		--pdf)
			render_pdf="$DG_TRUE"
			shift
			;;
		--no-pdf)
			render_pdf="$DG_FALSE"
			shift
			;;
		--pdf-profile | --profile)
			requested_profile="${2:-}"
			[[ -n "$requested_profile" ]] || _dg_die "$arg requires a value"
			shift 2
			;;
		-h | --help)
			usage
			return 0
			;;
		-*)
			_dg_die "unknown guidelines option: $arg"
			;;
		*)
			input_path="$arg"
			shift
			;;
		esac
	done

	local design_path
	design_path=$(_dg_design_path_from_arg "$input_path")
	[[ -f "$design_path" ]] || _dg_die "DESIGN.md not found: $design_path"
	if [[ -z "$output_dir" ]]; then
		if [[ -d "$input_path" ]]; then
			output_dir="$input_path/_reports/brand-guidelines"
		else
			output_dir="$(dirname "$design_path")/_reports/brand-guidelines"
		fi
	fi
	mkdir -p "$output_dir"

	local markdown_path="$output_dir/brand-guidelines.md"
	local html_path="$output_dir/brand-guidelines.html"
	local report_helper
	report_helper=$(_dg_report_helper) || _dg_die "report-render-helper.sh not found"

	_dg_generate_markdown "$design_path" "$markdown_path"
	"$report_helper" render "$markdown_path" --template "$template" --theme "$theme" --pdf-profile a4 --output "$html_path"
	_dg_success "Generated $markdown_path"
	_dg_success "Generated $html_path"

	_dg_render_guidelines_pdfs "$render_pdf" "$requested_profile" "$output_dir" "$html_path" "$markdown_path" "$report_helper" "$template" "$theme"

	printf '%s\n' "$html_path"
	return 0
}

_dg_current_login() {
	if command -v gh >/dev/null 2>&1; then
		gh api user --jq '.login' 2>/dev/null || printf ''
		return 0
	fi
	printf ''
	return 0
}

_dg_repo_is_owned() {
	local slug="$1"
	local maintainer="$2"
	local role="$3"
	local login="$4"
	local owner=""
	[[ "$slug" == */* ]] && owner="${slug%%/*}"
	[[ -n "$login" && "$owner" == "$login" ]] && return 0
	[[ -n "$login" && "$maintainer" == "$login" ]] && return 0
	[[ "$role" == "maintainer" ]] && return 0
	return 1
}

cmd_survey() {
	local json="$DG_FALSE"
	while [[ $# -gt 0 ]]; do
		local arg="$1"
		case "$arg" in
		--json)
			json="$DG_TRUE"
			shift
			;;
		-h | --help)
			usage
			return 0
			;;
		*)
			_dg_die "unknown survey option: $arg"
			;;
		esac
	done

	[[ -f "$REPOS_FILE" ]] || _dg_die "repos.json not found: $REPOS_FILE"
	command -v jq >/dev/null 2>&1 || _dg_die "jq required for survey"

	local login
	login=$(_dg_current_login)
	local tmp_json
	tmp_json=$(mktemp)
	printf '[\n' >"$tmp_json"
	local first="$DG_TRUE"

	while IFS=$'\t' read -r repo_path slug maintainer role local_only; do
		[[ -n "$repo_path" && -d "$repo_path" ]] || continue
		[[ -f "$repo_path/.aidevops.json" ]] || continue
		[[ "$local_only" == "$DG_TRUE" ]] && continue
		_dg_repo_is_owned "$slug" "$maintainer" "$role" "$login" || continue
		repo_has_interface "$repo_path" || continue

		local has_design="$DG_FALSE"
		local has_html="$DG_FALSE"
		local has_pdf="$DG_FALSE"
		[[ -f "$repo_path/DESIGN.md" ]] && has_design="$DG_TRUE"
		[[ -f "$repo_path/_reports/brand-guidelines/brand-guidelines.html" ]] && has_html="$DG_TRUE"
		[[ -f "$repo_path/_reports/brand-guidelines/brand-guidelines-a4.pdf" ]] && has_pdf="$DG_TRUE"

		if [[ "$json" == "$DG_TRUE" ]]; then
			[[ "$first" == "$DG_TRUE" ]] || printf ',\n' >>"$tmp_json"
			first="$DG_FALSE"
			jq -n --arg path "$repo_path" --arg slug "$slug" --argjson has_design "$has_design" --argjson has_html "$has_html" --argjson has_pdf "$has_pdf" \
				'{path:$path, slug:$slug, has_design:$has_design, has_brand_guidelines_html:$has_html, has_brand_guidelines_pdf:$has_pdf}' >>"$tmp_json"
		else
			printf '%s\tDESIGN.md=%s\tHTML=%s\tPDF=%s\n' "${slug:-$repo_path}" "$has_design" "$has_html" "$has_pdf"
		fi
	done < <(jq -r '.initialized_repos // [] | .[] | [.path // "", .slug // "", .maintainer // "", .role // "", (.local_only // false | tostring)] | @tsv' "$REPOS_FILE")

	if [[ "$json" == "$DG_TRUE" ]]; then
		printf '\n]\n' >>"$tmp_json"
		cat "$tmp_json"
	fi
	rm -f "$tmp_json"
	return 0
}

_dg_issue_body() {
	local body_file="$1"
	cat >"$body_file" <<'EOF'
## What

Create or populate the project-root `DESIGN.md` and generate brand guideline handoff artifacts from it.

## Why

This repo has a GUI/interface. Coding agents need a canonical design source before changing UI, and reviewers need generated HTML/PDF brand guideline files for visual QA and handoff.

## How (Approach)

### Files to Modify

- `DESIGN.md` — create if missing, otherwise replace placeholders with observed project tokens and rules.
- `_reports/brand-guidelines/brand-guidelines.md` — generated Markdown handoff from `DESIGN.md`.
- `_reports/brand-guidelines/brand-guidelines.html` — generated browser review file.
- `_reports/brand-guidelines/brand-guidelines-a4.pdf` — generated A4 PDF.
- `_reports/brand-guidelines/brand-guidelines-usletter.pdf` — generated US Letter PDF.
- `_reports/brand-guidelines/brand-guidelines-slides.pdf` — generated 16:9 slides PDF.

### Implementation Steps

1. Inspect existing UI sources for colours, typography, spacing, radius, component states, screenshots, and current brand copy.
2. If `DESIGN.md` is absent, run `aidevops design scaffold . --force`; then replace skeleton placeholders with real observed tokens.
3. Populate the canonical sections from `~/.aidevops/agents/tools/design/design-md.md`: overview, colours, typography, layout, elevation/depth, shapes, components, do/don'ts, responsive behaviour, and agent prompt guide.
4. Run `aidevops design guidelines . --pdf` to regenerate the brand guideline Markdown, HTML, and PDFs.
5. Review the generated HTML/PDF for placeholder values, broken contrast, bad pagination, and private identifiers before committing.

### Verification

```bash
npx @google/design.md lint DESIGN.md
aidevops design guidelines . --pdf
test -f _reports/brand-guidelines/brand-guidelines.html
test -f _reports/brand-guidelines/brand-guidelines-a4.pdf
test -f _reports/brand-guidelines/brand-guidelines-usletter.pdf
test -f _reports/brand-guidelines/brand-guidelines-slides.pdf
```

If `npx @google/design.md` is unavailable in this repo, record that as verification partial and include the exact install-free blocker in the PR body; still run the aidevops guideline generation command.

## Acceptance Criteria

- [ ] `DESIGN.md` exists at repo root and contains real project tokens, not skeleton placeholders.
- [ ] Brand guideline Markdown, HTML, A4 PDF, US Letter PDF, and slides PDF are generated under `_reports/brand-guidelines/`.
- [ ] Generated artifacts contain no secrets, private local paths, raw transcripts, or unrelated repo names.
- [ ] The PR body includes the lint/generation commands and their results.
EOF
	return 0
}

_dg_ensure_gh_create_issue() {
	if declare -F gh_create_issue >/dev/null 2>&1; then
		return 0
	fi
	local wrappers="$SCRIPT_DIR/shared-gh-wrappers.sh"
	[[ -f "$wrappers" ]] || return 1
	# shellcheck source=/dev/null
	source "$wrappers"
	declare -F gh_create_issue >/dev/null 2>&1
	return $?
}

_dg_existing_design_issue() {
	local slug="$1"
	local title="$2"
	gh issue list --repo "$slug" --state open --search "${title} in:title" --json number,title --jq '.[0].number // empty' 2>/dev/null || true
	return 0
}

cmd_issues() {
	local apply="$DG_FALSE"
	while [[ $# -gt 0 ]]; do
		local arg="$1"
		case "$arg" in
		--apply)
			apply="$DG_TRUE"
			shift
			;;
		--dry-run)
			apply="$DG_FALSE"
			shift
			;;
		-h | --help)
			usage
			return 0
			;;
		*)
			_dg_die "unknown issues option: $arg"
			;;
		esac
	done

	[[ -f "$REPOS_FILE" ]] || _dg_die "repos.json not found: $REPOS_FILE"
	command -v jq >/dev/null 2>&1 || _dg_die "jq required for issues"
	command -v gh >/dev/null 2>&1 || _dg_die "gh required for issues"
	if [[ "$apply" == "$DG_TRUE" ]]; then
		_dg_ensure_gh_create_issue || _dg_die "gh_create_issue wrapper unavailable"
	fi

	local survey_file
	survey_file=$(mktemp)
	cmd_survey --json >"$survey_file"
	local title="Populate DESIGN.md and brand guideline exports"
	local created=0 skipped=0 dry=0

	while IFS=$'\t' read -r slug has_design has_html has_pdf; do
		[[ -n "$slug" ]] || continue
		if [[ "$has_design" == "$DG_TRUE" && "$has_html" == "$DG_TRUE" && "$has_pdf" == "$DG_TRUE" ]]; then
			continue
		fi
		local existing=""
		existing=$(_dg_existing_design_issue "$slug" "$title")
		if [[ -n "$existing" ]]; then
			printf 'skip existing %s #%s\n' "$slug" "$existing"
			skipped=$((skipped + 1))
			continue
		fi
		if [[ "$apply" != "$DG_TRUE" ]]; then
			printf 'would-create %s %s\n' "$slug" "$title"
			dry=$((dry + 1))
			continue
		fi

		local body_file
		body_file=$(mktemp)
		_dg_issue_body "$body_file"
		if gh_create_issue --repo "$slug" --title "$title" --body-file "$body_file" --label "auto-dispatch,tier:standard,enhancement"; then
			created=$((created + 1))
		else
			_dg_warn "Issue creation failed for $slug"
		fi
		rm -f "$body_file"
	done < <(jq -r '.[] | [.slug, (.has_design|tostring), (.has_brand_guidelines_html|tostring), (.has_brand_guidelines_pdf|tostring)] | @tsv' "$survey_file")
	rm -f "$survey_file"

	printf 'created=%s skipped=%s dry_run=%s\n' "$created" "$skipped" "$dry"
	return 0
}

main() {
	local command="${1:-help}"
	[[ $# -gt 0 ]] && shift
	case "$command" in
	detect)
		cmd_detect "$@"
		;;
	scaffold | init)
		cmd_scaffold "$@"
		;;
	guidelines | guide | render)
		cmd_guidelines "$@"
		;;
	survey | status)
		cmd_survey "$@"
		;;
	issues | file-issues)
		cmd_issues "$@"
		;;
	help | --help | -h)
		usage
		;;
	*)
		_dg_die "unknown command: $command"
		;;
	esac
	return 0
}

main "$@"
