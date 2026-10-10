#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
set -euo pipefail

# Codacy Analysis CLI integration (GH#34164)
#
# Wraps Codacy's local analyzer: npm package @codacy/analysis-cli, command
# `codacy-analysis` (Node.js 20+). Docs: https://docs.codacy.com/codacy-analysis-cli/
#
# Usage: codacy-cli.sh <command> [options]   (see `codacy-cli.sh help`)
#
# Exit codes: 0 success / no findings
#             1 findings reported, or the command failed
#             2 usage or setup error (CLI missing, bad flags, missing auth),
#               or analyzer tool errors during `analyze` (results still written)
#
# Tokens come from the environment only and are never passed on argv:
#   CODACY_PROJECT_TOKEN, CODACY_<OWNER>_<REPO>_PROJECT_TOKEN (mapped to
#   CODACY_PROJECT_TOKEN for this process only), CODACY_API_TOKEN, or the
#   credentials stored by `codacy-analysis login`.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit
# shellcheck source=./shared-constants.sh
source "${SCRIPT_DIR}/shared-constants.sh"

readonly CODACY_PACKAGE="@codacy/analysis-cli"
readonly CODACY_PINNED_VERSION="${CODACY_ANALYSIS_CLI_VERSION:-0.24.0}"
readonly CODACY_BIN="codacy-analysis"
readonly CODACY_MIN_NODE_MAJOR=20
readonly CODACY_CONFIG_FILE=".codacy/codacy.config.json"
readonly CODACY_DEFAULT_SARIF="codacy-results.sarif"
readonly CODACY_CREDENTIALS_FILE="${HOME}/.codacy/credentials"

# Populated by resolve_repo_coords
CODACY_COORD_PROVIDER=""
CODACY_COORD_ORG=""
CODACY_COORD_REPO=""

# Populated by parse_analyze_args
ANALYZE_ARGS=()
ANALYZE_INSTALL_DEPS=true
ANALYZE_CUSTOM_CONFIG=false

print_header() {
	local message="$1"
	echo -e "${PURPLE}🔍 $message${NC}"
	return 0
}

has_codacy_cli() {
	command -v "$CODACY_BIN" >/dev/null 2>&1
	return $?
}

require_codacy_cli() {
	if has_codacy_cli; then
		return 0
	fi
	print_error "$CODACY_BIN not found. Install it with: $0 install"
	return 2
}

# Run the CLI with the update notifier disabled (keeps CI and agent output clean).
run_codacy() {
	local subcommand="$1"
	shift
	"$CODACY_BIN" "$subcommand" --no-update-notifier "$@"
	return $?
}

check_node_version() {
	if ! command -v node >/dev/null 2>&1; then
		print_error "Node.js ${CODACY_MIN_NODE_MAJOR}+ is required (node not found)"
		return 2
	fi
	local major
	major=$(node -p 'process.versions.node.split(".")[0]' 2>/dev/null || echo 0)
	if [[ "$major" =~ ^[0-9]+$ ]] && ((major >= CODACY_MIN_NODE_MAJOR)); then
		return 0
	fi
	print_error "Node.js ${CODACY_MIN_NODE_MAJOR}+ is required (found: $(node --version 2>/dev/null || echo unknown))"
	return 2
}

install_codacy_cli() {
	local requested="${1:-$CODACY_PINNED_VERSION}"
	print_header "Installing Codacy Analysis CLI"
	check_node_version || return $?
	if ! command -v npm >/dev/null 2>&1; then
		print_error "npm not found; install Node.js ${CODACY_MIN_NODE_MAJOR}+ with npm first"
		return 2
	fi
	# --ignore-scripts: the bundled analyzers work without lifecycle scripts, and
	# this skips third-party postinstall hooks (including install telemetry).
	print_info "npm install -g --ignore-scripts ${CODACY_PACKAGE}@${requested}"
	if ! npm install -g --ignore-scripts "${CODACY_PACKAGE}@${requested}"; then
		print_error "npm install failed (global prefix: $(npm prefix -g 2>/dev/null || echo unknown))"
		return 1
	fi
	if ! has_codacy_cli; then
		print_error "Installed, but $CODACY_BIN is not on PATH; add \"\$(npm prefix -g)/bin\" to PATH"
		return 1
	fi
	print_success "Installed $CODACY_BIN $("$CODACY_BIN" --version 2>/dev/null || echo unknown)"
	print_info "Next: $0 init   (then: $0 analyze --diff)"
	return 0
}

# Resolve provider/org/repo from CODACY_PROVIDER/ORGANIZATION/REPOSITORY, or
# from the origin remote (GitHub, GitLab, Bitbucket).
resolve_repo_coords() {
	CODACY_COORD_PROVIDER="${CODACY_PROVIDER:-}"
	CODACY_COORD_ORG="${CODACY_ORGANIZATION:-}"
	CODACY_COORD_REPO="${CODACY_REPOSITORY:-}"
	if [[ -n "$CODACY_COORD_PROVIDER" && -n "$CODACY_COORD_ORG" && -n "$CODACY_COORD_REPO" ]]; then
		return 0
	fi
	local url provider=""
	url=$(git remote get-url origin 2>/dev/null || true)
	url="${url%.git}"
	case "$url" in
	*github.com[:/]*) provider="gh" ;;
	*gitlab.com[:/]*) provider="gl" ;;
	*bitbucket.org[:/]*) provider="bb" ;;
	*) return 1 ;;
	esac
	local re='[:/]([^/:]+)/([^/:]+)$'
	[[ "$url" =~ $re ]] || return 1
	CODACY_COORD_PROVIDER="${CODACY_COORD_PROVIDER:-$provider}"
	CODACY_COORD_ORG="${CODACY_COORD_ORG:-${BASH_REMATCH[1]}}"
	CODACY_COORD_REPO="${CODACY_COORD_REPO:-${BASH_REMATCH[2]}}"
	return 0
}

# Print the repository-scoped token variable name, e.g.
# CODACY_MARCUSQUINN_AIDEVOPS_PROJECT_TOKEN.
scoped_token_name() {
	resolve_repo_coords || return 1
	local slug
	slug=$(printf '%s_%s' "$CODACY_COORD_ORG" "$CODACY_COORD_REPO" | tr '[:lower:]' '[:upper:]' | tr -c 'A-Z0-9' '_')
	printf 'CODACY_%s_PROJECT_TOKEN\n' "$slug"
	return 0
}

# Map a repository-scoped token to CODACY_PROJECT_TOKEN for this process only.
map_scoped_project_token() {
	if [[ -n "${CODACY_PROJECT_TOKEN:-}" ]]; then
		return 0
	fi
	local name
	name=$(scoped_token_name) || return 0
	if [[ -n "${!name:-}" ]]; then
		export CODACY_PROJECT_TOKEN="${!name}"
		print_info "Using repository token from $name (process-scoped)"
	fi
	return 0
}

has_remote_auth() {
	[[ -n "${CODACY_PROJECT_TOKEN:-}" || -n "${CODACY_API_TOKEN:-}" || -s "$CODACY_CREDENTIALS_FILE" ]]
	return $?
}

auth_hint() {
	local name
	name=$(scoped_token_name 2>/dev/null) || name="CODACY_<OWNER>_<REPO>_PROJECT_TOKEN"
	print_info "Provide one of: CODACY_PROJECT_TOKEN, $name, CODACY_API_TOKEN, or run '$CODACY_BIN login'"
	print_info "Stored secret example: aidevops secret $name -- $0 init"
	return 0
}

init_remote_config() {
	if ! resolve_repo_coords; then
		print_error "Cannot derive provider/org/repo from the origin remote"
		print_info "Set CODACY_PROVIDER (gh|gl|bb), CODACY_ORGANIZATION and CODACY_REPOSITORY"
		return 2
	fi
	if ! has_remote_auth; then
		print_error "Remote init needs a Codacy token"
		auth_hint
		return 2
	fi
	print_info "Pulling Codacy Cloud configuration: $CODACY_COORD_PROVIDER/$CODACY_COORD_ORG/$CODACY_COORD_REPO"
	run_codacy init --remote "$CODACY_COORD_PROVIDER" "$CODACY_COORD_ORG" "$CODACY_COORD_REPO" "$@"
	return $?
}

# codacy-analysis init refuses to overwrite; --force removes the generated
# configuration and its baseline first.
reset_existing_config() {
	local force="$1"
	if [[ ! -f "$CODACY_CONFIG_FILE" ]]; then
		return 0
	fi
	if [[ "$force" != true ]]; then
		print_error "$CODACY_CONFIG_FILE already exists"
		print_info "Use '$0 update-config' to re-sync it, or '$0 init [MODE] --force' to regenerate it"
		return 2
	fi
	rm -f "$CODACY_CONFIG_FILE" ".codacy/codacy.config.baseline.json"
	print_info "Removed existing $CODACY_CONFIG_FILE (--force)"
	return 0
}

# init [remote|auto [filters]|default|local] [--force] [extra init flags]
# With no mode: remote when a token and repo coordinates are available, else auto.
init_codacy_config() {
	local mode=""
	local force=false
	local passthrough=()
	local arg
	for arg in "$@"; do
		case "$arg" in
		--force) force=true ;;
		remote | auto | default | local)
			if [[ -z "$mode" ]]; then
				mode="$arg"
			else
				passthrough+=("$arg")
			fi
			;;
		*) passthrough+=("$arg") ;;
		esac
	done
	set -- ${passthrough[@]+"${passthrough[@]}"}
	require_codacy_cli || return $?
	print_header "Initializing Codacy configuration"
	reset_existing_config "$force" || return $?
	map_scoped_project_token
	if [[ -z "$mode" ]]; then
		mode="auto"
		if has_remote_auth && resolve_repo_coords; then
			mode="remote"
		fi
	fi
	local rc=0
	case "$mode" in
	remote) init_remote_config "$@" || rc=$? ;;
	auto)
		print_info "Detecting the repository stack locally (no token needed)"
		run_codacy init --auto "$@" || rc=$?
		;;
	default) run_codacy init --default "$@" || rc=$? ;;
	local) run_codacy init "$@" || rc=$? ;;
	*)
		print_error "Unknown init mode: $mode (use remote, auto, default or local)"
		return 2
		;;
	esac
	if [[ "$rc" -ne 0 ]]; then
		print_error "Configuration initialization failed (exit $rc)"
		return "$rc"
	fi
	print_success "Configuration written: $CODACY_CONFIG_FILE (mode: $mode)"
	return 0
}

update_codacy_config() {
	require_codacy_cli || return $?
	map_scoped_project_token
	run_codacy update-config "$@"
	return $?
}

ensure_codacy_config() {
	if [[ -f "$CODACY_CONFIG_FILE" ]]; then
		return 0
	fi
	print_info "No $CODACY_CONFIG_FILE yet; initializing first"
	init_codacy_config
	return $?
}

analyze_args_include() {
	local needle="$1"
	local item
	for item in ${ANALYZE_ARGS[@]+"${ANALYZE_ARGS[@]}"}; do
		if [[ "$item" == "$needle" ]]; then
			return 0
		fi
	done
	return 1
}

# Report output shortcuts: --sarif [FILE] / --json [FILE]
add_report_args() {
	local fmt="$1"
	local out="$2"
	ANALYZE_ARGS+=("--output-format" "$fmt" "--output" "$out")
	return 0
}

is_git_ref() {
	local ref="$1"
	[[ -n "$ref" && "$ref" != -* ]] && git rev-parse --verify --quiet "${ref}^{commit}" >/dev/null 2>&1
	return $?
}

parse_analyze_args() {
	ANALYZE_ARGS=()
	ANALYZE_INSTALL_DEPS=true
	ANALYZE_CUSTOM_CONFIG=false
	local files=()
	while [[ $# -gt 0 ]]; do
		local arg="$1"
		shift
		case "$arg" in
		"") ;; # tolerate empty legacy arguments
		--fix) print_warning "Codacy Analysis CLI has no auto-fix mode; running analysis only" ;;
		--staged | --pr | --no-log) ANALYZE_ARGS+=("$arg") ;;
		--inspect | --fail-if-missing) ANALYZE_ARGS+=("$arg") && ANALYZE_INSTALL_DEPS=false ;;
		--no-install) ANALYZE_INSTALL_DEPS=false ;;
		--diff)
			ANALYZE_ARGS+=("--diff")
			if [[ $# -gt 0 ]] && is_git_ref "$1"; then
				ANALYZE_ARGS+=("$1") && shift
			fi
			;;
		--sarif | --json)
			local out="codacy-results.${arg#--}"
			if [[ $# -gt 0 && -n "$1" && "$1" != -* ]]; then
				out="$1" && shift
			fi
			add_report_args "${arg#--}" "$out"
			;;
		--tool | -t | --output-format | -f | --output | -o | --parallel-tools | --tool-timeout | --log-level | --config-file)
			[[ $# -gt 0 ]] || { print_error "$arg requires a value" && return 2; }
			[[ "$arg" != "--config-file" ]] || ANALYZE_CUSTOM_CONFIG=true
			ANALYZE_ARGS+=("$arg" "$1") && shift
			;;
		--) ANALYZE_ARGS+=("$@") && shift "$#" ;;
		-*) print_error "Unknown analyze option: $arg (pass raw flags after --)" && return 2 ;;
		*) files+=("$arg") ;;
		esac
	done
	if [[ ${#files[@]} -gt 0 ]]; then
		ANALYZE_ARGS+=("--files" "${files[@]}")
	fi
	return 0
}

report_analysis_result() {
	local rc="$1"
	case "$rc" in
	0) print_success "Codacy analysis: no issues found" ;;
	1) print_warning "Codacy analysis: issues found" ;;
	2) print_warning "Codacy analysis: tool errors or invalid options (exit 2); see output above" ;;
	*) print_error "Codacy analysis failed (exit $rc)" ;;
	esac
	return 0
}

run_codacy_analysis() {
	require_codacy_cli || return $?
	parse_analyze_args "$@" || return $?
	print_header "Running Codacy analysis"
	map_scoped_project_token
	if [[ "$ANALYZE_CUSTOM_CONFIG" == false ]]; then
		ensure_codacy_config || return $?
	fi
	local cmd=(analyze)
	if [[ "$ANALYZE_INSTALL_DEPS" == true ]]; then
		cmd+=(--install-dependencies)
	fi
	if ! analyze_args_include --parallel-tools; then
		cmd+=(--parallel-tools "${CODACY_PARALLEL_TOOLS:-4}")
	fi
	if [[ -n "${CI:-}" ]] && ! analyze_args_include --no-log; then
		cmd+=(--no-log)
	fi
	cmd+=(${ANALYZE_ARGS[@]+"${ANALYZE_ARGS[@]}"})
	local rc=0
	run_codacy "${cmd[@]}" || rc=$?
	report_analysis_result "$rc"
	if [[ "$rc" -gt 2 ]]; then
		return 1
	fi
	return "$rc"
}

# upload [REPORT] [COMMIT] — REPORT must come from `analyze --sarif|--json`.
upload_codacy_results() {
	local report="${1:-$CODACY_DEFAULT_SARIF}"
	local commit="${2:-}"
	require_codacy_cli || return $?
	print_header "Uploading results to Codacy"
	if [[ ! -f "$report" ]]; then
		print_error "Report not found: $report (create it with: $0 analyze --sarif)"
		return 2
	fi
	map_scoped_project_token
	local cmd=(upload "$report")
	if [[ -n "$commit" ]]; then
		cmd+=(--commit "$commit")
	fi
	if [[ -z "${CODACY_PROJECT_TOKEN:-}" ]]; then
		if ! has_remote_auth; then
			print_error "Upload needs a Codacy token (a repository token is preferred)"
			auth_hint
			return 2
		fi
		if resolve_repo_coords; then
			cmd+=(--repository "$CODACY_COORD_PROVIDER" "$CODACY_COORD_ORG" "$CODACY_COORD_REPO")
		fi
	fi
	local rc=0
	run_codacy "${cmd[@]}" || rc=$?
	if [[ "$rc" -ne 0 ]]; then
		print_error "Upload failed (exit $rc)"
		return 1
	fi
	print_success "Results uploaded to Codacy"
	return 0
}

print_var_state() {
	local name="$1"
	if [[ -n "${!name:-}" ]]; then
		print_success "$name: set"
	else
		print_info "$name: not set"
	fi
	return 0
}

show_config_status() {
	if [[ ! -f "$CODACY_CONFIG_FILE" ]]; then
		print_warning "No $CODACY_CONFIG_FILE in this repository. Run: $0 init"
		return 0
	fi
	local summary="present"
	if command -v jq >/dev/null 2>&1; then
		summary=$(jq -r '"source: \(.metadata.source // "unknown"), tools: \(.tools | length)"' "$CODACY_CONFIG_FILE" 2>/dev/null || echo "unreadable")
	fi
	print_success "Configuration: $CODACY_CONFIG_FILE ($summary)"
	return 0
}

# Returns 0 only when the CLI is installed and usable.
show_codacy_status() {
	print_header "Codacy Analysis CLI status"
	local ready=0
	if has_codacy_cli; then
		print_success "$CODACY_BIN $("$CODACY_BIN" --version 2>/dev/null || echo unknown) (pinned install version: $CODACY_PINNED_VERSION)"
	else
		print_warning "$CODACY_BIN not installed. Run: $0 install"
		ready=1
	fi
	if check_node_version; then
		print_info "Node.js $(node --version)"
	else
		ready=1
	fi
	show_config_status
	print_info "Authentication (names only):"
	print_var_state CODACY_PROJECT_TOKEN
	local scoped
	if scoped=$(scoped_token_name 2>/dev/null); then
		print_var_state "$scoped"
	fi
	print_var_state CODACY_API_TOKEN
	if [[ -s "$CODACY_CREDENTIALS_FILE" ]]; then
		print_success "$CODACY_BIN login credentials: present"
	else
		print_info "$CODACY_BIN login credentials: not present"
	fi
	return "$ready"
}

show_help() {
	cat <<EOF
Codacy Analysis CLI integration (${CODACY_PACKAGE}, command: ${CODACY_BIN})

Usage: $0 <command> [options]

Commands:
  install [VERSION]          Install the CLI with npm (default: ${CODACY_PINNED_VERSION})
  init [MODE] [FLAGS]        Write ${CODACY_CONFIG_FILE}. MODE:
                               remote   Codacy Cloud rules for this repo (needs token)
                               auto     detect stack locally, optional filters (e.g. auto Critical,High,Security)
                               default  Codacy default patterns (public API, no token)
                               local    only tools with local config files
                             No MODE: remote when a token is available, else auto
  update-config [--reset]    Re-sync the configuration with the stack / Codacy Cloud
  analyze [OPTIONS] [PATHS]  Run analysis (initializes config when missing)
  upload [REPORT] [COMMIT]   Upload a report from 'analyze --sarif' (default: ${CODACY_DEFAULT_SARIF})
  status                     Show CLI, Node.js, configuration and auth status (exit 1 if not ready)
  info                       Pass through to '${CODACY_BIN} info'
  standard list [--org ORG] [--tool NAME|UUID]
                             Coding standards with tool state per standard and repository
  standard set-tool --org ORG --standard ID --tool NAME|UUID --enabled true|false [--promote]
                             Draft, repair, diff; promote only an exact diff (dry run without --promote)
  help                       Show this help

Analyze options:
  --staged                   Only files in the git staging area (pre-commit use)
  --diff [BASE]              Only files changed vs BASE (default: default branch)
  --pr                       Only files in the current pull request
  --tool ID                  Restrict to a tool ID (repeatable; IDs: '${CODACY_BIN} info')
  --sarif [FILE]             Write SARIF (default: ${CODACY_DEFAULT_SARIF})
  --json [FILE]              Write JSON (default: codacy-results.json)
  --parallel-tools N         Concurrent tools (default: \${CODACY_PARALLEL_TOOLS:-4})
  --tool-timeout MS          Per-tool timeout in milliseconds
  --no-install               Do not auto-install missing analyzers
  --inspect                  Report analyzer availability only
  -- FLAGS                   Pass remaining flags to '${CODACY_BIN} analyze' unchanged

Exit codes: 0 no issues, 1 issues found or failure, 2 usage/setup error or
analyzer tool errors (results are still written).

Authentication (environment only; never pass tokens as arguments):
  CODACY_PROJECT_TOKEN                 Repository token (preferred for CI and upload)
  CODACY_<OWNER>_<REPO>_PROJECT_TOKEN  Scoped repository token, mapped per process
  CODACY_API_TOKEN                     Account token (or '${CODACY_BIN} login')
  CODACY_PROVIDER / CODACY_ORGANIZATION / CODACY_REPOSITORY
                                       Override coordinates derived from 'origin'

Examples:
  $0 install
  aidevops secret CODACY_MARCUSQUINN_AIDEVOPS_PROJECT_TOKEN -- $0 init
  $0 analyze --diff
  $0 analyze --staged
  $0 analyze --sarif && $0 upload
EOF
	return 0
}

# Coding-standard management (GH#34183): list, set-tool. The account token is
# taken from CODACY_API_TOKEN, or injected via `aidevops secret` when unset.
run_codacy_standard() {
	local module="${SCRIPT_DIR}/codacy_standard.py"
	if ! command -v python3 >/dev/null 2>&1; then
		print_error "python3 is required for 'standard'"
		return 2
	fi
	if [[ -z "${CODACY_API_TOKEN:-}" ]] && command -v aidevops >/dev/null 2>&1; then
		aidevops secret CODACY_API_TOKEN -- python3 "$module" "$@"
		return $?
	fi
	python3 "$module" "$@"
	return $?
}

# Run repository-scoped commands from the repository root so the default
# configuration path and report paths resolve consistently.
cd_repo_root() {
	local root
	root=$(git rev-parse --show-toplevel 2>/dev/null || true)
	if [[ -n "$root" ]]; then
		cd "$root" || return 2
	fi
	return 0
}

main() {
	local command="${1:-help}"
	shift || true
	local rc=0
	case "$command" in
	install) install_codacy_cli "$@" || rc=$? ;;
	init) cd_repo_root && init_codacy_config "$@" || rc=$? ;;
	update-config) cd_repo_root && update_codacy_config "$@" || rc=$? ;;
	analyze) cd_repo_root && run_codacy_analysis "$@" || rc=$? ;;
	upload) upload_codacy_results "$@" || rc=$? ;;
	status) cd_repo_root && show_codacy_status || rc=$? ;;
	info) require_codacy_cli && run_codacy info "$@" || rc=$? ;;
	standard) run_codacy_standard "$@" || rc=$? ;;
	help | --help | -h) show_help ;;
	*)
		print_error "$ERROR_UNKNOWN_COMMAND $command"
		show_help
		rc=2
		;;
	esac
	return "$rc"
}

main "$@"
