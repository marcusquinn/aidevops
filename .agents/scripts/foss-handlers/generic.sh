#!/usr/bin/env bash
# foss-handlers/generic.sh — Generic fallback handler for FOSS contributions (t1698)
#
# Implements the standard handler interface for repositories that don't have a
# dedicated app_type handler. Reads README.md and CONTRIBUTING.md to infer
# build/test commands, then falls back to package-manager detection.
#
# Handler interface (called by foss-contribution-helper.sh):
#   generic.sh setup   <slug> <fork-path>   Install deps, detect commands
#   generic.sh build   <slug> <fork-path>   Run detected build command
#   generic.sh test    <slug> <fork-path>   Run detected test command
#   generic.sh review  <slug> <fork-path>   Report artifact path or localdev URL
#   generic.sh cleanup <slug> <fork-path>   Stop processes, clean up
#
# Exit codes: 0 = success, 1 = error, 2 = command not determinable (soft fail)

set -euo pipefail

export PATH="/bin:/usr/bin:/usr/local/bin:/opt/homebrew/bin:${PATH}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
HANDLERS_DIR="$SCRIPT_DIR"
AGENTS_SCRIPTS_DIR="$(dirname "$HANDLERS_DIR")"

# shellcheck source=../shared-constants.sh
source "${AGENTS_SCRIPTS_DIR}/shared-constants.sh" 2>/dev/null || true

# Fallback colours
[[ -z "${RED+x}" ]] && RED='\033[0;31m'
[[ -z "${GREEN+x}" ]] && GREEN='\033[0;32m'
[[ -z "${YELLOW+x}" ]] && YELLOW='\033[1;33m'
[[ -z "${BLUE+x}" ]] && BLUE='\033[0;34m'
[[ -z "${NC+x}" ]] && NC='\033[0m'

# =============================================================================
# Package manager / build system detection
# =============================================================================

# detect_package_manager <fork-path>
# Prints the detected package manager name to stdout.
detect_package_manager() {
	local fork_path="$1"

	if [[ -f "${fork_path}/package.json" ]]; then
		# Prefer pnpm > yarn > npm based on lockfile presence
		if [[ -f "${fork_path}/pnpm-lock.yaml" ]]; then
			echo "pnpm"
		elif [[ -f "${fork_path}/yarn.lock" ]]; then
			echo "yarn"
		else
			echo "npm"
		fi
		return 0
	fi

	if [[ -f "${fork_path}/composer.json" ]]; then
		echo "composer"
		return 0
	fi

	if [[ -f "${fork_path}/Makefile" ]]; then
		echo "make"
		return 0
	fi

	if [[ -f "${fork_path}/Cargo.toml" ]]; then
		echo "cargo"
		return 0
	fi

	if [[ -f "${fork_path}/go.mod" ]]; then
		echo "go"
		return 0
	fi

	if [[ -f "${fork_path}/pyproject.toml" ]] || [[ -f "${fork_path}/setup.py" ]]; then
		if command -v poetry &>/dev/null && [[ -f "${fork_path}/pyproject.toml" ]]; then
			echo "poetry"
		else
			echo "pip"
		fi
		return 0
	fi

	local _xcodeproj_found="false"
	for _f in "${fork_path}"/*.xcodeproj; do
		[[ -d "$_f" ]] && _xcodeproj_found="true" && break
	done
	if [[ "$_xcodeproj_found" == "true" ]] || [[ -f "${fork_path}/Package.swift" ]]; then
		echo "xcodebuild"
		return 0
	fi

	echo ""
	return 0
}

# detect_build_command <fork-path> <package-manager>
# Prints the build command to stdout, or empty string if not determinable.
detect_build_command() {
	local fork_path="$1"
	local pm="$2"

	case "$pm" in
	npm)
		# Check for a build script in package.json
		if command -v jq &>/dev/null && jq -e '.scripts.build' "${fork_path}/package.json" &>/dev/null; then
			echo "npm run build"
		else
			echo ""
		fi
		;;
	pnpm)
		if command -v jq &>/dev/null && jq -e '.scripts.build' "${fork_path}/package.json" &>/dev/null; then
			echo "pnpm run build"
		else
			echo ""
		fi
		;;
	yarn)
		if command -v jq &>/dev/null && jq -e '.scripts.build' "${fork_path}/package.json" &>/dev/null; then
			echo "yarn build"
		else
			echo ""
		fi
		;;
	composer)
		# PHP projects rarely have a separate build step; install is the build
		echo "composer install --no-interaction"
		;;
	make)
		echo "make"
		;;
	cargo)
		echo "cargo build --release"
		;;
	go)
		echo "go build ./..."
		;;
	poetry)
		echo "poetry install"
		;;
	pip)
		if [[ -f "${fork_path}/requirements.txt" ]]; then
			echo "pip install -r requirements.txt"
		else
			echo "pip install -e ."
		fi
		;;
	xcodebuild)
		if [[ -f "${fork_path}/Package.swift" ]]; then
			echo "swift build"
		else
			local proj=""
			for _xp in "${fork_path}"/*.xcodeproj; do
				[[ -d "$_xp" ]] && proj="$_xp" && break
			done
			if [[ -n "$proj" ]]; then
				echo "xcodebuild -project ${proj} -scheme ALL_BUILD build"
			else
				echo ""
			fi
		fi
		;;
	*)
		echo ""
		;;
	esac
	return 0
}

# detect_test_command <fork-path> <package-manager>
# Prints the test command to stdout, or empty string if not determinable.
detect_test_command() {
	local fork_path="$1"
	local pm="$2"

	case "$pm" in
	npm)
		if command -v jq &>/dev/null && jq -e '.scripts.test' "${fork_path}/package.json" &>/dev/null; then
			echo "npm test"
		else
			echo ""
		fi
		;;
	pnpm)
		if command -v jq &>/dev/null && jq -e '.scripts.test' "${fork_path}/package.json" &>/dev/null; then
			echo "pnpm test"
		else
			echo ""
		fi
		;;
	yarn)
		if command -v jq &>/dev/null && jq -e '.scripts.test' "${fork_path}/package.json" &>/dev/null; then
			echo "yarn test"
		else
			echo ""
		fi
		;;
	composer)
		# Check for PHPUnit
		if [[ -f "${fork_path}/vendor/bin/phpunit" ]] || [[ -f "${fork_path}/phpunit.xml" ]] || [[ -f "${fork_path}/phpunit.xml.dist" ]]; then
			echo "vendor/bin/phpunit"
		else
			echo ""
		fi
		;;
	make)
		# Check if a test target exists
		if grep -q '^test:' "${fork_path}/Makefile" 2>/dev/null; then
			echo "make test"
		else
			echo ""
		fi
		;;
	cargo)
		echo "cargo test"
		;;
	go)
		echo "go test ./..."
		;;
	poetry)
		if [[ -f "${fork_path}/pytest.ini" ]] || [[ -f "${fork_path}/pyproject.toml" ]] && grep -q 'pytest' "${fork_path}/pyproject.toml" 2>/dev/null; then
			echo "poetry run pytest"
		else
			echo ""
		fi
		;;
	pip)
		if [[ -f "${fork_path}/pytest.ini" ]] || [[ -f "${fork_path}/setup.cfg" ]]; then
			echo "pytest"
		else
			echo ""
		fi
		;;
	xcodebuild)
		if [[ -f "${fork_path}/Package.swift" ]]; then
			echo "swift test"
		else
			local proj=""
			for _xp in "${fork_path}"/*.xcodeproj; do
				[[ -d "$_xp" ]] && proj="$_xp" && break
			done
			if [[ -n "$proj" ]]; then
				echo "xcodebuild -project ${proj} test"
			else
				echo ""
			fi
		fi
		;;
	*)
		echo ""
		;;
	esac
	return 0
}

# =============================================================================
# State file helpers
# =============================================================================

# State is stored in a per-fork JSON file so cleanup can find running processes.
# Path: <fork-path>/.aidevops-handler-state.json

state_file() {
	local fork_path="$1"
	echo "${fork_path}/.aidevops-handler-state.json"
}

write_state() {
	local fork_path="$1"
	local key="$2"
	local value="$3"
	local sf
	sf="$(state_file "$fork_path")"

	if ! command -v jq &>/dev/null; then
		return 0
	fi

	local current="{}"
	[[ -f "$sf" ]] && current="$(cat "$sf")"
	echo "$current" | jq --arg k "$key" --arg v "$value" '. + {($k): $v}' >"${sf}.tmp" && mv "${sf}.tmp" "$sf"
	return 0
}

read_state() {
	local fork_path="$1"
	local key="$2"
	local sf
	sf="$(state_file "$fork_path")"

	if ! command -v jq &>/dev/null || [[ ! -f "$sf" ]]; then
		echo ""
		return 0
	fi

	jq -r --arg k "$key" '.[$k] // empty' "$sf" 2>/dev/null || echo ""
	return 0
}

# =============================================================================
# Handler commands
# =============================================================================

# setup_detect_commands <fork-path>
# Detects and persists package manager, build command, and test command.
# Prints the detected package manager name to stdout.
setup_detect_commands() {
	local fork_path="$1"

	local pm
	pm="$(detect_package_manager "$fork_path")"
	if [[ -z "$pm" ]]; then
		printf "${YELLOW}Warning: no recognised package manager found in %s${NC}\n" "$fork_path" >&2
		pm="unknown"
	fi
	printf "  Detected package manager: %s\n" "$pm"
	write_state "$fork_path" "package_manager" "$pm"

	local build_cmd
	build_cmd="$(detect_build_command "$fork_path" "$pm")"
	printf "  Detected build command: %s\n" "${build_cmd:-"(none)"}"
	write_state "$fork_path" "build_cmd" "$build_cmd"

	local test_cmd
	test_cmd="$(detect_test_command "$fork_path" "$pm")"
	printf "  Detected test command: %s\n" "${test_cmd:-"(none)"}"
	write_state "$fork_path" "test_cmd" "$test_cmd"

	echo "$pm"
	return 0
}

# setup_install_deps <fork-path> <package-manager>
# Installs dependencies for the detected package manager.
setup_install_deps() {
	local fork_path="$1"
	local pm="$2"

	case "$pm" in
	npm)
		printf "  Running: npm install\n"
		npm install --prefix "$fork_path" 2>&1 || {
			printf "${RED}npm install failed${NC}\n" >&2
			return 1
		}
		;;
	pnpm)
		printf "  Running: pnpm install\n"
		(cd "$fork_path" && pnpm install) 2>&1 || {
			printf "${RED}pnpm install failed${NC}\n" >&2
			return 1
		}
		;;
	yarn)
		printf "  Running: yarn install\n"
		(cd "$fork_path" && yarn install) 2>&1 || {
			printf "${RED}yarn install failed${NC}\n" >&2
			return 1
		}
		;;
	composer)
		printf "  Running: composer install\n"
		(cd "$fork_path" && composer install --no-interaction) 2>&1 || {
			printf "${RED}composer install failed${NC}\n" >&2
			return 1
		}
		;;
	cargo)
		printf "  Running: cargo fetch\n"
		(cd "$fork_path" && cargo fetch) 2>&1 || {
			printf "${RED}cargo fetch failed${NC}\n" >&2
			return 1
		}
		;;
	go)
		printf "  Running: go mod download\n"
		(cd "$fork_path" && go mod download) 2>&1 || {
			printf "${RED}go mod download failed${NC}\n" >&2
			return 1
		}
		;;
	poetry)
		printf "  Running: poetry install\n"
		(cd "$fork_path" && poetry install) 2>&1 || {
			printf "${RED}poetry install failed${NC}\n" >&2
			return 1
		}
		;;
	pip)
		printf "  Running: pip install\n"
		if [[ -f "${fork_path}/requirements.txt" ]]; then
			pip install -r "${fork_path}/requirements.txt" 2>&1 || {
				printf "${RED}pip install failed${NC}\n" >&2
				return 1
			}
		else
			(cd "$fork_path" && pip install -e .) 2>&1 || {
				printf "${RED}pip install failed${NC}\n" >&2
				return 1
			}
		fi
		;;
	make | xcodebuild | unknown)
		printf "  No automatic dependency install for %s — skipping\n" "$pm"
		;;
	esac
	return 0
}

cmd_setup() {
	local slug="$1"
	local fork_path="$2"

	printf "${BLUE}[generic] setup: %s at %s${NC}\n" "$slug" "$fork_path"

	if [[ ! -d "$fork_path" ]]; then
		printf "${RED}Error: fork path not found: %s${NC}\n" "$fork_path" >&2
		return 1
	fi

	local pm
	pm="$(setup_detect_commands "$fork_path")"

	setup_install_deps "$fork_path" "$pm" || return 1

	printf "${GREEN}[generic] setup complete${NC}\n"
	return 0
}

cmd_build() {
	local slug="$1"
	local fork_path="$2"

	printf "${BLUE}[generic] build: %s${NC}\n" "$slug"

	local build_cmd
	build_cmd="$(read_state "$fork_path" "build_cmd")"

	if [[ -z "$build_cmd" ]]; then
		printf "${YELLOW}[generic] No build command detected — skipping build step${NC}\n"
		return 2
	fi

	printf "  Running: %s\n" "$build_cmd"
	(cd "$fork_path" && eval "$build_cmd") 2>&1 || {
		printf "${RED}[generic] Build failed: %s${NC}\n" "$build_cmd" >&2
		return 1
	}

	printf "${GREEN}[generic] build complete${NC}\n"
	return 0
}

cmd_test() {
	local slug="$1"
	local fork_path="$2"

	printf "${BLUE}[generic] test: %s${NC}\n" "$slug"

	local test_cmd
	test_cmd="$(read_state "$fork_path" "test_cmd")"

	if [[ -z "$test_cmd" ]]; then
		printf "${YELLOW}[generic] No test command detected — cannot verify changes${NC}\n"
		printf "  Manual verification required before submitting PR\n"
		return 2
	fi

	printf "  Running: %s\n" "$test_cmd"
	local exit_code=0
	(cd "$fork_path" && eval "$test_cmd") 2>&1 || exit_code=$?

	if [[ $exit_code -ne 0 ]]; then
		printf "${RED}[generic] Tests failed (exit %d)${NC}\n" "$exit_code" >&2
		return 1
	fi

	printf "${GREEN}[generic] Tests passed${NC}\n"
	return 0
}

cmd_review() {
	local slug="$1"
	local fork_path="$2"

	printf "${BLUE}[generic] review: %s${NC}\n" "$slug"

	local pm
	pm="$(read_state "$fork_path" "package_manager")"

	# For HTTP-serving apps, attempt localdev registration
	local localdev_helper="${AGENTS_SCRIPTS_DIR}/localdev-helper.sh"
	if [[ -x "$localdev_helper" ]]; then
		# Detect if this is an HTTP-serving app (has a start/dev script or serves on a port)
		local serves_http="false"
		if [[ "$pm" == "npm" ]] || [[ "$pm" == "pnpm" ]] || [[ "$pm" == "yarn" ]]; then
			if command -v jq &>/dev/null; then
				if jq -e '.scripts.start // .scripts.dev // .scripts.serve' "${fork_path}/package.json" &>/dev/null; then
					serves_http="true"
				fi
			fi
		fi

		if [[ "$serves_http" == "true" ]]; then
			local app_name
			app_name="$(basename "$slug")"
			printf "  Registering with localdev: %s\n" "$app_name"
			"$localdev_helper" add "$app_name" 2>/dev/null || true
			printf "  Review URL: https://%s.local\n" "$app_name"
			write_state "$fork_path" "localdev_name" "$app_name"
			return 0
		fi
	fi

	# For CLI tools and native apps, report the binary/artifact path
	local artifact=""
	case "$pm" in
	cargo)
		artifact="${fork_path}/target/release/$(basename "$slug")"
		;;
	go)
		artifact="${fork_path}/$(basename "$slug")"
		;;
	npm | pnpm | yarn)
		# Check common output directories
		for dir in dist build out; do
			if [[ -d "${fork_path}/${dir}" ]]; then
				artifact="${fork_path}/${dir}"
				break
			fi
		done
		;;
	*)
		artifact=""
		;;
	esac

	if [[ -n "$artifact" ]] && [[ -e "$artifact" ]]; then
		printf "  Build artifact: %s\n" "$artifact"
	else
		printf "  No artifact path detected — manual review required\n"
	fi

	printf "${GREEN}[generic] review info reported${NC}\n"
	return 0
}

cmd_cleanup() {
	local slug="$1"
	local fork_path="$2"

	printf "${BLUE}[generic] cleanup: %s${NC}\n" "$slug"

	# Remove localdev registration if we added one
	local localdev_name
	localdev_name="$(read_state "$fork_path" "localdev_name")"
	if [[ -n "$localdev_name" ]]; then
		local localdev_helper="${AGENTS_SCRIPTS_DIR}/localdev-helper.sh"
		if [[ -x "$localdev_helper" ]]; then
			printf "  Removing localdev registration: %s\n" "$localdev_name"
			"$localdev_helper" rm "$localdev_name" 2>/dev/null || true
		fi
	fi

	# Remove state file
	local sf
	sf="$(state_file "$fork_path")"
	[[ -f "$sf" ]] && rm -f "$sf"

	printf "${GREEN}[generic] cleanup complete${NC}\n"
	return 0
}

cmd_help() {
	cat <<'EOF'
foss-handlers/generic.sh — Generic fallback handler for FOSS contributions

Usage:
  generic.sh setup   <slug> <fork-path>   Install deps, detect build/test commands
  generic.sh build   <slug> <fork-path>   Run detected build command
  generic.sh test    <slug> <fork-path>   Run detected test command, report pass/fail
  generic.sh review  <slug> <fork-path>   Report artifact path or localdev URL
  generic.sh cleanup <slug> <fork-path>   Stop processes, remove localdev registration
  generic.sh help                         Show this help

Exit codes:
  0  Success
  1  Error (build/test failed, directory not found, etc.)
  2  Command not determinable (soft fail — no build/test script detected)

State file: <fork-path>/.aidevops-handler-state.json
EOF
	return 0
}

# =============================================================================
# Entry point
# =============================================================================

main() {
	local command="${1:-help}"
	local slug="${2:-}"
	local fork_path="${3:-}"

	case "$command" in
	setup)
		[[ -z "$slug" ]] || [[ -z "$fork_path" ]] && {
			printf "Usage: generic.sh setup <slug> <fork-path>\n" >&2
			return 1
		}
		cmd_setup "$slug" "$fork_path"
		;;
	build)
		[[ -z "$slug" ]] || [[ -z "$fork_path" ]] && {
			printf "Usage: generic.sh build <slug> <fork-path>\n" >&2
			return 1
		}
		cmd_build "$slug" "$fork_path"
		;;
	test)
		[[ -z "$slug" ]] || [[ -z "$fork_path" ]] && {
			printf "Usage: generic.sh test <slug> <fork-path>\n" >&2
			return 1
		}
		cmd_test "$slug" "$fork_path"
		;;
	review)
		[[ -z "$slug" ]] || [[ -z "$fork_path" ]] && {
			printf "Usage: generic.sh review <slug> <fork-path>\n" >&2
			return 1
		}
		cmd_review "$slug" "$fork_path"
		;;
	cleanup)
		[[ -z "$slug" ]] || [[ -z "$fork_path" ]] && {
			printf "Usage: generic.sh cleanup <slug> <fork-path>\n" >&2
			return 1
		}
		cmd_cleanup "$slug" "$fork_path"
		;;
	help | --help | -h)
		cmd_help
		;;
	*)
		printf "Unknown command: %s\n" "$command" >&2
		cmd_help >&2
		return 1
		;;
	esac
	return 0
}

main "$@"
