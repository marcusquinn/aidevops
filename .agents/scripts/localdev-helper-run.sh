#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# =============================================================================
# localdev-helper-run.sh -- Zero-config dev server wrapper (cmd_run)
# =============================================================================
# Wraps a dev command (e.g., npm run dev) with automatic:
#   1. Project registration (if not already registered)
#   2. Port resolution (main or branch)
#   3. PORT/HOST env var injection
#   4. Signal passthrough (SIGINT/SIGTERM forwarded to child)
#
# Usage: source "${SCRIPT_DIR}/localdev-helper-run.sh"
#
# Dependencies:
#   - shared-constants.sh (print_error, print_info, print_success, print_warning)
#   - localdev-helper-ports.sh (infer_project_name, is_app_registered, get_app_port)
#   - localdev-helper-branch.sh (sanitise_branch_name, is_branch_registered, get_branch_port, cmd_branch)
#   - cmd_add() from localdev-helper.sh orchestrator
#
# Part of aidevops framework: https://aidevops.sh

# Apply strict mode only when executed directly (not when sourced)
[[ "${BASH_SOURCE[0]}" == "${0}" ]] && set -euo pipefail

# Include guard
[[ -n "${_LOCALDEV_RUN_LIB_LOADED:-}" ]] && return 0
_LOCALDEV_RUN_LIB_LOADED=1

# Defensive SCRIPT_DIR fallback (caller may not set it)
if [[ -z "${SCRIPT_DIR:-}" ]]; then
	_lib_path="${BASH_SOURCE[0]%/*}"
	[[ "$_lib_path" == "${BASH_SOURCE[0]}" ]] && _lib_path="."
	SCRIPT_DIR="$(cd "$_lib_path" && pwd)"
	unset _lib_path
fi

# =============================================================================
# Run Command — Zero-config dev server wrapper
# =============================================================================

# Parse cmd_run options; sets name_override, port_override, set_host, cmd_args via caller's locals
_cmd_run_parse_args() {
	while [[ $# -gt 0 ]]; do
		local arg="$1"
		case "$arg" in
		--name)
			name_override="${2:-}"
			if [[ -z "$name_override" ]]; then
				print_error "Usage: localdev run --name <name> <command...>"
				return 1
			fi
			shift 2
			;;
		--port)
			port_override="${2:-}"
			if [[ ! "$port_override" =~ ^[0-9]+$ ]]; then
				print_error "Invalid port: ${port_override:-<empty>} (must be numeric)"
				return 1
			fi
			shift 2
			;;
		--no-host)
			set_host=0
			shift
			;;
		--)
			shift
			cmd_args+=("$@")
			break
			;;
		-*)
			print_error "Unknown option: $arg"
			print_info "Usage: localdev run [--name <name>] [--port <port>] [--no-host] <command...>"
			return 1
			;;
		*)
			cmd_args+=("$@")
			break
			;;
		esac
	done
	return 0
}

# Print cmd_run usage and return 1
_cmd_run_usage() {
	print_error "Usage: localdev run [options] <command...>"
	print_info ""
	print_info "Wraps a dev command with automatic project registration and port injection."
	print_info ""
	print_info "Examples:"
	print_info "  localdev run npm run dev"
	print_info "  localdev run --name myapp pnpm dev"
	print_info "  localdev run bun run dev"
	print_info ""
	print_info "Options:"
	print_info "  --name <name>   Override inferred project name"
	print_info "  --port <port>   Override auto-assigned port"
	print_info "  --no-host       Don't set HOST=0.0.0.0"
	return 1
}

# Resolve the project name for cmd_run; outputs name to stdout
_cmd_run_resolve_name() {
	local name_override="$1"
	local name=""
	if [[ -n "$name_override" ]]; then
		# Sanitise: lowercase, replace non-alphanumeric with hyphens, collapse, trim
		name="$(echo "$name_override" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9-]/-/g; s/--*/-/g; s/^-//; s/-$//')"
		if [[ -z "$name" ]]; then
			print_error "Invalid project name after sanitisation: $name_override"
			return 1
		fi
	else
		name="$(infer_project_name ".")" || {
			print_error "Cannot infer project name from current directory"
			print_info "  Use --name <name> to specify explicitly"
			return 1
		}
	fi
	echo "$name"
	return 0
}

# Detect worktree/branch context; outputs "is_worktree branch_name is_feature_branch" (tab-separated)
_cmd_run_detect_worktree() {
	local is_worktree=0
	local branch_name=""
	local is_feature_branch=0
	if [[ -f ".git" ]]; then
		is_worktree=1
		branch_name="$(git rev-parse --abbrev-ref HEAD 2>/dev/null)"
		if [[ -n "$branch_name" ]] && [[ "$branch_name" != "main" ]] && [[ "$branch_name" != "master" ]]; then
			is_feature_branch=1
		fi
	fi
	printf '%s\t%s\t%s\n' "$is_worktree" "$branch_name" "$is_feature_branch"
	return 0
}

# Resolve the port for cmd_run; outputs port to stdout
_cmd_run_resolve_port() {
	local name="$1"
	local port_override="$2"
	local is_feature_branch="$3"
	local branch_name="$4"

	local port=""
	if [[ -n "$port_override" ]]; then
		port="$port_override"
	elif [[ "$is_feature_branch" -eq 1 ]]; then
		local sanitised_branch
		sanitised_branch="$(sanitise_branch_name "$branch_name")"
		if is_branch_registered "$name" "$sanitised_branch"; then
			port="$(get_branch_port "$name" "$sanitised_branch")"
			print_info "Using branch port: $port (${sanitised_branch}.${name}.local)"
		else
			print_info "Creating branch route for $sanitised_branch..."
			cmd_branch "$name" "$branch_name"
			port="$(get_branch_port "$name" "$sanitised_branch")"
			if [[ -z "$port" ]]; then
				port="$(get_app_port "$name")"
				print_warning "Branch route creation failed — using main port: $port"
			else
				print_info "Using branch port: $port (${sanitised_branch}.${name}.local)"
			fi
		fi
	else
		port="$(get_app_port "$name")"
	fi

	if [[ -z "$port" ]]; then
		print_error "Cannot determine port for '$name'"
		return 1
	fi
	echo "$port"
	return 0
}

cmd_run() {
	local name_override=""
	local port_override=""
	local set_host=1
	local cmd_args=()

	# Step 0: Parse options
	_cmd_run_parse_args "$@" || return 1
	# Rebuild positional args from cmd_args (populated by _cmd_run_parse_args via caller scope)
	set -- "${cmd_args[@]+"${cmd_args[@]}"}"

	if [[ ${#cmd_args[@]} -eq 0 ]]; then
		_cmd_run_usage
		return 1
	fi

	# Step 1: Determine project name
	local name
	name="$(_cmd_run_resolve_name "$name_override")" || return 1

	# Step 2: Detect worktree/branch context
	local worktree_info is_worktree branch_name is_feature_branch
	worktree_info="$(_cmd_run_detect_worktree)"
	is_worktree="$(echo "$worktree_info" | cut -f1)"
	branch_name="$(echo "$worktree_info" | cut -f2)"
	is_feature_branch="$(echo "$worktree_info" | cut -f3)"

	# Step 3: Auto-register if not already registered
	if ! is_app_registered "$name"; then
		print_info "Project '$name' not registered — auto-registering..."
		echo ""

		if [[ -n "$port_override" ]]; then
			cmd_add "$name" "$port_override"
		else
			cmd_add "$name"
		fi

		local add_exit=$?
		if [[ "$add_exit" -ne 0 ]]; then
			print_error "Auto-registration failed for '$name'"
			return 1
		fi
		echo ""
	fi

	# Step 4: Resolve the correct port
	local port
	port="$(_cmd_run_resolve_port "$name" "$port_override" "$is_feature_branch" "$branch_name")" || return 1

	# Step 5: Build the environment and exec
	local domain="${name}.local"
	if [[ "$is_feature_branch" -eq 1 ]]; then
		local sanitised
		sanitised="$(sanitise_branch_name "$branch_name")"
		domain="${sanitised}.${name}.local"
	fi

	echo ""
	print_success "localdev run: $name"
	print_info "  URL:     https://$domain"
	print_info "  PORT:    $port"
	if [[ "$set_host" -eq 1 ]]; then
		print_info "  HOST:    0.0.0.0"
	fi
	print_info "  Command: ${cmd_args[*]}"
	echo ""

	# Export PORT and optionally HOST, then exec the command
	# exec replaces this process — signals go directly to the child
	export PORT="$port"
	if [[ "$set_host" -eq 1 ]]; then
		export HOST="0.0.0.0"
	fi

	exec "${cmd_args[@]}"
}
