#!/usr/bin/env bash
# =============================================================================
# Testing Setup Helper - Per-repo testing infrastructure detection and config
# =============================================================================
# Discovers existing test infrastructure, compares against bundle-recommended
# quality gates, and generates configuration to fill gaps.
#
# Usage:
#   testing-setup-helper.sh discover [project-path]    Scan for existing test infra
#   testing-setup-helper.sh gaps [project-path]        Show gaps vs bundle gates
#   testing-setup-helper.sh status [project-path]      Show current test health
#   testing-setup-helper.sh verify [project-path]      Run configured tests
#   testing-setup-helper.sh help                       Show this help
#
# Integration with /testing-setup command:
#   The command doc (commands/testing-setup.md) drives the interactive flow.
#   This helper provides the deterministic detection and verification logic.
#
# Depends on:
#   - bundle-helper.sh (bundle detection and resolution)
#   - shared-constants.sh (print_*, color codes)
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit

# Source shared-constants if available
if [[ -f "${SCRIPT_DIR}/shared-constants.sh" ]]; then
	# shellcheck source=shared-constants.sh
	source "${SCRIPT_DIR}/shared-constants.sh"
else
	print_error() {
		echo "ERROR: $*" >&2
		return 0
	}
	print_success() {
		echo "OK: $*"
		return 0
	}
	print_warning() {
		echo "WARN: $*" >&2
		return 0
	}
	print_info() {
		echo "INFO: $*" >&2
		return 0
	}
fi

set -euo pipefail

# =============================================================================
# Constants
# =============================================================================

readonly TESTING_CONFIG_FILE=".aidevops-testing.json"
readonly CONFIG_UNKNOWN="unknown"

# =============================================================================
# Utility Functions
# =============================================================================

# Find the first config file matching one or more glob patterns in a directory.
# Returns the basename, or CONFIG_UNKNOWN if no match found.
# Usage: get_first_config_file /path/to/project "pattern1" "pattern2" ...
get_first_config_file() {
	local project_dir="$1"
	shift
	local result=""
	local pattern
	for pattern in "$@"; do
		result=$(compgen -G "${project_dir}/${pattern}" 2>/dev/null | head -1) || true
		[[ -n "$result" ]] && break
	done
	if [[ -n "$result" ]]; then
		basename "$result" 2>/dev/null || echo "$CONFIG_UNKNOWN"
	else
		echo "$CONFIG_UNKNOWN"
	fi
	return 0
}

resolve_project_path() {
	local path="${1:-.}"
	path="$(cd "$path" 2>/dev/null && pwd)" || {
		print_error "Cannot resolve project path: $1"
		return 1
	}
	echo "$path"
	return 0
}

# Check if a file matching a glob pattern exists in the project
# Uses compgen for safe glob matching without ls word-splitting issues
has_file() {
	local project_dir="$1"
	local pattern="$2"
	local matches
	matches=$(compgen -G "${project_dir}/${pattern}" 2>/dev/null) || true
	[[ -n "$matches" ]]
}

# Check if a directory exists in the project
has_dir() {
	local project_dir="$1"
	local dirname="$2"
	[[ -d "${project_dir}/${dirname}" ]]
}

# Check if package.json has a specific devDependency
has_npm_dep() {
	local project_dir="$1"
	local dep_name="$2"
	local pkg_file="${project_dir}/package.json"
	if [[ -f "$pkg_file" ]]; then
		jq -e --arg d "$dep_name" \
			'(.devDependencies[$d] // .dependencies[$d]) != null' \
			"$pkg_file" >/dev/null 2>&1
		return $?
	fi
	return 1
}

# Check if package.json has a specific script
has_npm_script() {
	local project_dir="$1"
	local script_name="$2"
	local pkg_file="${project_dir}/package.json"
	if [[ -f "$pkg_file" ]]; then
		jq -e --arg s "$script_name" '.scripts[$s] != null' \
			"$pkg_file" >/dev/null 2>&1
		return $?
	fi
	return 1
}

# =============================================================================
# Discovery Functions
# =============================================================================

# Discover test runners present in the project
# Output: JSON array of {name, source, configured} objects
discover_runners() {
	local project_dir="$1"
	local runners="[]"

	# Jest
	if has_npm_dep "$project_dir" "jest"; then
		local configured="false"
		if has_file "$project_dir" "jest.config.*" ||
			jq -e '.jest' "${project_dir}/package.json" >/dev/null 2>&1; then
			configured="true"
		fi
		runners=$(echo "$runners" | jq --arg c "$configured" \
			'. + [{"name":"jest","source":"package.json devDependencies","configured":($c == "true")}]')
	fi

	# Vitest
	if has_npm_dep "$project_dir" "vitest"; then
		local configured="false"
		if has_file "$project_dir" "vitest.config.*" || has_file "$project_dir" "vite.config.*"; then
			configured="true"
		fi
		runners=$(echo "$runners" | jq --arg c "$configured" \
			'. + [{"name":"vitest","source":"package.json devDependencies","configured":($c == "true")}]')
	fi

	# Pytest — detect via repository declarations, not runtime environment
	# Checks: pytest.ini, pyproject.toml [tool.pytest], setup.cfg [tool:pytest],
	# setup.py, requirements.txt, requirements-dev.txt
	local _pytest_source=""
	if [[ -f "${project_dir}/pytest.ini" ]]; then
		_pytest_source="pytest.ini"
	elif [[ -f "${project_dir}/pyproject.toml" ]] &&
		grep -qE '\[tool\.pytest' "${project_dir}/pyproject.toml" 2>/dev/null; then
		_pytest_source="pyproject.toml"
	elif [[ -f "${project_dir}/pyproject.toml" ]] &&
		grep -qi 'pytest' "${project_dir}/pyproject.toml" 2>/dev/null; then
		_pytest_source="pyproject.toml"
	elif [[ -f "${project_dir}/setup.cfg" ]] &&
		grep -qE '\[tool:pytest\]|tests_require.*pytest' "${project_dir}/setup.cfg" 2>/dev/null; then
		_pytest_source="setup.cfg"
	elif [[ -f "${project_dir}/setup.py" ]] &&
		grep -qi 'pytest' "${project_dir}/setup.py" 2>/dev/null; then
		_pytest_source="setup.py"
	elif [[ -f "${project_dir}/requirements.txt" ]] &&
		grep -qi 'pytest' "${project_dir}/requirements.txt" 2>/dev/null; then
		_pytest_source="requirements.txt"
	elif [[ -f "${project_dir}/requirements-dev.txt" ]] &&
		grep -qi 'pytest' "${project_dir}/requirements-dev.txt" 2>/dev/null; then
		_pytest_source="requirements-dev.txt"
	fi
	if [[ -n "$_pytest_source" ]]; then
		local configured="false"
		if [[ -f "${project_dir}/pytest.ini" ]] ||
			{ [[ -f "${project_dir}/pyproject.toml" ]] &&
				grep -q '\[tool\.pytest' "${project_dir}/pyproject.toml" 2>/dev/null; }; then
			configured="true"
		fi
		runners=$(echo "$runners" | jq --arg c "$configured" --arg s "$_pytest_source" \
			'. + [{"name":"pytest","source":$s,"configured":($c == "true")}]')
	fi

	# Cargo test (Rust)
	if [[ -f "${project_dir}/Cargo.toml" ]]; then
		runners=$(echo "$runners" | jq \
			'. + [{"name":"cargo-test","source":"Cargo.toml","configured":true}]')
	fi

	# Go test
	if [[ -f "${project_dir}/go.mod" ]]; then
		runners=$(echo "$runners" | jq \
			'. + [{"name":"go-test","source":"go.mod","configured":true}]')
	fi

	# Bats (Bash testing)
	if has_file "$project_dir" "*.bats" || has_file "$project_dir" "test/*.bats"; then
		runners=$(echo "$runners" | jq \
			'. + [{"name":"bats","source":".bats files","configured":true}]')
	fi

	# Bash test scripts (aidevops pattern)
	local bash_test_count=0
	if has_dir "$project_dir" "tests"; then
		bash_test_count=$(find "${project_dir}/tests" -maxdepth 1 -name "test-*.sh" 2>/dev/null | wc -l | tr -d ' ')
	fi
	if [[ "$bash_test_count" -gt 0 ]]; then
		runners=$(echo "$runners" | jq --arg c "$bash_test_count" \
			'. + [{"name":"bash-tests","source":"tests/test-*.sh","configured":true,"count":($c | tonumber)}]')
	fi

	# Agent test helper (aidevops-specific)
	if [[ -f "${project_dir}/.agents/scripts/agent-test-helper.sh" ]]; then
		local suite_count=0
		if has_dir "$project_dir" ".agents/tests"; then
			suite_count=$(find "${project_dir}/.agents/tests" -name "*.json" 2>/dev/null | wc -l | tr -d ' ')
		fi
		runners=$(echo "$runners" | jq --arg c "$suite_count" \
			'. + [{"name":"agent-tests","source":"agent-test-helper.sh","configured":true,"suites":($c | tonumber)}]')
	fi

	# Playwright
	if has_npm_dep "$project_dir" "@playwright/test" || has_npm_dep "$project_dir" "playwright"; then
		local configured="false"
		if has_file "$project_dir" "playwright.config.*"; then
			configured="true"
		fi
		runners=$(echo "$runners" | jq --arg c "$configured" \
			'. + [{"name":"playwright","source":"package.json","configured":($c == "true")}]')
	fi

	# Cypress
	if has_npm_dep "$project_dir" "cypress"; then
		local configured="false"
		if has_file "$project_dir" "cypress.config.*"; then
			configured="true"
		fi
		runners=$(echo "$runners" | jq --arg c "$configured" \
			'. + [{"name":"cypress","source":"package.json","configured":($c == "true")}]')
	fi

	echo "$runners"
	return 0
}

# Discover linter configurations present in the project
# Output: JSON array of {name, config_file, status} objects
discover_linters() {
	local project_dir="$1"
	local linters="[]"

	# ESLint
	if has_file "$project_dir" ".eslintrc*" || has_file "$project_dir" "eslint.config.*" ||
		has_file "$project_dir" ".eslintrc.json" || has_file "$project_dir" ".eslintrc.js"; then
		local config_file
		config_file=$(get_first_config_file "$project_dir" ".eslintrc*" "eslint.config.*")
		linters=$(echo "$linters" | jq --arg f "$config_file" \
			'. + [{"name":"eslint","config_file":$f,"status":"configured"}]')
	elif has_npm_dep "$project_dir" "eslint"; then
		linters=$(echo "$linters" | jq \
			'. + [{"name":"eslint","config_file":"none","status":"installed-not-configured"}]')
	fi

	# Prettier
	if has_file "$project_dir" ".prettierrc*" || has_file "$project_dir" "prettier.config.*"; then
		local config_file
		config_file=$(get_first_config_file "$project_dir" ".prettierrc*" "prettier.config.*")
		linters=$(echo "$linters" | jq --arg f "$config_file" \
			'. + [{"name":"prettier","config_file":$f,"status":"configured"}]')
	elif has_npm_dep "$project_dir" "prettier"; then
		linters=$(echo "$linters" | jq \
			'. + [{"name":"prettier","config_file":"none","status":"installed-not-configured"}]')
	fi

	# TypeScript
	if [[ -f "${project_dir}/tsconfig.json" ]]; then
		linters=$(echo "$linters" | jq \
			'. + [{"name":"typescript-check","config_file":"tsconfig.json","status":"configured"}]')
	fi

	# ShellCheck
	if [[ -f "${project_dir}/.shellcheckrc" ]]; then
		linters=$(echo "$linters" | jq \
			'. + [{"name":"shellcheck","config_file":".shellcheckrc","status":"configured"}]')
	elif command -v shellcheck >/dev/null 2>&1; then
		linters=$(echo "$linters" | jq \
			'. + [{"name":"shellcheck","config_file":"none","status":"available"}]')
	fi

	# Secretlint
	if [[ -f "${project_dir}/.secretlintrc.json" ]] || [[ -f "${project_dir}/.secretlintrc" ]]; then
		linters=$(echo "$linters" | jq \
			'. + [{"name":"secretlint","config_file":".secretlintrc.json","status":"configured"}]')
	fi

	# Markdownlint
	if [[ -f "${project_dir}/.markdownlint.json" ]] || [[ -f "${project_dir}/.markdownlint.jsonc" ]] ||
		[[ -f "${project_dir}/.markdownlint-cli2.jsonc" ]]; then
		local config_file
		config_file=$(get_first_config_file "$project_dir" ".markdownlint*")
		linters=$(echo "$linters" | jq --arg f "$config_file" \
			'. + [{"name":"markdownlint","config_file":$f,"status":"configured"}]')
	fi

	# Hadolint (Dockerfile linting)
	if [[ -f "${project_dir}/.hadolint.yaml" ]]; then
		linters=$(echo "$linters" | jq \
			'. + [{"name":"hadolint","config_file":".hadolint.yaml","status":"configured"}]')
	fi

	echo "$linters"
	return 0
}

# Discover test directories and file counts
discover_test_dirs() {
	local project_dir="$1"
	local dirs="[]"

	local test_dir_names=("tests" "test" "__tests__" "spec" "e2e" "integration")
	for dirname in "${test_dir_names[@]}"; do
		if has_dir "$project_dir" "$dirname"; then
			local file_count
			file_count=$(find "${project_dir}/${dirname}" -type f \( -name "*.test.*" -o -name "*.spec.*" -o -name "test_*" -o -name "test-*" -o -name "*_test.*" \) 2>/dev/null | wc -l | tr -d ' ')
			dirs=$(echo "$dirs" | jq --arg d "$dirname" --arg c "$file_count" \
				'. + [{"directory":$d,"test_files":($c | tonumber)}]')
		fi
	done

	echo "$dirs"
	return 0
}

# Discover CI pipeline test integration
discover_ci() {
	local project_dir="$1"
	local ci="[]"

	# GitHub Actions
	if has_dir "$project_dir" ".github/workflows"; then
		local has_test_step="false"
		if grep -rl 'npm test\|yarn test\|pnpm test\|pytest\|cargo test\|go test\|bats' \
			"${project_dir}/.github/workflows/" >/dev/null 2>&1; then
			has_test_step="true"
		fi
		ci=$(echo "$ci" | jq --arg t "$has_test_step" \
			'. + [{"platform":"github-actions","configured":true,"has_test_step":($t == "true")}]')
	fi

	# GitLab CI
	if [[ -f "${project_dir}/.gitlab-ci.yml" ]]; then
		local has_test_step="false"
		if grep -qE '(^test:|^\s+script:.*\b(pytest|npm test|yarn test|pnpm test|cargo test|go test|bats)\b)' \
			"${project_dir}/.gitlab-ci.yml" 2>/dev/null; then
			has_test_step="true"
		fi
		ci=$(echo "$ci" | jq --arg t "$has_test_step" \
			'. + [{"platform":"gitlab-ci","configured":true,"has_test_step":($t == "true")}]')
	fi

	echo "$ci"
	return 0
}

# Discover coverage configuration
discover_coverage() {
	local project_dir="$1"
	local coverage='{"enabled":false}'

	# NYC / Istanbul
	if [[ -f "${project_dir}/.nycrc" ]] || [[ -f "${project_dir}/.nycrc.json" ]]; then
		coverage='{"enabled":true,"tool":"nyc","config_file":".nycrc"}'
	fi

	# c8 (via vitest or standalone)
	if has_npm_dep "$project_dir" "c8"; then
		coverage='{"enabled":true,"tool":"c8","config_file":"package.json"}'
	fi

	# Jest coverage (check if --coverage is in test script)
	if has_npm_script "$project_dir" "test:coverage" ||
		has_npm_script "$project_dir" "coverage"; then
		coverage='{"enabled":true,"tool":"jest-coverage","config_file":"package.json"}'
	fi

	# Coverage directory exists
	if has_dir "$project_dir" "coverage" &&
		[[ "$(echo "$coverage" | jq -r '.enabled')" == "false" ]]; then
		coverage='{"enabled":true,"tool":"unknown","config_file":"none"}'
	fi

	echo "$coverage"
	return 0
}

# =============================================================================
# Main Discovery Command
# =============================================================================

cmd_discover() {
	local project_dir
	project_dir=$(resolve_project_path "${1:-.}") || return 1

	local runners linters test_dirs ci coverage

	runners=$(discover_runners "$project_dir")
	linters=$(discover_linters "$project_dir")
	test_dirs=$(discover_test_dirs "$project_dir")
	ci=$(discover_ci "$project_dir")
	coverage=$(discover_coverage "$project_dir")

	# Compose full discovery result
	jq -n \
		--arg path "$project_dir" \
		--arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
		--argjson runners "$runners" \
		--argjson linters "$linters" \
		--argjson test_dirs "$test_dirs" \
		--argjson ci "$ci" \
		--argjson coverage "$coverage" \
		'{
			project_path: $path,
			discovered_at: $ts,
			test_runners: $runners,
			linters: $linters,
			test_directories: $test_dirs,
			ci_pipelines: $ci,
			coverage: $coverage
		}'

	return 0
}

# =============================================================================
# Gap Analysis Command
# =============================================================================

cmd_gaps() {
	local project_dir
	project_dir=$(resolve_project_path "${1:-.}") || return 1

	# Resolve bundle
	local bundle_json
	bundle_json=$("${SCRIPT_DIR}/bundle-helper.sh" resolve "$project_dir" 2>/dev/null) || {
		print_warning "Could not resolve bundle, using cli-tool fallback"
		bundle_json=$("${SCRIPT_DIR}/bundle-helper.sh" load cli-tool 2>/dev/null) || {
			print_error "Cannot load any bundle"
			return 1
		}
	}

	local bundle_name
	bundle_name=$(echo "$bundle_json" | jq -r '.name // "unknown"')

	# Get recommended quality gates
	local quality_gates skip_gates
	quality_gates=$(echo "$bundle_json" | jq -r '.quality_gates // []')
	skip_gates=$(echo "$bundle_json" | jq -r '.skip_gates // []')

	# Run discovery
	local discovery
	discovery=$(cmd_discover "$project_dir")

	# Build gap analysis
	local found_names
	found_names=$(echo "$discovery" | jq -r '[.test_runners[].name, .linters[].name] | .[]')

	local ready=()
	local needs_attention=()
	local missing=()
	local skipped=()

	while IFS= read -r gate; do
		[[ -z "$gate" ]] && continue

		# Check if gate is in skip list
		if echo "$skip_gates" | jq -e --arg g "$gate" 'index($g) != null' >/dev/null 2>&1; then
			skipped+=("$gate")
			continue
		fi

		# Check if gate is found in discovery
		if echo "$found_names" | grep -qx "$gate" 2>/dev/null; then
			# Check if it's properly configured
			local is_configured
			is_configured=$(echo "$discovery" | jq -r --arg g "$gate" \
				'[.test_runners[], .linters[]] | map(select(.name == $g)) | .[0].configured // .[0].status' 2>/dev/null || echo "unknown")
			if [[ "$is_configured" == "true" ]] || [[ "$is_configured" == "configured" ]]; then
				ready+=("$gate")
			else
				needs_attention+=("$gate")
			fi
		else
			missing+=("$gate")
		fi
	done < <(echo "$quality_gates" | jq -r '.[]')

	# Helper: convert bash array to JSON array, handling empty arrays correctly
	_arr_to_json() {
		if [[ $# -eq 0 ]]; then
			echo '[]'
		else
			printf '%s\n' "$@" | jq -R 'select(length > 0)' | jq -s .
		fi
		return 0
	}

	# Output as JSON
	jq -n \
		--arg bundle "$bundle_name" \
		--arg path "$project_dir" \
		--argjson ready "$(_arr_to_json "${ready[@]+"${ready[@]}"}")" \
		--argjson needs_attention "$(_arr_to_json "${needs_attention[@]+"${needs_attention[@]}"}")" \
		--argjson missing "$(_arr_to_json "${missing[@]+"${missing[@]}"}")" \
		--argjson skipped "$(_arr_to_json "${skipped[@]+"${skipped[@]}"}")" \
		'{
			bundle: $bundle,
			project_path: $path,
			ready: $ready,
			needs_attention: $needs_attention,
			missing: $missing,
			skipped_by_bundle: $skipped
		}'

	return 0
}

# =============================================================================
# Status Command
# =============================================================================

cmd_status() {
	local project_dir
	project_dir=$(resolve_project_path "${1:-.}") || return 1

	local config_file="${project_dir}/${TESTING_CONFIG_FILE}"

	echo ""
	echo "=== Testing Infrastructure Status ==="
	echo ""

	# Check for .aidevops-testing.json
	if [[ -f "$config_file" ]]; then
		local bundle configured_at
		bundle=$(jq -r '.bundle // "unknown"' "$config_file")
		configured_at=$(jq -r '.configured_at // "unknown"' "$config_file")
		echo "  Config:     ${config_file}"
		echo "  Bundle:     ${bundle}"
		echo "  Configured: ${configured_at}"
	else
		echo "  Config:     not found (run /testing-setup to configure)"
	fi

	echo ""

	# Run discovery and show summary
	local discovery
	discovery=$(cmd_discover "$project_dir")

	local runner_count linter_count test_dir_count
	runner_count=$(echo "$discovery" | jq '.test_runners | length')
	linter_count=$(echo "$discovery" | jq '.linters | length')
	test_dir_count=$(echo "$discovery" | jq '.test_directories | length')
	local coverage_enabled
	coverage_enabled=$(echo "$discovery" | jq -r '.coverage.enabled')

	echo "  Test runners:  ${runner_count}"
	echo "$discovery" | jq -r '.test_runners[] | "    - \(.name) (\(.source))"'

	echo "  Linters:       ${linter_count}"
	echo "$discovery" | jq -r '.linters[] | "    - \(.name) [\(.status)]"'

	echo "  Test dirs:     ${test_dir_count}"
	echo "$discovery" | jq -r '.test_directories[] | "    - \(.directory)/ (\(.test_files) test files)"'

	echo "  Coverage:      ${coverage_enabled}"
	if [[ "$coverage_enabled" == "true" ]]; then
		echo "$discovery" | jq -r '"    - \(.coverage.tool) (\(.coverage.config_file))"'
	fi

	echo "  CI pipelines:"
	local ci_count
	ci_count=$(echo "$discovery" | jq '.ci_pipelines | length')
	if [[ "$ci_count" -gt 0 ]]; then
		echo "$discovery" | jq -r '.ci_pipelines[] | "    - \(.platform) (test step: \(.has_test_step))"'
	else
		echo "    - none detected"
	fi

	echo ""
	return 0
}

# =============================================================================
# Verify Command
# =============================================================================

cmd_verify() {
	local project_dir
	project_dir=$(resolve_project_path "${1:-.}") || return 1

	echo ""
	echo "=== Test Verification ==="
	echo ""

	local pass_count=0
	local fail_count=0
	local skip_count=0

	# Discover what's available
	local discovery
	discovery=$(cmd_discover "$project_dir")

	# Try each discovered runner
	while IFS= read -r runner_name; do
		[[ -z "$runner_name" ]] && continue

		case "$runner_name" in
		bats)
			if command -v bats >/dev/null 2>&1; then
				local bats_errors=0
				while IFS= read -r bats_file; do
					[[ -f "$bats_file" ]] || continue
					if ! bats --tap "$bats_file" >/dev/null 2>&1; then
						bats_errors=$((bats_errors + 1))
					fi
				done < <(find "$project_dir" -name "*.bats" -not -path "*/.git/*" 2>/dev/null)
				if [[ "$bats_errors" -eq 0 ]]; then
					echo "  [pass] bats"
					pass_count=$((pass_count + 1))
				else
					echo "  [fail] bats (${bats_errors} test files failed)"
					fail_count=$((fail_count + 1))
				fi
			else
				echo "  [skip] bats (not installed)"
				skip_count=$((skip_count + 1))
			fi
			;;
		jest)
			if (cd "$project_dir" && npx jest --passWithNoTests --silent 2>/dev/null); then
				echo "  [pass] jest"
				pass_count=$((pass_count + 1))
			else
				echo "  [fail] jest"
				fail_count=$((fail_count + 1))
			fi
			;;
		vitest)
			if (cd "$project_dir" && npx vitest run --silent 2>/dev/null); then
				echo "  [pass] vitest"
				pass_count=$((pass_count + 1))
			else
				echo "  [fail] vitest"
				fail_count=$((fail_count + 1))
			fi
			;;
		pytest)
			if (cd "$project_dir" && python -m pytest --quiet 2>/dev/null); then
				echo "  [pass] pytest"
				pass_count=$((pass_count + 1))
			else
				echo "  [fail] pytest"
				fail_count=$((fail_count + 1))
			fi
			;;
		cargo-test)
			if (cd "$project_dir" && cargo test --quiet 2>/dev/null); then
				echo "  [pass] cargo test"
				pass_count=$((pass_count + 1))
			else
				echo "  [fail] cargo test"
				fail_count=$((fail_count + 1))
			fi
			;;
		go-test)
			if (cd "$project_dir" && go test ./... 2>/dev/null); then
				echo "  [pass] go test"
				pass_count=$((pass_count + 1))
			else
				echo "  [fail] go test"
				fail_count=$((fail_count + 1))
			fi
			;;
		bash-tests)
			local test_pass=0
			local test_fail=0
			for test_file in "${project_dir}"/tests/test-*.sh; do
				[[ -f "$test_file" ]] || continue
				if bash -n "$test_file" 2>/dev/null; then
					test_pass=$((test_pass + 1))
				else
					test_fail=$((test_fail + 1))
				fi
			done
			if [[ "$test_fail" -eq 0 ]]; then
				echo "  [pass] bash-tests (${test_pass} scripts pass syntax check)"
				pass_count=$((pass_count + 1))
			else
				echo "  [fail] bash-tests (${test_fail} syntax errors)"
				fail_count=$((fail_count + 1))
			fi
			;;
		agent-tests)
			echo "  [skip] agent-tests (requires interactive CLI)"
			skip_count=$((skip_count + 1))
			;;
		playwright | cypress)
			echo "  [skip] ${runner_name} (E2E tests require browser environment)"
			skip_count=$((skip_count + 1))
			;;
		*)
			echo "  [skip] ${runner_name} (no verify handler)"
			skip_count=$((skip_count + 1))
			;;
		esac
	done < <(echo "$discovery" | jq -r '.test_runners[].name')

	# Try linters
	while IFS= read -r linter_name; do
		[[ -z "$linter_name" ]] && continue

		case "$linter_name" in
		eslint)
			if (cd "$project_dir" && npx eslint . --quiet 2>/dev/null); then
				echo "  [pass] eslint"
				pass_count=$((pass_count + 1))
			else
				echo "  [fail] eslint"
				fail_count=$((fail_count + 1))
			fi
			;;
		prettier)
			if (cd "$project_dir" && npx prettier --check . 2>/dev/null); then
				echo "  [pass] prettier"
				pass_count=$((pass_count + 1))
			else
				echo "  [fail] prettier"
				fail_count=$((fail_count + 1))
			fi
			;;
		typescript-check)
			if (cd "$project_dir" && npx tsc --noEmit 2>/dev/null); then
				echo "  [pass] typescript-check"
				pass_count=$((pass_count + 1))
			else
				echo "  [fail] typescript-check"
				fail_count=$((fail_count + 1))
			fi
			;;
		shellcheck)
			if command -v shellcheck >/dev/null 2>&1; then
				local sc_errors=0
				while IFS= read -r sh_file; do
					[[ -f "$sh_file" ]] || continue
					if ! shellcheck "$sh_file" >/dev/null 2>&1; then
						sc_errors=$((sc_errors + 1))
					fi
				done < <(find "$project_dir" -name "*.sh" -not -path "*/node_modules/*" -not -path "*/.git/*" 2>/dev/null)
				if [[ "$sc_errors" -eq 0 ]]; then
					echo "  [pass] shellcheck"
					pass_count=$((pass_count + 1))
				else
					echo "  [fail] shellcheck (${sc_errors} files with issues)"
					fail_count=$((fail_count + 1))
				fi
			else
				echo "  [skip] shellcheck (not installed)"
				skip_count=$((skip_count + 1))
			fi
			;;
		secretlint)
			if command -v secretlint >/dev/null 2>&1; then
				if (cd "$project_dir" && secretlint "**/*" 2>/dev/null); then
					echo "  [pass] secretlint"
					pass_count=$((pass_count + 1))
				else
					echo "  [fail] secretlint"
					fail_count=$((fail_count + 1))
				fi
			elif command -v npx >/dev/null 2>&1 && (cd "$project_dir" && npx --no-install secretlint --version >/dev/null 2>&1); then
				if (cd "$project_dir" && npx --no-install secretlint "**/*" 2>/dev/null); then
					echo "  [pass] secretlint"
					pass_count=$((pass_count + 1))
				else
					echo "  [fail] secretlint"
					fail_count=$((fail_count + 1))
				fi
			else
				echo "  [skip] secretlint (not installed)"
				skip_count=$((skip_count + 1))
			fi
			;;
		markdownlint)
			if command -v markdownlint-cli2 >/dev/null 2>&1; then
				if (cd "$project_dir" && markdownlint-cli2 "**/*.md" 2>/dev/null); then
					echo "  [pass] markdownlint"
					pass_count=$((pass_count + 1))
				else
					echo "  [fail] markdownlint"
					fail_count=$((fail_count + 1))
				fi
			elif command -v npx >/dev/null 2>&1 && (cd "$project_dir" && npx --no-install markdownlint-cli2 --version >/dev/null 2>&1); then
				if (cd "$project_dir" && npx --no-install markdownlint-cli2 "**/*.md" 2>/dev/null); then
					echo "  [pass] markdownlint"
					pass_count=$((pass_count + 1))
				else
					echo "  [fail] markdownlint"
					fail_count=$((fail_count + 1))
				fi
			else
				echo "  [skip] markdownlint (not installed)"
				skip_count=$((skip_count + 1))
			fi
			;;
		hadolint)
			if command -v hadolint >/dev/null 2>&1; then
				local hl_errors=0
				while IFS= read -r dockerfile; do
					[[ -f "$dockerfile" ]] || continue
					if ! hadolint "$dockerfile" >/dev/null 2>&1; then
						hl_errors=$((hl_errors + 1))
					fi
				done < <(find "$project_dir" -name "Dockerfile*" -not -path "*/.git/*" 2>/dev/null)
				if [[ "$hl_errors" -eq 0 ]]; then
					echo "  [pass] hadolint"
					pass_count=$((pass_count + 1))
				else
					echo "  [fail] hadolint (${hl_errors} Dockerfiles with issues)"
					fail_count=$((fail_count + 1))
				fi
			else
				echo "  [skip] hadolint (not installed)"
				skip_count=$((skip_count + 1))
			fi
			;;
		*)
			echo "  [skip] ${linter_name}"
			skip_count=$((skip_count + 1))
			;;
		esac
	done < <(echo "$discovery" | jq -r '.linters[].name')

	echo ""
	echo "  Results: ${pass_count} passed, ${fail_count} failed, ${skip_count} skipped"
	echo ""

	if [[ "$fail_count" -gt 0 ]]; then
		return 1
	fi
	return 0
}

# =============================================================================
# Help Command
# =============================================================================

cmd_help() {
	cat <<'HELP'
Testing Setup Helper - Per-repo testing infrastructure detection and config

Usage:
  testing-setup-helper.sh <command> [project-path]

Commands:
  discover [path]    Scan project for existing test infrastructure (JSON output)
  gaps [path]        Compare discovered infra against bundle quality gates (JSON)
  status [path]      Show human-readable test infrastructure status
  verify [path]      Run all discovered test runners and linters
  help               Show this help

Options:
  project-path       Path to project root (default: current directory)

Examples:
  testing-setup-helper.sh discover ~/Git/my-app
  testing-setup-helper.sh gaps .
  testing-setup-helper.sh status
  testing-setup-helper.sh verify ~/Git/my-project

Integration:
  This helper is used by the /testing-setup command for the interactive
  onboarding flow. Use the command for guided setup, or this helper for
  scripted/CI usage.

Related:
  /testing-setup                    Interactive setup command
  bundle-helper.sh resolve [path]   Detect project bundle
  linters-local.sh                  Local quality checks
  agent-test-helper.sh              Agent-specific testing
HELP
	return 0
}

# =============================================================================
# Main
# =============================================================================

main() {
	local command="${1:-help}"
	shift || true

	case "$command" in
	discover) cmd_discover "$@" ;;
	gaps) cmd_gaps "$@" ;;
	status) cmd_status "$@" ;;
	verify) cmd_verify "$@" ;;
	help | --help | -h) cmd_help ;;
	*)
		print_error "Unknown command: ${command}. Run 'testing-setup-helper.sh help' for usage."
		cmd_help
		return 1
		;;
	esac
	return 0
}

main "$@"
