#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# Conservative primary-rate quota attribution for direct `gh api` REST calls.
# The caller may record the returned value only after the command succeeds.
# Ambiguous transports intentionally return no value so benchmark evidence
# remains fail-closed rather than estimating cost from cumulative headers.

_GHQA_ENDPOINT=""
_GHQA_HOSTNAME=""
_GHQA_METHOD=""
_GHQA_FIELDS_REQUESTED=0
_GHQA_INPUT_REQUESTED=0
_GHQA_AMBIGUOUS=0

_ghqa_lower() {
	local value="$1"
	printf '%s' "$value" | LC_ALL=C tr '[:upper:]' '[:lower:]'
	return 0
}

_ghqa_is_conditional_header() {
	local header="$1"
	header=$(_ghqa_lower "$header")
	[[ "$header" =~ ^[[:space:]]*if-(match|none-match|modified-since|unmodified-since)[[:space:]]*: ]]
	return $?
}

_ghqa_apply_option_value() {
	local option="$1"
	local value="$2"
	case "$option" in
	-X | --method) _GHQA_METHOD=$(_ghqa_lower "$value") ;;
	-H | --header)
		_ghqa_is_conditional_header "$value" && _GHQA_AMBIGUOUS=1
		;;
	--hostname) _GHQA_HOSTNAME=$(_ghqa_lower "$value") ;;
	-F | --field | -f | --raw-field) _GHQA_FIELDS_REQUESTED=1 ;;
	--input) _GHQA_INPUT_REQUESTED=1 ;;
	--cache) _GHQA_AMBIGUOUS=1 ;;
	-q | --jq | -p | --preview | -t | --template) ;;
	*) _GHQA_AMBIGUOUS=1 ;;
	esac
	return 0
}

_ghqa_parse_api_args() {
	local path="$1"
	shift
	local arg=""
	local option=""
	local value=""
	_GHQA_ENDPOINT=""
	_GHQA_HOSTNAME=$(_ghqa_lower "${GH_HOST:-github.com}")
	_GHQA_METHOD=""
	_GHQA_FIELDS_REQUESTED=0
	_GHQA_INPUT_REQUESTED=0
	_GHQA_AMBIGUOUS=0
	[[ ("$path" == "rest" || "$path" == "search-rest") && "${1:-}" == "api" ]] || return 1
	shift
	while [[ $# -gt 0 ]]; do
		arg="$1"
		shift
		case "$arg" in
		--paginate) _GHQA_AMBIGUOUS=1 ;;
		--include | -i | --silent | --slurp | --verbose) ;;
		-X | --method | -H | --header | --hostname | -F | --field | -f | --raw-field | --input | --cache | -q | --jq | -p | --preview | -t | --template)
			if [[ $# -eq 0 ]]; then
				_GHQA_AMBIGUOUS=1
				continue
			fi
			value="$1"
			shift
			_ghqa_apply_option_value "$arg" "$value"
			;;
		--method=* | --header=* | --hostname=* | --field=* | --raw-field=* | --input=* | --cache=* | --jq=* | --preview=* | --template=*)
			option="${arg%%=*}"
			value="${arg#*=}"
			_ghqa_apply_option_value "$option" "$value"
			;;
		-X?*) _ghqa_apply_option_value -X "${arg#-X}" ;;
		-H?*) _ghqa_apply_option_value -H "${arg#-H}" ;;
		-F?*) _ghqa_apply_option_value -F "${arg#-F}" ;;
		-f?*) _ghqa_apply_option_value -f "${arg#-f}" ;;
		-q?*) _ghqa_apply_option_value -q "${arg#-q}" ;;
		-p?*) _ghqa_apply_option_value -p "${arg#-p}" ;;
		-t?*) _ghqa_apply_option_value -t "${arg#-t}" ;;
		-*) _GHQA_AMBIGUOUS=1 ;;
		*)
			if [[ -z "$_GHQA_ENDPOINT" ]]; then
				_GHQA_ENDPOINT="$arg"
			else
				_GHQA_AMBIGUOUS=1
			fi
			;;
		esac
	done
	[[ -n "$_GHQA_ENDPOINT" ]] || return 1
	return 0
}

_ghqa_normalize_endpoint() {
	local endpoint="$1"
	case "$endpoint" in
	https://api.github.com/*) endpoint="${endpoint#https://api.github.com/}" ;;
	https://github.com/api/v3/*) endpoint="${endpoint#https://github.com/api/v3/}" ;;
	http://* | https://* | *://*) return 1 ;;
	esac
	endpoint="${endpoint#/}"
	endpoint="${endpoint#api/v3/}"
	endpoint="${endpoint%%\?*}"
	endpoint="${endpoint%%#*}"
	[[ -n "$endpoint" ]] || return 1
	printf '%s' "$endpoint"
	return 0
}

# _ghqa_exact_success_cost <path> <gh argv...>
# Print an exact documented primary-rate cost only when one direct REST request
# is attributable after successful execution. Empty output/non-zero is unknown.
_ghqa_exact_success_cost() {
	local path="$1"
	shift
	local endpoint=""
	local method=""
	_ghqa_parse_api_args "$path" "$@" || return 1
	[[ "$_GHQA_AMBIGUOUS" -eq 0 && "$_GHQA_HOSTNAME" == "github.com" ]] || return 1
	endpoint=$(_ghqa_normalize_endpoint "$_GHQA_ENDPOINT") || return 1
	[[ "$endpoint" != "graphql" && "$endpoint" != graphql/* ]] || return 1
	method="$_GHQA_METHOD"
	if [[ -z "$method" ]]; then
		method="get"
		if [[ "$_GHQA_FIELDS_REQUESTED" -eq 1 || "$_GHQA_INPUT_REQUESTED" -eq 1 ]]; then
			method="post"
		fi
	fi
	if [[ "$method" == "get" && "$endpoint" == "rate_limit" ]]; then
		printf '0'
		return 0
	fi
	printf '1'
	return 0
}
