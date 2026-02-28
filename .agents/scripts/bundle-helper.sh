#!/usr/bin/env bash
# =============================================================================
# Bundle Helper - Load and resolve project bundle presets
# =============================================================================
# Loads bundle definitions from .agents/bundles/ and resolves the effective
# configuration for a project. Supports explicit bundle assignment (via
# repos.json "bundle" field) and auto-detection from marker files.
#
# Usage:
#   bundle-helper.sh load <bundle-name>         Load a single bundle by name
#   bundle-helper.sh detect [project-path]      Auto-detect bundle from markers
#   bundle-helper.sh resolve [project-path]     Resolve effective bundle (explicit or detected)
#   bundle-helper.sh list                       List all available bundles
#   bundle-helper.sh validate [bundle-name]     Validate bundle JSON against schema
#   bundle-helper.sh get <field> [project-path] Get a specific field from resolved bundle
#   bundle-helper.sh compose <b1> <b2> [...]    Compose multiple bundles into one
#   bundle-helper.sh help                       Show this help
#
# Examples:
#   bundle-helper.sh load web-app
#   bundle-helper.sh detect ~/Git/my-nextjs-app
#   bundle-helper.sh resolve ~/Git/my-project
#   bundle-helper.sh get model_defaults.implementation ~/Git/my-project
#   bundle-helper.sh compose web-app infrastructure
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit
source "${SCRIPT_DIR}/shared-constants.sh"

set -euo pipefail

# =============================================================================
# Configuration
# =============================================================================

# Bundle directory: check worktree first, then main repo, then deployed location
BUNDLES_DIR=""
_resolve_bundles_dir() {
	local candidates=(
		"${SCRIPT_DIR}/../bundles"
		"${HOME}/.aidevops/agents/bundles"
	)
	for candidate in "${candidates[@]}"; do
		if [[ -d "$candidate" ]]; then
			BUNDLES_DIR="$(cd "$candidate" && pwd)"
			return 0
		fi
	done
	print_error "Bundle directory not found. Expected at .agents/bundles/ or ~/.aidevops/agents/bundles/"
	return 1
}

REPOS_JSON="${HOME}/.config/aidevops/repos.json"

# =============================================================================
# Core Functions
# =============================================================================

# Load a bundle by name and print its JSON to stdout.
# Arguments:
#   $1 - bundle name (e.g., "web-app")
# Returns: 0 on success, 1 if bundle not found
cmd_load() {
	local bundle_name="$1"

	if [[ -z "$bundle_name" ]]; then
		print_error "Bundle name is required"
		return 1
	fi

	local bundle_file="${BUNDLES_DIR}/${bundle_name}.json"
	if [[ ! -f "$bundle_file" ]]; then
		print_error "Bundle not found: ${bundle_name} (expected at ${bundle_file})"
		return 1
	fi

	# If bundle extends another, merge parent first
	local extends
	extends=$(jq -r '.extends // empty' "$bundle_file" 2>/dev/null) || true

	if [[ -n "$extends" ]]; then
		local parent_file="${BUNDLES_DIR}/${extends}.json"
		if [[ ! -f "$parent_file" ]]; then
			print_error "Parent bundle not found: ${extends} (referenced by ${bundle_name})"
			return 1
		fi
		# Merge: parent as base, child overrides. Arrays are replaced, not merged.
		jq -s '.[0] * .[1] | del(.extends)' "$parent_file" "$bundle_file"
	else
		jq '.' "$bundle_file"
	fi

	return 0
}

# Detect which bundle(s) match a project based on marker files.
# Arguments:
#   $1 - project path (defaults to current directory)
# Output: newline-separated list of matching bundle names
# Returns: 0 if at least one match, 1 if no matches
cmd_detect() {
	local project_path="${1:-.}"
	project_path="$(cd "$project_path" 2>/dev/null && pwd)" || {
		print_error "Project path not found: $1"
		return 1
	}

	local matches=()

	for bundle_file in "${BUNDLES_DIR}"/*.json; do
		local basename
		basename="$(basename "$bundle_file" .json)"
		[[ "$basename" == "schema" ]] && continue

		local markers
		markers=$(jq -r '.markers[]? // empty' "$bundle_file" 2>/dev/null) || continue

		while IFS= read -r marker; do
			[[ -z "$marker" ]] && continue
			# Check if marker exists in project (supports glob patterns)
			# shellcheck disable=SC2086
			if compgen -G "${project_path}/${marker}" >/dev/null 2>&1; then
				matches+=("$basename")
				break
			fi
		done <<<"$markers"
	done

	if [[ ${#matches[@]} -eq 0 ]]; then
		return 1
	fi

	printf '%s\n' "${matches[@]}"
	return 0
}

# Resolve the effective bundle for a project.
# Priority: explicit assignment in repos.json > auto-detection > no bundle.
# Arguments:
#   $1 - project path (defaults to current directory)
# Output: resolved bundle JSON to stdout
# Returns: 0 on success, 1 if no bundle found
cmd_resolve() {
	local project_path="${1:-.}"
	project_path="$(cd "$project_path" 2>/dev/null && pwd)" || {
		print_error "Project path not found: $1"
		return 1
	}

	# 1. Check repos.json for explicit bundle assignment
	local explicit_bundle=""
	if [[ -f "$REPOS_JSON" ]]; then
		explicit_bundle=$(jq -r --arg path "$project_path" \
			'.[] | select(.path == $path) | .bundle // empty' \
			"$REPOS_JSON" 2>/dev/null) || true
	fi

	if [[ -n "$explicit_bundle" ]]; then
		# Explicit bundle may be comma-separated for composition
		local IFS=','
		local bundle_names
		read -ra bundle_names <<<"$explicit_bundle"
		if [[ ${#bundle_names[@]} -eq 1 ]]; then
			cmd_load "${bundle_names[0]}"
			return $?
		else
			cmd_compose "${bundle_names[@]}"
			return $?
		fi
	fi

	# 2. Auto-detect from markers
	local detected
	detected=$(cmd_detect "$project_path" 2>/dev/null) || true

	if [[ -z "$detected" ]]; then
		print_info "No bundle detected for ${project_path}. Using framework defaults."
		return 1
	fi

	local detected_array
	mapfile -t detected_array <<<"$detected"

	if [[ ${#detected_array[@]} -eq 1 ]]; then
		cmd_load "${detected_array[0]}"
		return $?
	else
		# Multiple matches: compose them
		print_info "Multiple bundles detected: ${detected_array[*]}. Composing."
		cmd_compose "${detected_array[@]}"
		return $?
	fi
}

# List all available bundles with their descriptions.
# Returns: 0
cmd_list() {
	local count=0

	printf "%-18s %s\n" "BUNDLE" "DESCRIPTION"
	printf "%-18s %s\n" "------" "-----------"

	for bundle_file in "${BUNDLES_DIR}"/*.json; do
		local basename
		basename="$(basename "$bundle_file" .json)"
		[[ "$basename" == "schema" ]] && continue

		local description
		description=$(jq -r '.description // "No description"' "$bundle_file" 2>/dev/null) || description="(invalid JSON)"

		# Truncate description to 60 chars for display
		if [[ ${#description} -gt 60 ]]; then
			description="${description:0:57}..."
		fi

		printf "%-18s %s\n" "$basename" "$description"
		count=$((count + 1))
	done

	echo ""
	print_info "${count} bundles available in ${BUNDLES_DIR}"
	return 0
}

# Validate a bundle file against the schema (basic structural check).
# Arguments:
#   $1 - bundle name (optional; validates all if omitted)
# Returns: 0 if valid, 1 if invalid
cmd_validate() {
	local bundle_name="${1:-}"
	local failures=0
	local checked=0

	local files_to_check=()
	if [[ -n "$bundle_name" ]]; then
		local bundle_file="${BUNDLES_DIR}/${bundle_name}.json"
		if [[ ! -f "$bundle_file" ]]; then
			print_error "Bundle not found: ${bundle_name}"
			return 1
		fi
		files_to_check+=("$bundle_file")
	else
		for f in "${BUNDLES_DIR}"/*.json; do
			local bn
			bn="$(basename "$f" .json)"
			[[ "$bn" == "schema" ]] && continue
			files_to_check+=("$f")
		done
	fi

	for bundle_file in "${files_to_check[@]}"; do
		local bn
		bn="$(basename "$bundle_file" .json)"
		checked=$((checked + 1))

		# Check valid JSON
		if ! jq empty "$bundle_file" 2>/dev/null; then
			print_error "${bn}: Invalid JSON"
			failures=$((failures + 1))
			continue
		fi

		# Check required fields
		local has_required
		has_required=$(jq -e '.model_defaults and .quality_gates and .agent_routing' "$bundle_file" 2>/dev/null) || true
		if [[ "$has_required" != "true" ]]; then
			print_error "${bn}: Missing required fields (model_defaults, quality_gates, agent_routing)"
			failures=$((failures + 1))
			continue
		fi

		# Check name matches filename
		local json_name
		json_name=$(jq -r '.name // empty' "$bundle_file" 2>/dev/null) || true
		if [[ "$json_name" != "$bn" ]]; then
			print_warning "${bn}: name field '${json_name}' does not match filename"
		fi

		print_success "${bn}: Valid"
	done

	echo ""
	if [[ $failures -eq 0 ]]; then
		print_success "All ${checked} bundles valid"
		return 0
	else
		print_error "${failures} of ${checked} bundles have issues"
		return 1
	fi
}

# Get a specific field from the resolved bundle for a project.
# Arguments:
#   $1 - jq field path (e.g., "model_defaults.implementation", "quality_gates")
#   $2 - project path (optional, defaults to current directory)
# Output: field value to stdout
# Returns: 0 on success, 1 if field not found
cmd_get() {
	local field="$1"
	local project_path="${2:-.}"

	if [[ -z "$field" ]]; then
		print_error "Field path is required (e.g., model_defaults.implementation)"
		return 1
	fi

	local resolved
	resolved=$(cmd_resolve "$project_path" 2>/dev/null) || {
		print_error "Could not resolve bundle for ${project_path}"
		return 1
	}

	local value
	value=$(echo "$resolved" | jq -r ".${field} // empty" 2>/dev/null) || true

	if [[ -z "$value" ]]; then
		print_error "Field not found: ${field}"
		return 1
	fi

	echo "$value"
	return 0
}

# Compose multiple bundles into a single effective configuration.
# Composition rules:
#   - model_defaults: most-restrictive (highest) tier wins per task type
#   - quality_gates: union of all gates
#   - skip_gates: union of all skip gates
#   - agent_routing: later bundles override earlier ones
#   - dispatch: most-restrictive values (lowest concurrency, shortest timeout)
#   - tool_allowlist: union of all tools
# Arguments:
#   $1..$N - bundle names to compose
# Output: composed bundle JSON to stdout
# Returns: 0 on success, 1 on error
cmd_compose() {
	if [[ $# -lt 2 ]]; then
		print_error "At least 2 bundle names required for composition"
		return 1
	fi

	# Load all bundles into a JSON array
	local bundles_json="["
	local first=true
	for bundle_name in "$@"; do
		local bundle
		bundle=$(cmd_load "$bundle_name" 2>/dev/null) || {
			print_error "Failed to load bundle: ${bundle_name}"
			return 1
		}
		if [[ "$first" == "true" ]]; then
			first=false
		else
			bundles_json+=","
		fi
		bundles_json+="$bundle"
	done
	bundles_json+="]"

	# Compose using jq
	echo "$bundles_json" | jq '
		# Model tier ordering for most-restrictive comparison
		def tier_rank:
			if . == "opus" then 6
			elif . == "pro" then 5
			elif . == "sonnet" then 4
			elif . == "flash" then 3
			elif . == "haiku" then 2
			elif . == "local" then 1
			else 0
			end;

		# Pick the higher (more restrictive) tier
		def max_tier(a; b):
			if (a | tier_rank) >= (b | tier_rank) then a else b end;

		reduce .[] as $bundle (
			{
				name: "composed",
				description: "Composed bundle",
				version: "1.0.0",
				model_defaults: {},
				quality_gates: [],
				skip_gates: [],
				agent_routing: {},
				dispatch: {
					max_concurrent_workers: 10,
					default_timeout_minutes: 120,
					auto_dispatch: true
				},
				tool_allowlist: []
			};
			# model_defaults: most restrictive tier per task type
			.model_defaults = (
				reduce ($bundle.model_defaults | to_entries[]) as $entry (
					.model_defaults;
					if .[$entry.key] then
						.[$entry.key] = max_tier(.[$entry.key]; $entry.value)
					else
						.[$entry.key] = $entry.value
					end
				)
			) |
			# quality_gates: union
			.quality_gates = (.quality_gates + ($bundle.quality_gates // []) | unique) |
			# skip_gates: union
			.skip_gates = (.skip_gates + ($bundle.skip_gates // []) | unique) |
			# agent_routing: later overrides earlier
			.agent_routing = (.agent_routing * ($bundle.agent_routing // {})) |
			# dispatch: most restrictive
			.dispatch.max_concurrent_workers = (
				[.dispatch.max_concurrent_workers, ($bundle.dispatch.max_concurrent_workers // 10)] | min
			) |
			.dispatch.default_timeout_minutes = (
				[.dispatch.default_timeout_minutes, ($bundle.dispatch.default_timeout_minutes // 120)] | min
			) |
			.dispatch.auto_dispatch = (
				.dispatch.auto_dispatch and ($bundle.dispatch.auto_dispatch // true)
			) |
			# tool_allowlist: union
			.tool_allowlist = (.tool_allowlist + ($bundle.tool_allowlist // []) | unique) |
			# Composed name and description
			.name = (.name + "+" + $bundle.name) |
			.description = "Composed: " + ([.description, $bundle.description] | join(" | "))
		) |
		# Fix composed name (remove leading "composed+")
		.name = (.name | ltrimstr("composed+")) |
		.description = (.description | ltrimstr("Composed: Composed bundle | ") | "Composed: " + .)
	'

	return 0
}

# Show help text.
# Returns: 0
cmd_help() {
	cat <<'EOF'
Bundle Helper - Load and resolve project bundle presets

USAGE:
    bundle-helper.sh <command> [options]

COMMANDS:
    load <name>              Load a single bundle by name
    detect [path]            Auto-detect bundle from project marker files
    resolve [path]           Resolve effective bundle (explicit > detected)
    list                     List all available bundles
    validate [name]          Validate bundle(s) against schema
    get <field> [path]       Get a specific field from resolved bundle
    compose <b1> <b2> ...    Compose multiple bundles into one
    help                     Show this help

FIELD EXAMPLES (for 'get' command):
    model_defaults.implementation    Primary model tier for code changes
    model_defaults.review            Model tier for code review
    quality_gates                    Array of quality checks to run
    dispatch.max_concurrent_workers  Max parallel workers

BUNDLE RESOLUTION ORDER:
    1. Explicit: repos.json "bundle" field for the project path
    2. Auto-detect: marker files in the project directory
    3. Fallback: framework defaults (no bundle)

COMPOSITION RULES:
    model_defaults   Most-restrictive (highest) tier wins per task type
    quality_gates    Union of all gates from all bundles
    skip_gates       Union of all skip gates
    agent_routing    Later bundles override earlier ones
    dispatch         Most-restrictive values (lowest concurrency, shortest timeout)
    tool_allowlist   Union of all tools

EXAMPLES:
    # List available bundles
    bundle-helper.sh list

    # Load a specific bundle
    bundle-helper.sh load web-app

    # Auto-detect bundle for current project
    bundle-helper.sh detect .

    # Get the implementation model tier for a project
    bundle-helper.sh get model_defaults.implementation ~/Git/my-app

    # Compose web-app and infrastructure bundles
    bundle-helper.sh compose web-app infrastructure

    # Validate all bundles
    bundle-helper.sh validate
EOF
	return 0
}

# =============================================================================
# Main
# =============================================================================

main() {
	# Resolve bundles directory
	_resolve_bundles_dir || return 1

	# Check jq dependency
	if ! command -v jq &>/dev/null; then
		print_error "jq is required but not installed. Install with: brew install jq (macOS) or apt install jq (Linux)"
		return 1
	fi

	local command="${1:-help}"
	shift || true

	case "$command" in
	load)
		cmd_load "${1:?Bundle name required}"
		;;
	detect)
		cmd_detect "${1:-.}"
		;;
	resolve)
		cmd_resolve "${1:-.}"
		;;
	list)
		cmd_list
		;;
	validate)
		cmd_validate "${1:-}"
		;;
	get)
		cmd_get "${1:?Field path required}" "${2:-.}"
		;;
	compose)
		cmd_compose "$@"
		;;
	help | --help | -h)
		cmd_help
		;;
	*)
		print_error "${ERROR_UNKNOWN_COMMAND}: ${command}"
		cmd_help
		return 1
		;;
	esac
}

main "$@"
