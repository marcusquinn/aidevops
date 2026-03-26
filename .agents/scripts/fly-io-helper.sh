#!/usr/bin/env bash
# fly-io-helper.sh — Fly.io deployment automation
# Managed by AI DevOps Framework
# Subcommands: deploy, scale, status, secrets, volumes, logs, apps, machines, ssh
# Usage: fly-io-helper.sh <command> [app] [args...]
# Bash 3.2 compatible (macOS default shell)

set -euo pipefail

# ------------------------------------------------------------------------------
# CONSTANTS
# ------------------------------------------------------------------------------

readonly SCRIPT_NAME="fly-io-helper.sh"
readonly FLY_CMD="fly"

# ------------------------------------------------------------------------------
# UTILITY FUNCTIONS
# ------------------------------------------------------------------------------

print_info() {
	local msg="$1"
	printf '[fly-io] %s\n' "$msg" >&2
	return 0
}

print_error() {
	local msg="$1"
	printf '[fly-io] ERROR: %s\n' "$msg" >&2
	return 0
}

print_usage() {
	cat >&2 <<'EOF'
fly-io-helper.sh — Fly.io deployment automation

Usage: fly-io-helper.sh <command> [app] [args...]

Commands:
  deploy   <app> [--image <img>] [--region <r>]  Deploy app (fly deploy)
  scale    <app> <count> [--region <r>]           Scale machine count
  status   <app>                                  Show app status and machines
  secrets  <app>                                  List secret names (never values)
  volumes  <app> [create <name> <size> <region>]  Manage persistent volumes
  logs     <app> [--region <r>]                   Stream recent logs
  apps     [--org <org>]                          List all apps
  machines <app> [list|start|stop] [machine-id]   Manage Fly Machines
  ssh      <app> [--command <cmd>]                SSH into a running machine
  postgres <cluster-app> [connect|status|list]    Manage Fly Postgres
  help                                            Show this help

Examples:
  fly-io-helper.sh deploy my-app
  fly-io-helper.sh scale my-app 3
  fly-io-helper.sh scale my-app 2 --region lhr
  fly-io-helper.sh status my-app
  fly-io-helper.sh secrets my-app
  fly-io-helper.sh volumes my-app
  fly-io-helper.sh volumes my-app create app_data 10 lhr
  fly-io-helper.sh logs my-app
  fly-io-helper.sh apps
  fly-io-helper.sh machines my-app list
  fly-io-helper.sh ssh my-app
  fly-io-helper.sh ssh my-app --command "env | cut -d= -f1"
  fly-io-helper.sh postgres my-db-app status
EOF
	return 0
}

# ------------------------------------------------------------------------------
# DEPENDENCY CHECK
# ------------------------------------------------------------------------------

check_flyctl() {
	if ! command -v "$FLY_CMD" >/dev/null 2>&1; then
		print_error "flyctl is not installed"
		print_info "Install: curl -L https://fly.io/install.sh | sh"
		print_info "Or: brew install flyctl"
		return 1
	fi
	return 0
}

check_auth() {
	if ! "$FLY_CMD" auth whoami >/dev/null 2>&1; then
		print_error "Not authenticated with Fly.io"
		print_info "Run: fly auth login"
		return 1
	fi
	return 0
}

require_app() {
	local app="$1"
	if [[ -z "$app" ]]; then
		print_error "App name required"
		print_usage
		return 1
	fi
	return 0
}

# ------------------------------------------------------------------------------
# COMMANDS
# ------------------------------------------------------------------------------

cmd_deploy() {
	local app="$1"
	shift
	require_app "$app" || return 1

	local extra_args=""
	local image=""
	local region=""

	while [[ $# -gt 0 ]]; do
		case "$1" in
		--image)
			image="$2"
			shift 2
			;;
		--region)
			region="$2"
			shift 2
			;;
		*)
			extra_args="$extra_args $1"
			shift
			;;
		esac
	done

	print_info "Deploying app: $app"

	local deploy_args="--app $app"
	if [[ -n "$image" ]]; then
		deploy_args="$deploy_args --image $image"
	fi
	if [[ -n "$region" ]]; then
		deploy_args="$deploy_args --region $region"
	fi

	# shellcheck disable=SC2086
	"$FLY_CMD" deploy $deploy_args $extra_args
	print_info "Deploy complete: $app"
	return 0
}

cmd_scale() {
	local app="$1"
	local count="${2:-}"
	shift 2 || shift 1

	require_app "$app" || return 1

	if [[ -z "$count" ]]; then
		print_error "Machine count required"
		print_info "Usage: fly-io-helper.sh scale <app> <count> [--region <r>]"
		return 1
	fi

	local region=""
	while [[ $# -gt 0 ]]; do
		case "$1" in
		--region)
			region="$2"
			shift 2
			;;
		*)
			shift
			;;
		esac
	done

	print_info "Scaling $app to $count machines${region:+ in $region}"

	if [[ -n "$region" ]]; then
		"$FLY_CMD" scale count "$count" --region "$region" --app "$app"
	else
		"$FLY_CMD" scale count "$count" --app "$app"
	fi

	print_info "Scale complete: $app ($count machines)"
	return 0
}

cmd_status() {
	local app="$1"
	require_app "$app" || return 1

	print_info "Status for: $app"
	"$FLY_CMD" status --app "$app"
	echo ""
	print_info "Machines:"
	"$FLY_CMD" machines list --app "$app"
	return 0
}

cmd_secrets() {
	local app="$1"
	require_app "$app" || return 1

	print_info "Secret names for: $app (values never shown)"
	"$FLY_CMD" secrets list --app "$app"
	print_info "To set a secret: echo 'value' | fly secrets set KEY=- --app $app"
	print_info "To import from file: fly secrets import --app $app < .env.production"
	return 0
}

cmd_volumes() {
	local app="$1"
	local subcommand="${2:-list}"
	shift 2 || shift 1

	require_app "$app" || return 1

	case "$subcommand" in
	list | "")
		print_info "Volumes for: $app"
		"$FLY_CMD" volumes list --app "$app"
		;;
	create)
		local vol_name="${1:-}"
		local vol_size="${2:-10}"
		local vol_region="${3:-}"

		if [[ -z "$vol_name" ]]; then
			print_error "Volume name required"
			print_info "Usage: fly-io-helper.sh volumes <app> create <name> <size-gb> <region>"
			return 1
		fi

		local create_args="$vol_name --size $vol_size --app $app"
		if [[ -n "$vol_region" ]]; then
			create_args="$create_args --region $vol_region"
		fi

		print_info "Creating volume: $vol_name (${vol_size}GB) for $app"
		# shellcheck disable=SC2086
		"$FLY_CMD" volumes create $create_args
		print_info "Volume created. Add to fly.toml:"
		printf '  [[mounts]]\n    source = "%s"\n    destination = "/data"\n' "$vol_name"
		;;
	extend)
		local vol_id="${1:-}"
		local new_size="${2:-}"

		if [[ -z "$vol_id" || -z "$new_size" ]]; then
			print_error "Volume ID and new size required"
			print_info "Usage: fly-io-helper.sh volumes <app> extend <volume-id> <new-size-gb>"
			return 1
		fi

		print_info "Extending volume $vol_id to ${new_size}GB"
		"$FLY_CMD" volumes extend "$vol_id" --size "$new_size" --app "$app"
		;;
	*)
		print_error "Unknown volumes subcommand: $subcommand"
		print_info "Valid: list, create, extend"
		return 1
		;;
	esac
	return 0
}

cmd_logs() {
	local app="$1"
	shift
	require_app "$app" || return 1

	local region=""
	while [[ $# -gt 0 ]]; do
		case "$1" in
		--region)
			region="$2"
			shift 2
			;;
		*)
			shift
			;;
		esac
	done

	print_info "Logs for: $app${region:+ (region: $region)}"

	if [[ -n "$region" ]]; then
		"$FLY_CMD" logs --app "$app" --region "$region"
	else
		"$FLY_CMD" logs --app "$app"
	fi
	return 0
}

cmd_apps() {
	local org=""
	while [[ $# -gt 0 ]]; do
		case "$1" in
		--org)
			org="$2"
			shift 2
			;;
		*)
			shift
			;;
		esac
	done

	print_info "Listing apps${org:+ for org: $org}"

	if [[ -n "$org" ]]; then
		"$FLY_CMD" apps list --org "$org"
	else
		"$FLY_CMD" apps list
	fi
	return 0
}

cmd_machines() {
	local app="$1"
	local subcommand="${2:-list}"
	local machine_id="${3:-}"

	require_app "$app" || return 1

	case "$subcommand" in
	list | "")
		print_info "Machines for: $app"
		"$FLY_CMD" machines list --app "$app"
		;;
	start)
		if [[ -z "$machine_id" ]]; then
			print_error "Machine ID required for start"
			print_info "Usage: fly-io-helper.sh machines <app> start <machine-id>"
			return 1
		fi
		print_info "Starting machine: $machine_id"
		"$FLY_CMD" machines start "$machine_id" --app "$app"
		;;
	stop)
		if [[ -z "$machine_id" ]]; then
			print_error "Machine ID required for stop"
			print_info "Usage: fly-io-helper.sh machines <app> stop <machine-id>"
			return 1
		fi
		print_info "Stopping machine: $machine_id"
		"$FLY_CMD" machines stop "$machine_id" --app "$app"
		;;
	destroy)
		if [[ -z "$machine_id" ]]; then
			print_error "Machine ID required for destroy"
			print_info "Usage: fly-io-helper.sh machines <app> destroy <machine-id>"
			return 1
		fi
		print_info "Destroying machine: $machine_id (IRREVERSIBLE)"
		"$FLY_CMD" machines destroy "$machine_id" --app "$app" --force
		;;
	*)
		print_error "Unknown machines subcommand: $subcommand"
		print_info "Valid: list, start, stop, destroy"
		return 1
		;;
	esac
	return 0
}

cmd_ssh() {
	local app="$1"
	shift
	require_app "$app" || return 1

	local ssh_command=""
	while [[ $# -gt 0 ]]; do
		case "$1" in
		--command)
			ssh_command="$2"
			shift 2
			;;
		*)
			shift
			;;
		esac
	done

	if [[ -n "$ssh_command" ]]; then
		print_info "Running command on $app: $ssh_command"
		"$FLY_CMD" ssh console --app "$app" --command "$ssh_command"
	else
		print_info "Opening SSH console for: $app"
		"$FLY_CMD" ssh console --app "$app"
	fi
	return 0
}

cmd_postgres() {
	local cluster_app="$1"
	local subcommand="${2:-status}"
	local db_name="${3:-}"

	require_app "$cluster_app" || return 1

	case "$subcommand" in
	status)
		print_info "Postgres cluster status: $cluster_app"
		"$FLY_CMD" status --app "$cluster_app"
		;;
	connect)
		print_info "Connecting to Postgres: $cluster_app"
		if [[ -n "$db_name" ]]; then
			"$FLY_CMD" postgres connect --app "$cluster_app" --database "$db_name"
		else
			"$FLY_CMD" postgres connect --app "$cluster_app"
		fi
		;;
	list)
		print_info "Databases in cluster: $cluster_app"
		"$FLY_CMD" postgres db list --app "$cluster_app"
		;;
	*)
		print_error "Unknown postgres subcommand: $subcommand"
		print_info "Valid: status, connect, list"
		return 1
		;;
	esac
	return 0
}

# ------------------------------------------------------------------------------
# MAIN
# ------------------------------------------------------------------------------

main() {
	local command="${1:-help}"
	shift || true

	case "$command" in
	help | -h | --help)
		print_usage
		return 0
		;;
	esac

	check_flyctl || return 1

	case "$command" in
	deploy)
		check_auth || return 1
		cmd_deploy "$@"
		;;
	scale)
		check_auth || return 1
		cmd_scale "$@"
		;;
	status)
		check_auth || return 1
		cmd_status "$@"
		;;
	secrets)
		check_auth || return 1
		cmd_secrets "$@"
		;;
	volumes)
		check_auth || return 1
		cmd_volumes "$@"
		;;
	logs)
		check_auth || return 1
		cmd_logs "$@"
		;;
	apps)
		check_auth || return 1
		cmd_apps "$@"
		;;
	machines)
		check_auth || return 1
		cmd_machines "$@"
		;;
	ssh)
		check_auth || return 1
		cmd_ssh "$@"
		;;
	postgres)
		check_auth || return 1
		cmd_postgres "$@"
		;;
	*)
		print_error "Unknown command: $command"
		print_usage
		return 1
		;;
	esac
	return 0
}

main "$@"
