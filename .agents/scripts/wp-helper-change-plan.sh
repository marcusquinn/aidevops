#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# =============================================================================
# WordPress change plan transport for `wp-helper.sh --change-plan` (GH#34853)
# =============================================================================
# Runs wp-change-plan.php on a configured site. LocalWP sites run locally.
# SSH sites reuse the auth that execute_wp_via_ssh() resolves (identity file,
# password env, password file, port, wp_path). The script and plan go to a
# private temporary directory on the server, `wp eval-file` runs from wp_path,
# the run output and the backup are downloaded into the agent workspace, and
# the uploaded copies are deleted. Backups stay on the server.
#
# Usage: source "${SCRIPT_DIR}/wp-helper-change-plan.sh"
#        (sourced by wp-helper.sh; do not execute directly)
#
# Dependencies:
#   - wp-helper.sh (load_config, get_site_config, resolve_server_ref, check_sshpass)
#   - shared-constants.sh (print_error, print_info, print_success, print_warning)
#   - Globals: SCRIPT_DIR
#
# Docs: .agents/tools/wordpress/wp-change-plan.md

# Include guard
[[ -n "${_WP_CHANGE_PLAN_LIB_LOADED:-}" ]] && return 0
_WP_CHANGE_PLAN_LIB_LOADED=1

WPCP_SSH_OPTS=()
WPCP_SCP_OPTS=()
WPCP_AUTH=()
WPCP_TARGET=""
WPCP_MODE_RESTORE="restore"
WPCP_USAGE="Usage: wp-helper.sh --change-plan <site> PLAN.json [apply | restore BACKUP.json] [--user=<id>]"

# Private output directory for one run: run.log and the backup copy.
_wpcp_output_dir() {
	local site_key="$1"
	local safe_key
	safe_key=$(printf '%s' "$site_key" | tr -c 'A-Za-z0-9._-' '_')
	local out_dir
	out_dir="${HOME}/.aidevops/.agent-workspace/work/wp-change-plan/${safe_key}-$(date -u +%Y%m%dT%H%M%SZ)-$$"
	if ! mkdir -p "$out_dir"; then
		print_error "Cannot create output directory: $out_dir"
		return 1
	fi
	chmod 700 "$out_dir"
	printf '%s\n' "$out_dir"
	return 0
}

# Absolute path of an existing local file.
_wpcp_abs_path() {
	local file="$1"
	local dir
	dir=$(cd "$(dirname "$file")" && pwd) || return 1
	printf '%s/%s\n' "$dir" "$(basename "$file")"
	return 0
}

# Set WPCP_* SSH/scp arguments with the same auth rules as execute_wp_via_ssh().
_wpcp_prepare_ssh() {
	local site_config="$1"
	local site_type ssh_host ssh_user ssh_port identity password_env password_file
	site_type=$(jq -r '.type' <<<"$site_config")
	ssh_host=$(jq -r '.ssh_host // empty' <<<"$site_config")
	ssh_user=$(jq -r '.ssh_user // empty' <<<"$site_config")
	ssh_port=$(jq -r '.ssh_port // 22' <<<"$site_config")
	identity=$(jq -r '.ssh_identity_file // empty' <<<"$site_config")
	password_env=$(jq -r '.ssh_password_env // empty' <<<"$site_config")
	password_file=$(jq -r '.password_file // empty' <<<"$site_config")

	case "$site_type" in
	hostinger | hetzner | cloudways | cloudron) ;;
	*)
		print_error "Unknown hosting type: $site_type"
		return 1
		;;
	esac
	if [[ -z "$ssh_host" || -z "$ssh_user" ]]; then
		print_error "Site needs ssh_host and ssh_user for --change-plan"
		return 1
	fi
	WPCP_TARGET="${ssh_user}@${ssh_host}"
	WPCP_SSH_OPTS=(-p "$ssh_port")
	WPCP_SCP_OPTS=(-q -P "$ssh_port")
	WPCP_AUTH=()

	if [[ -n "$identity" ]]; then
		local expanded_identity="${identity/#\~/$HOME}"
		WPCP_SSH_OPTS+=(-i "$expanded_identity")
		WPCP_SCP_OPTS+=(-i "$expanded_identity")
		return 0
	fi
	[[ "$site_type" == "hostinger" ]] || return 0

	if [[ -n "$password_env" ]]; then
		if [[ ! "$password_env" =~ ^[A-Z_][A-Z0-9_]*$ ]]; then
			print_error "Invalid ssh_password_env name: $password_env"
			return 1
		fi
		if [[ -z "${!password_env:-}" ]]; then
			print_error "SSH password environment variable is not set: $password_env"
			print_info "Run with: aidevops secret $password_env -- wp-helper.sh --change-plan ..."
			return 1
		fi
		check_sshpass
		export SSHPASS="${!password_env}"
		WPCP_AUTH=(sshpass -e)
		return 0
	fi

	check_sshpass
	local expanded_password_file="${HOME}/.ssh/hostinger_password"
	[[ -n "$password_file" ]] && expanded_password_file="${password_file/#\~/$HOME}"
	if [[ ! -f "$expanded_password_file" ]]; then
		print_error "Password file not found: $expanded_password_file"
		return 1
	fi
	WPCP_AUTH=(sshpass -f "$expanded_password_file")
	return 0
}

# Run one remote shell command on the prepared SSH target.
_wpcp_ssh() {
	local remote_cmd="$1"
	${WPCP_AUTH[@]+"${WPCP_AUTH[@]}"} ssh -n "${WPCP_SSH_OPTS[@]}" "$WPCP_TARGET" "$remote_cmd"
	return $?
}

# Copy one file with scp on the prepared SSH target.
_wpcp_scp() {
	local source_path="$1"
	local dest_path="$2"
	${WPCP_AUTH[@]+"${WPCP_AUTH[@]}"} scp "${WPCP_SCP_OPTS[@]}" "$source_path" "$dest_path"
	return $?
}

# Delete the remote temporary directory and confirm nothing is left.
_wpcp_cleanup_remote() {
	local remote_tmp="$1"
	[[ -n "$remote_tmp" ]] || return 0
	local quoted
	quoted=$(printf '%q' "$remote_tmp")
	if _wpcp_ssh "rm -rf -- ${quoted} && test ! -e ${quoted}"; then
		print_success "Removed the uploaded copies from the server ($remote_tmp)"
		return 0
	fi
	print_warning "Could not confirm removal of $remote_tmp on the server; delete it by hand"
	return 1
}

# Copy the backup named in run.log into the output directory.
_wpcp_fetch_backup() {
	local log_file="$1"
	local out_dir="$2"
	local remote="$3"
	local backup_path
	backup_path=$(sed -n 's/^BACKUP: //p' "$log_file" | tail -n 1)
	[[ -n "$backup_path" ]] || return 0
	if [[ ! "$backup_path" =~ ^/[^[:space:]]+\.json$ ]]; then
		print_warning "Unexpected backup path in output: $backup_path"
		return 1
	fi
	local copied=1
	if [[ "$remote" == "1" ]]; then
		_wpcp_scp "${WPCP_TARGET}:${backup_path}" "$out_dir/" && copied=0
	else
		cp -p "$backup_path" "$out_dir/" && copied=0
	fi
	if [[ "$copied" -ne 0 ]]; then
		print_warning "Could not copy the backup; it stays at $backup_path"
		return 1
	fi
	chmod 600 "$out_dir/$(basename "$backup_path")"
	print_info "Backup on the site: $backup_path"
	print_info "Backup copy: $out_dir/$(basename "$backup_path")"
	return 0
}

# LocalWP: run the script in place from the site's path.
_wpcp_run_local() {
	local site_config="$1"
	local out_dir="$2"
	shift 2
	local local_path
	local_path=$(jq -r '.path // empty' <<<"$site_config")
	local expanded_path="${local_path/#\~/$HOME}"
	if [[ -z "$local_path" || ! -d "$expanded_path" ]]; then
		print_error "LocalWP site path not found: ${local_path:-<unset>}"
		return 1
	fi
	local rc=0
	(cd "$expanded_path" && wp eval-file "${SCRIPT_DIR}/wp-change-plan.php" "$@") 2>&1 | tee "$out_dir/run.log" || rc=$?
	_wpcp_fetch_backup "$out_dir/run.log" "$out_dir" 0 || true
	return "$rc"
}

# SSH sites: upload, run from wp_path, download, delete the uploads.
# Args: site_config out_dir plan_file mode backup_arg user_arg
_wpcp_run_remote() {
	local site_config="$1"
	local out_dir="$2"
	local plan_file="$3"
	local mode="$4"
	local backup_arg="$5"
	local user_arg="$6"
	_wpcp_prepare_ssh "$site_config" || return 1
	local wp_path
	wp_path=$(jq -r '.wp_path // empty' <<<"$site_config")
	if [[ -z "$wp_path" ]]; then
		print_error "Site has no wp_path"
		return 1
	fi

	local remote_tmp
	# shellcheck disable=SC2016 # ${TMPDIR:-/tmp} expands on the server.
	remote_tmp=$(_wpcp_ssh 'umask 077 && mktemp -d "${TMPDIR:-/tmp}/wp-change-plan.XXXXXX"') || remote_tmp=""
	if [[ ! "$remote_tmp" =~ ^/[A-Za-z0-9._/-]+/wp-change-plan\.[A-Za-z0-9]+$ ]]; then
		print_error "Could not create a private temporary directory on the server"
		return 1
	fi
	trap '_wpcp_cleanup_remote "$remote_tmp"; trap - INT TERM; exit 130' INT TERM

	local rc=0
	local remote_backup="$backup_arg"
	if ! _wpcp_scp "${SCRIPT_DIR}/wp-change-plan.php" "${WPCP_TARGET}:${remote_tmp}/wp-change-plan.php" ||
		! _wpcp_scp "$plan_file" "${WPCP_TARGET}:${remote_tmp}/plan.json"; then
		print_error "Upload to the server failed"
		rc=1
	elif [[ "$mode" == "$WPCP_MODE_RESTORE" && -f "$backup_arg" ]]; then
		remote_backup="${remote_tmp}/backup.json"
		_wpcp_scp "$backup_arg" "${WPCP_TARGET}:${remote_backup}" || rc=1
	fi

	if [[ "$rc" -eq 0 ]]; then
		local -a wp_args=(eval-file "${remote_tmp}/wp-change-plan.php" "${remote_tmp}/plan.json")
		[[ -n "$mode" ]] && wp_args+=("$mode")
		[[ -n "$remote_backup" ]] && wp_args+=("$remote_backup")
		[[ -n "$user_arg" ]] && wp_args+=("--user=${user_arg}")
		local remote_cmd
		remote_cmd="cd $(printf '%q' "$wp_path") && wp $(printf '%q ' "${wp_args[@]}")"
		_wpcp_ssh "${remote_cmd% }" 2>&1 | tee "$out_dir/run.log" || rc=$?
	fi

	_wpcp_cleanup_remote "$remote_tmp" || true
	trap - INT TERM
	[[ -f "$out_dir/run.log" ]] && { _wpcp_fetch_backup "$out_dir/run.log" "$out_dir" 1 || true; }
	return "$rc"
}

# wp-helper.sh --change-plan <site> PLAN.json [apply | restore BACKUP.json] [--user=<id>]
cmd_change_plan() {
	local site_key="${1:-}"
	local plan_file="${2:-}"
	if [[ -z "$site_key" || -z "$plan_file" ]]; then
		print_error "$WPCP_USAGE"
		return 1
	fi
	shift 2
	local mode="" backup_arg="" user_arg=""
	while [[ $# -gt 0 ]]; do
		local arg="$1"
		case "$arg" in
		apply) mode="apply" ;;
		restore)
			mode="$WPCP_MODE_RESTORE"
			backup_arg="${2:-}"
			if [[ -z "$backup_arg" ]]; then
				print_error "restore needs BACKUP.json (a local copy or the path on the site)"
				return 1
			fi
			shift
			;;
		--user=*) user_arg="${arg#--user=}" ;;
		--user)
			user_arg="${2:-}"
			shift
			;;
		*)
			print_error "Unknown --change-plan argument: $arg"
			print_info "$WPCP_USAGE"
			return 1
			;;
		esac
		shift
	done
	if [[ ! -f "$plan_file" ]] || ! jq -e 'type == "object"' "$plan_file" >/dev/null 2>&1; then
		print_error "PLAN.json is missing or not a JSON object: $plan_file"
		return 1
	fi
	if [[ -n "$user_arg" && ! "$user_arg" =~ ^[A-Za-z0-9_.@-]+$ ]]; then
		print_error "Invalid --user value: $user_arg"
		return 1
	fi
	if [[ "$mode" == "$WPCP_MODE_RESTORE" && -f "$backup_arg" ]]; then
		backup_arg=$(_wpcp_abs_path "$backup_arg") || return 1
	fi
	plan_file=$(_wpcp_abs_path "$plan_file") || return 1

	load_config
	local site_config
	site_config=$(get_site_config "$site_key")
	site_config=$(resolve_server_ref "$site_config")
	local out_dir
	out_dir=$(_wpcp_output_dir "$site_key") || return 1
	local site_type
	site_type=$(jq -r '.type' <<<"$site_config")
	print_info "Change plan on $site_key ($site_type): ${mode:-dry run}" >&2

	local rc=0
	if [[ "$site_type" == "localwp" ]]; then
		local -a php_args=("$plan_file")
		[[ -n "$mode" ]] && php_args+=("$mode")
		[[ -n "$backup_arg" ]] && php_args+=("$backup_arg")
		[[ -n "$user_arg" ]] && php_args+=("--user=${user_arg}")
		_wpcp_run_local "$site_config" "$out_dir" "${php_args[@]}" || rc=$?
	else
		_wpcp_run_remote "$site_config" "$out_dir" "$plan_file" "$mode" "$backup_arg" "$user_arg" || rc=$?
	fi
	print_info "Run output: $out_dir/run.log"
	local site_backup=""
	[[ -f "$out_dir/run.log" ]] && site_backup=$(sed -n 's/^BACKUP: //p' "$out_dir/run.log" | tail -n 1)
	if [[ "$mode" == "apply" && -n "$site_backup" ]]; then
		print_info "To undo: wp-helper.sh --change-plan $site_key $plan_file restore $site_backup --user=${user_arg}"
	fi
	return "$rc"
}
