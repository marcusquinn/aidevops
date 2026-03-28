#!/usr/bin/env bash
# shellcheck disable=SC1091
# wordpress-plugin.sh — FOSS contribution handler for WordPress plugins (t1696)
#
# Implements the foss-contribution-helper.sh handler interface for WordPress plugins.
# Sets up wp-env with multisite, integrates with localdev for HTTPS review URLs,
# runs PHPUnit + Playwright smoke tests, and cleans up all resources.
#
# Handler interface (required by foss-contribution-helper.sh):
#   setup   <github-slug> [worktree-path]   Fork, clone, wp-env start, localdev register
#   build   <plugin-dir>                    Activate plugin, install composer/npm deps
#   test    <plugin-dir>                    PHPUnit (if available) + Playwright smoke tests
#   review  <plugin-dir> [branch-name]      Print review URLs (current + branch)
#   cleanup <plugin-dir>                    wp-env destroy, localdev rm, port deregistration
#
# Usage:
#   wordpress-plugin.sh setup afragen/git-updater
#   wordpress-plugin.sh setup afragen/git-updater ~/Git/wordpress/git-updater-fix
#   wordpress-plugin.sh build ~/Git/wordpress/git-updater
#   wordpress-plugin.sh test ~/Git/wordpress/git-updater
#   wordpress-plugin.sh review ~/Git/wordpress/git-updater bugfix-xyz
#   wordpress-plugin.sh cleanup ~/Git/wordpress/git-updater
#
# Prerequisites:
#   - Docker (for wp-env)
#   - Node.js >= 18 + npm (for @wordpress/env)
#   - localdev-helper.sh (for HTTPS .local domains)
#   - mkcert (installed by localdev-helper.sh init)
#   - Optional: composer (for PHPUnit), playwright (for E2E smoke tests)
#
# State file: ~/.aidevops/cache/foss-wp-handler.json
# Smoke test template: foss-handlers/wp-plugin-smoke-test.spec.js

set -euo pipefail

# PATH normalisation for launchd/MCP environments
export PATH="/bin:/usr/bin:/usr/local/bin:/opt/homebrew/bin:${PATH}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
AGENTS_SCRIPTS_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

# shellcheck source=../shared-constants.sh
source "${AGENTS_SCRIPTS_DIR}/shared-constants.sh" 2>/dev/null || true

# Fallback colours if shared-constants.sh not loaded
[[ -z "${RED+x}" ]] && RED='\033[0;31m'
[[ -z "${GREEN+x}" ]] && GREEN='\033[0;32m'
[[ -z "${YELLOW+x}" ]] && YELLOW='\033[1;33m'
[[ -z "${BLUE+x}" ]] && BLUE='\033[0;34m'
[[ -z "${NC+x}" ]] && NC='\033[0m'

# Fallback print helpers if shared-constants.sh not loaded
if ! command -v print_info >/dev/null 2>&1; then
	print_info() {
		printf "${BLUE}[INFO]${NC} %s\n" "$1"
		return 0
	}
	print_success() {
		printf "${GREEN}[OK]${NC} %s\n" "$1"
		return 0
	}
	print_error() {
		printf "${RED}[ERROR]${NC} %s\n" "$1" >&2
		return 0
	}
	print_warning() {
		printf "${YELLOW}[WARN]${NC} %s\n" "$1"
		return 0
	}
fi

# =============================================================================
# Configuration
# =============================================================================

readonly WP_HANDLER_STATE="${HOME}/.aidevops/cache/foss-wp-handler.json"
readonly WP_CLONE_BASE="${HOME}/Git/wordpress"
readonly LOCALDEV_HELPER="${AGENTS_SCRIPTS_DIR}/localdev-helper.sh"
readonly SMOKE_TEST_TEMPLATE="${SCRIPT_DIR}/wp-plugin-smoke-test.spec.js"

# wp-env port range (separate from localdev 3100-3999 range)
readonly WP_ENV_PORT_START=8880
readonly WP_ENV_PORT_END=8999

# Multisite wp-env config constants
readonly WP_MULTISITE_DOMAIN="localhost"
readonly WP_DEBUG_CONFIG='{"WP_DEBUG":true,"WP_DEBUG_LOG":true,"WP_DEBUG_DISPLAY":false,"SCRIPT_DEBUG":true}'

# =============================================================================
# Utility helpers
# =============================================================================

# Derive a safe slug from a GitHub slug (owner/repo → repo)
plugin_slug_from_github() {
	local github_slug="${1:-}"
	echo "${github_slug##*/}" | tr '[:upper:]' '[:lower:]' | tr '_' '-'
	return 0
}

# Derive the clone directory from a plugin slug
plugin_dir_from_slug() {
	local slug="${1:-}"
	echo "${WP_CLONE_BASE}/${slug}"
	return 0
}

# Read a value from the state JSON file
state_get() {
	local key="${1:-}"
	if [[ ! -f "$WP_HANDLER_STATE" ]]; then
		echo ""
		return 0
	fi
	jq -r --arg k "$key" '.[$k] // empty' "$WP_HANDLER_STATE" 2>/dev/null || echo ""
	return 0
}

# Write a key=value pair to the state JSON file
state_set() {
	local key="${1:-}"
	local value="${2:-}"
	local tmp
	tmp="$(mktemp)"
	if [[ -f "$WP_HANDLER_STATE" ]]; then
		jq --arg k "$key" --arg v "$value" '.[$k] = $v' "$WP_HANDLER_STATE" >"$tmp"
	else
		mkdir -p "$(dirname "$WP_HANDLER_STATE")"
		jq -n --arg k "$key" --arg v "$value" '{($k): $v}' >"$tmp"
	fi
	mv "$tmp" "$WP_HANDLER_STATE"
	return 0
}

# Remove a key from the state JSON file
state_del() {
	local key="${1:-}"
	if [[ ! -f "$WP_HANDLER_STATE" ]]; then
		return 0
	fi
	local tmp
	tmp="$(mktemp)"
	jq --arg k "$key" 'del(.[$k])' "$WP_HANDLER_STATE" >"$tmp"
	mv "$tmp" "$WP_HANDLER_STATE"
	return 0
}

# Check if a command exists
require_cmd() {
	local cmd="${1:-}"
	local install_hint="${2:-}"
	if ! command -v "$cmd" >/dev/null 2>&1; then
		print_error "Required command not found: $cmd"
		if [[ -n "$install_hint" ]]; then
			print_info "Install: $install_hint"
		fi
		return 1
	fi
	return 0
}

# Find an available port in the wp-env range
find_available_wp_env_port() {
	local port="$WP_ENV_PORT_START"
	while [[ "$port" -le "$WP_ENV_PORT_END" ]]; do
		if ! lsof -i ":${port}" >/dev/null 2>&1; then
			echo "$port"
			return 0
		fi
		port=$((port + 1))
	done
	print_error "No available port in range ${WP_ENV_PORT_START}-${WP_ENV_PORT_END}"
	return 1
}

# =============================================================================
# wp-env.json generation
# =============================================================================

# Generate .wp-env.json with multisite config for a plugin directory.
# Writes the file into the plugin directory (or a temp dir if plugin dir
# doesn't have write permission).
generate_wp_env_json() {
	local plugin_dir="${1:-}"
	local wp_port="${2:-8888}"
	local slug
	slug="$(basename "$plugin_dir")"

	print_info "Generating .wp-env.json for ${slug} (port ${wp_port}, multisite)"

	# Build multisite config object
	local multisite_config
	multisite_config=$(jq -n \
		--argjson debug "$WP_DEBUG_CONFIG" \
		--arg domain "$WP_MULTISITE_DOMAIN" \
		--arg port "$wp_port" \
		'{
			"WP_DEBUG": $debug.WP_DEBUG,
			"WP_DEBUG_LOG": $debug.WP_DEBUG_LOG,
			"WP_DEBUG_DISPLAY": $debug.WP_DEBUG_DISPLAY,
			"SCRIPT_DEBUG": $debug.SCRIPT_DEBUG,
			"WP_ALLOW_MULTISITE": true,
			"MULTISITE": true,
			"SUBDOMAIN_INSTALL": false,
			"DOMAIN_CURRENT_SITE": $domain,
			"PATH_CURRENT_SITE": "/",
			"SITE_ID_CURRENT_SITE": 1,
			"BLOG_ID_CURRENT_SITE": 1
		}')

	# Write .wp-env.json
	jq -n \
		--arg plugin "." \
		--argjson config "$multisite_config" \
		--argjson port "$wp_port" \
		'{
			"core": "WordPress/WordPress",
			"phpVersion": "8.1",
			"plugins": [$plugin, "https://downloads.wordpress.org/plugin/query-monitor.latest-stable.zip"],
			"config": $config,
			"port": $port,
			"testsPort": ($port + 1)
		}' >"${plugin_dir}/.wp-env.json"

	print_success ".wp-env.json written to ${plugin_dir}/.wp-env.json"
	return 0
}

# =============================================================================
# setup command
# =============================================================================

cmd_setup() {
	local github_slug="${1:-}"
	local worktree_path="${2:-}"

	if [[ -z "$github_slug" ]]; then
		print_error "Usage: wordpress-plugin.sh setup <github-slug> [worktree-path]"
		print_info "  github-slug: e.g. afragen/git-updater"
		print_info "  worktree-path: optional path to an existing worktree for a fix branch"
		return 1
	fi

	require_cmd "docker" "brew install --cask docker" || return 1
	require_cmd "node" "brew install node" || return 1
	require_cmd "npm" "brew install node" || return 1
	require_cmd "jq" "brew install jq" || return 1

	local slug
	slug="$(plugin_slug_from_github "$github_slug")"
	local plugin_dir
	plugin_dir="$(plugin_dir_from_slug "$slug")"

	# Use worktree path if provided, otherwise use default clone dir
	if [[ -n "$worktree_path" ]]; then
		plugin_dir="$worktree_path"
	fi

	print_info "=== WordPress Plugin Handler: setup ==="
	print_info "GitHub slug : $github_slug"
	print_info "Plugin slug : $slug"
	print_info "Plugin dir  : $plugin_dir"
	echo ""

	# Step 1: Clone if not already present
	if [[ ! -d "$plugin_dir" ]]; then
		print_info "Cloning ${github_slug} → ${plugin_dir}"
		mkdir -p "$(dirname "$plugin_dir")"
		if ! git clone "https://github.com/${github_slug}.git" "$plugin_dir"; then
			print_error "Failed to clone ${github_slug}"
			return 1
		fi
		print_success "Cloned ${github_slug}"
	else
		print_info "Plugin directory already exists: ${plugin_dir}"
	fi

	# Step 2: Install @wordpress/env if not present
	if ! command -v wp-env >/dev/null 2>&1; then
		print_info "Installing @wordpress/env globally..."
		npm install -g @wordpress/env || {
			print_error "Failed to install @wordpress/env"
			return 1
		}
	fi

	# Step 3: Find available port and generate .wp-env.json
	local wp_port
	wp_port="$(find_available_wp_env_port)" || return 1
	generate_wp_env_json "$plugin_dir" "$wp_port" || return 1

	# Step 4: Start wp-env
	print_info "Starting wp-env (port ${wp_port})..."
	if ! wp-env start --update 2>&1; then
		print_error "wp-env start failed"
		return 1
	fi
	print_success "wp-env started on port ${wp_port}"

	# Step 5: Register with localdev for HTTPS .local domain
	if [[ -x "$LOCALDEV_HELPER" ]]; then
		print_info "Registering ${slug} with localdev (port ${wp_port})..."
		if "$LOCALDEV_HELPER" add "$slug" "$wp_port" 2>/dev/null; then
			print_success "Registered: https://${slug}.local → localhost:${wp_port}"
		else
			print_warning "localdev registration failed — HTTP access only at http://localhost:${wp_port}"
		fi
	else
		print_warning "localdev-helper.sh not found — skipping HTTPS domain registration"
		print_info "HTTP access: http://localhost:${wp_port}"
	fi

	# Step 6: Persist state
	state_set "${slug}:port" "$wp_port"
	state_set "${slug}:dir" "$plugin_dir"
	state_set "${slug}:github" "$github_slug"

	echo ""
	print_success "=== Setup complete ==="
	print_info "Plugin dir : ${plugin_dir}"
	print_info "wp-env URL : http://localhost:${wp_port}"
	if [[ -x "$LOCALDEV_HELPER" ]]; then
		print_info "HTTPS URL  : https://${slug}.local"
	fi
	print_info "Next: wordpress-plugin.sh build ${plugin_dir}"
	return 0
}

# =============================================================================
# build command
# =============================================================================

cmd_build() {
	local plugin_dir="${1:-}"

	if [[ -z "$plugin_dir" ]]; then
		print_error "Usage: wordpress-plugin.sh build <plugin-dir>"
		return 1
	fi

	if [[ ! -d "$plugin_dir" ]]; then
		print_error "Plugin directory not found: ${plugin_dir}"
		return 1
	fi

	local slug
	slug="$(basename "$plugin_dir")"

	print_info "=== WordPress Plugin Handler: build (${slug}) ==="

	# Step 1: Install Composer dependencies if composer.json exists
	if [[ -f "${plugin_dir}/composer.json" ]]; then
		if command -v composer >/dev/null 2>&1; then
			print_info "Installing Composer dependencies..."
			if composer install --no-interaction --prefer-dist --working-dir="$plugin_dir" 2>&1; then
				print_success "Composer install complete"
			else
				print_warning "Composer install failed — continuing without PHP deps"
			fi
		else
			print_warning "composer not found — skipping PHP dependency install"
			print_info "Install: brew install composer"
		fi
	fi

	# Step 2: Install npm dependencies if package.json exists
	if [[ -f "${plugin_dir}/package.json" ]]; then
		if command -v npm >/dev/null 2>&1; then
			print_info "Installing npm dependencies..."
			if npm install --prefix "$plugin_dir" 2>&1; then
				print_success "npm install complete"
			else
				print_warning "npm install failed — continuing without JS deps"
			fi
		fi
	fi

	# Step 3: Activate plugin in wp-env
	print_info "Activating plugin in wp-env..."
	if wp-env run cli wp plugin activate "$slug" 2>&1; then
		print_success "Plugin activated: ${slug}"
	else
		print_warning "Plugin activation failed — check wp-env is running"
	fi

	# Step 4: Activate on multisite network if applicable
	print_info "Checking multisite network activation..."
	if wp-env run cli wp plugin is-active "$slug" --network 2>/dev/null; then
		print_info "Plugin already network-active"
	else
		if wp-env run cli wp plugin activate "$slug" --network 2>&1; then
			print_success "Plugin network-activated on multisite"
		else
			print_info "Network activation skipped (may not be network-activatable)"
		fi
	fi

	echo ""
	print_success "=== Build complete ==="
	print_info "Next: wordpress-plugin.sh test ${plugin_dir}"
	return 0
}

# =============================================================================
# test command
# =============================================================================

cmd_test() {
	local plugin_dir="${1:-}"

	if [[ -z "$plugin_dir" ]]; then
		print_error "Usage: wordpress-plugin.sh test <plugin-dir>"
		return 1
	fi

	if [[ ! -d "$plugin_dir" ]]; then
		print_error "Plugin directory not found: ${plugin_dir}"
		return 1
	fi

	local slug
	slug="$(basename "$plugin_dir")"
	local test_passed=true

	print_info "=== WordPress Plugin Handler: test (${slug}) ==="

	# Step 1: PHPUnit (if tests exist)
	local has_phpunit=false
	if [[ -f "${plugin_dir}/phpunit.xml" ]] || [[ -f "${plugin_dir}/phpunit.xml.dist" ]]; then
		has_phpunit=true
	fi

	if [[ "$has_phpunit" == "true" ]]; then
		print_info "Running PHPUnit tests..."
		if wp-env run tests-cli phpunit 2>&1; then
			print_success "PHPUnit: PASS"
		else
			print_error "PHPUnit: FAIL"
			test_passed=false
		fi
	else
		print_info "No phpunit.xml found — skipping PHPUnit"
	fi

	# Step 2: Check debug.log for PHP fatal errors
	print_info "Checking debug.log for PHP errors..."
	local debug_log_errors
	debug_log_errors="$(wp-env run cli cat /var/www/html/wp-content/debug.log 2>/dev/null | grep -ciE '(Fatal error|PHP Fatal|PHP Parse error)' || echo 0)"
	if [[ "$debug_log_errors" -gt 0 ]]; then
		print_error "PHP fatal/parse errors found in debug.log (${debug_log_errors} occurrences)"
		wp-env run cli cat /var/www/html/wp-content/debug.log 2>/dev/null | grep -iE '(Fatal error|PHP Fatal|PHP Parse error)' | head -10
		test_passed=false
	else
		print_success "debug.log: no PHP fatal errors"
	fi

	# Step 3: Playwright smoke tests
	local smoke_test_file="${plugin_dir}/tests/e2e/wp-plugin-smoke-test.spec.js"
	# Fall back to the generic template if no plugin-specific E2E tests exist
	if [[ ! -f "$smoke_test_file" ]]; then
		smoke_test_file="$SMOKE_TEST_TEMPLATE"
	fi

	if [[ -f "$smoke_test_file" ]]; then
		if command -v npx >/dev/null 2>&1; then
			local slug_port
			slug_port="$(state_get "${slug}:port")"
			local base_url="http://localhost:${slug_port:-8888}"

			print_info "Running Playwright smoke tests (base URL: ${base_url})..."
			if WP_BASE_URL="$base_url" WP_PLUGIN_SLUG="$slug" \
				npx playwright test "$smoke_test_file" \
				--reporter=line 2>&1; then
				print_success "Playwright smoke tests: PASS"
			else
				print_error "Playwright smoke tests: FAIL"
				test_passed=false
			fi
		else
			print_warning "npx not found — skipping Playwright smoke tests"
		fi
	else
		print_warning "No smoke test file found — skipping Playwright tests"
		print_info "Expected: ${smoke_test_file}"
	fi

	# Step 4: Multisite-specific checks
	print_info "Running multisite checks..."
	_run_multisite_checks "$slug" || test_passed=false

	echo ""
	if [[ "$test_passed" == "true" ]]; then
		print_success "=== All tests PASSED ==="
	else
		print_error "=== Some tests FAILED — review output above ==="
		return 1
	fi
	return 0
}

# Run multisite-specific checks: verify plugin works on sub-sites,
# check for multisite-incompatible code patterns.
_run_multisite_checks() {
	local slug="${1:-}"

	# Check plugin is active on network
	if wp-env run cli wp plugin is-active "$slug" --network 2>/dev/null; then
		print_success "Multisite: plugin is network-active"
	else
		print_info "Multisite: plugin is not network-active (may be site-specific)"
	fi

	# Check for common multisite incompatibility patterns in PHP files
	local incompatible_patterns=0
	if command -v rg >/dev/null 2>&1; then
		incompatible_patterns="$(rg -l 'get_option\s*\(\s*['"'"'"]blogname['"'"'"]' \
			--type php "${SCRIPT_DIR}/../../../" 2>/dev/null | wc -l | tr -d ' ')" || incompatible_patterns=0
	fi

	if [[ "$incompatible_patterns" -gt 0 ]]; then
		print_warning "Multisite: found ${incompatible_patterns} file(s) using get_option('blogname') — consider get_bloginfo()"
	fi

	return 0
}

# =============================================================================
# review command
# =============================================================================

cmd_review() {
	local plugin_dir="${1:-}"
	local branch_name="${2:-}"

	if [[ -z "$plugin_dir" ]]; then
		print_error "Usage: wordpress-plugin.sh review <plugin-dir> [branch-name]"
		return 1
	fi

	local slug
	slug="$(basename "$plugin_dir")"
	local wp_port
	wp_port="$(state_get "${slug}:port")"

	print_info "=== WordPress Plugin Handler: review (${slug}) ==="
	echo ""

	# Current release URL
	print_info "Current release:"
	print_info "  HTTP  : http://localhost:${wp_port:-8888}"
	if [[ -x "$LOCALDEV_HELPER" ]]; then
		print_info "  HTTPS : https://${slug}.local"
	fi

	# Branch/worktree URL (if branch provided)
	if [[ -n "$branch_name" ]]; then
		echo ""
		print_info "Branch: ${branch_name}"
		if [[ -x "$LOCALDEV_HELPER" ]]; then
			# Register branch subdomain if not already registered
			local branch_subdomain
			branch_subdomain="$(echo "$branch_name" | tr '/' '-' | tr '_' '-' | tr '[:upper:]' '[:lower:]')"
			local branch_port
			branch_port="$(find_available_wp_env_port)" || branch_port=""

			if [[ -n "$branch_port" ]]; then
				if "$LOCALDEV_HELPER" branch "$slug" "$branch_subdomain" "$branch_port" 2>/dev/null; then
					print_info "  HTTPS : https://${branch_subdomain}.${slug}.local"
				else
					print_info "  Branch URL registration failed — use HTTP"
					print_info "  HTTP  : http://localhost:${branch_port}"
				fi
			fi
		fi
	fi

	echo ""
	print_info "wp-admin: http://localhost:${wp_port:-8888}/wp-admin/ (admin/password)"
	return 0
}

# =============================================================================
# cleanup command
# =============================================================================

cmd_cleanup() {
	local plugin_dir="${1:-}"

	if [[ -z "$plugin_dir" ]]; then
		print_error "Usage: wordpress-plugin.sh cleanup <plugin-dir>"
		return 1
	fi

	local slug
	slug="$(basename "$plugin_dir")"

	print_info "=== WordPress Plugin Handler: cleanup (${slug}) ==="

	# Step 1: Stop and destroy wp-env
	if [[ -f "${plugin_dir}/.wp-env.json" ]]; then
		print_info "Destroying wp-env environment..."
		if wp-env destroy --yes 2>&1; then
			print_success "wp-env destroyed"
		else
			print_warning "wp-env destroy failed — may already be stopped"
		fi
		rm -f "${plugin_dir}/.wp-env.json"
	else
		print_info "No .wp-env.json found — skipping wp-env destroy"
	fi

	# Step 2: Remove localdev registration
	if [[ -x "$LOCALDEV_HELPER" ]]; then
		print_info "Removing localdev registration for ${slug}..."
		if "$LOCALDEV_HELPER" rm "$slug" 2>/dev/null; then
			print_success "localdev: removed ${slug}.local"
		else
			print_info "localdev: ${slug} was not registered (already removed)"
		fi
	fi

	# Step 3: Clear state
	state_del "${slug}:port"
	state_del "${slug}:dir"
	state_del "${slug}:github"

	echo ""
	print_success "=== Cleanup complete ==="
	return 0
}

# =============================================================================
# help command
# =============================================================================

cmd_help() {
	cat <<'EOF'
wordpress-plugin.sh — FOSS contribution handler for WordPress plugins (t1696)

USAGE
  wordpress-plugin.sh <command> [args]

COMMANDS
  setup   <github-slug> [worktree-path]
      Fork, clone, generate .wp-env.json (multisite), start wp-env,
      register HTTPS .local domain via localdev.
      Example: wordpress-plugin.sh setup afragen/git-updater

  build   <plugin-dir>
      Install composer/npm deps, activate plugin on single site + network.
      Example: wordpress-plugin.sh build ~/Git/wordpress/git-updater

  test    <plugin-dir>
      Run PHPUnit (if phpunit.xml exists), check debug.log for PHP errors,
      run Playwright smoke tests, run multisite checks.
      Example: wordpress-plugin.sh test ~/Git/wordpress/git-updater

  review  <plugin-dir> [branch-name]
      Print review URLs. With branch-name, registers a branch subdomain
      via localdev for side-by-side comparison.
      Example: wordpress-plugin.sh review ~/Git/wordpress/git-updater bugfix-xyz

  cleanup <plugin-dir>
      Destroy wp-env, remove localdev registration, deregister port.
      Example: wordpress-plugin.sh cleanup ~/Git/wordpress/git-updater

  help
      Show this help.

PREREQUISITES
  docker          — for wp-env containers
  node >= 18      — for @wordpress/env
  jq              — for JSON config generation
  composer        — optional, for PHP deps
  mkcert          — optional, for HTTPS .local (via localdev-helper.sh init)

STATE FILE
  ~/.aidevops/cache/foss-wp-handler.json

SMOKE TEST TEMPLATE
  foss-handlers/wp-plugin-smoke-test.spec.js
  (used when plugin has no tests/e2e/ directory)

REVIEW URLS
  Current release : https://<slug>.local
  Branch/worktree : https://<branch>.<slug>.local
EOF
	return 0
}

# =============================================================================
# Entry point
# =============================================================================

main() {
	local cmd="${1:-help}"
	shift || true

	case "$cmd" in
	setup) cmd_setup "$@" ;;
	build) cmd_build "$@" ;;
	test) cmd_test "$@" ;;
	review) cmd_review "$@" ;;
	cleanup) cmd_cleanup "$@" ;;
	help | --help | -h) cmd_help ;;
	*)
		print_error "Unknown command: ${cmd}"
		print_info "Use 'wordpress-plugin.sh help' for usage"
		return 1
		;;
	esac
	return $?
}

main "$@"
