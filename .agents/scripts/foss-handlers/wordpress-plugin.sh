#!/usr/bin/env bash
# shellcheck disable=SC1091
# wordpress-plugin.sh — FOSS contribution handler: WordPress plugins (t1696)
#
# Implements the foss-contribution-helper.sh handler interface: WordPress plugins.
# Sets up wp-env with multisite, integrates with localdev to provide HTTPS review URLs,
# runs PHPUnit + Playwright smoke tests, and cleans up all resources.
#
# Handler interface (required by foss-contribution-helper.sh):
#   setup   <github-slug> [worktree-path]   Fork, clone, wp-env start, localdev register
#   build   <plugin-dir>                    Activate plugin, install composer/npm deps
#   test    <plugin-dir>                    PHPUnit (available) + Playwright smoke tests
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
#   - Docker (required by wp-env)
#   - Node.js >= 18 + npm (required by @wordpress/env)
#   - localdev-helper.sh (required by HTTPS .local domains)
#   - mkcert (installed by localdev-helper.sh init)
#   - Optional: composer (PHP deps), playwright (E2E smoke tests)
#
# State file: ~/.aidevops/cache/foss-wp-handler.json
# Smoke test template: foss-handlers/wp-plugin-smoke-test.spec.js

set -euo pipefail

# PATH normalisation: launchd/MCP environments
export PATH="/bin:/usr/bin:/usr/local/bin:/opt/homebrew/bin:${PATH}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
AGENTS_SCRIPTS_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

# shellcheck source=../shared-constants.sh
source "${AGENTS_SCRIPTS_DIR}/shared-constants.sh" 2>/dev/null || true

# Fallback colours when shared-constants.sh not loaded
[[ -z "${RED+x}" ]] && RED='\033[0;31m'
[[ -z "${GREEN+x}" ]] && GREEN='\033[0;32m'
[[ -z "${YELLOW+x}" ]] && YELLOW='\033[1;33m'
[[ -z "${BLUE+x}" ]] && BLUE='\033[0;34m'
[[ -z "${NC+x}" ]] && NC='\033[0m'

# Fallback print helpers when shared-constants.sh not loaded
_define_print_helpers() {
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
}
command -v print_info >/dev/null 2>&1 || _define_print_helpers

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

# Derive a safe slug from a GitHub slug (owner/repo -> repo)
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

# Check that a command exists; print error + optional install hint on failure
require_cmd() {
	local cmd="${1:-}"
	local install_hint="${2:-}"
	if ! command -v "$cmd" >/dev/null 2>&1; then
		print_error "Required command not found: $cmd"
		[[ -n "$install_hint" ]] && print_info "Install: $install_hint"
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

# Generate .wp-env.json with multisite config — writes into the plugin directory.
generate_wp_env_json() {
	local plugin_dir="${1:-}"
	local wp_port="${2:-8888}"
	local slug
	slug="$(basename "$plugin_dir")"

	print_info "Generating .wp-env.json: ${slug} (port ${wp_port}, multisite)"

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
# Build sub-helpers (extracted to reduce nesting depth)
# =============================================================================

# Install Composer dependencies when composer.json is present
_install_composer_deps() {
	local plugin_dir="${1:-}"
	if [[ ! -f "${plugin_dir}/composer.json" ]]; then
		return 0
	fi
	if ! command -v composer >/dev/null 2>&1; then
		print_warning "composer not found — skipping PHP dependency install"
		print_info "Install: brew install composer"
		return 0
	fi
	print_info "Installing Composer dependencies..."
	if composer install --no-interaction --prefer-dist --working-dir="$plugin_dir" 2>&1; then
		print_success "Composer install complete"
	else
		print_warning "Composer install failed — continuing without PHP deps"
	fi
	return 0
}

# Install npm dependencies when package.json is present
_install_npm_deps() {
	local plugin_dir="${1:-}"
	if [[ ! -f "${plugin_dir}/package.json" ]]; then
		return 0
	fi
	if ! command -v npm >/dev/null 2>&1; then
		return 0
	fi
	print_info "Installing npm dependencies..."
	if npm install --prefix "$plugin_dir" 2>&1; then
		print_success "npm install complete"
	else
		print_warning "npm install failed — continuing without JS deps"
	fi
	return 0
}

# Activate plugin on multisite network (best-effort)
_activate_plugin_network() {
	local slug="${1:-}"
	print_info "Checking multisite network activation..."
	if wp-env run cli wp plugin is-active "$slug" --network 2>/dev/null; then
		print_info "Plugin already network-active"
		return 0
	fi
	if wp-env run cli wp plugin activate "$slug" --network 2>&1; then
		print_success "Plugin network-activated on multisite"
	else
		print_info "Network activation skipped (may not be network-activatable)"
	fi
	return 0
}

# =============================================================================
# Test sub-helpers (extracted to reduce nesting depth)
# =============================================================================

# Run Playwright smoke tests against the given base URL; returns 1 on failure
_run_playwright_tests() {
	local smoke_test_file="${1:-}"
	local base_url="${2:-}"
	local slug="${3:-}"

	if [[ ! -f "$smoke_test_file" ]]; then
		print_warning "No smoke test file found — skipping Playwright tests"
		print_info "Expected: ${smoke_test_file}"
		return 0
	fi
	if ! command -v npx >/dev/null 2>&1; then
		print_warning "npx not found — skipping Playwright smoke tests"
		return 0
	fi
	print_info "Running Playwright smoke tests (base URL: ${base_url})..."
	if WP_BASE_URL="$base_url" WP_PLUGIN_SLUG="$slug" \
		npx playwright test "$smoke_test_file" \
		--reporter=line 2>&1; then
		print_success "Playwright smoke tests: PASS"
	else
		print_error "Playwright smoke tests: FAIL"
		return 1
	fi
	return 0
}

# =============================================================================
# Review sub-helpers (extracted to reduce nesting depth)
# =============================================================================

# Register a branch subdomain via localdev and print the URL
_register_branch_url() {
	local slug="${1:-}"
	local branch_name="${2:-}"
	local branch_subdomain
	branch_subdomain="$(echo "$branch_name" | tr '/' '-' | tr '_' '-' | tr '[:upper:]' '[:lower:]')"
	local branch_port
	branch_port="$(find_available_wp_env_port)" || branch_port=""
	if [[ -z "$branch_port" ]]; then
		return 0
	fi
	if "$LOCALDEV_HELPER" branch "$slug" "$branch_subdomain" "$branch_port" 2>/dev/null; then
		print_info "  HTTPS : https://${branch_subdomain}.${slug}.local"
	else
		print_info "  Branch URL registration failed — use HTTP"
		print_info "  HTTP  : http://localhost:${branch_port}"
	fi
	return 0
}

# =============================================================================
# Cleanup sub-helpers (extracted to reduce nesting depth)
# =============================================================================

# Stop and destroy the wp-env environment
_destroy_wp_env() {
	local plugin_dir="${1:-}"
	if [[ ! -f "${plugin_dir}/.wp-env.json" ]]; then
		print_info "No .wp-env.json found — skipping wp-env destroy"
		return 0
	fi
	print_info "Destroying wp-env environment..."
	if wp-env destroy --yes 2>&1; then
		print_success "wp-env destroyed"
	else
		print_warning "wp-env destroy failed — may already be stopped"
	fi
	rm -f "${plugin_dir}/.wp-env.json"
	return 0
}

# Remove localdev registration by plugin slug
_remove_localdev_reg() {
	local slug="${1:-}"
	if [[ ! -x "$LOCALDEV_HELPER" ]]; then
		return 0
	fi
	print_info "Removing localdev registration for ${slug}..."
	if "$LOCALDEV_HELPER" rm "$slug" 2>/dev/null; then
		print_success "localdev: removed ${slug}.local"
	else
		print_info "localdev: ${slug} was not registered (already removed)"
	fi
	return 0
}

# =============================================================================
# Setup sub-helpers (extracted to reduce nesting depth)
# =============================================================================

# Clone the plugin repo when not already present
_clone_plugin() {
	local github_slug="${1:-}"
	local plugin_dir="${2:-}"
	if [[ -d "$plugin_dir" ]]; then
		print_info "Plugin directory already exists: ${plugin_dir}"
		return 0
	fi
	print_info "Cloning ${github_slug} -> ${plugin_dir}"
	mkdir -p "$(dirname "$plugin_dir")"
	if ! git clone "https://github.com/${github_slug}.git" "$plugin_dir"; then
		print_error "Failed to clone ${github_slug}"
		return 1
	fi
	print_success "Cloned ${github_slug}"
	return 0
}

# Register plugin with localdev for HTTPS .local domain
_register_localdev() {
	local slug="${1:-}"
	local wp_port="${2:-}"
	if [[ ! -x "$LOCALDEV_HELPER" ]]; then
		print_warning "localdev-helper.sh not found — skipping HTTPS domain registration"
		print_info "HTTP access: http://localhost:${wp_port}"
		return 0
	fi
	print_info "Registering ${slug} with localdev (port ${wp_port})..."
	if "$LOCALDEV_HELPER" add "$slug" "$wp_port" 2>/dev/null; then
		print_success "Registered: https://${slug}.local -> localhost:${wp_port}"
	else
		print_warning "localdev registration failed — HTTP access only at http://localhost:${wp_port}"
	fi
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
		print_info "  worktree-path: optional path to an existing worktree (fix branch)"
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

	[[ -n "$worktree_path" ]] && plugin_dir="$worktree_path"

	print_info "=== WordPress Plugin Handler: setup ==="
	print_info "GitHub slug : $github_slug"
	print_info "Plugin slug : $slug"
	print_info "Plugin dir  : $plugin_dir"
	echo ""

	_clone_plugin "$github_slug" "$plugin_dir" || return 1

	if ! command -v wp-env >/dev/null 2>&1; then
		print_info "Installing @wordpress/env globally..."
		npm install -g @wordpress/env || {
			print_error "Failed to install @wordpress/env"
			return 1
		}
	fi

	local wp_port
	wp_port="$(find_available_wp_env_port)" || return 1
	generate_wp_env_json "$plugin_dir" "$wp_port" || return 1

	print_info "Starting wp-env (port ${wp_port})..."
	if ! wp-env start --update 2>&1; then
		print_error "wp-env start failed"
		return 1
	fi
	print_success "wp-env started on port ${wp_port}"

	_register_localdev "$slug" "$wp_port"

	state_set "${slug}:port" "$wp_port"
	state_set "${slug}:dir" "$plugin_dir"
	state_set "${slug}:github" "$github_slug"

	echo ""
	print_success "=== Setup complete ==="
	print_info "Plugin dir : ${plugin_dir}"
	print_info "wp-env URL : http://localhost:${wp_port}"
	[[ -x "$LOCALDEV_HELPER" ]] && print_info "HTTPS URL  : https://${slug}.local"
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

	_install_composer_deps "$plugin_dir"
	_install_npm_deps "$plugin_dir"

	print_info "Activating plugin in wp-env..."
	if wp-env run cli wp plugin activate "$slug" 2>&1; then
		print_success "Plugin activated: ${slug}"
	else
		print_warning "Plugin activation failed — check wp-env is running"
	fi

	_activate_plugin_network "$slug"

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

	# PHPUnit (when tests exist)
	local has_phpunit=false
	[[ -f "${plugin_dir}/phpunit.xml" ]] || [[ -f "${plugin_dir}/phpunit.xml.dist" ]] && has_phpunit=true

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

	# Check debug.log — PHP fatal errors
	print_info "Checking debug.log: PHP errors..."
	local debug_log_errors
	debug_log_errors="$(wp-env run cli cat /var/www/html/wp-content/debug.log 2>/dev/null | grep -ciE '(Fatal error|PHP Fatal|PHP Parse error)' || echo 0)"
	if [[ "$debug_log_errors" -gt 0 ]]; then
		print_error "PHP fatal/parse errors found in debug.log (${debug_log_errors} occurrences)"
		wp-env run cli cat /var/www/html/wp-content/debug.log 2>/dev/null | grep -iE '(Fatal error|PHP Fatal|PHP Parse error)' | head -10
		test_passed=false
	else
		print_success "debug.log: no PHP fatal errors"
	fi

	# Playwright smoke tests
	local smoke_test_file="${plugin_dir}/tests/e2e/wp-plugin-smoke-test.spec.js"
	[[ ! -f "$smoke_test_file" ]] && smoke_test_file="$SMOKE_TEST_TEMPLATE"

	local slug_port
	slug_port="$(state_get "${slug}:port")"
	local base_url="http://localhost:${slug_port:-8888}"

	if ! _run_playwright_tests "$smoke_test_file" "$base_url" "$slug"; then
		test_passed=false
	fi

	# Multisite-specific checks
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
# check multisite-incompatible code patterns.
_run_multisite_checks() {
	local slug="${1:-}"

	if wp-env run cli wp plugin is-active "$slug" --network 2>/dev/null; then
		print_success "Multisite: plugin is network-active"
	else
		print_info "Multisite: plugin is not network-active (may be site-specific)"
	fi

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

	print_info "Current release:"
	print_info "  HTTP  : http://localhost:${wp_port:-8888}"
	[[ -x "$LOCALDEV_HELPER" ]] && print_info "  HTTPS : https://${slug}.local"

	if [[ -n "$branch_name" ]]; then
		echo ""
		print_info "Branch: ${branch_name}"
		[[ -x "$LOCALDEV_HELPER" ]] && _register_branch_url "$slug" "$branch_name"
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

	_destroy_wp_env "$plugin_dir"
	_remove_localdev_reg "$slug"

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
	printf '%s\n' \
		'wordpress-plugin.sh — FOSS contribution handler: WordPress plugins (t1696)' \
		'' \
		'USAGE' \
		'  wordpress-plugin.sh <command> [args]' \
		'' \
		'COMMANDS' \
		'  setup   <github-slug> [worktree-path]' \
		'      Fork, clone, generate .wp-env.json (multisite), start wp-env,' \
		'      register HTTPS .local domain via localdev.' \
		'      Example: wordpress-plugin.sh setup afragen/git-updater' \
		'' \
		'  build   <plugin-dir>' \
		'      Install composer/npm deps, activate plugin on single site + network.' \
		'      Example: wordpress-plugin.sh build ~/Git/wordpress/git-updater' \
		'' \
		'  test    <plugin-dir>' \
		'      Run PHPUnit (phpunit.xml present), check debug.log, PHP errors,' \
		'      run Playwright smoke tests, run multisite checks.' \
		'      Example: wordpress-plugin.sh test ~/Git/wordpress/git-updater' \
		'' \
		'  review  <plugin-dir> [branch-name]' \
		'      Print review URLs. With branch-name, registers a branch subdomain' \
		'      via localdev — side-by-side comparison.' \
		'      Example: wordpress-plugin.sh review ~/Git/wordpress/git-updater bugfix-xyz' \
		'' \
		'  cleanup <plugin-dir>' \
		'      Destroy wp-env, remove localdev registration, deregister port.' \
		'      Example: wordpress-plugin.sh cleanup ~/Git/wordpress/git-updater' \
		'' \
		'  help' \
		'      Show this help.' \
		'' \
		'PREREQUISITES' \
		'  docker          — required by wp-env containers' \
		'  node >= 18      — required by @wordpress/env' \
		'  jq              — required by JSON config generation' \
		'  composer        — optional, PHP deps' \
		'  mkcert          — optional, HTTPS .local (via localdev-helper.sh init)' \
		'' \
		'STATE FILE' \
		'  ~/.aidevops/cache/foss-wp-handler.json' \
		'' \
		'SMOKE TEST TEMPLATE' \
		'  foss-handlers/wp-plugin-smoke-test.spec.js' \
		'  (used when plugin has no tests/e2e/ directory)' \
		'' \
		'REVIEW URLS' \
		'  Current release : https://<slug>.local' \
		'  Branch/worktree : https://<branch>.<slug>.local'
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
