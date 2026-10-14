#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
# Sourced by site-crawler-helper.sh; uses shared print functions and jq/curl.

[[ -n "${_SITE_CRAWLER_SEOPROSTATS_LOADED:-}" ]] && return 0
_SITE_CRAWLER_SEOPROSTATS_LOADED=1

# POSIX-shell quoting for the remote command (not local printf %q's Bash syntax).
_seoprostats_quote() {
	local value="$1"
	printf "'%s'" "${value//\'/\'\\\'\'}"
	return 0
}

# Upload using inventory-resolved SSH metadata; never fall back after a write.
_seoprostats_ssh() (
	local record="$1"
	shift
	local host user port path remote="" command file rc=0
	host=$(printf '%s' "$record" | jq -r '.hosting.ssh_host // empty')
	user=$(printf '%s' "$record" | jq -r '.hosting.ssh_user // empty')
	port=$(printf '%s' "$record" | jq -r '.hosting.ssh_port // 22')
	path=$(printf '%s' "$record" | jq -r '.hosting.deployment_path // empty')
	if [[ ! "$host" =~ ^[a-zA-Z0-9][a-zA-Z0-9.-]*$ || ! "$user" =~ ^[a-zA-Z0-9_][a-zA-Z0-9_.-]*$ ||
		! "$port" =~ ^[0-9]+$ || "$path" != /* || "$path" == *$'\n'* || "$path" == *$'\r'* ]]; then
		print_error "SEO Pro Stats SSH requires valid host, user, port and absolute deployment_path"
		return 1
	fi
	local ssh_args=(-o BatchMode=yes -o ConnectTimeout=10 -p "$port" "${user}@${host}")
	remote=$(ssh "${ssh_args[@]}" 'umask 077; mktemp -d /tmp/seoprostats-XXXXXXXXXX') || return 1
	[[ "$remote" =~ ^/tmp/seoprostats-[a-zA-Z0-9]+$ ]] || {
		print_error "Unexpected SSH temporary directory"
		return 1
	}
	# Private remote files are removed on success, copy/import failure or interruption.
	trap 'if ! ssh "${ssh_args[@]}" "rm -rf -- $(_seoprostats_quote "$remote")" >/dev/null; then print_error "Could not remove remote import files in $remote"; exit 1; fi' EXIT
	trap 'exit 130' INT TERM
	command="wp seoprostats crawl import"
	for file in "$@"; do
		scp -q -o BatchMode=yes -o ConnectTimeout=10 -P "$port" -- "$file" "${user}@${host}:${remote}/${file##*/}" || return 1
		command+=" $(_seoprostats_quote "${remote}/${file##*/}")"
	done
	command+=" --path=$(_seoprostats_quote "$path")"
	# Each interpolated remote argument has been POSIX-quoted above.
	# shellcheck disable=SC2029
	ssh "${ssh_args[@]}" "$command" || rc=$?
	return "$rc"
)

# An HTTP request never follows redirects with authentication or prints a body on error.
_seoprostats_request() {
	local auth="$1"
	local response="$2"
	local timeout="$3"
	shift 3
	local code
	code=$(curl -sS --config "$auth" --connect-timeout 10 --max-time "$timeout" \
		-o "$response" -w '%{http_code}' "$@") || return 1
	case "$code" in
	2??) ;;
	*)
		print_error "SEO Pro Stats import HTTP $code (check application password, permissions and upload limits)"
		return 1
		;;
	esac
	jq -e 'type == "object" and (.status | type == "string") and (.id | type == "number")' "$response" >/dev/null 2>&1 || {
		print_error "Unexpected SEO Pro Stats import response"
		return 1
	}
	return 0
}

# REST jobs are advanced by GET; verify the job ID on every response.
_seoprostats_rest() (
	local site="$1"
	local timeout="$2"
	shift 2
	local key username password token temp response id status remaining deadline file
	key=$(printf '%s' "$site" | tr '[:lower:].-' '[:upper:]__')
	username=$(_librecrawl_secret "SEOPROSTATS_USERNAME_${key}")
	password=$(_librecrawl_secret "SEOPROSTATS_APP_PASSWORD_${key}")
	if [[ -z "$username" || -z "$password" || "$username" == *:* ]]; then
		print_error "REST import needs SEOPROSTATS_USERNAME_${key} and SEOPROSTATS_APP_PASSWORD_${key} in aidevops secret or environment"
		return 1
	fi
	temp=$(mktemp -d "${TMPDIR:-/tmp}/seoprostats-XXXXXXXXXX") || return 1
	trap 'rm -rf -- "$temp"' EXIT
	trap 'exit 130' INT TERM
	response="${temp}/response.json"
	# Only builtins handle plaintext; curl reads authentication from a private file.
	token=$(printf '%s:%s' "$username" "$password" | jq -Rs '@base64' -r) || return 1
	(
		umask 077
		printf 'header = "Authorization: Basic %s"\n' "$token" >"${temp}/auth"
	) || return 1
	password=""
	token=""
	local endpoint="https://${site}/wp-json/seoprostats/v1/crawl/import"
	local args=(-X POST)
	for file in "$@"; do
		# curl's form parser treats commas/semicolons specially: quote the path.
		file="${file//\\/\\\\}"
		file="${file//\"/\\\"}"
		args+=(-F "files[]=@\"${file}\"")
	done
	deadline=$(($(date +%s) + timeout))
	_seoprostats_request "${temp}/auth" "$response" "$timeout" "${args[@]}" "$endpoint" || return 1
	id=$(jq -r '.id' "$response")
	[[ "$id" =~ ^[1-9][0-9]*$ ]] || {
		print_error "Import returned no job ID"
		return 1
	}
	print_info "SEO Pro Stats import $id started"
	while true; do
		[[ "$(jq -r '.id' "$response")" == "$id" ]] || {
			print_error "SEO Pro Stats import job changed; refusing to report another job"
			return 1
		}
		status=$(jq -r '.status' "$response")
		case "$status" in
		done)
			jq -r '"Import \(.id): \(.pages) pages, \(.links) links, \(.skipped) skipped, \(.changes) served changes"' "$response"
			return 0
			;;
		failed | error)
			print_error "SEO Pro Stats import $id failed; inspect the plugin import status"
			return 1
			;;
		running) ;;
		*)
			print_error "Unexpected import status for job $id"
			return 1
			;;
		esac
		remaining=$((deadline - $(date +%s)))
		if [[ "$remaining" -le 2 ]]; then
			print_error "SEO Pro Stats import $id timed out; it may still finish on the server"
			return 1
		fi
		sleep 2
		remaining=$((deadline - $(date +%s)))
		# curl interprets --max-time 0 as unlimited; recheck after scheduling delays.
		if [[ "$remaining" -le 0 ]]; then
			print_error "SEO Pro Stats import $id timed out; it may still finish on the server"
			return 1
		fi
		_seoprostats_request "${temp}/auth" "$response" "$remaining" "$endpoint" || return 1
	done
)

push_seoprostats() {
	local output="${1:-}"
	[[ -n "$output" ]] || {
		print_error "Usage: push-seoprostats <crawl-output-dir> --site <hostname>"
		return 1
	}
	shift
	local site="" transport=auto timeout=600 file size record="" option value
	while [[ $# -gt 0 ]]; do
		local option="$1"
		local value="${2:-}"
		[[ $# -ge 2 && -n "$value" ]] || {
			print_error "Push options need a value"
			return 1
		}
		case "$option" in
		--site) site="$value" ;;
		--transport) transport="$value" ;;
		--timeout) timeout="$value" ;;
		*)
			print_error "Unknown push option: $option"
			return 1
			;;
		esac
		shift 2
	done
	if [[ ! "$site" =~ ^[a-zA-Z0-9]([a-zA-Z0-9.-]*[a-zA-Z0-9])?$ ||
		! "$timeout" =~ ^[1-9][0-9]*$ || ! -d "$output" ]]; then
		print_error "Push requires an existing crawl directory, hostname (no URL/path/port) and positive timeout in seconds"
		return 1
	fi
	case "$transport" in auto | ssh | rest) ;; *)
		print_error "Transport must be auto, ssh or rest"
		return 1
		;;
	esac
	command -v jq >/dev/null && command -v curl >/dev/null || {
		print_error "Push requires jq and curl"
		return 1
	}
	# Resolve relative paths to prevent scp treating a colon as a remote source.
	output=$(cd "$output" && pwd -P) || return 1
	local names=(crawl-data.csv broken-links.csv redirects.csv) files=()
	if [[ -f "${output}/librecrawl-urls.json" ]]; then
		names=(librecrawl-urls.json librecrawl-links.csv)
	elif [[ ! -f "${output}/crawl-data.csv" ]]; then
		print_error "No crawl pages export in $output"
		return 1
	fi
	for file in "${names[@]}"; do
		file="${output}/${file}"
		[[ -f "$file" ]] || continue
		size=$(wc -c <"$file") || return 1
		if [[ "$size" -gt 52428800 ]]; then
			print_error "${file##*/} exceeds the plugin's 50 MiB per-file limit"
			return 1
		fi
		files+=("$file")
	done
	if [[ "$transport" != rest ]]; then
		record=$("${SCRIPT_DIR}/site-context-helper.sh" readiness "$site") || record=""
		if printf '%s' "$record" | jq -e '.readiness == "ready"' >/dev/null 2>&1; then
			_seoprostats_ssh "$record" "${files[@]}"
			return $?
		fi
		[[ "$transport" != ssh ]] || {
			print_error "Site inventory is not SSH-ready for $site"
			return 1
		}
	fi
	_seoprostats_rest "$site" "$timeout" "${files[@]}"
	return $?
}
