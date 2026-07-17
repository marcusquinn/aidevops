#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# Explicit REST page loop for the aidevops gh PATH shim. This library is
# sourced by `.agents/scripts/gh`; it never records endpoint values or response
# bodies and keeps temporary response data in a private, short-lived directory.
# Set AIDEVOPS_GH_EXPLICIT_PAGINATION_DISABLE=1 to retain native pagination;
# AIDEVOPS_GH_REST_MAX_PAGES bounds explicit loops from 1 to 1000 (default 100).

_GHRP_ARGS=()
_GHRP_BASE_ARGS=()
_GHRP_ENDPOINT_INDEX=-1
_GHRP_BASE_ENDPOINT_INDEX=-1
_GHRP_ENDPOINT=""
_GHRP_INCLUDE_REQUESTED=0
_GHRP_SLURP_REQUESTED=0
_GHRP_SILENT_REQUESTED=0
_GHRP_HOSTNAME="${GH_HOST:-github.com}"
_GHRP_FALLBACK_SAFE=0
_GHRP_PREFLIGHT_ONLY=0
_GHRP_PAGE_ARGS=()
_GHRP_PAGE_FILES=()
_GHRP_VISITED_ENDPOINTS=()
_GHRP_NEXT_ENDPOINT=""
_GHRP_EXPECT_OPTION="option"
_GHRP_INVALID_NEXT_SENTINEL="__GHRP_INVALID_NEXT__"

_ghrp_is_value_flag() {
	local arg="$1"
	case "$arg" in
	-F | --field | -H | --header | --hostname | --input | -q | --jq | -X | --method | -p | --preview | -f | --raw-field | -t | --template | --cache) return 0 ;;
	esac
	return 1
}

_ghrp_find_endpoint_index() {
	local index=0
	local arg=""
	local expect_value=0
	_GHRP_ENDPOINT_INDEX=-1
	_GHRP_ENDPOINT=""
	while [[ "$index" -lt "${#_GHRP_ARGS[@]}" ]]; do
		arg="${_GHRP_ARGS[$index]}"
		if [[ "$expect_value" -eq 1 ]]; then
			expect_value=0
			index=$((index + 1))
			continue
		fi
		if _ghrp_is_value_flag "$arg"; then
			expect_value=1
			index=$((index + 1))
			continue
		fi
		case "$arg" in
		api | --paginate | --slurp | --include | -i | --silent) ;;
		--*=* | -F* | -H* | -q* | -X* | -p* | -f* | -t*) ;;
		-*) ;;
		*)
			_GHRP_ENDPOINT_INDEX="$index"
			_GHRP_ENDPOINT="$arg"
			return 0
			;;
		esac
		index=$((index + 1))
	done
	return 1
}

_ghrp_validate_prepare() {
	local paginate_requested="$1"
	local unsupported="$2"
	local method="$3"
	local fields_requested="$4"
	local method_explicit="$5"
	local jq_requested="$6"
	local template_requested="$7"

	[[ "$paginate_requested" -eq 1 ]] || return 1
	[[ "$unsupported" -eq 0 ]] || return 1
	[[ "$method" == "GET" ]] || return 1
	if [[ "$fields_requested" -eq 1 && "$method_explicit" -ne 1 ]]; then
		# Native gh changes its default method to POST when fields are present.
		# Only an explicit GET proves these fields belong in the query string.
		return 1
	fi
	if [[ "$_GHRP_SLURP_REQUESTED" -eq 1 && ("$jq_requested" -eq 1 || "$template_requested" -eq 1) ]]; then
		# Native gh rejects --slurp with --jq/--template before transport. Let the
		# native CLI preserve its exact diagnostic without recording a request.
		_GHRP_PREFLIGHT_ONLY=1
		return 1
	fi
	if [[ "$_GHRP_SLURP_REQUESTED" -eq 1 ]]; then
		[[ "$_GHRP_INCLUDE_REQUESTED" -eq 0 && "$_GHRP_SILENT_REQUESTED" -eq 0 ]] || return 1
		command -v jq >/dev/null 2>&1 || return 1
	fi
	[[ "$_GHRP_SILENT_REQUESTED" -eq 0 ]] || return 1
	_ghrp_find_endpoint_index || return 1
	[[ "$_GHRP_ENDPOINT" != "graphql" && "$_GHRP_ENDPOINT" != graphql/* ]] || return 1
	return 0
}

_ghrp_prepare() {
	local path="$1"
	shift
	local index=0
	local arg=""
	local paginate_requested=0
	local jq_requested=0
	local template_requested=0
	local fields_requested=0
	local unsupported=0
	local method="GET"
	local method_explicit=0
	local expect_value=""

	_GHRP_ARGS=("$@")
	_GHRP_BASE_ARGS=()
	_GHRP_INCLUDE_REQUESTED=0
	_GHRP_SLURP_REQUESTED=0
	_GHRP_SILENT_REQUESTED=0
	_GHRP_HOSTNAME="${GH_HOST:-github.com}"
	_GHRP_BASE_ENDPOINT_INDEX=-1
	_GHRP_PREFLIGHT_ONLY=0
	[[ "$path" == "rest" ]] || return 1
	[[ "${AIDEVOPS_GH_EXPLICIT_PAGINATION_DISABLE:-0}" != "1" ]] || return 1

	while [[ "$index" -lt "${#_GHRP_ARGS[@]}" ]]; do
		arg="${_GHRP_ARGS[$index]}"
		if [[ -n "$expect_value" ]]; then
			if [[ "$expect_value" == "method" ]]; then
				method="$arg"
				method_explicit=1
			elif [[ "$expect_value" == "hostname" ]]; then
				_GHRP_HOSTNAME="$arg"
			fi
			expect_value=""
			index=$((index + 1))
			continue
		fi
		case "$arg" in
		--paginate) paginate_requested=1 ;;
		--slurp) _GHRP_SLURP_REQUESTED=1 ;;
		--include | -i) _GHRP_INCLUDE_REQUESTED=1 ;;
		--jq | -q)
			jq_requested=1
			expect_value="$_GHRP_EXPECT_OPTION"
			;;
		--jq=* | -q*) jq_requested=1 ;;
		--template | -t)
			template_requested=1
			expect_value="$_GHRP_EXPECT_OPTION"
			;;
		--template=* | -t*) template_requested=1 ;;
		--method | -X) expect_value="method" ;;
		--method=*)
			method="${arg#--method=}"
			method_explicit=1
			;;
		-X*)
			method="${arg#-X}"
			method_explicit=1
			;;
		-F | --field | -f | --raw-field)
			fields_requested=1
			expect_value="$_GHRP_EXPECT_OPTION"
			;;
		-F* | --field=* | -f* | --raw-field=*) fields_requested=1 ;;
		--hostname) expect_value="hostname" ;;
		--hostname=*) _GHRP_HOSTNAME="${arg#--hostname=}" ;;
		-H | --header | -p | --preview) expect_value="$_GHRP_EXPECT_OPTION" ;;
		-H* | --header=* | -p* | --preview=* | api) ;;
		--silent) _GHRP_SILENT_REQUESTED=1 ;;
		--input | --cache)
			unsupported=1
			expect_value="$_GHRP_EXPECT_OPTION"
			;;
		--input=* | --cache=* | --verbose) unsupported=1 ;;
		-*) unsupported=1 ;;
		esac
		index=$((index + 1))
	done

	[[ -z "$expect_value" ]] || return 1
	_ghrp_validate_prepare "$paginate_requested" "$unsupported" "$method" \
		"$fields_requested" "$method_explicit" "$jq_requested" "$template_requested" || return 1
	return 0
}

_ghrp_build_base_args() {
	local index=0
	local arg=""
	local expect_value=0
	_GHRP_BASE_ARGS=()
	_GHRP_BASE_ENDPOINT_INDEX=-1
	while [[ "$index" -lt "${#_GHRP_ARGS[@]}" ]]; do
		arg="${_GHRP_ARGS[$index]}"
		if [[ "$index" -eq "$_GHRP_ENDPOINT_INDEX" ]]; then
			_GHRP_BASE_ENDPOINT_INDEX="${#_GHRP_BASE_ARGS[@]}"
			_GHRP_BASE_ARGS+=("$arg")
			expect_value=0
			index=$((index + 1))
			continue
		fi
		if [[ "$expect_value" -eq 1 ]]; then
			_GHRP_BASE_ARGS+=("$arg")
			expect_value=0
			index=$((index + 1))
			continue
		fi
		if _ghrp_is_value_flag "$arg"; then
			_GHRP_BASE_ARGS+=("$arg")
			expect_value=1
			index=$((index + 1))
			continue
		fi
		if [[ "$arg" == "--paginate" || "$arg" == "--slurp" ]]; then
			index=$((index + 1))
			continue
		fi
		_GHRP_BASE_ARGS+=("$arg")
		index=$((index + 1))
	done
	if [[ "$_GHRP_INCLUDE_REQUESTED" -eq 0 ]]; then
		_GHRP_BASE_ARGS+=(--include)
	fi
	[[ "$_GHRP_BASE_ENDPOINT_INDEX" -ge 0 ]] || return 1
	return 0
}

_ghrp_strip_replayed_fields() {
	local index=0
	local arg=""
	local value_mode=""
	local -a args=("$@")
	_GHRP_PAGE_ARGS=()
	while [[ "$index" -lt "${#args[@]}" ]]; do
		arg="${args[$index]}"
		if [[ "$value_mode" == "keep" ]]; then
			_GHRP_PAGE_ARGS+=("$arg")
			value_mode=""
			index=$((index + 1))
			continue
		fi
		if [[ "$value_mode" == "drop" ]]; then
			value_mode=""
			index=$((index + 1))
			continue
		fi
		case "$arg" in
		-F | --field | -f | --raw-field)
			value_mode="drop"
			;;
		-F* | --field=* | -f* | --raw-field=*) ;;
		*)
			_GHRP_PAGE_ARGS+=("$arg")
			if _ghrp_is_value_flag "$arg"; then
				value_mode="keep"
			fi
			;;
		esac
		index=$((index + 1))
	done
	return 0
}

_ghrp_split_included_response() {
	local response_file="$1"
	local header_file="$2"
	local body_file="$3"
	local body_offset=""
	body_offset=$(LC_ALL=C awk '
		BEGIN { bytes = 0; found = 0 }
		{
			bytes += length($0) + 1
			line = $0
			sub(/\r$/, "", line)
			if (line == "") {
				found = 1
				print bytes
				exit
			}
		}
		END { if (!found) exit 1 }
	' "$response_file") || return 1
	[[ "$body_offset" =~ ^[0-9]+$ && "$body_offset" -gt 0 ]] || return 1
	command dd if="$response_file" of="$header_file" bs="$body_offset" count=1 2>/dev/null || return 1
	command dd if="$response_file" of="$body_file" bs="$body_offset" skip=1 2>/dev/null || return 1
	return 0
}

_ghrp_next_endpoint() {
	local header_file="$1"
	local target=""
	local authority=""
	target=$(LC_ALL=C awk -v invalid="$_GHRP_INVALID_NEXT_SENTINEL" '
		function emit_next(segment, start_at, remainder, end_at, params) {
			start_at = index(segment, "<")
			if (start_at == 0) {
				print invalid
				return 1
			}
			remainder = substr(segment, start_at + 1)
			end_at = index(remainder, ">")
			if (end_at == 0) {
				print invalid
				return 1
			}
			params = tolower(substr(remainder, end_at + 1))
			if (params !~ /(^|[;[:space:]])rel[[:space:]]*=[[:space:]]*"next"([;[:space:]]|$)/ &&
				params !~ /(^|[;[:space:]])rel[[:space:]]*=[[:space:]]*next([;[:space:]]|$)/) return 0
			print substr(remainder, 1, end_at - 1)
			return 1
		}
		{
			line = tolower($0)
			if (line !~ /^link:/) next
			payload = substr($0, index($0, ":") + 1)
			segment = ""
			in_angle = 0
			in_quote = 0
			for (char_index = 1; char_index <= length(payload); char_index++) {
				char = substr(payload, char_index, 1)
				if (char == "<" && !in_quote) in_angle = 1
				if (char == ">" && in_angle) in_angle = 0
				if (char == "\"" && !in_angle) in_quote = !in_quote
				if (char == "," && !in_angle && !in_quote) {
					if (emit_next(segment)) exit
					segment = ""
					continue
				}
				segment = segment char
			}
			if (emit_next(segment)) exit
		}
	' "$header_file")
	[[ -n "$target" ]] || return 1
	[[ "$target" != "$_GHRP_INVALID_NEXT_SENTINEL" ]] || return 2
	case "$target" in
	https://* | http://*)
		target="${target#*://}"
		[[ "$target" == */* ]] || return 2
		authority="${target%%/*}"
		target="${target#*/}"
		case "$_GHRP_HOSTNAME" in
		github.com)
			[[ "$authority" == "github.com" || "$authority" == "api.github.com" ]] || return 2
			;;
		*)
			[[ "$authority" == "$_GHRP_HOSTNAME" || "$authority" == "api.${_GHRP_HOSTNAME}" ]] || return 2
			;;
		esac
		;;
	/*) target="${target#/}" ;;
	esac
	case "$target" in
	api/v3/*) target="${target#api/v3/}" ;;
	esac
	[[ -n "$target" && "$target" != -* ]] || return 2
	case "$target" in
	*$'\n'* | *$'\r'*) return 2 ;;
	esac
	printf '%s' "$target"
	return 0
}

_ghrp_max_pages() {
	local value="${AIDEVOPS_GH_REST_MAX_PAGES:-100}"
	if [[ ! "$value" =~ ^[0-9]+$ || "$value" -lt 1 ]]; then
		value=100
	fi
	if [[ "$value" -gt 1000 ]]; then
		value=1000
	fi
	printf '%s' "$value"
	return 0
}

_ghrp_cleanup_temp() {
	local temp_root="$1"
	if [[ -n "$temp_root" && -d "$temp_root" ]]; then
		rm -rf -- "$temp_root"
	fi
	return 0
}

_ghrp_restore_trap() {
	local signal="$1"
	local saved_trap="$2"
	trap - "$signal"
	if [[ -n "$saved_trap" ]]; then
		# shellcheck disable=SC2294 # trap -p emits shell-escaped restorable code.
		eval "$saved_trap"
	fi
	return 0
}

_ghrp_release_temp() {
	local temp_root="$1"
	local exit_trap="$2"
	local hup_trap="$3"
	local int_trap="$4"
	local term_trap="$5"
	_ghrp_cleanup_temp "$temp_root"
	_ghrp_restore_trap EXIT "$exit_trap"
	_ghrp_restore_trap HUP "$hup_trap"
	_ghrp_restore_trap INT "$int_trap"
	_ghrp_restore_trap TERM "$term_trap"
	return 0
}

_ghrp_emit_page_output() {
	local response_file="$1"
	local body_file="$2"
	if [[ "$_GHRP_SLURP_REQUESTED" -eq 1 ]]; then
		_GHRP_PAGE_FILES+=("$body_file")
	elif [[ "$_GHRP_INCLUDE_REQUESTED" -eq 1 ]]; then
		command cat "$response_file" || return 1
	else
		command cat "$body_file" || return 1
	fi
	return 0
}

_ghrp_resolve_next_page() {
	local header_file="$1"
	local rc=0
	local visited_endpoint=""
	_GHRP_NEXT_ENDPOINT=""
	_GHRP_NEXT_ENDPOINT=$(_ghrp_next_endpoint "$header_file" 2>/dev/null) || rc=$?
	[[ "$rc" -ne 1 ]] || return 1
	if [[ "$rc" -ne 0 ]]; then
		printf 'gh pagination: rejected an invalid next-page link\n' >&2
		return 2
	fi
	for visited_endpoint in "${_GHRP_VISITED_ENDPOINTS[@]}"; do
		if [[ "$_GHRP_NEXT_ENDPOINT" == "$visited_endpoint" ]]; then
			printf 'gh pagination: repeated next-page link detected\n' >&2
			return 2
		fi
	done
	_GHRP_VISITED_ENDPOINTS+=("$_GHRP_NEXT_ENDPOINT")
	return 0
}

_ghrp_run() {
	local executable="$1"
	shift
	local path="$1"
	shift
	local caller="$1"
	shift
	local retry="$1"
	shift
	local temp_base="${AIDEVOPS_TEMP_DIR:-${HOME:-}/.aidevops/.agent-workspace/tmp}"
	local temp_root=""
	local page_count=0
	local max_pages=100
	local page_endpoint="$_GHRP_ENDPOINT"
	local response_file=""
	local header_file=""
	local body_file=""
	local rc=0
	local prior_exit_trap=""
	local prior_hup_trap=""
	local prior_int_trap=""
	local prior_term_trap=""
	local -a page_args=()

	_GHRP_FALLBACK_SAFE=1
	_GHRP_PAGE_FILES=()
	_GHRP_VISITED_ENDPOINTS=("$page_endpoint")
	_ghrp_build_base_args || return 125
	max_pages=$(_ghrp_max_pages)
	[[ -n "$temp_base" ]] || return 125
	mkdir -p "$temp_base" 2>/dev/null || return 125
	temp_root=$(mktemp -d "${temp_base}/gh-rest-pages.XXXXXX") || return 125
	prior_exit_trap=$(trap -p EXIT)
	prior_hup_trap=$(trap -p HUP)
	prior_int_trap=$(trap -p INT)
	prior_term_trap=$(trap -p TERM)
	trap '_ghrp_cleanup_temp "$temp_root"' EXIT
	trap 'exit 129' HUP
	trap 'exit 130' INT
	trap 'exit 143' TERM

	while :; do
		if [[ "$page_count" -ge "$max_pages" ]]; then
			printf 'gh pagination: page budget exhausted after %s pages\n' "$page_count" >&2
			_ghrp_release_temp "$temp_root" "$prior_exit_trap" "$prior_hup_trap" "$prior_int_trap" "$prior_term_trap"
			return 1
		fi
		page_count=$((page_count + 1))
		page_args=("${_GHRP_BASE_ARGS[@]}")
		page_args[$_GHRP_BASE_ENDPOINT_INDEX]="$page_endpoint"
		if [[ "$page_count" -gt 1 ]]; then
			_ghrp_strip_replayed_fields "${page_args[@]}"
			page_args=("${_GHRP_PAGE_ARGS[@]}")
		fi
		response_file="${temp_root}/response-${page_count}.txt"
		header_file="${temp_root}/headers-${page_count}.txt"
		body_file="${temp_root}/body-${page_count}.json"

		_GHRP_FALLBACK_SAFE=0
		AIDEVOPS_GH_PAGE_NUMBER="$page_count" \
			AIDEVOPS_GH_ROUTE_DECISION="${AIDEVOPS_GH_ROUTE_DECISION:-explicit-rest-pagination}" \
			_shim_run_single_transport "$executable" "$path" "$caller" "$retry" "${page_args[@]}" >"$response_file"
		rc=$?
		if [[ "$rc" -ne 0 ]]; then
			_ghrp_release_temp "$temp_root" "$prior_exit_trap" "$prior_hup_trap" "$prior_int_trap" "$prior_term_trap"
			return "$rc"
		fi
		if ! _ghrp_split_included_response "$response_file" "$header_file" "$body_file"; then
			printf 'gh pagination: could not parse included response headers\n' >&2
			_ghrp_release_temp "$temp_root" "$prior_exit_trap" "$prior_hup_trap" "$prior_int_trap" "$prior_term_trap"
			return 1
		fi

		if ! _ghrp_emit_page_output "$response_file" "$body_file"; then
			_ghrp_release_temp "$temp_root" "$prior_exit_trap" "$prior_hup_trap" "$prior_int_trap" "$prior_term_trap"
			return 1
		fi

		rc=0
		_ghrp_resolve_next_page "$header_file" || rc=$?
		if [[ "$rc" -eq 1 ]]; then
			break
		fi
		if [[ "$rc" -ne 0 ]]; then
			_ghrp_release_temp "$temp_root" "$prior_exit_trap" "$prior_hup_trap" "$prior_int_trap" "$prior_term_trap"
			return 1
		fi
		page_endpoint="$_GHRP_NEXT_ENDPOINT"
	done

	if [[ "$_GHRP_SLURP_REQUESTED" -eq 1 ]]; then
		jq -s '.' "${_GHRP_PAGE_FILES[@]}" || {
			_ghrp_release_temp "$temp_root" "$prior_exit_trap" "$prior_hup_trap" "$prior_int_trap" "$prior_term_trap"
			return 1
		}
	fi
	_ghrp_release_temp "$temp_root" "$prior_exit_trap" "$prior_hup_trap" "$prior_int_trap" "$prior_term_trap"
	return 0
}
