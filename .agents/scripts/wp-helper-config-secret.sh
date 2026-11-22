#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
# =============================================================================
# Secret constants in wp-config.php for `wp-helper.sh --config-secret` (GH#39922)
# =============================================================================
# Runs wp-config-secret.php on a configured site: set one constant from a
# stored secret, check it in a fresh PHP process, list backups, undo.
# LocalWP sites run locally; SSH sites reuse the change-plan transport.
#
# The value never appears in argv or output: run under `aidevops secret NAME --`
# and pass the variable NAME; jq reads the value from the environment and the
# JSON reaches `wp` on stdin over plain `ssh` (not the `ssh -n` WP-CLI path).
#
# Usage: source "${SCRIPT_DIR}/wp-helper-config-secret.sh"
#        (sourced by wp-helper.sh after wp-helper-change-plan.sh)
#
# Dependencies:
#   - wp-helper.sh (load_config, get_site_config, resolve_server_ref)
#   - wp-helper-change-plan.sh (_wpcp_prepare_ssh, _wpcp_scp,
#     _wpcp_remote_mktemp, _wpcp_cleanup_remote; WPCP_AUTH/WPCP_SSH_OPTS/WPCP_TARGET)
#   - shared-constants.sh (print_error, print_info, print_success)
#
# Docs: .agents/tools/wordpress/wp-dev.md "Secrets in wp-config.php"

# Include guard
[[ -n "${_WP_CONFIG_SECRET_LIB_LOADED:-}" ]] && return 0
_WP_CONFIG_SECRET_LIB_LOADED=1

WPCS_PHP_FILE="wp-config-secret.php"
# The entry file loads its sibling from its own directory; upload them together.
WPCS_PHP_FILES=("$WPCS_PHP_FILE" wp-config-file.php)
WPCS_USAGE="Usage: wp-helper.sh --config-secret <site> <set CONSTANT --value-env VAR [--dry-run] | status CONSTANT | backups | undo --backup DIR> [--url URL]"
# Parsed options (globals keep Bash 3.2 compatibility without namerefs).
WPCS_ARGS=()
WPCS_GLOBALS=()
WPCS_CONSTANT=""
WPCS_VALUE_ENV=""
WPCS_BACKUP=""
WPCS_DRY_RUN=0

# Validate one option value; return 1 with a message when it is malformed.
_wpcs_check_value() {
	local flag="$1"
	local value="$2"
	local pattern=""
	case "$flag" in
	constant) pattern='^[A-Z][A-Z0-9_]{1,63}$' ;;
	--value-env) pattern='^[A-Z_][A-Z0-9_]*$' ;;
	--backup) pattern='^/[A-Za-z0-9._/-]+$' ;;
	--url) pattern='^https?://[A-Za-z0-9.:/_-]+$' ;;
	esac
	[[ "$value" =~ $pattern ]] && return 0
	print_error "Invalid $flag value: $value"
	return 1
}

# Parse ACTION [CONSTANT] [options] into WPCS_ARGS (payload key=value) and WPCS_GLOBALS.
_wpcs_parse() {
	local action="$1"
	shift
	WPCS_ARGS=("$action")
	WPCS_GLOBALS=()
	WPCS_CONSTANT=""
	WPCS_VALUE_ENV=""
	WPCS_BACKUP=""
	WPCS_DRY_RUN=0
	if [[ "$action" == "set" || "$action" == "status" ]]; then
		WPCS_CONSTANT="${1:-}"
		if [[ -z "$WPCS_CONSTANT" || "$WPCS_CONSTANT" == --* ]]; then
			print_error "$action needs a CONSTANT name"
			return 1
		fi
		_wpcs_check_value constant "$WPCS_CONSTANT" || return 1
		WPCS_ARGS+=("constant=${WPCS_CONSTANT}")
		shift
	fi
	while [[ $# -gt 0 ]]; do
		local flag="$1"
		local value="${2:-}"
		case "$flag" in
		--dry-run)
			WPCS_DRY_RUN=1
			WPCS_ARGS+=("dry_run=1")
			shift
			continue
			;;
		--url=*)
			value="${flag#*=}"
			flag="--url"
			shift
			;;
		--value-env | --backup | --url)
			if [[ $# -lt 2 || -z "$value" ]]; then
				print_error "$flag needs a value"
				return 1
			fi
			shift 2
			;;
		*)
			print_error "Unknown --config-secret argument: $flag"
			return 1
			;;
		esac
		_wpcs_check_value "$flag" "$value" || return 1
		case "$flag" in
		--url) WPCS_GLOBALS+=("--url=${value}") ;;
		--value-env) WPCS_VALUE_ENV="$value" ;;
		--backup)
			WPCS_BACKUP="$value"
			WPCS_ARGS+=("backup=${value}")
			;;
		esac
	done
	return 0
}

# Refuse set unless the value variable is named and set; refuse it elsewhere.
_wpcs_check_value_env() {
	if [[ "${WPCS_ARGS[0]}" != "set" ]]; then
		if [[ -n "$WPCS_VALUE_ENV" ]]; then
			print_error "--value-env applies only to set"
			return 1
		fi
		return 0
	fi
	if [[ -z "$WPCS_VALUE_ENV" ]]; then
		print_error "set needs --value-env VAR (a variable name, not the value)"
		return 1
	fi
	if [[ -z "${!WPCS_VALUE_ENV:-}" ]]; then
		print_error "$WPCS_VALUE_ENV is not set in this environment"
		print_info "Run with: aidevops secret $WPCS_VALUE_ENV -- wp-helper.sh --config-secret ..."
		return 1
	fi
	return 0
}

# Print the value JSON for stdin; the value comes from the environment, not argv.
_wpcs_value_json() {
	if [[ "${WPCS_ARGS[0]}" != "set" ]]; then
		printf '{}'
		return 0
	fi
	jq -cn --arg n "$WPCS_VALUE_ENV" '{value: env[$n]}'
	return $?
}

# True when a real write must be confirmed in a fresh PHP process.
_wpcs_needs_status() {
	[[ "${WPCS_ARGS[0]}" == "set" && "$WPCS_DRY_RUN" -eq 0 ]]
	return $?
}

# LocalWP: run the payload in place from the site's path, then status for a real set.
_wpcs_run_local() {
	local site_config="$1"
	local out_file="$2"
	local local_path
	local_path=$(jq -r '.path // empty' <<<"$site_config")
	local expanded_path="${local_path/#\~/$HOME}"
	if [[ -z "$local_path" || ! -d "$expanded_path" ]]; then
		print_error "LocalWP site path not found: ${local_path:-<unset>}"
		return 1
	fi
	local payload="${SCRIPT_DIR}/${WPCS_PHP_FILE}"
	local -a globals=(${WPCS_GLOBALS[@]+"${WPCS_GLOBALS[@]}"})
	local rc=0
	_wpcs_value_json | (cd "$expanded_path" && wp eval-file "$payload" "${WPCS_ARGS[@]}" ${globals[@]+"${globals[@]}"}) >"$out_file" || rc=$?
	if [[ "$rc" -eq 0 ]] && _wpcs_needs_status; then
		(cd "$expanded_path" && wp eval-file "$payload" status "constant=${WPCS_CONSTANT}" ${globals[@]+"${globals[@]}"} </dev/null) >>"$out_file" || rc=$?
	fi
	return "$rc"
}

# SSH sites: upload the payload, run it from wp_path with the value on stdin, delete it.
_wpcs_run_remote() {
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
	remote_tmp=$(_wpcp_remote_mktemp wp-config-secret) || return 1
	trap '_wpcp_cleanup_remote "$remote_tmp"; trap - INT TERM; exit 130' INT TERM

	local rc=0 php_file
	for php_file in "${WPCS_PHP_FILES[@]}"; do
		_wpcp_scp "${SCRIPT_DIR}/${php_file}" "${WPCP_TARGET}:${remote_tmp}/${php_file}" || {
			rc=1
			break
		}
	done
	if [[ "$rc" -ne 0 ]]; then
		print_error "Upload to the server failed"
	else
		local payload="${remote_tmp}/${WPCS_PHP_FILE}"
		local -a globals=(${WPCS_GLOBALS[@]+"${WPCS_GLOBALS[@]}"})
		local remote_cmd
		remote_cmd="cd $(printf '%q' "$wp_path") && wp eval-file $(printf '%q ' "$payload" "${WPCS_ARGS[@]}" ${globals[@]+"${globals[@]}"})"
		if _wpcs_needs_status; then
			# A second process loads the rewritten wp-config.php; it reads nothing from stdin.
			remote_cmd="${remote_cmd% } && wp eval-file $(printf '%q ' "$payload" status "constant=${WPCS_CONSTANT}" ${globals[@]+"${globals[@]}"}) </dev/null"
		fi
		# Not _wpcp_ssh: that passes -n, and the value travels on stdin.
		_wpcs_value_json | ${WPCP_AUTH[@]+"${WPCP_AUTH[@]}"} ssh "${WPCP_SSH_OPTS[@]}" "$WPCP_TARGET" "${remote_cmd% }" >"$out_file" || rc=$?
	fi

	_wpcp_cleanup_remote "$remote_tmp" >&2 || true
	trap - INT TERM
	return "$rc"
}

# After a real set: the fresh process must see the constant with the written length.
_wpcs_confirm() {
	local out_file="$1"
	local verdict
	verdict=$(jq -rs '
		if length == 2 and .[0].written == true and .[1].defined == true and .[1].length == .[0].length
		then "ok \(.[0].length)" else "mismatch" end' "$out_file" 2>/dev/null) || verdict="unreadable"
	if [[ "$verdict" == ok* ]]; then
		print_success "Confirmed in a fresh PHP process: $WPCS_CONSTANT is defined, length ${verdict#ok }" >&2
		return 0
	fi
	print_error "Written, but a fresh PHP process does not show $WPCS_CONSTANT with the written length ($verdict)"
	print_info "Check where else it is defined, or restore with: wp-helper.sh --config-secret <site> undo --backup DIR"
	return 1
}

# wp-helper.sh --config-secret <site> <action> [options]
cmd_config_secret() {
	local site_key="${1:-}"
	local action="${2:-}"
	case "$action" in
	set | status | backups | undo) ;;
	*)
		print_error "$WPCS_USAGE"
		return 1
		;;
	esac
	shift 2
	_wpcs_parse "$action" "$@" || {
		print_info "$WPCS_USAGE"
		return 1
	}
	if [[ "$action" == "undo" && -z "$WPCS_BACKUP" ]]; then
		print_error "undo needs --backup DIR (see: backups)"
		return 1
	fi
	_wpcs_check_value_env || return 1

	load_config
	local site_config
	site_config=$(get_site_config "$site_key")
	site_config=$(resolve_server_ref "$site_config")
	local site_type
	site_type=$(jq -r '.type' <<<"$site_config")
	if [[ "$action" == "set" ]]; then
		local mode_note=""
		[[ "$WPCS_DRY_RUN" -eq 1 ]] && mode_note=" [dry run]"
		print_info "Setting $WPCS_CONSTANT on $site_key from \$$WPCS_VALUE_ENV (value not shown)${mode_note}" >&2
	fi

	local tmp_dir="${AIDEVOPS_TEMP_DIR:-$HOME/.aidevops/.agent-workspace/tmp}"
	mkdir -p "$tmp_dir" || return 1
	local out_file
	out_file=$(mktemp "${tmp_dir}/wp-config-secret.XXXXXX") || return 1
	chmod 600 "$out_file"
	local rc=0
	if [[ "$site_type" == "localwp" ]]; then
		_wpcs_run_local "$site_config" "$out_file" || rc=$?
	else
		_wpcs_run_remote "$site_config" "$out_file" || rc=$?
	fi
	cat "$out_file"
	if [[ "$rc" -eq 0 ]] && _wpcs_needs_status; then
		_wpcs_confirm "$out_file" || rc=1
	fi
	rm -f "$out_file"
	return "$rc"
}
