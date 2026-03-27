#!/usr/bin/env bash

# Fly.io Helper Script
# Wrapper around flyctl CLI for common deployment and management operations
# Managed by AI DevOps Framework
#
# Usage: fly-io-helper.sh <command> [app] [args...]
# Commands: deploy, scale, status, secrets, volumes, logs, apps
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
		print_success "Deploy completed for $app"
	else
		print_error "Deploy failed for $app (exit $rc)"
	fi
	return $rc
}

cmd_scale() {
	local fly_cmd="$1"
	local app="$2"
	shift 2

	require_app "$app" || return 1

	# No args: show current scale
	if [[ $# -eq 0 ]]; then
		print_info "Current scale for $app:"
		"$fly_cmd" scale show --app "$app"
		return $?
	fi

	local first_arg="$1"

	case "$first_arg" in
	count | vm | memory | show)
		# Pass through to fly scale <subcommand> ... --app
		"$fly_cmd" scale "$@" --app "$app"
		return $?
		;;
	*)
		# If first arg is a number, treat as shorthand for count
		if [[ "$first_arg" =~ ^[0-9]+$ ]]; then
			print_info "Scaling $app to $first_arg machines"
			shift
			if [[ $# -gt 0 ]]; then
				"$fly_cmd" scale count "$first_arg" --app "$app" "$@"
			else
				"$fly_cmd" scale count "$first_arg" --app "$app"
			fi
			return $?
		fi
		# Otherwise pass through
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

	print_info "Status for $app:"
	"$fly_cmd" status --app "$app"
	echo ""
	print_info "Machines:"
	"$fly_cmd" machines list --app "$app"
	return $?
}

cmd_secrets() {
	local fly_cmd="$1"
	local app="$2"
	shift 2

	require_app "$app" || return 1

	# Default: list secret names (never values)
	if [[ $# -eq 0 ]]; then
		print_info "Secrets for $app (names only — values never shown):"
		"$fly_cmd" secrets list --app "$app"
		return $?
	fi

	local action="$1"
	shift

	case "$action" in
	list)
		print_info "Secrets for $app (names only — values never shown):"
		"$fly_cmd" secrets list --app "$app"
		return $?
		;;
	set)
		if [[ $# -eq 0 ]]; then
			print_error "Secret NAME=VALUE pair required"
			print_info "Usage: echo 'value' | $SCRIPT_NAME secrets <app> set NAME=-"
			print_warning "Prefer piping values via stdin (NAME=-) to avoid shell history exposure"
			return 1
		fi
		"$fly_cmd" secrets set "$@" --app "$app"
		return $?
		;;
	unset)
		if [[ $# -eq 0 ]]; then
			print_error "Secret name required for unset"
			print_info "Usage: $SCRIPT_NAME secrets <app> unset SECRET_NAME"
			return 1
		fi
		"$fly_cmd" secrets unset "$@" --app "$app"
		return $?
		;;
	import)
		print_info "Importing secrets for $app from stdin"
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

cmd_volumes() {
	local fly_cmd="$1"
	local app="$2"
	shift 2

	require_app "$app" || return 1

	# Default: list volumes
	if [[ $# -eq 0 ]]; then
		print_info "Volumes for $app:"
		"$fly_cmd" volumes list --app "$app"
		return $?
	fi

	local action="$1"
	shift

	case "$action" in
	list)
		print_info "Volumes for $app:"
		"$fly_cmd" volumes list --app "$app"
		return $?
		;;
	create)
		if [[ $# -lt 1 ]]; then
			print_error "Volume name required"
			print_info "Usage: $SCRIPT_NAME volumes <app> create <name> [--size N] [--region REGION]"
			return 1
		fi
		print_info "Creating volume for $app"
		"$fly_cmd" volumes create "$@" --app "$app"
		return $?
		;;
	extend)
		if [[ $# -lt 1 ]]; then
			print_error "Volume ID required"
			print_info "Usage: $SCRIPT_NAME volumes <app> extend <volume-id> --size N"
			return 1
		fi
		print_info "Extending volume for $app"
		"$fly_cmd" volumes extend "$@" --app "$app"
		return $?
		;;
	destroy)
		if [[ $# -lt 1 ]]; then
			print_error "Volume ID required"
			print_info "Usage: $SCRIPT_NAME volumes <app> destroy <volume-id>"
			return 1
		fi
		print_warning "IRREVERSIBLE: Destroying volume $1 on $app"
		"$fly_cmd" volumes destroy "$@" --app "$app"
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

	print_info "Logs for $app:"
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

cmd_ssh() {
	local fly_cmd="$1"
	local app="$2"
	shift 2

	require_app "$app" || return 1

	# No args: open interactive SSH console
	if [[ $# -eq 0 ]]; then
		print_info "Opening SSH console for $app"
		"$fly_cmd" ssh console --app "$app"
		return $?
	fi

	local action="$1"
	shift

	case "$action" in
	console)
		print_info "Opening SSH console for $app"
		if [[ $# -gt 0 ]]; then
			"$fly_cmd" ssh console --app "$app" "$@"
		else
			"$fly_cmd" ssh console --app "$app"
		fi
		return $?
		;;
	sftp)
		print_info "Opening SFTP session for $app"
		if [[ $# -gt 0 ]]; then
			"$fly_cmd" ssh sftp "$@" --app "$app"
		else
			"$fly_cmd" ssh sftp shell --app "$app"
		fi
		return $?
		;;
	issue)
		print_info "Issuing SSH certificate for $app"
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

cmd_destroy() {
	local fly_cmd="$1"
	local app="$2"
	shift 2

	require_app "$app" || return 1

	print_warning "IRREVERSIBLE: This will permanently destroy app '$app' and all its data."
	print_warning "All machines, volumes, and configuration will be deleted."

	# Require explicit --yes flag to prevent accidental destruction
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

	if [[ "$confirmed" != "true" ]]; then
		print_error "Confirmation required. Re-run with --yes to confirm destruction of '$app'."
		print_info "Usage: $SCRIPT_NAME destroy $app --yes"
		return 1
	fi

	print_info "Destroying app: $app"
	if [[ ${#extra_args[@]} -gt 0 ]]; then
		"$fly_cmd" apps destroy "$app" --yes "${extra_args[@]}"
	else
		"$fly_cmd" apps destroy "$app" --yes
	fi
	local rc=$?

	if [[ $rc -eq 0 ]]; then
		print_success "App '$app' destroyed"
	else
		print_error "Destroy failed for '$app' (exit $rc)"
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

main() {
	local command="${1:-help}"
	shift || true

	# Help doesn't need flyctl
	if [[ "$command" == "help" || "$command" == "-h" || "$command" == "--help" ]]; then
		show_help
		return 0
	fi

	# Check flyctl is installed
	check_flyctl || return 1

	local fly_cmd
	fly_cmd="$(get_fly_cmd)" || return 1

	# Check auth for all operational commands
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

	# Dispatch to subcommand
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
}

main "$@"
