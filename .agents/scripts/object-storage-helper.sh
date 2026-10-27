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
ERROR_BUCKET_NOT_ALLOWED="bucket_not_allowed"
MANUAL_REVIEW="manual_provider_review_required"
STATE_VERIFIED="VERIFIED"

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
  migrate-plan <src-account> <dst-account> [--bucket <b>]... [--remote-host <alias>]
  migrate-run <src-account> <dst-account> [--bucket <b>]... [--lane large|small] [--remote-host <alias>] [--confirm migrate:<src>:<dst>]
  migrate-retire-source <src-account> <dst-account> --bucket <b> [--confirm retire:<src>:<dst>:<b>]

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
		case "$endpoint" in
		https://s3.wasabisys.com)
			endpoint_region="us-east-1"
			;;
		https://s3.us-east-1.wasabisys.com | https://s3.us-east-2.wasabisys.com | https://s3.us-central-1.wasabisys.com | https://s3.us-west-1.wasabisys.com | https://s3.us-west-2.wasabisys.com | https://s3.ca-central-1.wasabisys.com | https://s3.eu-central-1.wasabisys.com | https://s3.eu-central-2.wasabisys.com | https://s3.eu-west-1.wasabisys.com | https://s3.eu-west-2.wasabisys.com | https://s3.eu-west-3.wasabisys.com | https://s3.eu-south-1.wasabisys.com | https://s3.ap-northeast-1.wasabisys.com | https://s3.ap-northeast-2.wasabisys.com | https://s3.ap-southeast-1.wasabisys.com | https://s3.ap-southeast-2.wasabisys.com)
			endpoint_region="${endpoint#https://s3.}"
			endpoint_region="${endpoint_region%.wasabisys.com}"
			;;
		https://s3.nl-1.wasabisys.com) endpoint_region="eu-central-1" ;;
		https://s3.de-1.wasabisys.com) endpoint_region="eu-central-2" ;;
		https://s3.uk-1.wasabisys.com) endpoint_region="eu-west-1" ;;
		https://s3.fr-1.wasabisys.com) endpoint_region="eu-west-2" ;;
		https://s3.uk-2.wasabisys.com) endpoint_region="eu-west-3" ;;
		https://s3.it-1.wasabisys.com) endpoint_region="eu-south-1" ;;
		*)
			fail_json "wasabi_endpoint_invalid"
			return 1
			;;
		esac
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
		fail_json "$ERROR_BUCKET_NOT_ALLOWED"
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
	emit_result "audit-protection" "$account" "$(jq -cn --arg bucket "$bucket" --arg review "$MANUAL_REVIEW" '{bucket:$bucket,mutation_supported:false,status:$review}')"
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

# ---------------------------------------------------------------------------
# Bucket migration (copy, verify, retire source). Credentials are never passed:
# both accounts must reference rclone remotes that already exist on the machine
# that runs rclone (local, or --remote-host alias reached over SSH).
# ---------------------------------------------------------------------------

MIGRATE_MIN_RCLONE_MINOR=70
MIGRATE_LIST_CUTOFF=200000
MIGRATE_STATE_DIR="${AIDEVOPS_OBJECT_STORAGE_STATE_DIR:-$HOME/.aidevops/.agent-workspace/work/object-storage-migrations}"
M_BUCKETS=()
M_LANE="small"
M_REMOTE_HOST=""
M_CONFIRM=""
M_DST_REMOTE=""
M_SRC_REMOTE=""
M_SRC_JSON=""
M_DST_JSON=""
M_SRC_PROVIDER=""
M_DST_PROVIDER=""

# Run rclone locally, or on the transfer host over SSH (arguments shell-quoted).
mrc() {
	if [[ -n "$M_REMOTE_HOST" ]]; then
		ssh -o BatchMode=yes -- "$M_REMOTE_HOST" "$(printf '%q ' "$RCLONE_BIN" "$@")"
		return $?
	fi
	"$RCLONE_BIN" "$@"
}

migrate_parse_options() {
	local -a args=("$@")
	local flag flag_value
	M_BUCKETS=()
	M_LANE="small"
	M_REMOTE_HOST=""
	M_CONFIRM=""
	while [[ "${#args[@]}" -gt 0 ]]; do
		flag="${args[0]}"
		flag_value="${args[1]:-}"
		[[ "${#args[@]}" -ge 2 ]] || {
			fail_json "$ERROR_ARGUMENTS_INVALID"
			return 1
		}
		case "$flag" in
		--bucket) M_BUCKETS+=("$flag_value") ;;
		--lane) M_LANE="$flag_value" ;;
		--remote-host) M_REMOTE_HOST="$flag_value" ;;
		--confirm) M_CONFIRM="$flag_value" ;;
		*)
			fail_json "$ERROR_ARGUMENTS_INVALID"
			return 1
			;;
		esac
		args=("${args[@]:2}")
	done
	case "$M_LANE" in large | small) ;; *)
		fail_json "lane_invalid"
		return 1
		;;
	esac
	if [[ -n "$M_REMOTE_HOST" && ! "$M_REMOTE_HOST" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]]; then
		fail_json "remote_host_invalid"
		return 1
	fi
	return 0
}

migrate_load_accounts() {
	local src="$1" dst="$2"
	[[ "$src" != "$dst" ]] || {
		fail_json "accounts_identical"
		return 1
	}
	get_account_config "$src" || return 1
	M_SRC_JSON="$ACCOUNT_JSON"
	M_SRC_REMOTE="$ACCOUNT_REMOTE"
	M_SRC_PROVIDER="$ACCOUNT_PROVIDER"
	get_account_config "$dst" || return 1
	M_DST_JSON="$ACCOUNT_JSON"
	M_DST_REMOTE="$ACCOUNT_REMOTE"
	M_DST_PROVIDER="$ACCOUNT_PROVIDER"
	[[ "$M_SRC_REMOTE" != "$M_DST_REMOTE" ]] || {
		fail_json "accounts_identical"
		return 1
	}
	return 0
}

# Select buckets: explicit --bucket values or the whole source allowlist. Every
# bucket must be allowlisted on both accounts and be a plain DNS-style name.
migrate_select_buckets() {
	local bucket
	if [[ "${#M_BUCKETS[@]}" -eq 0 ]]; then
		while IFS= read -r bucket; do
			[[ -n "$bucket" ]] && M_BUCKETS+=("$bucket")
		done < <(jq -r '.buckets[]?' <<<"$M_SRC_JSON")
	fi
	[[ "${#M_BUCKETS[@]}" -gt 0 ]] || {
		fail_json "$ERROR_BUCKET_NOT_ALLOWED"
		return 1
	}
	for bucket in "${M_BUCKETS[@]}"; do
		safe_value "$bucket" && [[ "$bucket" =~ ^[a-z0-9][a-z0-9.-]*$ ]] || {
			fail_json "bucket_invalid"
			return 1
		}
		jq -e --arg bucket "$bucket" '.buckets | index($bucket) != null' <<<"$M_SRC_JSON" >/dev/null &&
			jq -e --arg bucket "$bucket" '.buckets | index($bucket) != null' <<<"$M_DST_JSON" >/dev/null || {
			fail_json "$ERROR_BUCKET_NOT_ALLOWED"
			return 1
		}
	done
	return 0
}

# rclone >= 1.70 is required: older releases hold whole directory listings in
# memory, which exhausts small transfer hosts on very large flat prefixes.
migrate_check_rclone_version() {
	local version major minor
	version=$(mrc version 2>/dev/null | awk 'NR == 1 { print $2 }') || version=""
	if [[ "$version" =~ ^v?([0-9]+)\.([0-9]+) ]]; then
		major="${BASH_REMATCH[1]}"
		minor="${BASH_REMATCH[2]}"
		if [[ "$major" -gt 1 || ( "$major" -eq 1 && "$minor" -ge "$MIGRATE_MIN_RCLONE_MINOR" ) ]]; then
			return 0
		fi
	fi
	fail_json "rclone_version_too_old"
	return 1
}

migrate_status_file() {
	local src="$1" dst="$2" bucket="$3"
	printf '%s/%s__%s/%s.status' "$MIGRATE_STATE_DIR" "$src" "$dst" "$bucket"
	return 0
}

migrate_read_status() {
	local file="$1" state=""
	if [[ -f "$file" ]]; then
		read -r state _ <"$file" || true
	fi
	printf '%s' "${state:-NONE}"
	return 0
}

migrate_write_status() {
	local file="$1" state="$2" tmp
	mkdir -p "$(dirname "$file")" || return 1
	tmp="${file}.tmp.$$"
	printf '%s %s\n' "$state" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >"$tmp" && mv "$tmp" "$file" || return 1
	return 0
}

# One-way size/hash check: every source object must exist unchanged on the destination.
migrate_check_bucket() {
	local bucket="$1"
	mrc check --one-way --list-cutoff "$MIGRATE_LIST_CUTOFF" "${M_SRC_REMOTE}:${bucket}" "${M_DST_REMOTE}:${bucket}" >/dev/null 2>&1
	return $?
}

migrate_plan_bucket() {
	local bucket="$1" size_json="" versioning="" newest="" count=0 bytes=0
	size_json=$(mrc size --json --list-cutoff "$MIGRATE_LIST_CUTOFF" "${M_SRC_REMOTE}:${bucket}" 2>/dev/null) || size_json=""
	count=$(jq -r '.count // 0' <<<"$size_json" 2>/dev/null) || count=0
	bytes=$(jq -r '.bytes // 0' <<<"$size_json" 2>/dev/null) || bytes=0
	versioning=$(mrc backend versioning "${M_SRC_REMOTE}:${bucket}" 2>/dev/null) || versioning=""
	versioning="${versioning%%$'\n'*}"
	versioning="${versioning//\"/}"
	newest=$(mrc lsf -R --files-only --format t --list-cutoff "$MIGRATE_LIST_CUTOFF" "${M_SRC_REMOTE}:${bucket}" 2>/dev/null | sort | tail -n 1) || newest=""
	jq -cn --arg review "$MANUAL_REVIEW" --arg bucket "$bucket" --arg region "$(jq -r '.region // "unknown"' <<<"$M_SRC_JSON")" \
		--arg versioning "${versioning:-unknown}" --arg newest "$newest" \
		--argjson count "${count:-0}" --argjson bytes "${bytes:-0}" '{
			bucket:$bucket, region:$region, region_source:"configured_account",
			versioning:$versioning, object_lock:$review,
			public_acl:$review, bucket_policy:$review,
			policies_and_acls_copied:false, objects:$count, bytes:$bytes,
			newest_upload:(if $newest == "" then null else $newest end)
		}'
	return 0
}

run_migrate_plan() {
	local src="$1" dst="$2" bucket rows=""
	migrate_check_rclone_version || return 1
	for bucket in "${M_BUCKETS[@]}"; do
		rows+="$(migrate_plan_bucket "$bucket")"$'\n'
	done
	emit_result "migrate-plan" "$src" "$(printf '%s' "$rows" | jq -s --arg dst "$dst" --arg lane "$M_LANE" '{destination:$dst,read_only:true,buckets:.}')"
	return 0
}

migrate_copy_bucket() {
	local bucket="$1"
	local -a lane_flags
	if [[ "$M_LANE" == "large" ]]; then
		# memory ~ transfers x s3-upload-concurrency x s3-chunk-size (4 x 4 x 64M = 1 GiB)
		lane_flags=(--transfers 4 --checkers 8 --s3-upload-concurrency 4 --s3-chunk-size 64M)
	else
		lane_flags=(--transfers 64 --checkers 32 --buffer-size 1M)
	fi
	mrc copy --list-cutoff "$MIGRATE_LIST_CUTOFF" "${lane_flags[@]}" "${M_SRC_REMOTE}:${bucket}" "${M_DST_REMOTE}:${bucket}" >/dev/null 2>&1
	return $?
}

run_migrate_run() {
	local src="$1" dst="$2" bucket file state rows="" result failed=0
	local expected="migrate:${src}:${dst}"
	if [[ "$M_CONFIRM" != "$expected" ]]; then
		emit_result "migrate-run" "$src" "$(printf '%s\n' "${M_BUCKETS[@]}" | jq -R . | jq -s --arg c "$expected" --arg dst "$dst" '{dry_run:true,confirmation_required:$c,destination:$dst,buckets:.}')"
		return 0
	fi
	migrate_check_rclone_version || return 1
	for bucket in "${M_BUCKETS[@]}"; do
		file=$(migrate_status_file "$src" "$dst" "$bucket")
		state=$(migrate_read_status "$file")
		if [[ "$state" == "$STATE_VERIFIED" ]]; then
			result="$STATE_VERIFIED"
			rows+="$(jq -cn --arg b "$bucket" --arg s "$result" '{bucket:$b,status:$s,skipped:true}')"$'\n'
			continue
		fi
		migrate_write_status "$file" COPYING || {
			fail_json "state_unwritable"
			return 1
		}
		if migrate_copy_bucket "$bucket"; then
			migrate_write_status "$file" COPIED || true
			# Reclaim stale in-flight multipart uploads left by earlier interrupted runs.
			mrc backend cleanup "${M_DST_REMOTE}:${bucket}" >/dev/null 2>&1 || true
			if migrate_check_bucket "$bucket"; then
				result="$STATE_VERIFIED"
			else
				result="CHECK_FAIL"
			fi
		else
			result="COPY_FAIL"
		fi
		migrate_write_status "$file" "$result" || true
		[[ "$result" == "$STATE_VERIFIED" ]] || failed=1
		rows+="$(jq -cn --arg b "$bucket" --arg s "$result" '{bucket:$b,status:$s,skipped:false}')"$'\n'
	done
	emit_result "migrate-run" "$src" "$(printf '%s' "$rows" | jq -s --arg dst "$dst" --arg lane "$M_LANE" '{destination:$dst,lane:$lane,dry_run:false,buckets:.}')"
	return "$failed"
}

# Gated source delete: exactly one bucket, VERIFIED status, exact token, and a
# fresh verification immediately before purge.
run_migrate_retire() {
	local src="$1" dst="$2" bucket file state
	[[ "${#M_BUCKETS[@]}" -eq 1 ]] || {
		fail_json "retire_requires_single_bucket"
		return 1
	}
	bucket="${M_BUCKETS[0]}"
	file=$(migrate_status_file "$src" "$dst" "$bucket")
	state=$(migrate_read_status "$file")
	[[ "$state" == "$STATE_VERIFIED" ]] || {
		fail_json "bucket_not_verified"
		return 1
	}
	local expected="retire:${src}:${dst}:${bucket}"
	if [[ -z "$M_CONFIRM" ]]; then
		emit_result "migrate-retire-source" "$src" "$(jq -cn --arg c "$expected" --arg b "$bucket" '{dry_run:true,bucket:$b,confirmation_required:$c}')"
		return 0
	fi
	[[ "$M_CONFIRM" == "$expected" ]] || {
		fail_json "confirmation_invalid"
		return 1
	}
	migrate_check_rclone_version || return 1
	if ! migrate_check_bucket "$bucket"; then
		migrate_write_status "$file" CHECK_FAIL || true
		fail_json "recheck_failed"
		return 1
	fi
	mrc purge "${M_SRC_REMOTE}:${bucket}" >/dev/null 2>&1 || {
		fail_json "$ERROR_RCLONE_FAILED"
		return 1
	}
	migrate_write_status "$file" RETIRED || true
	emit_result "migrate-retire-source" "$src" "$(jq -cn --arg b "$bucket" '{bucket:$b,retired:true}')"
	return 0
}

run_migrate_command() {
	local command="$1" src="${2:-}" dst="${3:-}"
	[[ "$#" -ge 3 ]] || {
		fail_json "$ERROR_ARGUMENTS_INVALID"
		return 1
	}
	shift 3
	check_dependencies && load_config || return 1
	migrate_parse_options "$@" || return 1
	migrate_load_accounts "$src" "$dst" || return 1
	migrate_select_buckets || return 1
	case "$command" in
	migrate-plan) run_migrate_plan "$src" "$dst" ;;
	migrate-run) run_migrate_run "$src" "$dst" ;;
	migrate-retire-source) run_migrate_retire "$src" "$dst" ;;
	esac
}

main() {
	local command="${1:-}" account="${2:-}" bucket="${3:-}" argument="${4:-}" option="${5:-}" value="${6:-}"
	local confirmation=""
	case "$command" in help | -h | --help | '')
		usage
		return 0
		;;
	migrate-plan | migrate-run | migrate-retire-source)
		run_migrate_command "$@"
		return $?
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
		[[ "$#" -eq 5 ]] || {
			fail_json "$ERROR_ARGUMENTS_INVALID"
			return 1
		}
		validate_bucket "$bucket" || return 1
		[[ "$argument" == "--limit" ]] || {
			fail_json "$ERROR_ARGUMENTS_INVALID"
			return 1
		}
		run_list_objects "$account" "$bucket" "$option"
		;;
	object-info)
		[[ "$#" -eq 4 ]] || {
			fail_json "$ERROR_ARGUMENTS_INVALID"
			return 1
		}
		validate_bucket "$bucket" && validate_object "$argument" || return 1
		run_object_info "$account" "$bucket" "$argument"
		;;
	verify-backups)
		validate_bucket "$bucket" || return 1
		if [[ "$#" -eq 3 ]]; then argument=30; elif [[ "$#" -eq 5 && "$argument" == "--max-age-days" ]]; then argument="$option"; else
			fail_json "$ERROR_ARGUMENTS_INVALID"
			return 1
		fi
		run_verify_backups "$account" "$bucket" "$argument"
		;;
	audit-protection)
		[[ "$#" -eq 3 ]] || {
			fail_json "$ERROR_ARGUMENTS_INVALID"
			return 1
		}
		validate_bucket "$bucket" || return 1
		run_audit_protection "$account" "$bucket"
		;;
	copy | download)
		if [[ "$#" -eq 7 && "$value" == "--confirm" ]]; then
			confirmation="${7:-}"
		elif [[ "$#" -ne 5 ]]; then
			fail_json "$ERROR_ARGUMENTS_INVALID"
			return 1
		fi
		validate_bucket "$bucket" && validate_object "$argument" && safe_value "$option" || return 1
		run_transfer "$command" "$account" "$bucket" "$argument" "$option" "$confirmation"
		;;
	*)
		fail_json "command_unknown"
		return 1
		;;
	esac
}

main "$@"
