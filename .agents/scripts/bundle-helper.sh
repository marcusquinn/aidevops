#!/usr/bin/env bash
# =============================================================================
# Bundle Helper - Detect, resolve, and query project bundle presets
# =============================================================================
# Loads bundle definitions from .agents/bundles/ and resolves the effective
# configuration for a project. Supports explicit bundle assignment (via
# repos.json "bundle" field or .aidevops.json), auto-detection from marker
# files, and a cli-tool fallback.
#
# Usage:
#   bundle-helper.sh detect [project-path]        Auto-detect bundle from markers
#   bundle-helper.sh resolve [project-path]       Resolve effective bundle (priority chain)
#   bundle-helper.sh show [project-path]          Human-readable bundle summary
#   bundle-helper.sh list                         List all available bundles
#   bundle-helper.sh validate [bundle-name]       Validate bundle JSON against schema
#   bundle-helper.sh load <bundle-name>           Load a single bundle by name
#   bundle-helper.sh get <field> [project-path]   Get a specific field from resolved bundle
#   bundle-helper.sh compose <b1> <b2> [...]      Compose multiple bundles into one
#   bundle-helper.sh help                         Show this help
#
# Resolution priority chain:
#   1. repos.json "bundle" field (explicit per-repo)
#   2. .aidevops.json "bundle" field (per-project config)
#   3. Auto-detection from marker files
#   4. Fallback: cli-tool (most conservative)
#
# Integration API (source this script, then call functions):
#   get_bundle_config <project-path>    Get full resolved bundle JSON
#   get_quality_gates <project-path>    Get quality gates array
#   get_model_default <task> <path>     Get model tier for a task type
#   should_skip_gate <gate> <path>      Check if a gate should be skipped
#
# Examples:
#   bundle-helper.sh detect ~/Git/my-nextjs-app
#   bundle-helper.sh resolve ~/Git/my-project
#   bundle-helper.sh show .
#   bundle-helper.sh get model_defaults.implementation ~/Git/my-app
#   bundle-helper.sh compose web-app infrastructure
#
#   # Integration API usage from another script:
#   source "$(dirname "$0")/bundle-helper.sh" --source-only
#   tier=$(get_model_default "implementation" ~/Git/my-app)
#   if should_skip_gate "shellcheck" ~/Git/my-app; then echo "skip"; fi
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit

# Support --source-only mode for integration API
# When sourced with --source-only, only define functions — don't run main()
_BUNDLE_HELPER_SOURCE_ONLY=false
for _arg in "$@"; do
	if [[ "$_arg" == "--source-only" ]]; then
		_BUNDLE_HELPER_SOURCE_ONLY=true
		break
	fi
done

# Source shared-constants if available (provides print_error, print_info, etc.)
if [[ -f "${SCRIPT_DIR}/shared-constants.sh" ]]; then
	# shellcheck source=shared-constants.sh
	source "${SCRIPT_DIR}/shared-constants.sh"
else
	# Minimal fallback if shared-constants.sh is not available
	print_error() { echo "ERROR: $*" >&2; }
	print_success() { echo "OK: $*"; }
	print_warning() { echo "WARN: $*" >&2; }
	print_info() { echo "INFO: $*" >&2; }
	readonly ERROR_UNKNOWN_COMMAND="Unknown command"
fi

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
FALLBACK_BUNDLE="cli-tool"

# =============================================================================
# Internal Utilities
# =============================================================================

# Expand tilde in a path to the actual home directory.
# repos.json stores paths like ~/Git/project — these need expansion for comparison.
# Arguments:
#   $1 - path that may contain a leading tilde
# Output: expanded path to stdout
_expand_tilde() {
	local path="$1"
	# shellcheck disable=SC2088  # Intentional: matching literal tilde from JSON, not shell expansion
	if [[ "$path" == "~/"* ]]; then
		echo "${HOME}/${path#\~/}"
	elif [[ "$path" == "~" ]]; then
		echo "${HOME}"
	else
		echo "$path"
	fi
}

# Resolve a project path to an absolute path.
# Arguments:
#   $1 - project path (may be relative, may contain tilde)
# Output: absolute path to stdout
# Returns: 0 on success, 1 if path not found
_resolve_project_path() {
	local raw_path="${1:-.}"
	local expanded
	expanded="$(_expand_tilde "$raw_path")"

	if [[ -d "$expanded" ]]; then
		(cd "$expanded" && pwd)
		return 0
	fi

	print_error "Project path not found: ${raw_path}"
	return 1
}

# Read the "bundle" field from a project's .aidevops.json.
# Arguments:
#   $1 - absolute project path
# Output: bundle name(s) to stdout (may be comma-separated), empty if not set
_read_project_config_bundle() {
	local project_path="$1"
	local config_file="${project_path}/.aidevops.json"

	if [[ -f "$config_file" ]]; then
		jq -r '.bundle // empty' "$config_file" 2>/dev/null || true
	fi
}

# Read the cached detected bundle from .aidevops.json.
# Arguments:
#   $1 - absolute project path
# Output: cached bundle name(s) to stdout, empty if not cached
_read_cached_detection() {
	local project_path="$1"
	local config_file="${project_path}/.aidevops.json"

	if [[ -f "$config_file" ]]; then
		jq -r '.detected_bundle // empty' "$config_file" 2>/dev/null || true
	fi
}

# Write detected bundle to .aidevops.json cache.
# Creates the file if it doesn't exist; merges if it does.
# Arguments:
#   $1 - absolute project path
#   $2 - detected bundle name(s), comma-separated
_write_cached_detection() {
	local project_path="$1"
	local detected="$2"
	local config_file="${project_path}/.aidevops.json"
	local timestamp
	timestamp="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

	# Use atomic write (mktemp + mv) to prevent race conditions
	local tmpfile
	tmpfile=$(mktemp "${config_file}.XXXXXX") || {
		print_warning "Could not create temp file for ${config_file}"
		return 0
	}

	if [[ -f "$config_file" ]]; then
		# Merge into existing file
		jq --arg d "$detected" --arg t "$timestamp" \
			'.detected_bundle = $d | .detected_bundle_at = $t' \
			"$config_file" >"$tmpfile" 2>/dev/null || {
			rm -f "$tmpfile"
			print_warning "Could not update cache in ${config_file}"
			return 0
		}
	else
		# Create new file
		jq -n --arg d "$detected" --arg t "$timestamp" \
			'{detected_bundle: $d, detected_bundle_at: $t}' >"$tmpfile" 2>/dev/null || {
			rm -f "$tmpfile"
			print_warning "Could not create cache file ${config_file}"
			return 0
		}
	fi

	mv -f "$tmpfile" "$config_file" || {
		rm -f "$tmpfile"
		print_warning "Could not write cache file ${config_file}"
		return 0
	}

	return 0
}

# Look up a project in repos.json by its absolute path.
# Handles tilde expansion in repos.json paths.
# Arguments:
#   $1 - absolute project path
# Output: bundle field value to stdout, empty if not found
_lookup_repos_json_bundle() {
	local project_path="$1"

	if [[ ! -f "$REPOS_JSON" ]]; then
		return 0
	fi

	# repos.json paths may use ~/... so we need to expand them for comparison
	jq -r --arg path "$project_path" --arg home "$HOME" '
		[.[] | select(
			(.path | gsub("^~"; $home)) == $path
		) | .bundle // empty] | first // empty
	' "$REPOS_JSON" 2>/dev/null || true
}

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
#   --force - skip cache, re-detect from markers
# Output: newline-separated list of matching bundle names
# Returns: 0 if at least one match, 1 if no matches
cmd_detect() {
	local project_path=""
	local force=false

	# Parse arguments
	while [[ $# -gt 0 ]]; do
		case "$1" in
		--force)
			force=true
			shift
			;;
		*)
			project_path="$1"
			shift
			;;
		esac
	done

	project_path="$(_resolve_project_path "${project_path:-.}")" || return 1

	# Check cache unless --force
	if [[ "$force" == "false" ]]; then
		local cached
		cached="$(_read_cached_detection "$project_path")"
		if [[ -n "$cached" ]]; then
			# Convert comma-separated to newline-separated
			echo "$cached" | tr ',' '\n'
			return 0
		fi
	fi

	local matches=()

	for bundle_file in "${BUNDLES_DIR}"/*.json; do
		local basename
		basename="$(basename "$bundle_file" .json)"
		[[ "$basename" == "schema" ]] && continue

		local markers
		markers=$(jq -r '.markers[]? // empty' "$bundle_file" 2>/dev/null) || continue

		while IFS= read -r marker; do
			[[ -z "$marker" ]] && continue
			# Check if marker exists in project (supports glob patterns).
			# compgen -G has a quirk: patterns ending in / return the literal
			# pattern even when nothing matches. Verify with -e as a safeguard.
			local match_path="${project_path}/${marker}"
			# shellcheck disable=SC2086
			local matched
			matched=$(compgen -G "$match_path" 2>/dev/null | head -1) || true
			if [[ -n "$matched" && -e "$matched" ]]; then
				matches+=("$basename")
				break
			fi
		done <<<"$markers"
	done

	if [[ ${#matches[@]} -eq 0 ]]; then
		return 1
	fi

	# Cache the detection result
	local comma_separated
	comma_separated=$(
		IFS=','
		echo "${matches[*]}"
	)
	_write_cached_detection "$project_path" "$comma_separated"

	printf '%s\n' "${matches[@]}"
	return 0
}

# Resolve the effective bundle for a project.
# Priority chain: repos.json > .aidevops.json > auto-detect > cli-tool fallback.
# Arguments:
#   $1 - project path (defaults to current directory)
#   --force - force re-detection (skip cache)
# Output: resolved bundle JSON to stdout
# Returns: 0 on success
cmd_resolve() {
	local project_path=""
	local force_flag=""

	# Parse arguments
	while [[ $# -gt 0 ]]; do
		case "$1" in
		--force)
			force_flag="--force"
			shift
			;;
		*)
			project_path="$1"
			shift
			;;
		esac
	done

	project_path="$(_resolve_project_path "${project_path:-.}")" || return 1

	# 1. Check repos.json for explicit bundle assignment
	local explicit_bundle
	explicit_bundle="$(_lookup_repos_json_bundle "$project_path")"

	if [[ -n "$explicit_bundle" ]]; then
		local bundle_names
		IFS=',' read -ra bundle_names <<<"$explicit_bundle"
		if [[ ${#bundle_names[@]} -eq 1 ]]; then
			cmd_load "${bundle_names[0]}"
			return $?
		else
			cmd_compose "${bundle_names[@]}"
			return $?
		fi
	fi

	# 2. Check .aidevops.json for explicit bundle assignment
	local project_bundle
	project_bundle="$(_read_project_config_bundle "$project_path")"

	if [[ -n "$project_bundle" ]]; then
		local bundle_names
		IFS=',' read -ra bundle_names <<<"$project_bundle"
		if [[ ${#bundle_names[@]} -eq 1 ]]; then
			cmd_load "${bundle_names[0]}"
			return $?
		else
			cmd_compose "${bundle_names[@]}"
			return $?
		fi
	fi

	# 3. Auto-detect from markers
	local detected
	if [[ -n "$force_flag" ]]; then
		detected=$(cmd_detect "$project_path" --force 2>/dev/null) || true
	else
		detected=$(cmd_detect "$project_path" 2>/dev/null) || true
	fi

	if [[ -n "$detected" ]]; then
		local detected_array
		mapfile -t detected_array <<<"$detected"

		if [[ ${#detected_array[@]} -eq 1 ]]; then
			cmd_load "${detected_array[0]}"
			return $?
		else
			# Multiple matches: compose them
			print_info "Multiple bundles detected: ${detected_array[*]}. Composing." >&2
			cmd_compose "${detected_array[@]}"
			return $?
		fi
	fi

	# 4. Fallback to cli-tool (most conservative)
	print_info "No bundle detected for ${project_path}. Using fallback: ${FALLBACK_BUNDLE}" >&2
	cmd_load "$FALLBACK_BUNDLE"
	return $?
}

# Show a human-readable summary of the resolved bundle for a project.
# Arguments:
#   $1 - project path (defaults to current directory)
#   --force - force re-detection
# Output: formatted summary to stdout
# Returns: 0
cmd_show() {
	local project_path=""
	local force_flag=""

	# Parse arguments
	while [[ $# -gt 0 ]]; do
		case "$1" in
		--force)
			force_flag="--force"
			shift
			;;
		*)
			project_path="$1"
			shift
			;;
		esac
	done

	local resolved_path
	resolved_path="$(_resolve_project_path "${project_path:-.}")" || return 1

	# Determine resolution source for display
	local source="unknown"
	local explicit_bundle
	explicit_bundle="$(_lookup_repos_json_bundle "$resolved_path")"
	if [[ -n "$explicit_bundle" ]]; then
		source="repos.json (explicit)"
	else
		local project_bundle
		project_bundle="$(_read_project_config_bundle "$resolved_path")"
		if [[ -n "$project_bundle" ]]; then
			source=".aidevops.json (explicit)"
		else
			local detected
			if [[ -n "$force_flag" ]]; then
				detected=$(cmd_detect "$resolved_path" --force 2>/dev/null) || true
			else
				detected=$(cmd_detect "$resolved_path" 2>/dev/null) || true
			fi
			if [[ -n "$detected" ]]; then
				source="auto-detected"
			else
				source="fallback (${FALLBACK_BUNDLE})"
			fi
		fi
	fi

	# Resolve the bundle
	local resolved
	if [[ -n "$force_flag" ]]; then
		resolved=$(cmd_resolve "$resolved_path" --force 2>/dev/null) || {
			print_error "Could not resolve bundle for ${resolved_path}"
			return 1
		}
	else
		resolved=$(cmd_resolve "$resolved_path" 2>/dev/null) || {
			print_error "Could not resolve bundle for ${resolved_path}"
			return 1
		}
	fi

	# Format output
	local name description
	name=$(echo "$resolved" | jq -r '.name // "unknown"')
	description=$(echo "$resolved" | jq -r '.description // "No description"')

	echo "Bundle Summary for: ${resolved_path}"
	echo "============================================================"
	echo ""
	printf "  %-20s %s\n" "Name:" "$name"
	printf "  %-20s %s\n" "Source:" "$source"
	printf "  %-20s %s\n" "Description:" "$description"
	echo ""

	echo "  Model Defaults:"
	echo "$resolved" | jq -r '.model_defaults | to_entries[] | "    \(.key): \(.value)"' 2>/dev/null || true
	echo ""

	echo "  Quality Gates:"
	echo "$resolved" | jq -r '.quality_gates[]? // empty' 2>/dev/null | while IFS= read -r gate; do
		echo "    + ${gate}"
	done
	echo ""

	local skip_gates
	skip_gates=$(echo "$resolved" | jq -r '.skip_gates[]? // empty' 2>/dev/null)
	if [[ -n "$skip_gates" ]]; then
		echo "  Skip Gates:"
		echo "$skip_gates" | while IFS= read -r gate; do
			echo "    - ${gate}"
		done
		echo ""
	fi

	echo "  Agent Routing:"
	echo "$resolved" | jq -r '.agent_routing | to_entries[]? | "    \(.key) -> \(.value)"' 2>/dev/null || true
	echo ""

	echo "  Dispatch:"
	local max_workers timeout auto_dispatch
	max_workers=$(echo "$resolved" | jq -r '.dispatch.max_concurrent_workers // "3"')
	timeout=$(echo "$resolved" | jq -r '.dispatch.default_timeout_minutes // "30"')
	auto_dispatch=$(echo "$resolved" | jq -r '.dispatch.auto_dispatch // "true"')
	printf "    %-28s %s\n" "max_concurrent_workers:" "$max_workers"
	printf "    %-28s %s\n" "default_timeout_minutes:" "$timeout"
	printf "    %-28s %s\n" "auto_dispatch:" "$auto_dispatch"
	echo ""

	local tools
	tools=$(echo "$resolved" | jq -r '.tool_allowlist[]? // empty' 2>/dev/null)
	if [[ -n "$tools" ]]; then
		echo "  Tool Allowlist:"
		echo "$tools" | while IFS= read -r tool; do
			echo "    * ${tool}"
		done
		echo ""
	fi

	return 0
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

		# Check markers array exists (needed for auto-detection)
		local has_markers
		has_markers=$(jq -e '.markers | type == "array" and length > 0' "$bundle_file" 2>/dev/null) || true
		if [[ "$has_markers" != "true" ]]; then
			print_warning "${bn}: No markers defined (auto-detection will not work)"
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
Bundle Helper - Detect, resolve, and query project bundle presets

USAGE:
    bundle-helper.sh <command> [options]

COMMANDS:
    detect [path] [--force]  Auto-detect bundle from project marker files
    resolve [path] [--force] Resolve effective bundle (priority chain)
    show [path] [--force]    Human-readable bundle summary
    list                     List all available bundles
    validate [name]          Validate bundle(s) against schema
    load <name>              Load a single bundle by name
    get <field> [path]       Get a specific field from resolved bundle
    compose <b1> <b2> ...    Compose multiple bundles into one
    help                     Show this help

OPTIONS:
    --force                  Skip detection cache, re-scan marker files

RESOLUTION PRIORITY CHAIN:
    1. repos.json "bundle" field (explicit per-repo assignment)
    2. .aidevops.json "bundle" field (per-project config)
    3. Auto-detection from marker files in the project directory
    4. Fallback: cli-tool (most conservative bundle)

FIELD EXAMPLES (for 'get' command):
    model_defaults.implementation    Primary model tier for code changes
    model_defaults.review            Model tier for code review
    quality_gates                    Array of quality checks to run
    dispatch.max_concurrent_workers  Max parallel workers

COMPOSITION RULES:
    model_defaults   Most-restrictive (highest) tier wins per task type
    quality_gates    Union of all gates from all bundles
    skip_gates       Union of all skip gates
    agent_routing    Later bundles override earlier ones
    dispatch         Most-restrictive values (lowest concurrency, shortest timeout)
    tool_allowlist   Union of all tools

INTEGRATION API:
    Source this script with --source-only to use functions in other scripts:

    source bundle-helper.sh --source-only
    config=$(get_bundle_config ~/Git/my-app)
    gates=$(get_quality_gates ~/Git/my-app)
    tier=$(get_model_default "implementation" ~/Git/my-app)
    if should_skip_gate "shellcheck" ~/Git/my-app; then echo "skip"; fi

EXAMPLES:
    # List available bundles
    bundle-helper.sh list

    # Show bundle for current project
    bundle-helper.sh show .

    # Auto-detect bundle for a project
    bundle-helper.sh detect ~/Git/my-nextjs-app

    # Force re-detection (skip cache)
    bundle-helper.sh detect ~/Git/my-app --force

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
# Integration API Functions
# =============================================================================
# These functions are designed to be sourced by other scripts:
#   source "$(dirname "$0")/bundle-helper.sh" --source-only
#
# They handle bundles directory resolution internally and provide a clean
# interface for querying bundle configuration.
# =============================================================================

# Get the full resolved bundle configuration for a project.
# Arguments:
#   $1 - project path (defaults to current directory)
# Output: full bundle JSON to stdout
# Returns: 0 on success, 1 on error
get_bundle_config() {
	local project_path="${1:-.}"

	# Ensure bundles dir is resolved
	if [[ -z "$BUNDLES_DIR" ]]; then
		_resolve_bundles_dir || return 1
	fi

	cmd_resolve "$project_path"
}

# Get the quality gates array for a project.
# Arguments:
#   $1 - project path (defaults to current directory)
# Output: newline-separated list of quality gate names
# Returns: 0 on success, 1 on error
get_quality_gates() {
	local project_path="${1:-.}"

	# Ensure bundles dir is resolved
	if [[ -z "$BUNDLES_DIR" ]]; then
		_resolve_bundles_dir || return 1
	fi

	local resolved
	resolved=$(cmd_resolve "$project_path" 2>/dev/null) || {
		return 1
	}

	echo "$resolved" | jq -r '.quality_gates[]? // empty' 2>/dev/null
}

# Get the model default tier for a specific task type.
# Arguments:
#   $1 - task type (e.g., "implementation", "review", "triage")
#   $2 - project path (defaults to current directory)
# Output: model tier name (e.g., "sonnet", "opus") to stdout
# Returns: 0 on success, 1 if not found
get_model_default() {
	local task_type="$1"
	local project_path="${2:-.}"

	if [[ -z "$task_type" ]]; then
		print_error "Task type is required (e.g., implementation, review, triage)"
		return 1
	fi

	# Ensure bundles dir is resolved
	if [[ -z "$BUNDLES_DIR" ]]; then
		_resolve_bundles_dir || return 1
	fi

	local resolved
	resolved=$(cmd_resolve "$project_path" 2>/dev/null) || {
		return 1
	}

	local tier
	tier=$(echo "$resolved" | jq -r --arg task "$task_type" '.model_defaults[$task] // empty' 2>/dev/null) || true

	if [[ -z "$tier" ]]; then
		return 1
	fi

	echo "$tier"
	return 0
}

# Check if a quality gate should be skipped for a project.
# A gate should be skipped if it appears in skip_gates but not in quality_gates,
# or if it's not relevant to the resolved bundle.
# Arguments:
#   $1 - gate name (e.g., "shellcheck", "eslint")
#   $2 - project path (defaults to current directory)
# Returns: 0 if gate should be skipped, 1 if gate should run
should_skip_gate() {
	local gate_name="$1"
	local project_path="${2:-.}"

	if [[ -z "$gate_name" ]]; then
		print_error "Gate name is required"
		return 1
	fi

	# Ensure bundles dir is resolved
	if [[ -z "$BUNDLES_DIR" ]]; then
		_resolve_bundles_dir || return 1
	fi

	local resolved
	resolved=$(cmd_resolve "$project_path" 2>/dev/null) || {
		# No bundle resolved — don't skip anything
		return 1
	}

	# Skip a gate only if it is in skip_gates AND not in quality_gates.
	# quality_gates takes precedence — if a gate appears in both, it should run.
	local should_skip
	should_skip=$(echo "$resolved" | jq -r --arg gate "$gate_name" \
		'(([.skip_gates[]?] | index($gate)) != null) and (([.quality_gates[]?] | index($gate)) == null)' \
		2>/dev/null) || true

	if [[ "$should_skip" == "true" ]]; then
		return 0
	fi

	# Gate is not skippable (either not in skip_gates, or overridden by quality_gates)
	return 1
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
		cmd_detect "$@"
		;;
	resolve)
		cmd_resolve "$@"
		;;
	show)
		cmd_show "$@"
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

# Only run main() when executed directly, not when sourced with --source-only
if [[ "$_BUNDLE_HELPER_SOURCE_ONLY" == "false" ]]; then
	main "$@"
fi
