#!/usr/bin/env bash
# venv-health-check-helper.sh — Lightweight Python venv smoke tests for managed projects
#
# Discovers .venv/ directories in repos registered in repos.json and runs
# minimal health checks: pip check (broken deps), stale editable installs
# (.pth files pointing to deleted paths), and missing requirements.txt.
#
# This is Option B from GH#6764: smoke tests only — no version management,
# no update logic. The goal is to catch real breakage (broken editable installs,
# dependency conflicts) without becoming a package manager.
#
# Usage:
#   venv-health-check-helper.sh scan              # Scan all managed repos
#   venv-health-check-helper.sh scan --json       # JSON output
#   venv-health-check-helper.sh scan --quiet      # Only report broken venvs
#   venv-health-check-helper.sh scan --path DIR   # Scan a specific directory
#   venv-health-check-helper.sh help              # Show this help
#
# Exit codes:
#   0 — all venvs healthy (or no venvs found)
#   1 — one or more venvs have issues
#   2 — usage error

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit
# shellcheck source=shared-constants.sh
source "${SCRIPT_DIR}/shared-constants.sh"

# BOLD is not in shared-constants.sh — define locally
readonly BOLD='\033[1m'

readonly REPOS_JSON="${HOME}/.config/aidevops/repos.json"

# =============================================================================
# Venv Discovery
# =============================================================================

# Discover .venv directories in a given root path.
# Looks for .venv/pyvenv.cfg as the canonical marker (PEP 405).
# Outputs one path per line (the .venv directory itself).
discover_venvs_in_dir() {
	local root_dir="$1"
	[[ -d "$root_dir" ]] || return 0

	# Search up to 3 levels deep — covers monorepos with per-package venvs.
	# Avoid descending into the venv itself (skip lib/python*/site-packages).
	local venv_dir
	while IFS= read -r cfg; do
		venv_dir="$(dirname "$cfg")"
		echo "$venv_dir"
	done < <(find "$root_dir" -maxdepth 3 -name "pyvenv.cfg" -type f 2>/dev/null |
		grep -v "/lib/python" |
		grep -v "/.venv/lib/" |
		sort)
	return 0
}

# Collect all venv paths from repos.json + optional extra path.
# Outputs one venv path per line.
collect_all_venvs() {
	local extra_path="${1:-}"
	local seen=" "

	# Repos from repos.json
	if [[ -f "$REPOS_JSON" ]] && command -v jq &>/dev/null; then
		while IFS= read -r repo_path; do
			[[ -z "$repo_path" ]] && continue
			[[ -d "$repo_path" ]] || continue
			while IFS= read -r venv; do
				[[ -z "$venv" ]] && continue
				local real_venv
				real_venv="$(cd "$venv" && pwd -P 2>/dev/null)" || real_venv="$venv"
				if [[ "$seen" != *" ${real_venv} "* ]]; then
					seen="${seen}${real_venv} "
					echo "$venv"
				fi
			done < <(discover_venvs_in_dir "$repo_path")
		done < <(jq -r '.[].path // empty' "$REPOS_JSON" 2>/dev/null)
	fi

	# Extra path (--path flag)
	if [[ -n "$extra_path" && -d "$extra_path" ]]; then
		while IFS= read -r venv; do
			[[ -z "$venv" ]] && continue
			local real_venv
			real_venv="$(cd "$venv" && pwd -P 2>/dev/null)" || real_venv="$venv"
			if [[ "$seen" != *" ${real_venv} "* ]]; then
				seen="${seen}${real_venv} "
				echo "$venv"
			fi
		done < <(discover_venvs_in_dir "$extra_path")
	fi
	return 0
}

# =============================================================================
# Health Checks
# =============================================================================

# Check 1: pip check — detects broken dependency requirements and missing packages.
# Returns: "ok", "broken:<message>", or "skip:<reason>"
check_pip_deps() {
	local venv_dir="$1"
	local pip_bin="${venv_dir}/bin/pip"

	if [[ ! -x "$pip_bin" ]]; then
		echo "skip:no pip binary"
		return 0
	fi

	local output
	local rc=0
	output=$("$pip_bin" check 2>&1) || rc=$?

	if [[ $rc -eq 0 ]]; then
		echo "ok"
	else
		# Truncate to first 200 chars to avoid log bloat
		local short_output="${output:0:200}"
		echo "broken:${short_output}"
	fi
	return 0
}

# Check 2: Stale editable installs — .pth files pointing to deleted paths.
# Editable installs add a .pth file in site-packages that points to the source
# directory. If the source directory is deleted (e.g., a git worktree was pruned),
# the .pth file remains and causes ImportError on every Python startup.
# Returns: "ok", "stale:<path>:<target>", or "skip:<reason>"
check_stale_editable_installs() {
	local venv_dir="$1"

	# Find site-packages directory (Python version-agnostic)
	local site_packages=""
	local sp_candidate
	while IFS= read -r sp_candidate; do
		if [[ -d "$sp_candidate" ]]; then
			site_packages="$sp_candidate"
			break
		fi
	done < <(find "${venv_dir}/lib" -maxdepth 2 -name "site-packages" -type d 2>/dev/null | sort)

	if [[ -z "$site_packages" ]]; then
		echo "skip:no site-packages"
		return 0
	fi

	local stale_found=false
	local stale_details=""

	# Scan .pth files for paths that no longer exist
	local pth_file
	for pth_file in "${site_packages}"/*.pth; do
		[[ -f "$pth_file" ]] || continue

		# Skip known-safe framework .pth files
		local pth_name
		pth_name="$(basename "$pth_file")"
		case "$pth_name" in
		distutils-precedence.pth | easy-install.pth | setuptools.pth | pip.pth)
			continue
			;;
		esac

		# Read each line of the .pth file — each non-comment line is a path
		local line
		while IFS= read -r line; do
			# Skip blank lines and comments
			[[ -z "$line" ]] && continue
			[[ "$line" == "#"* ]] && continue
			# Skip import statements (used by some .pth files for side effects)
			[[ "$line" == "import "* ]] && continue

			# Check if the path exists
			if [[ ! -e "$line" ]]; then
				stale_found=true
				stale_details="${stale_details}${pth_file}:${line};"
			fi
		done <"$pth_file"
	done

	if [[ "$stale_found" == "true" ]]; then
		echo "stale:${stale_details%%;}"
	else
		echo "ok"
	fi
	return 0
}

# Check 3: Missing requirements file — venv exists but no requirements.txt,
# pyproject.toml, or setup.py in the parent directory.
# This flags undeclared, unreproducible dependency sets.
check_requirements_file() {
	local venv_dir="$1"
	local project_dir
	project_dir="$(dirname "$venv_dir")"

	if [[ -f "${project_dir}/requirements.txt" ]] ||
		[[ -f "${project_dir}/pyproject.toml" ]] ||
		[[ -f "${project_dir}/setup.py" ]] ||
		[[ -f "${project_dir}/setup.cfg" ]] ||
		[[ -f "${project_dir}/Pipfile" ]]; then
		echo "ok"
	else
		echo "missing:no requirements.txt/pyproject.toml/setup.py in ${project_dir}"
	fi
	return 0
}

# =============================================================================
# Reporting
# =============================================================================

# Run all checks on a single venv and return a result record.
# Outputs a tab-separated line: venv_path<TAB>status<TAB>details
check_single_venv() {
	local venv_dir="$1"

	local pip_result stale_result req_result
	pip_result=$(check_pip_deps "$venv_dir")
	stale_result=$(check_stale_editable_installs "$venv_dir")
	req_result=$(check_requirements_file "$venv_dir")

	local issues=""
	local status="healthy"

	# pip check failures are errors (broken deps = import failures)
	if [[ "$pip_result" == broken:* ]]; then
		status="broken"
		issues="${issues}pip-check:${pip_result#broken:}|"
	fi

	# Stale editable installs are errors (silent import failures)
	if [[ "$stale_result" == stale:* ]]; then
		status="broken"
		issues="${issues}stale-editable:${stale_result#stale:}|"
	fi

	# Missing requirements is a warning (not a runtime error, but unreproducible)
	if [[ "$req_result" == missing:* ]]; then
		if [[ "$status" == "healthy" ]]; then
			status="warning"
		fi
		issues="${issues}no-requirements:${req_result#missing:}|"
	fi

	printf '%s\t%s\t%s\n' "$venv_dir" "$status" "${issues%|}"
	return 0
}

# =============================================================================
# Output Formatters
# =============================================================================

format_console_output() {
	local venv_dir="$1"
	local status="$2"
	local issues="$3"
	local quiet="$4"

	case "$status" in
	healthy)
		[[ "$quiet" == "true" ]] && return 0
		echo -e "${GREEN}✓${NC}  ${venv_dir} — healthy"
		;;
	warning)
		echo -e "${YELLOW}⚠${NC}  ${venv_dir} — warning"
		if [[ -n "$issues" ]]; then
			local issue
			while IFS= read -r issue; do
				[[ -z "$issue" ]] && continue
				local issue_type="${issue%%:*}"
				local issue_detail="${issue#*:}"
				case "$issue_type" in
				no-requirements)
					echo "     No requirements file: ${issue_detail}"
					;;
				*)
					echo "     ${issue_type}: ${issue_detail}"
					;;
				esac
			done < <(printf '%s\n' "$issues" | tr '|' '\n')
		fi
		;;
	broken)
		echo -e "${RED}✗${NC}  ${venv_dir} — broken"
		if [[ -n "$issues" ]]; then
			local issue
			while IFS= read -r issue; do
				[[ -z "$issue" ]] && continue
				local issue_type="${issue%%:*}"
				local issue_detail="${issue#*:}"
				case "$issue_type" in
				pip-check)
					echo "     Dependency conflict: ${issue_detail}"
					echo "     Fix: ${venv_dir}/bin/pip check"
					;;
				stale-editable)
					echo "     Stale editable install (.pth -> deleted path):"
					local entry
					while IFS= read -r entry; do
						[[ -z "$entry" ]] && continue
						local pth_file="${entry%%:*}"
						local missing_path="${entry#*:}"
						echo "       ${pth_file} -> ${missing_path} (missing)"
					done < <(printf '%s\n' "$issue_detail" | tr ';' '\n')
					echo "     Fix: ${venv_dir}/bin/pip install -e <package> or remove the .pth file"
					;;
				*)
					echo "     ${issue_type}: ${issue_detail}"
					;;
				esac
			done < <(printf '%s\n' "$issues" | tr '|' '\n')
		fi
		;;
	esac
	return 0
}

format_json_record() {
	local venv_dir="$1"
	local status="$2"
	local issues="$3"

	# Build issues array for JSON
	local issues_json="[]"
	if [[ -n "$issues" ]] && command -v jq &>/dev/null; then
		local issues_arr="["
		local first=true
		local issue
		while IFS= read -r issue; do
			[[ -z "$issue" ]] && continue
			local issue_type="${issue%%:*}"
			local issue_detail="${issue#*:}"
			# Escape for JSON
			local escaped_detail
			escaped_detail=$(printf '%s' "$issue_detail" | jq -Rs '.')
			if [[ "$first" == "true" ]]; then
				first=false
			else
				issues_arr="${issues_arr},"
			fi
			issues_arr="${issues_arr}{\"type\":\"${issue_type}\",\"detail\":${escaped_detail}}"
		done < <(printf '%s\n' "$issues" | tr '|' '\n')
		issues_arr="${issues_arr}]"
		issues_json="$issues_arr"
	fi

	# Escape venv_dir for JSON
	local escaped_dir
	escaped_dir=$(printf '%s' "$venv_dir" | jq -Rs '.')

	printf '{"venv":"%s","status":"%s","issues":%s}' \
		"${venv_dir//\"/\\\"}" "$status" "$issues_json"
	return 0
}

# =============================================================================
# Main Scan Command
# =============================================================================

cmd_scan() {
	local json_output=false
	local quiet=false
	local extra_path=""

	while [[ $# -gt 0 ]]; do
		case "$1" in
		--json | -j)
			json_output=true
			shift
			;;
		--quiet | -q)
			quiet=true
			shift
			;;
		--path | -p)
			if [[ -z "${2:-}" ]]; then
				echo "Error: --path requires a directory argument" >&2
				exit 2
			fi
			extra_path="$2"
			shift 2
			;;
		*)
			echo "Unknown option: $1" >&2
			exit 2
			;;
		esac
	done

	local venv_count=0
	local healthy_count=0
	local warning_count=0
	local broken_count=0
	local json_records=""
	local first_json=true
	local overall_exit=0

	if [[ "$json_output" != "true" && "$quiet" != "true" ]]; then
		echo -e "${BOLD}${BLUE}Python Venv Health Check${NC}"
		echo "========================"
		echo ""
	fi

	while IFS= read -r venv_dir; do
		[[ -z "$venv_dir" ]] && continue
		venv_count=$((venv_count + 1))

		local result_line
		result_line=$(check_single_venv "$venv_dir")

		local venv_path status issues
		venv_path=$(printf '%s' "$result_line" | cut -f1)
		status=$(printf '%s' "$result_line" | cut -f2)
		issues=$(printf '%s' "$result_line" | cut -f3)

		case "$status" in
		healthy) healthy_count=$((healthy_count + 1)) ;;
		warning) warning_count=$((warning_count + 1)) ;;
		broken)
			broken_count=$((broken_count + 1))
			overall_exit=1
			;;
		esac

		if [[ "$json_output" == "true" ]]; then
			local record
			record=$(format_json_record "$venv_path" "$status" "$issues")
			if [[ "$first_json" == "true" ]]; then
				first_json=false
			else
				json_records="${json_records},"
			fi
			json_records="${json_records}${record}"
		else
			format_console_output "$venv_path" "$status" "$issues" "$quiet"
		fi
	done < <(collect_all_venvs "$extra_path")

	if [[ "$json_output" == "true" ]]; then
		printf '{"summary":{"total":%d,"healthy":%d,"warnings":%d,"broken":%d},"venvs":[%s]}\n' \
			"$venv_count" "$healthy_count" "$warning_count" "$broken_count" \
			"$json_records"
		return $overall_exit
	fi

	if [[ $venv_count -eq 0 ]]; then
		if [[ "$quiet" != "true" ]]; then
			echo "No Python venvs found in managed repos."
			echo ""
			echo "Venvs are discovered by looking for .venv/pyvenv.cfg in repos"
			echo "registered in ~/.config/aidevops/repos.json."
		fi
		return 0
	fi

	if [[ "$quiet" != "true" ]]; then
		echo ""
		echo -e "${BOLD}Summary${NC}"
		echo "  Total venvs:  $venv_count"
		echo "  Healthy:      $healthy_count"
		if [[ $warning_count -gt 0 ]]; then
			echo -e "  Warnings:     ${YELLOW}${warning_count}${NC}"
		fi
		if [[ $broken_count -gt 0 ]]; then
			echo -e "  Broken:       ${RED}${broken_count}${NC}"
			echo ""
			echo "Run the fix commands shown above to resolve broken venvs."
		else
			echo ""
			echo -e "${GREEN}All venvs are healthy.${NC}"
		fi
	fi

	return $overall_exit
}

# =============================================================================
# Help
# =============================================================================

cmd_help() {
	cat <<'EOF'
venv-health-check-helper.sh — Lightweight Python venv smoke tests

Usage:
  venv-health-check-helper.sh scan              Scan all managed repos
  venv-health-check-helper.sh scan --json       JSON output
  venv-health-check-helper.sh scan --quiet      Only report broken/warning venvs
  venv-health-check-helper.sh scan --path DIR   Scan a specific directory
  venv-health-check-helper.sh help              Show this help

Checks performed:
  pip check          Detects broken dependency requirements (missing packages,
                     version conflicts). A single command that catches the most
                     common real-world breakage.
  stale editable     .pth files in site-packages pointing to deleted paths
                     (e.g., a git worktree that was pruned). Causes silent
                     ImportError on every Python startup.
  requirements file  Flags venvs with no requirements.txt, pyproject.toml,
                     setup.py, setup.cfg, or Pipfile — undeclared dependencies
                     that cannot be reproduced.

Venv discovery:
  Looks for .venv/pyvenv.cfg (PEP 405 marker) up to 3 levels deep in each
  repo registered in ~/.config/aidevops/repos.json.

Exit codes:
  0  All venvs healthy (or no venvs found)
  1  One or more venvs have issues
  2  Usage error
EOF
	return 0
}

# =============================================================================
# Entry Point
# =============================================================================

main() {
	local cmd="${1:-scan}"
	shift || true

	case "$cmd" in
	scan) cmd_scan "$@" ;;
	help | --help | -h) cmd_help ;;
	*)
		echo "Unknown command: $cmd" >&2
		echo "Run: venv-health-check-helper.sh help" >&2
		exit 2
		;;
	esac
}

main "$@"
