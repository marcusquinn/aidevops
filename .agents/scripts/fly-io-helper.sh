#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

# Fly.io Helper Script
# Wrapper around flyctl CLI for common deployment and management operations
# Managed by AI DevOps Framework
#
# Usage: fly-io-helper.sh <command> [app] [args...]
# Commands: deploy, scale, status, secrets, volumes, logs, apps, ssh, destroy
# Bash 3.2 compatible (macOS default shell)

set -euo pipefail

# ------------------------------------------------------------------------------
# CONFIGURATION & CONSTANTS
# ------------------------------------------------------------------------------

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=shared-constants.sh
source "${script_dir}/shared-constants.sh"

readonly SCRIPT_DIR="$script_dir"
_script_name="$(basename "$0")"
readonly SCRIPT_NAME="$_script_name"

# Error messages
readonly ERROR_FLY_NOT_INSTALLED="flyctl (fly) is not installed"
readonly ERROR_APP_NAME_REQUIRED="App name is required"
readonly ERROR_FLY_NOT_AUTHENTICATED="Not authenticated with Fly.io. Run: fly auth login"

# ------------------------------------------------------------------------------
# DEPENDENCY CHECKS
# ------------------------------------------------------------------------------

get_fly_cmd() {
	if command -v fly &>/dev/null; then
		printf '%s' "fly"
		return 0
	fi
	if command -v flyctl &>/dev/null; then
		printf '%s' "flyctl"
		return 0
	fi
	return 1
}

check_flyctl() {
	if ! get_fly_cmd >/dev/null 2>&1; then
		print_error "$ERROR_FLY_NOT_INSTALLED"
		print_info "Install: curl -L https://fly.io/install.sh | sh"
		print_info "Or: brew install flyctl"
		return 1
	fi
	return 0
}

check_auth() {
	local fly_cmd="$1"

	if ! "$fly_cmd" auth whoami >/dev/null 2>&1; then
		print_error "$ERROR_FLY_NOT_AUTHENTICATED"
		return 1
	fi
	return 0
}

require_app() {
	local app_name="$1"

	if [[ -z "$app_name" ]]; then
		print_error "$ERROR_APP_NAME_REQUIRED"
		print_info "Usage: $SCRIPT_NAME <command> <app-name> [args...]"
		return 1
	fi
	return 0
}

# ------------------------------------------------------------------------------
# SUBCOMMANDS
# ------------------------------------------------------------------------------

cmd_deploy() {
	local fly_cmd="$1"
	local app="$2"
	shift 2

	require_app "$app" || return 1

	print_info "Deploying app: $app"

	if [[ $# -gt 0 ]]; then
		"$fly_cmd" deploy --app "$app" "$@"
	else
		"$fly_cmd" deploy --app "$app"
	fi
	local rc=$?

	if [[ $rc -eq 0 ]]; then
		print_success "Deploy completed: $app"
	else
		print_error "Deploy failed: $app (exit $rc)"
	fi
	return $rc
}

_scale_numeric() {
	local fly_cmd="$1"
	local app="$2"
	local count="$3"
	shift 3

	print_info "Scaling app: $app to $count machines"
	if [[ $# -gt 0 ]]; then
		"$fly_cmd" scale count "$count" --app "$app" "$@"
	else
		"$fly_cmd" scale count "$count" --app "$app"
	fi
	return $?
}

cmd_scale() {
	local fly_cmd="$1"
	local app="$2"
	shift 2

	require_app "$app" || return 1

	if [[ $# -eq 0 ]]; then
		print_info "Current scale, app: $app"
		"$fly_cmd" scale show --app "$app"
		return $?
	fi

	local first_arg="$1"

	case "$first_arg" in
	count | vm | memory | show)
		"$fly_cmd" scale "$@" --app "$app"
		return $?
		;;
	*)
		if [[ "$first_arg" =~ ^[0-9]+$ ]]; then
			shift
			_scale_numeric "$fly_cmd" "$app" "$first_arg" "$@"
			return $?
		fi
		"$fly_cmd" scale "$@" --app "$app"
		return $?
		;;
	esac
}

cmd_status() {
	local fly_cmd="$1"
	local app="$2"
	shift 2

	require_app "$app" || return 1

	print_info "Status, app: $app"
	"$fly_cmd" status --app "$app"
	echo ""
	print_info "Machines:"
	"$fly_cmd" machines list --app "$app"
	return $?
}

_secrets_list() {
	local fly_cmd="$1"
	local app="$2"

	print_info "Secrets (names only — values never shown), app: $app"
	"$fly_cmd" secrets list --app "$app"
	return $?
}

_secrets_set() {
	local fly_cmd="$1"
	local app="$2"
	shift 2

	if [[ $# -eq 0 ]]; then
		print_error "Secret NAME=VALUE pair required"
		print_info "Usage: echo 'value' | $SCRIPT_NAME secrets <app> set NAME=-"
		print_warning "Prefer piping values via stdin (NAME=-) to avoid shell history exposure"
		return 1
	fi
	"$fly_cmd" secrets set "$@" --app "$app"
	return $?
}

_secrets_unset() {
	local fly_cmd="$1"
	local app="$2"
	shift 2

	if [[ $# -eq 0 ]]; then
		print_error "Secret name required"
		print_info "Usage: $SCRIPT_NAME secrets <app> unset SECRET_NAME"
		return 1
	fi
	"$fly_cmd" secrets unset "$@" --app "$app"
	return $?
}

cmd_secrets() {
	local fly_cmd="$1"
	local app="$2"
	shift 2

	require_app "$app" || return 1

	if [[ $# -eq 0 ]]; then
		_secrets_list "$fly_cmd" "$app"
		return $?
	fi

	local action="$1"
	shift

	case "$action" in
	list)
		_secrets_list "$fly_cmd" "$app"
		return $?
		;;
	set)
		_secrets_set "$fly_cmd" "$app" "$@"
		return $?
		;;
	unset)
		_secrets_unset "$fly_cmd" "$app" "$@"
		return $?
		;;
	import)
		print_info "Importing secrets, app: $app"
		"$fly_cmd" secrets import --app "$app"
		return $?
		;;
	*)
		print_error "Unknown secrets action: $action"
		print_info "Available: list, set, unset, import"
		return 1
		;;
	esac
}

_volumes_create() {
	local fly_cmd="$1"
	local app="$2"
	shift 2

	if [[ $# -lt 1 ]]; then
		print_error "Volume name required"
		print_info "Usage: $SCRIPT_NAME volumes <app> create <name> [--size N] [--region REGION]"
		return 1
	fi
	print_info "Creating volume, app: $app"
	"$fly_cmd" volumes create "$@" --app "$app"
	return $?
}

_volumes_extend() {
	local fly_cmd="$1"
	local app="$2"
	shift 2

	if [[ $# -lt 1 ]]; then
		print_error "Volume ID required"
		print_info "Usage: $SCRIPT_NAME volumes <app> extend <volume-id> --size N"
		return 1
	fi
	print_info "Extending volume, app: $app"
	"$fly_cmd" volumes extend "$@" --app "$app"
	return $?
}

_volumes_destroy() {
	local fly_cmd="$1"
	local app="$2"
	shift 2

	if [[ $# -lt 1 ]]; then
		print_error "Volume ID required"
		print_info "Usage: $SCRIPT_NAME volumes <app> destroy <volume-id>"
		return 1
	fi
	print_warning "IRREVERSIBLE: Destroying volume $1 on $app"
	"$fly_cmd" volumes destroy "$@" --app "$app"
	return $?
}

cmd_volumes() {
	local fly_cmd="$1"
	local app="$2"
	shift 2

	require_app "$app" || return 1

	if [[ $# -eq 0 ]]; then
		print_info "Volumes, app: $app"
		"$fly_cmd" volumes list --app "$app"
		return $?
	fi

	local action="$1"
	shift

	case "$action" in
	list)
		print_info "Volumes, app: $app"
		"$fly_cmd" volumes list --app "$app"
		return $?
		;;
	create)
		_volumes_create "$fly_cmd" "$app" "$@"
		return $?
		;;
	extend)
		_volumes_extend "$fly_cmd" "$app" "$@"
		return $?
		;;
	destroy)
		_volumes_destroy "$fly_cmd" "$app" "$@"
		return $?
		;;
	*)
		print_error "Unknown volumes action: $action"
		print_info "Available: list, create, extend, destroy"
		return 1
		;;
	esac
}

cmd_logs() {
	local fly_cmd="$1"
	local app="$2"
	shift 2

	require_app "$app" || return 1

	print_info "Logs, app: $app"
	if [[ $# -gt 0 ]]; then
		"$fly_cmd" logs --app "$app" "$@"
	else
		"$fly_cmd" logs --app "$app"
	fi
	return $?
}

cmd_apps() {
	local fly_cmd="$1"
	shift

	print_info "Fly.io apps:"
	if [[ $# -gt 0 ]]; then
		"$fly_cmd" apps list "$@"
	else
		"$fly_cmd" apps list
	fi
	return $?
}

_ssh_console() {
	local fly_cmd="$1"
	local app="$2"
	shift 2

	print_info "Opening SSH console, app: $app"
	if [[ $# -gt 0 ]]; then
		"$fly_cmd" ssh console --app "$app" "$@"
	else
		"$fly_cmd" ssh console --app "$app"
	fi
	return $?
}

_ssh_sftp() {
	local fly_cmd="$1"
	local app="$2"
	shift 2

	print_info "Opening SFTP session, app: $app"
	if [[ $# -gt 0 ]]; then
		"$fly_cmd" ssh sftp "$@" --app "$app"
	else
		"$fly_cmd" ssh sftp shell --app "$app"
	fi
	return $?
}

cmd_ssh() {
	local fly_cmd="$1"
	local app="$2"
	shift 2

	require_app "$app" || return 1

	if [[ $# -eq 0 ]]; then
		_ssh_console "$fly_cmd" "$app"
		return $?
	fi

	local action="$1"
	shift

	case "$action" in
	console)
		_ssh_console "$fly_cmd" "$app" "$@"
		return $?
		;;
	sftp)
		_ssh_sftp "$fly_cmd" "$app" "$@"
		return $?
		;;
	issue)
		print_info "Issuing SSH certificate, app: $app"
		"$fly_cmd" ssh issue --app "$app" "$@"
		return $?
		;;
	*)
		print_error "Unknown ssh action: $action"
		print_info "Available: console, sftp, issue"
		return 1
		;;
	esac
}

_parse_destroy_flags() {
	local confirmed_var="$1"
	shift

	local confirmed="false"
	local extra_args=()
	while [[ $# -gt 0 ]]; do
		case "$1" in
		--yes | -y)
			confirmed="true"
			;;
		*)
			extra_args+=("$1")
			;;
		esac
		shift
	done

	# Export results via global-style variables (Bash 3.2 compatible)
	_DESTROY_CONFIRMED="$confirmed"
	_DESTROY_EXTRA_ARGS=("${extra_args[@]+"${extra_args[@]}"}")
	return 0
}

cmd_destroy() {
	local fly_cmd="$1"
	local app="$2"
	shift 2

	require_app "$app" || return 1

	print_warning "IRREVERSIBLE: This will permanently destroy app '$app' and all its data."
	print_warning "All machines, volumes, and configuration will be deleted."

	_DESTROY_CONFIRMED="false"
	_DESTROY_EXTRA_ARGS=()
	_parse_destroy_flags "confirmed" "$@"

	if [[ "$_DESTROY_CONFIRMED" != "true" ]]; then
		print_error "Confirmation required. Re-run with --yes to confirm destruction of '$app'."
		print_info "Usage: $SCRIPT_NAME destroy $app --yes"
		return 1
	fi

	print_info "Destroying app: $app"
	if [[ ${#_DESTROY_EXTRA_ARGS[@]} -gt 0 ]]; then
		"$fly_cmd" apps destroy "$app" --yes "${_DESTROY_EXTRA_ARGS[@]}"
	else
		"$fly_cmd" apps destroy "$app" --yes
	fi
	local rc=$?

	if [[ $rc -eq 0 ]]; then
		print_success "App '$app' destroyed"
	else
		print_error "Destroy failed: '$app' (exit $rc)"
	fi
	return $rc
}

# ------------------------------------------------------------------------------
# HELP
# ------------------------------------------------------------------------------

show_help() {
	cat <<EOF
$HELP_LABEL_USAGE
  $SCRIPT_NAME <command> [app] [args...]

$HELP_LABEL_COMMANDS
  deploy  <app> [flags]                              Deploy app (wraps fly deploy)
  scale   <app> [count|vm|memory|show] [args]        Scale machines or show current scale
  status  <app>                                       Show app health and machine status
  secrets <app> [list|set|unset|import] [args]        Manage secrets (names only — values never shown)
  volumes <app> [list|create|extend|destroy] [args]   Manage persistent volumes
  logs    <app> [flags]                               Show recent logs
  ssh     <app> [console|sftp|issue] [args]           SSH into app machines
  destroy <app> --yes                                 Permanently destroy app (irreversible)
  apps    [flags]                                     List all Fly.io apps
  help                                                Show this help

$HELP_LABEL_EXAMPLES
  $SCRIPT_NAME deploy my-app
  $SCRIPT_NAME deploy my-app --strategy rolling
  $SCRIPT_NAME scale my-app 3
  $SCRIPT_NAME scale my-app vm performance-2x
  $SCRIPT_NAME scale my-app memory 1024
  $SCRIPT_NAME status my-app
  $SCRIPT_NAME secrets my-app
  $SCRIPT_NAME secrets my-app set NAME=- < <(echo "value")
  $SCRIPT_NAME secrets my-app unset OLD_SECRET
  $SCRIPT_NAME volumes my-app
  $SCRIPT_NAME volumes my-app create data_vol --size 10 --region lhr
  $SCRIPT_NAME volumes my-app extend vol_abc123 --size 20
  $SCRIPT_NAME logs my-app
  $SCRIPT_NAME logs my-app --region lhr
  $SCRIPT_NAME ssh my-app
  $SCRIPT_NAME ssh my-app console --command "/bin/sh"
  $SCRIPT_NAME destroy my-app --yes
  $SCRIPT_NAME apps
EOF
	return 0
}

# ------------------------------------------------------------------------------
# MAIN
# ------------------------------------------------------------------------------

_dispatch_command() {
	local fly_cmd="$1"
	local command="$2"
	shift 2

	case "$command" in
	apps)
		cmd_apps "$fly_cmd" "$@"
		return $?
		;;
	deploy | scale | status | secrets | volumes | logs | ssh | destroy)
		local app_name="${1:-}"
		shift || true
		"cmd_${command}" "$fly_cmd" "$app_name" "$@"
		return $?
		;;
	esac
	return 1
}

main() {
	local command="${1:-help}"
	shift || true

	if [[ "$command" == "help" || "$command" == "-h" || "$command" == "--help" ]]; then
		show_help
		return 0
	fi

	check_flyctl || return 1

	local fly_cmd
	fly_cmd="$(get_fly_cmd)" || return 1

	case "$command" in
	deploy | scale | status | secrets | volumes | logs | ssh | destroy | apps)
		check_auth "$fly_cmd" || return 1
		;;
	*)
		print_error "$ERROR_UNKNOWN_COMMAND: $command"
		show_help
		return 1
		;;
	esac

	_dispatch_command "$fly_cmd" "$command" "$@"
	return $?
}

main "$@"
