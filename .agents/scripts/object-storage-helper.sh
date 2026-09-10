#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

# Safe, provider-neutral object storage operations backed by rclone.  This helper
# deliberately never passes credentials or arbitrary user flags to rclone.
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
# shellcheck source=shared-constants.sh
[[ -f "$SCRIPT_DIR/shared-constants.sh" ]] && source "$SCRIPT_DIR/shared-constants.sh"

CONFIG_FILE="${AIDEVOPS_OBJECT_STORAGE_CONFIG:-$SCRIPT_DIR/../../configs/object-storage-config.json}"
RCLONE_BIN="${AIDEVOPS_RCLONE_BIN:-rclone}"
MAX_LIST_LIMIT=1000
ERROR_ARGUMENTS_INVALID="arguments_invalid"
ERROR_RCLONE_FAILED="rclone_failed"

usage() {
	cat <<'USAGE'
Usage: object-storage-helper.sh <command> <account> [arguments]

Commands:
  readiness <account>
  list-buckets <account>
  list-objects <account> <bucket> --limit <1-1000>
  object-info <account> <bucket> <object>
  verify-backups <account> <bucket> [--max-age-days <1-3650>]
  audit-protection <account> <bucket>
  copy <account> <bucket> <source> <destination> [--confirm preview:<account>:<bucket>]
  download <account> <bucket> <object> <destination> [--confirm preview:<account>:<bucket>]

Configuration only stores named rclone remotes and bucket allowlists. It never
writes rclone configuration or accepts arbitrary rclone flags.
USAGE
	return 0
}

fail_json() {
	local code="$1"
	jq -cn --arg status "error" --arg code "$code" '{status:$status,code:$code}'
	return 1
}

safe_value() {
	local value="$1"
	[[ -n "$value" && "$value" != *$'\n'* && "$value" != *$'\r'* && "$value" != *".."* && "$value" != -* && "$value" != *://* ]]
}

check_dependencies() {
	command -v jq >/dev/null 2>&1 || {
		fail_json "jq_unavailable"
		return 1
	}
	command -v "$RCLONE_BIN" >/dev/null 2>&1 || {
		fail_json "rclone_unavailable"
		return 1
	}
	return 0
}

load_config() {
	[[ -f "$CONFIG_FILE" ]] || {
		fail_json "config_unavailable"
		return 1
	}
	jq -e '.version == 1 and (.accounts | type == "object")' "$CONFIG_FILE" >/dev/null 2>&1 || {
		fail_json "config_invalid"
		return 1
	}
	return 0
}

get_account_config() {
	local account="$1"
	safe_value "$account" || {
		fail_json "account_invalid"
		return 1
	}
	ACCOUNT_JSON=$(jq -ce --arg account "$account" '.accounts[$account] | select(type == "object")' "$CONFIG_FILE") || {
		fail_json "account_unknown"
		return 1
	}
	ACCOUNT_REMOTE=$(jq -r '.remote' <<<"$ACCOUNT_JSON")
	ACCOUNT_PROVIDER=$(jq -r '.provider' <<<"$ACCOUNT_JSON")
	[[ "$ACCOUNT_REMOTE" =~ ^[A-Za-z0-9_-]+$ ]] || {
		fail_json "remote_invalid"
		return 1
	}
	case "$ACCOUNT_PROVIDER" in idrive-e2 | backblaze-b2 | wasabi | s3-compatible) ;; *)
		fail_json "provider_unknown"
		return 1
		;;
	esac
	validate_provider_endpoint || return 1
	return 0
}

validate_provider_endpoint() {
	local endpoint region endpoint_region
	endpoint=$(jq -r '.endpoint // empty' <<<"$ACCOUNT_JSON")
	region=$(jq -r '.region // empty' <<<"$ACCOUNT_JSON")
	case "$ACCOUNT_PROVIDER" in
	idrive-e2)
		[[ "$endpoint" =~ ^https://s3\.([a-z0-9-]+)\.idrivee2\.com$ ]] || {
			fail_json "idrive_endpoint_invalid"
			return 1
		}
		endpoint_region="${BASH_REMATCH[1]}"
		;;
	wasabi)
		[[ "$endpoint" =~ ^https://s3\.([a-z0-9-]+)\.wasabisys\.com$ ]] || {
			fail_json "wasabi_endpoint_invalid"
			return 1
		}
		endpoint_region="${BASH_REMATCH[1]}"
		;;
	*)
		return 0
		;;
	esac
	[[ "$region" =~ ^[a-z0-9-]+$ ]] || {
		fail_json "${ACCOUNT_PROVIDER}_endpoint_invalid"
		return 1
	}
	[[ "$endpoint_region" == "$region" ]] || {
		fail_json "${ACCOUNT_PROVIDER}_region_mismatch"
		return 1
	}
	return 0
}

validate_bucket() {
	local bucket="$1"
	safe_value "$bucket" || {
		fail_json "bucket_invalid"
		return 1
	}
	jq -e --arg bucket "$bucket" '.buckets | index($bucket) != null' <<<"$ACCOUNT_JSON" >/dev/null || {
		fail_json "bucket_not_allowed"
		return 1
	}
	return 0
}

validate_object() {
	local object="$1"
	safe_value "$object" || {
		fail_json "object_invalid"
		return 1
	}
	return 0
}

rclone_json() {
	"$RCLONE_BIN" "$@" --use-json-log --log-level ERROR 2>/dev/null
}

emit_result() {
	local command="$1"
	local account="$2"
	local data="$3"
	jq -cn --arg command "$command" --arg account "$account" --argjson data "$data" '{status:"ok",command:$command,account:$account,data:$data}'
	return 0
}

run_readiness() {
	local account="$1"
	local version=""
	version=$("$RCLONE_BIN" version 2>/dev/null | awk 'NR == 1 { print $2 }') || fail_json "$ERROR_RCLONE_FAILED"
	emit_result "readiness" "$account" "$(jq -cn --arg provider "$ACCOUNT_PROVIDER" --arg version "$version" '{provider:$provider,rclone_version:$version,ready:true}')"
}

run_list_buckets() {
	local account="$1"
	local output=""
	output=$(rclone_json lsd "${ACCOUNT_REMOTE}:") || fail_json "$ERROR_RCLONE_FAILED"
	emit_result "list-buckets" "$account" "$(printf '%s\n' "$output" | jq -s '[.[] | {bucket:.Path}]')"
}

run_list_objects() {
	local account="$1" bucket="$2" limit="$3" output=""
	[[ "$limit" =~ ^[1-9][0-9]*$ && "$limit" -le "$MAX_LIST_LIMIT" ]] || fail_json "list_limit_invalid"
	# rclone's max-depth prevents recursive expansion; jq applies the explicit output bound.
	output=$(rclone_json lsjson --files-only --max-depth 1 "${ACCOUNT_REMOTE}:${bucket}") || fail_json "$ERROR_RCLONE_FAILED"
	emit_result "list-objects" "$account" "$(printf '%s\n' "$output" | jq --argjson limit "$limit" 'if type == "array" then .[0:$limit] else [] end')"
}

run_object_info() {
	local account="$1" bucket="$2" object="$3" output=""
	output=$(rclone_json lsjson --files-only "${ACCOUNT_REMOTE}:${bucket}/${object}") || fail_json "$ERROR_RCLONE_FAILED"
	emit_result "object-info" "$account" "$(printf '%s\n' "$output" | jq 'if type == "array" then .[0] else null end')"
}

run_verify_backups() {
	local account="$1" bucket="$2" max_age="$3" output=""
	[[ "$max_age" =~ ^[1-9][0-9]*$ && "$max_age" -le 3650 ]] || fail_json "max_age_invalid"
	output=$(rclone_json lsjson --files-only --max-depth 1 "${ACCOUNT_REMOTE}:${bucket}") || fail_json "$ERROR_RCLONE_FAILED"
	emit_result "verify-backups" "$account" "$(printf '%s\n' "$output" | jq --argjson days "$max_age" '
		if type != "array" then [] else . end |
		[.[] | select((.ModTime? | fromdateiso8601) >= (now - ($days * 86400)))] as $fresh |
		{max_age_days:$days,objects:length,fresh_objects:($fresh | length),fresh:($fresh | length > 0),restore_verified:false}
	')"
}

run_audit_protection() {
	local account="$1"
	local bucket="$2"
	emit_result "audit-protection" "$account" "$(jq -cn --arg bucket "$bucket" '{bucket:$bucket,mutation_supported:false,status:"manual_provider_review_required"}')"
}

run_transfer() {
	local command="$1" account="$2" bucket="$3" source="$4" destination="$5" confirmation="$6"
	local expected="preview:${account}:${bucket}"
	[[ "$confirmation" == "$expected" ]] || {
		emit_result "$command" "$account" "$(jq -cn --arg confirmation "$expected" '{dry_run:true,confirmation_required:$confirmation}')"
		return 0
	}
	# The confirmation authorizes execution, but rclone remains dry-run in this foundation.
	"$RCLONE_BIN" copy --dry-run "${ACCOUNT_REMOTE}:${bucket}/${source}" "$destination" >/dev/null 2>&1 || fail_json "$ERROR_RCLONE_FAILED"
	emit_result "$command" "$account" "$(jq -cn '{dry_run:true,executed:false}')"
}

main() {
	local command="${1:-}" account="${2:-}" bucket="${3:-}" argument="${4:-}" option="${5:-}" value="${6:-}"
	case "$command" in help | -h | --help | '')
		usage
		return 0
		;;
	esac
	check_dependencies && load_config && get_account_config "$account" || return 1
	case "$command" in
	readiness)
		[[ "$#" -eq 2 ]] || {
			fail_json "$ERROR_ARGUMENTS_INVALID"
			return 1
		}
		run_readiness "$account"
		;;
	list-buckets)
		[[ "$#" -eq 2 ]] || {
			fail_json "$ERROR_ARGUMENTS_INVALID"
			return 1
		}
		run_list_buckets "$account"
		;;
	list-objects)
		validate_bucket "$bucket" || return 1
		[[ "$argument" == "--limit" ]] || {
			fail_json "$ERROR_ARGUMENTS_INVALID"
			return 1
		}
		run_list_objects "$account" "$bucket" "$option"
		;;
	object-info)
		validate_bucket "$bucket" && validate_object "$argument" || return 1
		run_object_info "$account" "$bucket" "$argument"
		;;
	verify-backups)
		validate_bucket "$bucket" || return 1
		if [[ "$#" -eq 3 ]]; then argument=30; elif [[ "$argument" == "--max-age-days" ]]; then argument="$option"; else
			fail_json "$ERROR_ARGUMENTS_INVALID"
			return 1
		fi
		run_verify_backups "$account" "$bucket" "$argument"
		;;
	audit-protection)
		validate_bucket "$bucket" || return 1
		run_audit_protection "$account" "$bucket"
		;;
	copy | download)
		validate_bucket "$bucket" && validate_object "$argument" && safe_value "$option" || return 1
		run_transfer "$command" "$account" "$bucket" "$argument" "$option" "$value"
		;;
	*)
		fail_json "command_unknown"
		return 1
		;;
	esac
}

main "$@"
