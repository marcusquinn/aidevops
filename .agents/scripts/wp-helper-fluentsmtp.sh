#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
# =============================================================================
# FluentSMTP Amazon SES connections over SSH/WP-CLI for `wp-helper.sh --fluentsmtp` (GH#38865)
# =============================================================================
# Runs wp-fluentsmtp.php, which reads and writes through FluentSMTP's own
# settings functions, on a configured site: list connections, migrate SES
# connections to a new sending domain/region with keys in wp-config.php,
# send a proof message, and undo from a checksummed backup. LocalWP sites run
# locally; SSH sites reuse the change-plan transport.
#
# AWS keys never appear in argv or output: run under `aidevops secret A B --`
# and pass the variable NAMES; jq reads the values from the environment and
# the JSON reaches `wp` on stdin.
#
# Usage: source "${SCRIPT_DIR}/wp-helper-fluentsmtp.sh"
#        (sourced by wp-helper.sh after wp-helper-change-plan.sh)
#
# Dependencies:
#   - wp-helper.sh (load_config, get_site_config, resolve_server_ref)
#   - wp-helper-change-plan.sh (_wpcp_prepare_ssh, _wpcp_scp,
#     _wpcp_remote_mktemp, _wpcp_cleanup_remote; WPCP_AUTH/WPCP_SSH_OPTS/WPCP_TARGET)
#   - shared-constants.sh (print_error, print_info)
#
# Docs: .agents/services/email/ses.md "FluentSMTP"

# Include guard
[[ -n "${_WP_FLUENTSMTP_LIB_LOADED:-}" ]] && return 0
_WP_FLUENTSMTP_LIB_LOADED=1

WPFS_PHP_FILE="wp-fluentsmtp.php"
# The entry file loads its siblings from its own directory; upload them together.
WPFS_PHP_FILES=("$WPFS_PHP_FILE" wp-fluentsmtp-store.php wp-fluentsmtp-migrate.php wp-fluentsmtp-backup.php)
WPFS_USAGE="Usage: wp-helper.sh --fluentsmtp <site> <list | migrate --domain D --region R [--from-domain OLD] [--dry-run] --access-key-env VAR --secret-key-env VAR | test --to ADDR [--from ADDR] [--lift-http-block] | backups | undo --backup DIR> [--url URL]"
# Parsed options (globals keep Bash 3.2 compatibility without namerefs).
WPFS_ARGS=()
WPFS_GLOBALS=()
WPFS_ACCESS_ENV=""
WPFS_SECRET_ENV=""
WPFS_DRY_RUN=0

# Validate one option value; return 1 with a message when it is malformed.
_wpfs_check_value() {
	local flag="$1"
	local value="$2"
	local pattern=""
	case "$flag" in
	--domain | --from-domain) pattern='^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+$' ;;
	--region) pattern='^[a-z]{2}(-[a-z]+)+-[0-9]$' ;;
	--to | --from) pattern='^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$' ;;
	--backup) pattern='^/[A-Za-z0-9._/-]+$' ;;
	--url) pattern='^https?://[A-Za-z0-9.:/_-]+$' ;;
	--access-key-env | --secret-key-env) pattern='^[A-Z_][A-Z0-9_]*$' ;;
	esac
	[[ "$value" =~ $pattern ]] && return 0
	print_error "Invalid $flag value: $value"
	return 1
}

# Parse ACTION [options] into WPFS_ARGS (payload key=value) and WPFS_GLOBALS.
_wpfs_parse() {
	local action="$1"
	shift
	WPFS_ARGS=("$action")
	WPFS_GLOBALS=()
	WPFS_ACCESS_ENV=""
	WPFS_SECRET_ENV=""
	WPFS_DRY_RUN=0
	while [[ $# -gt 0 ]]; do
		local flag="$1"
		local value="${2:-}"
		case "$flag" in
		--dry-run)
			WPFS_DRY_RUN=1
			WPFS_ARGS+=("dry_run=1")
			shift
			continue
			;;
		--lift-http-block)
			WPFS_ARGS+=("lift_http_block=1")
			shift
			continue
			;;
		--url=*)
			value="${flag#*=}"
			flag="--url"
			shift
			;;
		--domain | --from-domain | --region | --to | --from | --backup | --url | --access-key-env | --secret-key-env)
			if [[ $# -lt 2 || -z "$value" ]]; then
				print_error "$flag needs a value"
				return 1
			fi
			shift 2
			;;
		*)
			print_error "Unknown --fluentsmtp argument: $flag"
			return 1
			;;
		esac
		_wpfs_check_value "$flag" "$value" || return 1
		case "$flag" in
		--url) WPFS_GLOBALS+=("--url=${value}") ;;
		--access-key-env) WPFS_ACCESS_ENV="$value" ;;
		--secret-key-env) WPFS_SECRET_ENV="$value" ;;
		--from-domain) WPFS_ARGS+=("from_domain=${value}") ;;
		*) WPFS_ARGS+=("${flag#--}=${value}") ;;
		esac
	done
	return 0
}

# True when this run must send the AWS keys (a real migrate).
_wpfs_needs_keys() {
	[[ "${WPFS_ARGS[0]}" == "migrate" && "$WPFS_DRY_RUN" -eq 0 ]]
	return $?
}

# Refuse a real migrate unless both key variables are named and set.
_wpfs_check_keys() {
	_wpfs_needs_keys || return 0
	if [[ -z "$WPFS_ACCESS_ENV" || -z "$WPFS_SECRET_ENV" ]]; then
		print_error "migrate needs --access-key-env VAR --secret-key-env VAR (variable names, not values)"
		return 1
	fi
	if [[ -z "${!WPFS_ACCESS_ENV:-}" || -z "${!WPFS_SECRET_ENV:-}" ]]; then
		print_error "$WPFS_ACCESS_ENV or $WPFS_SECRET_ENV is not set in this environment"
		print_info "Run with: aidevops secret $WPFS_ACCESS_ENV $WPFS_SECRET_ENV -- wp-helper.sh --fluentsmtp ..."
		return 1
	fi
	return 0
}

# Print the key JSON for stdin; values come from the environment, not argv.
_wpfs_keys_json() {
	if ! _wpfs_needs_keys; then
		printf '{}'
		return 0
	fi
	jq -cn --arg a "$WPFS_ACCESS_ENV" --arg s "$WPFS_SECRET_ENV" \
		'{access_key: $ENV[$a], secret_key: $ENV[$s]}'
	return $?
}

# LocalWP: run the payload in place from the site's path.
_wpfs_run_local() {
	local site_config="$1"
	local out_file="$2"
	local local_path
	local_path=$(jq -r '.path // empty' <<<"$site_config")
	local expanded_path="${local_path/#\~/$HOME}"
	if [[ -z "$local_path" || ! -d "$expanded_path" ]]; then
		print_error "LocalWP site path not found: ${local_path:-<unset>}"
		return 1
	fi
	local -a wp_args=(eval-file "${SCRIPT_DIR}/${WPFS_PHP_FILE}" "${WPFS_ARGS[@]}")
	wp_args+=(${WPFS_GLOBALS[@]+"${WPFS_GLOBALS[@]}"})
	local rc=0
	_wpfs_keys_json | (cd "$expanded_path" && wp "${wp_args[@]}") >"$out_file" || rc=$?
	return "$rc"
}

# SSH sites: upload the payload, run it from wp_path with keys on stdin, delete it.
_wpfs_run_remote() {
	local site_config="$1"
	local out_file="$2"
	_wpcp_prepare_ssh "$site_config" || return 1
	local wp_path
	wp_path=$(jq -r '.wp_path // empty' <<<"$site_config")
	if [[ -z "$wp_path" ]]; then
		print_error "Site has no wp_path"
		return 1
	fi
	local remote_tmp
	remote_tmp=$(_wpcp_remote_mktemp wp-fluentsmtp) || return 1
	trap '_wpcp_cleanup_remote "$remote_tmp"; trap - INT TERM; exit 130' INT TERM

	local rc=0 php_file
	for php_file in "${WPFS_PHP_FILES[@]}"; do
		_wpcp_scp "${SCRIPT_DIR}/${php_file}" "${WPCP_TARGET}:${remote_tmp}/${php_file}" || {
			rc=1
			break
		}
	done
	if [[ "$rc" -ne 0 ]]; then
		print_error "Upload to the server failed"
	else
		local -a wp_args=(eval-file "${remote_tmp}/${WPFS_PHP_FILE}" "${WPFS_ARGS[@]}")
		wp_args+=(${WPFS_GLOBALS[@]+"${WPFS_GLOBALS[@]}"})
		local remote_cmd
		remote_cmd="cd $(printf '%q' "$wp_path") && wp $(printf '%q ' "${wp_args[@]}")"
		# Not _wpcp_ssh: that passes -n, and the keys travel on stdin.
		_wpfs_keys_json | ${WPCP_AUTH[@]+"${WPCP_AUTH[@]}"} ssh "${WPCP_SSH_OPTS[@]}" "$WPCP_TARGET" "${remote_cmd% }" >"$out_file" || rc=$?
	fi

	_wpcp_cleanup_remote "$remote_tmp" >&2 || true
	trap - INT TERM
	return "$rc"
}

# wp-helper.sh --fluentsmtp <site> <action> [options]
cmd_fluentsmtp() {
	local site_key="${1:-}"
	local action="${2:-}"
	case "$action" in
	list | migrate | test | backups | undo) ;;
	*)
		print_error "$WPFS_USAGE"
		return 1
		;;
	esac
	shift 2
	_wpfs_parse "$action" "$@" || {
		print_info "$WPFS_USAGE"
		return 1
	}
	_wpfs_check_keys || return 1

	load_config
	local site_config
	site_config=$(get_site_config "$site_key")
	site_config=$(resolve_server_ref "$site_config")
	local site_type
	site_type=$(jq -r '.type' <<<"$site_config")

	local tmp_dir="${AIDEVOPS_TEMP_DIR:-$HOME/.aidevops/.agent-workspace/tmp}"
	mkdir -p "$tmp_dir" || return 1
	local out_file
	out_file=$(mktemp "${tmp_dir}/wp-fluentsmtp.XXXXXX") || return 1
	chmod 600 "$out_file"
	local rc=0
	if [[ "$site_type" == "localwp" ]]; then
		_wpfs_run_local "$site_config" "$out_file" || rc=$?
	else
		_wpfs_run_remote "$site_config" "$out_file" || rc=$?
	fi
	cat "$out_file"
	rm -f "$out_file"
	return "$rc"
}
