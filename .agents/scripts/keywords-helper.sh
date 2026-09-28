#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# keywords-helper.sh — context/keywords.md search-targets standard: scaffold,
# repo survey/backfill, team hub config, routines, and registry operations.
# Standard: .agents/seo/keywords-standard.md

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
SCRIPT_NAME="$(basename "${BASH_SOURCE[0]:-$0}")"
AGENTS_DIR="${AIDEVOPS_AGENTS_DIR:-$HOME/.aidevops/agents}"
REPOS_FILE="${AIDEVOPS_REPOS_FILE:-$HOME/.config/aidevops/repos.json}"
REGISTRY_PY="$SCRIPT_DIR/keywords-registry-helper.py"
STRATEGY_REL="context/keywords.md"
LEGACY_REL="context/target-keywords.md"
ISSUE_TITLE="Populate context/keywords.md search targets"

# shellcheck source=shared-constants.sh
[[ -f "${SCRIPT_DIR}/shared-constants.sh" ]] && source "${SCRIPT_DIR}/shared-constants.sh"

[[ -z "${RED+x}" ]] && RED='\033[0;31m'
[[ -z "${GREEN+x}" ]] && GREEN='\033[0;32m'
[[ -z "${BLUE+x}" ]] && BLUE='\033[0;34m'
[[ -z "${YELLOW+x}" ]] && YELLOW='\033[1;33m'
[[ -z "${NC+x}" ]] && NC='\033[0m'

KW_TRUE=true
KW_FALSE=false

_kw_info() {
	local message="$1"
	printf '%b[INFO]%b %s\n' "$BLUE" "$NC" "$message" >&2
	return 0
}

_kw_success() {
	local message="$1"
	printf '%b[OK]%b %s\n' "$GREEN" "$NC" "$message" >&2
	return 0
}

_kw_warn() {
	local message="$1"
	printf '%b[WARN]%b %s\n' "$YELLOW" "$NC" "$message" >&2
	return 0
}

_kw_die() {
	local message="${1:-usage error}"
	printf '%b[%s] ERROR: %s%b\n' "$RED" "$SCRIPT_NAME" "$message" "$NC" >&2
	exit 2
	# shellcheck disable=SC2317
	return 1
}

usage() {
	cat <<'USAGE'
Usage: keywords-helper.sh <command> [args]   (also: aidevops keywords <command>)

Setup and rollout:
  detect [path]                      Print detected search surfaces
  scaffold [path] [--data tracked|ignored] [--dry-run]
                                     Create context/keywords.md + registry tables,
                                     migrate legacy context files, gitignore data
                                     for public repos, add an AGENTS.md pointer
  survey [--json]                    Registered owned repos and keywords status
  issues [--apply]                   File worker-ready backfill issues (dry run default)
  routines                           Print suggested TODO.md routine lines
  hub set <owner/repo> [--path DIR]  Configure the private team hub (local config only)
  hub show                           Show hub and data-store locations

Registry (run in a linked worktree for tracked repos):
  validate [--json]                  Schema, references, duplicate phrases, cannibalisation
  migrate [--apply]                  Import context/target-keywords.md and competitor-analysis.md
  add <table> field=value ...        Append a row (tables: targets queries clusters modifiers entities)
  set <table> <id> field=value ...   Update a row
  list <table> [--status S]          Compact listing
  score [--apply]                    Recompute deterministic 0-100 priorities
  brief [--target ID|--url U|--cluster C] [--asset image|video|social|pr|schema|domain|product|repo]
  slug <text>                        URL/file-name slug
  expand <head-id> [--apply] [--force]
                                     Modifier drill-down ("X for Y", attributes, locations)
  cluster --serps FILE [--threshold 3] [--apply]
                                     SERP-overlap clustering

Data, tracking and budget:
  sync [--no-local-write]            Merge registry with the hub; strategy file 3-way
  track --source export|github|npm|dataforseo|ai [--file F] [--domain D] [--limit N]
  rollup                             Update last/best position and trend from history
  report                             Striking distance, movers, spend
  budget [--estimate USD]            Month spend vs cap (default $1/property)
  index                              Rebuild the local SQLite index from the data store
  routine-run [--paid]               Scheduled tracking for every registered property

All registry commands accept --root <repo> (default: current directory).
USAGE
	return 0
}

_kw_config_get() {
	local dotpath="$1"
	local default="$2"
	local value=""
	if [[ -f "$SCRIPT_DIR/config-helper.sh" ]]; then
		value=$(bash "$SCRIPT_DIR/config-helper.sh" get "$dotpath" 2>/dev/null || printf '')
	fi
	printf '%s\n' "${value:-$default}"
	return 0
}

# Pulse routines run this script directly; use the shared resolver.
_kw_load_credentials() {
	# shellcheck source=dataforseo-credentials.sh
	source "$SCRIPT_DIR/dataforseo-credentials.sh"
	dataforseo_load_credentials || true
	return 0
}

# Exported environment wins over local config, even when set to empty
# (an empty AIDEVOPS_KEYWORDS_HUB_SLUG deliberately disables the hub).
_kw_env_or_config() {
	local name="$1"
	local dotpath="$2"
	local default="$3"
	if printenv "$name" >/dev/null 2>&1; then
		printenv "$name"
		return 0
	fi
	_kw_config_get "$dotpath" "$default"
	return 0
}

_kw_export_env() {
	AIDEVOPS_KEYWORDS_HUB_SLUG=$(_kw_env_or_config AIDEVOPS_KEYWORDS_HUB_SLUG keywords.hub_slug "")
	AIDEVOPS_KEYWORDS_HUB_PATH=$(_kw_env_or_config AIDEVOPS_KEYWORDS_HUB_PATH keywords.hub_path "")
	AIDEVOPS_KEYWORDS_MONTHLY_BUDGET_USD=$(_kw_env_or_config AIDEVOPS_KEYWORDS_MONTHLY_BUDGET_USD keywords.monthly_budget_usd "1")
	AIDEVOPS_KEYWORDS_DATAFORSEO_ESTIMATE_USD=$(_kw_env_or_config AIDEVOPS_KEYWORDS_DATAFORSEO_ESTIMATE_USD keywords.dataforseo_estimate_usd "0.05")
	export AIDEVOPS_KEYWORDS_HUB_SLUG AIDEVOPS_KEYWORDS_HUB_PATH
	export AIDEVOPS_KEYWORDS_MONTHLY_BUDGET_USD AIDEVOPS_KEYWORDS_DATAFORSEO_ESTIMATE_USD
	export AIDEVOPS_REPOS_FILE="$REPOS_FILE"
	return 0
}

_kw_py() {
	python3 "$REGISTRY_PY" "$@"
	return $?
}

_kw_abs_path() {
	local input_path="$1"
	(cd "$input_path" 2>/dev/null && pwd -P) || return 1
	return 0
}

_kw_repo_name() {
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

_kw_github_slug() {
	local repo_path="$1"
	local remote_url=""
	remote_url=$(git -C "$repo_path" remote get-url origin 2>/dev/null || printf '')
	if [[ "$remote_url" =~ github\.com[:/]([^/]+/[^/]+)$ ]]; then
		printf '%s\n' "${BASH_REMATCH[1]%.git}"
	fi
	return 0
}

_kw_json_field() {
	local file="$1"
	local filter="$2"
	[[ -f "$file" ]] || return 0
	command -v jq >/dev/null 2>&1 || return 0
	jq -r "$filter // empty" "$file" 2>/dev/null || true
	return 0
}

_kw_repos_field() {
	local repo_path="$1"
	local field="$2"
	[[ -f "$REPOS_FILE" ]] || return 0
	command -v jq >/dev/null 2>&1 || return 0
	jq -r --arg path "$repo_path" --arg field "$field" '
		.initialized_repos // [] | map(select(.path == $path)) | .[0] // {}
		| getpath($field | split(".")) // empty' "$REPOS_FILE" 2>/dev/null || true
	return 0
}

# Resolve whether registry data is tracked in Git or ignored (public repos).
_kw_data_mode() {
	local repo_path="$1"
	local init_scope="${2:-}"
	local mode=""
	mode=$(_kw_json_field "$repo_path/.aidevops.json" '.keywords.data')
	[[ -z "$mode" ]] && mode=$(_kw_repos_field "$repo_path" "keywords.data")
	case "$mode" in
	tracked | ignored)
		printf '%s\n' "$mode"
		return 0
		;;
	esac
	[[ -z "$init_scope" ]] && init_scope=$(_kw_json_field "$repo_path/.aidevops.json" '.init_scope')
	if [[ "$init_scope" == "public" ]]; then
		printf 'ignored\n'
		return 0
	fi
	local slug=""
	slug=$(_kw_github_slug "$repo_path")
	if [[ -n "$slug" ]] && command -v gh >/dev/null 2>&1; then
		local private=""
		private=$(gh api "repos/$slug" --jq '.private' 2>/dev/null || printf '')
		if [[ "$private" == "false" ]]; then
			printf 'ignored\n'
			return 0
		fi
	fi
	printf 'tracked\n'
	return 0
}

_kw_has_interface() {
	local repo_path="$1"
	local design_helper="$SCRIPT_DIR/design-guidelines-helper.sh"
	[[ -x "$design_helper" ]] || return 1
	"$design_helper" detect "$repo_path" >/dev/null 2>&1
	return $?
}

_kw_template_path() {
	local candidate
	for candidate in "$AGENTS_DIR/templates/keywords/keywords.md.template" \
		"$SCRIPT_DIR/../templates/keywords/keywords.md.template"; do
		if [[ -f "$candidate" ]]; then
			printf '%s\n' "$candidate"
			return 0
		fi
	done
	return 1
}

_kw_render_template() {
	local template_path="$1"
	local output_path="$2"
	local repo_name="$3"
	local property="$4"
	local surfaces="$5"
	local data_mode="$6"
	mkdir -p "$(dirname "$output_path")"
	python3 - "$template_path" "$output_path" "$repo_name" "$property" "$surfaces" "$data_mode" <<'PY'
from pathlib import Path
import sys

template, output, name, prop, surfaces, data = sys.argv[1:7]
text = Path(template).read_text(encoding="utf-8")
for key, value in {"{Project Name}": name, "{property}": prop,
                   "{surfaces}": surfaces.replace(",", ", "), "{data}": data}.items():
    text = text.replace(key, value)
Path(output).write_text(text, encoding="utf-8")
PY
	return 0
}

_kw_gitignore_data() {
	local repo_path="$1"
	local gitignore="$repo_path/.gitignore"
	if [[ -f "$gitignore" ]] && grep -qxF "context/keywords/" "$gitignore"; then
		return 0
	fi
	{
		printf '\n# aidevops keywords: search-target data lives in the private team hub (aidevops keywords sync)\n'
		printf '%s\n' "$STRATEGY_REL" "context/keywords.md.hub" "context/keywords/"
	} >>"$gitignore"
	_kw_info "Added keywords data paths to .gitignore (public repo)"
	return 0
}

_kw_agents_pointer() {
	local repo_path="$1"
	local agents_md="$repo_path/AGENTS.md"
	[[ -f "$agents_md" ]] || return 0
	grep -qF "$STRATEGY_REL" "$agents_md" && return 0
	cat >>"$agents_md" <<'EOF'

## Search targets

Search keywords, AI-answer questions and search entities live in `context/keywords.md` and `context/keywords/` (standard: `~/.aidevops/agents/seo/keywords-standard.md`). Read them, or run `aidevops keywords brief`, before naming, copy, metadata, schema, media, social or PR work. If the files are missing in a clone, run `aidevops keywords sync`.
EOF
	_kw_info "Added search-targets pointer to AGENTS.md"
	return 0
}

_kw_parse_scaffold_args() {
	KW_ARG_PATH="."
	KW_ARG_DATA=""
	KW_ARG_SCOPE=""
	KW_ARG_DRY="$KW_FALSE"
	while [[ $# -gt 0 ]]; do
		local arg="$1"
		case "$arg" in
		--data)
			KW_ARG_DATA="${2:-}"
			shift 2
			;;
		--init-scope)
			KW_ARG_SCOPE="${2:-}"
			shift 2
			;;
		--dry-run)
			KW_ARG_DRY="$KW_TRUE"
			shift
			;;
		-*) _kw_die "unknown scaffold option: $arg" ;;
		*)
			KW_ARG_PATH="$arg"
			shift
			;;
		esac
	done
	return 0
}

cmd_scaffold() {
	_kw_parse_scaffold_args "$@"
	local repo_path
	repo_path=$(_kw_abs_path "$KW_ARG_PATH") || _kw_die "repo path not found: $KW_ARG_PATH"
	local data_mode="${KW_ARG_DATA:-$(_kw_data_mode "$repo_path" "$KW_ARG_SCOPE")}"
	case "$data_mode" in tracked | ignored) ;; *) _kw_die "--data must be tracked or ignored" ;; esac
	local surfaces
	surfaces=$(cmd_detect "$repo_path")
	if [[ "$KW_ARG_DRY" == "$KW_TRUE" ]]; then
		printf 'would-scaffold %s data=%s surfaces=%s\n' "$repo_path/$STRATEGY_REL" "$data_mode" "$surfaces"
		return 0
	fi
	[[ "$data_mode" == "ignored" ]] && _kw_gitignore_data "$repo_path"
	if [[ -f "$repo_path/$STRATEGY_REL" ]]; then
		_kw_info "$STRATEGY_REL already exists"
	else
		local template_path property
		template_path=$(_kw_template_path) || _kw_die "keywords.md template not found"
		property=$(_kw_github_slug "$repo_path")
		property="${property//\//__}"
		_kw_render_template "$template_path" "$repo_path/$STRATEGY_REL" "$(_kw_repo_name "$repo_path")" \
			"${property:-$(basename "$repo_path")}" "$surfaces" "$data_mode"
		_kw_success "Created $STRATEGY_REL (surfaces: $surfaces; data: $data_mode)"
	fi
	_kw_py init-tables --root "$repo_path" >/dev/null
	if [[ -f "$repo_path/$LEGACY_REL" ]]; then
		_kw_py migrate --root "$repo_path" --apply >/dev/null && _kw_info "Migrated $LEGACY_REL (source kept)"
	fi
	_kw_agents_pointer "$repo_path"
	printf '%s\n' "$repo_path/$STRATEGY_REL"
	return 0
}

cmd_detect() {
	local repo_path="${1:-.}"
	local interface="$KW_FALSE"
	_kw_has_interface "$repo_path" && interface="$KW_TRUE"
	_kw_py detect --root "$repo_path" --interface "$interface" --platform "$(_kw_repos_field "$repo_path" platform)"
	return $?
}

_kw_current_login() {
	if command -v gh >/dev/null 2>&1; then
		gh api user --jq '.login' 2>/dev/null || printf ''
		return 0
	fi
	printf ''
	return 0
}

_kw_repo_is_owned() {
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

_kw_survey_rows() {
	local login
	login=$(_kw_current_login)
	local repo_path slug maintainer role local_only maintenance
	while IFS=$'\t' read -r repo_path slug maintainer role local_only maintenance; do
		[[ -n "$repo_path" && -d "$repo_path" && -f "$repo_path/.aidevops.json" ]] || continue
		[[ "$local_only" == "$KW_TRUE" || "$maintenance" == "$KW_FALSE" ]] && continue
		_kw_repo_is_owned "$slug" "$maintainer" "$role" "$login" || continue
		local has_keywords="$KW_FALSE" has_legacy="$KW_FALSE"
		[[ -f "$repo_path/$STRATEGY_REL" ]] && has_keywords="$KW_TRUE"
		[[ -f "$repo_path/$LEGACY_REL" ]] && has_legacy="$KW_TRUE"
		printf '%s\t%s\t%s\t%s\n' "$slug" "$repo_path" "$has_keywords" "$has_legacy"
	done < <(jq -r '.initialized_repos // [] | .[] | [.path // "", .slug // "", .maintainer // "", .role // "",
		(.local_only // false | tostring), (.maintenance // true | tostring)] | @tsv' "$REPOS_FILE")
	return 0
}

cmd_survey() {
	local json="$KW_FALSE"
	[[ "${1:-}" == "--json" ]] && json="$KW_TRUE"
	[[ -f "$REPOS_FILE" ]] || _kw_die "repos.json not found: $REPOS_FILE"
	command -v jq >/dev/null 2>&1 || _kw_die "jq required for survey"
	local rows
	rows=$(_kw_survey_rows)
	if [[ "$json" == "$KW_TRUE" ]]; then
		printf '%s\n' "$rows" | jq -R -s 'split("\n") | map(select(length > 0) | split("\t")
			| {slug: .[0], path: .[1], has_keywords: (.[2] == "true"), has_legacy: (.[3] == "true")})'
		return 0
	fi
	printf '%s\n' "$rows" | awk -F'\t' 'NF { printf "%s\tkeywords=%s\tlegacy=%s\n", $1, $3, $4 }'
	return 0
}

_kw_issue_body() {
	local body_file="$1"
	cat >"$body_file" <<'EOF'
## What

Create and populate `context/keywords.md` plus the `context/keywords/` registry (targets, questions, clusters, modifiers, entities) so every search-facing change in this repo uses the same target keywords, AI-answer questions and entity names.

## Why

aidevops now standardises search targets per repository (`~/.aidevops/agents/seo/keywords-standard.md`). Repositories rank on GitHub, package registries and AI answers even without a website, and agents for copy, images, video, schema, social and PR read this registry instead of guessing keywords.

## How (Approach)

### Files to Modify

- `context/keywords.md` — create with `aidevops keywords scaffold .`, then fill Positioning, Priorities, Naming and metadata rules.
- `context/keywords/*.toon` — rows added with `aidevops keywords add|set` (never hand-edit row counts).
- `.gitignore` and `AGENTS.md` — updated by the scaffold (public repos keep registry data out of Git).

### Files Scope

- context/keywords.md
- context/keywords/targets.toon
- context/keywords/queries.toon
- context/keywords/clusters.toon
- context/keywords/modifiers.toon
- context/keywords/entities.toon
- .gitignore
- AGENTS.md

### Implementation Steps

1. `aidevops keywords scaffold .` — detects surfaces, migrates any `context/target-keywords.md`, and picks tracked vs ignored data.
2. Add the brand entity (`role=self`, `same_as` profiles) and 3-5 competitors to `entities`.
3. Add 10-30 targets from existing evidence first (README, docs, GSC/Bing exports, package keywords, GitHub topics); set `business_value` 1-5. Paid research must stay inside the monthly budget (`aidevops keywords budget`).
4. Add 5-15 AI-answer questions (`queries`) people ask where this project should be recommended.
5. `aidevops keywords score --apply` then `aidevops keywords validate`.
6. Public repos: run `aidevops keywords sync` to publish the registry to the team hub; commit only `.gitignore` and `AGENTS.md`. If no hub is configured, say so in the PR body.

### Verification

```bash
aidevops keywords validate
aidevops keywords brief
```

## Acceptance Criteria

- [ ] `aidevops keywords validate` passes.
- [ ] At least one `role=self` entity, 10 targets and 5 questions exist with evidence notes.
- [ ] Naming and metadata rules in `context/keywords.md` contain no template placeholders.
- [ ] Public repos commit no registry data; the PR body records hub sync status.
EOF
	return 0
}

_kw_ensure_gh_create_issue() {
	declare -F gh_create_issue >/dev/null 2>&1 && return 0
	local wrappers="$SCRIPT_DIR/shared-gh-wrappers.sh"
	[[ -f "$wrappers" ]] || return 1
	# shellcheck source=/dev/null
	source "$wrappers"
	declare -F gh_create_issue >/dev/null 2>&1
	return $?
}

_kw_file_issue() {
	local slug="$1"
	local body_file
	body_file=$(mktemp)
	_kw_issue_body "$body_file"
	local status=0
	gh_create_issue --repo "$slug" --title "$ISSUE_TITLE" --body-file "$body_file" \
		--label "auto-dispatch,tier:standard,enhancement" || status=1
	rm -f "$body_file"
	return "$status"
}

cmd_issues() {
	local apply="$KW_FALSE"
	[[ "${1:-}" == "--apply" ]] && apply="$KW_TRUE"
	[[ -f "$REPOS_FILE" ]] || _kw_die "repos.json not found: $REPOS_FILE"
	command -v gh >/dev/null 2>&1 || _kw_die "gh required for issues"
	if [[ "$apply" == "$KW_TRUE" ]]; then
		_kw_ensure_gh_create_issue || _kw_die "gh_create_issue wrapper unavailable"
	fi
	local created=0 skipped=0 dry=0
	local slug repo_path has_keywords has_legacy
	while IFS=$'\t' read -r slug repo_path has_keywords has_legacy; do
		[[ -n "$slug" && "$has_keywords" != "$KW_TRUE" ]] || continue
		local existing=""
		existing=$(gh issue list --repo "$slug" --state open --search "${ISSUE_TITLE} in:title" --json number --jq '.[0].number // empty' 2>/dev/null || true)
		if [[ -n "$existing" ]]; then
			printf 'skip existing %s #%s\n' "$slug" "$existing"
			skipped=$((skipped + 1))
		elif [[ "$apply" != "$KW_TRUE" ]]; then
			printf 'would-create %s %s (legacy=%s)\n' "$slug" "$ISSUE_TITLE" "$has_legacy"
			dry=$((dry + 1))
		elif _kw_file_issue "$slug"; then
			created=$((created + 1))
		else
			_kw_warn "Issue creation failed for $slug"
		fi
	done < <(_kw_survey_rows)
	printf 'created=%s skipped=%s dry_run=%s\n' "$created" "$skipped" "$dry"
	return 0
}

cmd_routines() {
	cat <<'EOF'
# Add under `## Routines` in the TODO.md of the repo that runs your scheduled jobs (see /routine).
- [x] r-keywords-track Search targets: free rank tracking (GitHub, npm, latest GSC/Bing exports) repeat:weekly(mon@07:00) ~5m run:scripts/keywords-helper.sh routine-run
- [x] r-keywords-paid Search targets: budgeted DataForSEO + AI capture import (cap: keywords.monthly_budget_usd) repeat:monthly(2@07:30) ~10m run:scripts/keywords-helper.sh routine-run --paid
- [ ] r-keywords-review Search targets: quarterly registry review (retire, promote candidates, re-cluster) repeat:cron(0 8 1 1,4,7,10 *) ~30m agent:SEO
EOF
	return 0
}

cmd_hub() {
	local action="${1:-show}"
	[[ $# -gt 0 ]] && shift
	case "$action" in
	set)
		local slug="${1:-}"
		local path_flag="${2:-}"
		local hub_path="${3:-}"
		[[ "$slug" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || _kw_die "hub set requires owner/repo"
		bash "$SCRIPT_DIR/config-helper.sh" set keywords.hub_slug "$slug" >/dev/null
		if [[ "$path_flag" == "--path" && -n "$hub_path" ]]; then
			bash "$SCRIPT_DIR/config-helper.sh" set keywords.hub_path "$hub_path" >/dev/null
		fi
		_kw_success "Keywords hub configured in local config (not committed anywhere)"
		;;
	show)
		_kw_export_env
		printf 'hub_slug=%s\nhub_path=%s\nmonthly_budget_usd=%s\n' "${AIDEVOPS_KEYWORDS_HUB_SLUG:-<none>}" \
			"${AIDEVOPS_KEYWORDS_HUB_PATH:-<workspace>}" "$AIDEVOPS_KEYWORDS_MONTHLY_BUDGET_USD"
		;;
	*) _kw_die "unknown hub action: $action" ;;
	esac
	return 0
}

_kw_with_repo_budget() {
	local args=("$@")
	local root="."
	local index
	for ((index = 0; index < ${#args[@]}; index++)); do
		[[ "${args[$index]}" == "--root" ]] && root="${args[$((index + 1))]:-.}"
	done
	local abs_root repo_budget=""
	abs_root=$(_kw_abs_path "$root" 2>/dev/null || printf '%s' "$root")
	repo_budget=$(_kw_repos_field "$abs_root" "keywords.budget_usd_month")
	[[ -n "$repo_budget" ]] && export AIDEVOPS_KEYWORDS_MONTHLY_BUDGET_USD="$repo_budget"
	return 0
}

main() {
	local command="${1:-help}"
	[[ $# -gt 0 ]] && shift
	case "$command" in
	detect) cmd_detect "$@" ;;
	scaffold | init) cmd_scaffold "$@" ;;
	survey | status) cmd_survey "$@" ;;
	issues | file-issues) cmd_issues "$@" ;;
	routines) cmd_routines ;;
	hub) cmd_hub "$@" ;;
	routine-run)
		_kw_export_env
		_kw_load_credentials
		_kw_py routine --estimate "$AIDEVOPS_KEYWORDS_DATAFORSEO_ESTIMATE_USD" "$@"
		;;
	track)
		_kw_export_env
		_kw_load_credentials
		_kw_with_repo_budget "$@"
		_kw_py track --estimate "$AIDEVOPS_KEYWORDS_DATAFORSEO_ESTIMATE_USD" "$@"
		;;
	validate | migrate | add | set | list | score | brief | slug | expand | cluster | sync | rollup | report | budget | index | property)
		_kw_export_env
		_kw_with_repo_budget "$@"
		_kw_py "$command" "$@"
		;;
	help | --help | -h) usage ;;
	*) _kw_die "unknown command: $command (see: keywords-helper.sh help)" ;;
	esac
	return $?
}

main "$@"
