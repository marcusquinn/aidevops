#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
# session-attachments-helper.sh - Export images pasted into OpenCode sessions (GH#35470)
# Part of aidevops framework: https://aidevops.sh
#
# Pasted images live only inline in the session database (part.data JSON,
# {"type":"file","mime":"image/png","url":"data:image/png;base64,..."}), so
# no tool or session has a path to them. This helper finds the session in
# every OpenCode database and writes its images to private files on demand.
#
# Usage:
#   session-attachments-helper.sh locations
#   session-attachments-helper.sh sessions [--days N] [--title TEXT] [--limit N]
#   session-attachments-helper.sh list <session-id|latest> [--db PATH]
#   session-attachments-helper.sh export <session-id|latest> [--message ID | --last]
#                                        [--out DIR] [--db PATH]
#   session-attachments-helper.sh cleanup [--days N] [--dry-run]
#
# Databases searched, in order (read-only):
#   1. current:  ${XDG_DATA_HOME:-~/.local/share}/opencode/opencode.db
#                (aidevops launches set XDG_DATA_HOME to a per-project folder)
#   2. shared:   ~/.local/share/opencode/opencode.db
#   3. isolated: ~/.aidevops/.agent-workspace/work/opencode-interactive/*/opencode/opencode.db
#   4. archive:  opencode-archive.db beside 1 and 2 (opencode-db-archive.sh)
#
# Exports go to ${AIDEVOPS_SESSION_ATTACHMENTS_DIR:-~/.aidevops/.agent-workspace/tmp/session-attachments}/<session>/
# (folder 0700, files 0600) as <UTC time>-<message>-<n>.<ext>, where n is the
# image's position in its message ("Image n"). Folders untouched for
# ${AIDEVOPS_SESSION_ATTACHMENTS_RETENTION_DAYS:-60} days are removed by
# cleanup and after each export. The databases are never modified: an export
# is a copy and can be made again while the session exists.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit
# shellcheck source=shared-constants.sh
source "${SCRIPT_DIR}/shared-constants.sh"
# shellcheck source=opencode-db-inventory-lib.sh
source "${SCRIPT_DIR}/opencode-db-inventory-lib.sh"

set -euo pipefail

ATTACH_ROOT="${AIDEVOPS_SESSION_ATTACHMENTS_DIR:-${HOME}/.aidevops/.agent-workspace/tmp/session-attachments}"
RETENTION_DAYS="${AIDEVOPS_SESSION_ATTACHMENTS_RETENTION_DAYS:-60}"
SHARED_DATA_DIR="${HOME}/.local/share/opencode"
CURRENT_DATA_DIR="${XDG_DATA_HOME:-${HOME}/.local/share}/opencode"
IMAGE_FILTER="json_extract(data, '\$.type') = 'file' AND json_extract(data, '\$.mime') LIKE 'image/%'"

DB_LIST=()

usage() {
	sed -n '4,32p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
	return 0
}

die() {
	local msg="$1"
	print_error "$msg"
	exit 1
}

unknown_option() {
	local opt="$1"
	die "unknown option: $opt"
	return 1
}

require_tools() {
	command -v sqlite3 >/dev/null 2>&1 || die "sqlite3 is required"
	command -v base64 >/dev/null 2>&1 || die "base64 is required"
	return 0
}

# Read-only URI: plain -readonly fails on WAL databases whose -shm it cannot map.
ro_uri() {
	local path="$1"
	path="${path//%/%25}"
	path="${path//\?/%3f}"
	path="${path//#/%23}"
	path="${path// /%20}"
	printf 'file:%s?mode=ro' "$path"
	return 0
}

sql() {
	local db="$1"
	local query="$2"
	sqlite3 -batch -noheader -separator $'\t' -cmd '.timeout 5000' "$(ro_uri "$db")" "$query"
	return $?
}

valid_id() {
	local id="$1"
	[[ "$id" =~ ^[A-Za-z0-9_-]{4,128}$ ]]
	return $?
}

valid_days() {
	local days="$1"
	[[ "$days" =~ ^[0-9]{1,5}$ ]] || die "days must be a whole number: $days"
	return 0
}

add_db() {
	local db="$1"
	local known
	[[ -f "$db" && ! -L "$db" ]] || return 0
	for known in "${DB_LIST[@]+"${DB_LIST[@]}"}"; do
		[[ "$known" -ef "$db" ]] && return 0
	done
	DB_LIST+=("$db")
	return 0
}

collect_dbs() {
	local db
	DB_LIST=()
	add_db "${CURRENT_DATA_DIR}/opencode.db"
	add_db "${SHARED_DATA_DIR}/opencode.db"
	while IFS= read -r -d '' db; do
		add_db "$db"
	done < <(opencode_db_inventory "${CURRENT_DATA_DIR}/opencode.db")
	add_db "${CURRENT_DATA_DIR}/opencode-archive.db"
	add_db "${SHARED_DATA_DIR}/opencode-archive.db"
	return 0
}

cmd_locations() {
	local db label
	collect_dbs
	printf 'current\t%s\t%s\n' "${CURRENT_DATA_DIR}/opencode.db" "$([[ -f "${CURRENT_DATA_DIR}/opencode.db" ]] && echo present || echo missing)"
	for db in "${DB_LIST[@]+"${DB_LIST[@]}"}"; do
		[[ "$db" -ef "${CURRENT_DATA_DIR}/opencode.db" ]] && continue
		case "$db" in
		*opencode-archive.db) label=archive ;;
		"${SHARED_DATA_DIR}/opencode.db") label=shared ;;
		*) label=isolated ;;
		esac
		printf '%s\t%s\tpresent\n' "$label" "$db"
	done
	printf 'exports\t%s\t(retention %s days)\n' "$ATTACH_ROOT" "$RETENTION_DAYS"
	return 0
}

# Prints the database that holds session $1; exits 1 when none does.
find_session_db() {
	local sid="$1"
	local forced="$2"
	local db
	if [[ -n "$forced" ]]; then
		[[ -f "$forced" ]] || die "no database at $forced"
		[[ "$(sql "$forced" "SELECT count(*) FROM session WHERE id = '$sid';")" == "1" ]] || die "session $sid is not in $forced"
		printf '%s\n' "$forced"
		return 0
	fi
	collect_dbs
	for db in "${DB_LIST[@]+"${DB_LIST[@]}"}"; do
		if [[ "$(sql "$db" "SELECT count(*) FROM session WHERE id = '$sid';" 2>/dev/null || true)" == "1" ]]; then
			printf '%s\n' "$db"
			return 0
		fi
	done
	die "session $sid not found in any OpenCode database (see: $(basename "$0") locations)"
}

# Resolves "latest" to the most recently updated top-level session in the
# current database (the session running this command, when run from one).
resolve_session() {
	local ref="$1"
	local forced="$2"
	local db="${forced:-${CURRENT_DATA_DIR}/opencode.db}"
	local sid
	if [[ "$ref" == "latest" ]]; then
		[[ -f "$db" ]] || die "no current OpenCode database at $db"
		sid="$(sql "$db" "SELECT id FROM session WHERE parent_id IS NULL ORDER BY time_updated DESC LIMIT 1;")"
		[[ -n "$sid" ]] || die "no sessions in $db"
		printf '%s\n' "$sid"
		return 0
	fi
	valid_id "$ref" || die "not a session id: $ref"
	printf '%s\n' "$ref"
	return 0
}

cmd_sessions() {
	local days=14 title="" limit=15 db cutoff where rows opt val
	while [[ $# -gt 0 ]]; do
		local opt="$1"
		local val="${2:-}"
		case "$opt" in
		--days) days="$val" ;;
		--title) title="$val" ;;
		--limit) limit="$val" ;;
		*) unknown_option "$opt" ;;
		esac
		shift 2 || shift
	done
	valid_days "$days"
	[[ "$limit" =~ ^[0-9]{1,4}$ ]] || die "limit must be a whole number: $limit"
	cutoff=$(( ($(date +%s) - days * 86400) * 1000 ))
	where="parent_id IS NULL AND time_updated >= $cutoff"
	if [[ -n "$title" ]]; then
		title="${title//\'/\'\'}"
		where="$where AND title LIKE '%${title}%'"
	fi
	collect_dbs
	rows=""
	for db in "${DB_LIST[@]+"${DB_LIST[@]}"}"; do
		rows+="$(sql "$db" "SELECT time_updated, id, replace(replace(title, char(9), ' '), char(10), ' ') FROM session WHERE $where ORDER BY time_updated DESC LIMIT $limit;" 2>/dev/null |
			awk -v d="$db" 'BEGIN { OFS = "\t" } { print $0, d }' || true)"$'\n'
	done
	# Count images only for the sessions shown: counting reads each session's parts.
	printf '%s' "$rows" | sed '/^$/d' | sort -t $'\t' -k1,1nr | awk -v n="$limit" 'NR <= n' |
		while IFS=$'\t' read -r updated sid stitle sdb; do
			local images when
			images="$(sql "$sdb" "SELECT count(*) FROM part WHERE session_id = '$sid' AND $IMAGE_FILTER;" 2>/dev/null || echo '?')"
			when="$(sql "$sdb" "SELECT strftime('%Y-%m-%d %H:%M', $updated / 1000, 'unixepoch');")"
			printf '%s UTC\t%s\timages=%s\t%s\t%s\n' "$when" "$sid" "$images" "$stitle" "$sdb"
		done
	return 0
}

# Rows: part id, message id, UTC stamp, mime, url kind, approx bytes, position in message.
image_rows() {
	local db="$1"
	local sid="$2"
	sql "$db" "SELECT p.id, p.message_id, strftime('%Y%m%dT%H%M%SZ', m.time_created / 1000, 'unixepoch'),
		json_extract(p.data, '\$.mime'),
		CASE WHEN json_extract(p.data, '\$.url') LIKE 'data:%' THEN 'data' WHEN json_extract(p.data, '\$.url') LIKE 'file://%' THEN 'file' ELSE 'other' END,
		CASE WHEN json_extract(p.data, '\$.url') LIKE 'data:%' THEN length(json_extract(p.data, '\$.url')) * 3 / 4 ELSE 0 END
		FROM part p JOIN message m ON m.id = p.message_id
		WHERE p.session_id = '$sid' AND json_extract(p.data, '\$.type') = 'file' AND json_extract(p.data, '\$.mime') LIKE 'image/%'
		ORDER BY m.time_created, p.message_id, p.id;" |
		awk -F '\t' 'BEGIN { OFS = "\t" } { n = ($2 == last) ? n + 1 : 1; last = $2; print $0, n }'
	return 0
}

cmd_list() {
	local ref="${1:-}"
	local forced="" sid db count=0 opt val
	[[ -n "$ref" ]] || die "usage: list <session-id|latest> [--db PATH]"
	shift
	while [[ $# -gt 0 ]]; do
		local opt="$1"
		local val="${2:-}"
		[[ "$opt" == "--db" ]] || unknown_option "$opt"
		forced="$val"
		shift 2 || shift
	done
	sid="$(resolve_session "$ref" "$forced")"
	db="$(find_session_db "$sid" "$forced")"
	printf 'session %s (%s)\n' "$sid" "$db"
	while IFS=$'\t' read -r _part msg stamp mime kind bytes n; do
		count=$((count + 1))
		printf '%s\t%s\timage %s\t%s\t%s\t~%s bytes\n' "$stamp" "$msg" "$n" "$mime" "$kind" "$bytes"
	done < <(image_rows "$db" "$sid")
	printf 'images: %s\n' "$count"
	return 0
}

ext_for() {
	local mime="$1"
	case "$mime" in
	image/png) printf 'png' ;;
	image/jpeg | image/jpg) printf 'jpg' ;;
	image/webp) printf 'webp' ;;
	image/gif) printf 'gif' ;;
	image/svg+xml) printf 'svg' ;;
	image/heic) printf 'heic' ;;
	*) printf 'img' ;;
	esac
	return 0
}

# Writes one image part to $3; data: URLs are decoded, file:// URLs copied.
write_part() {
	local db="$1"
	local part="$2"
	local dest="$3"
	local kind="$4"
	local tmp="${dest}.tmp.$$"
	local src
	if [[ "$kind" == "data" ]]; then
		sql "$db" "SELECT substr(json_extract(data, '\$.url'), instr(json_extract(data, '\$.url'), ',') + 1) FROM part WHERE id = '$part';" |
			base64 --decode >"$tmp" || {
			rm -f "$tmp"
			return 1
		}
	elif [[ "$kind" == "file" ]]; then
		src="$(sql "$db" "SELECT substr(json_extract(data, '\$.url'), 8) FROM part WHERE id = '$part';")"
		[[ -f "$src" ]] || return 1
		cp "$src" "$tmp" || return 1
	else
		return 1
	fi
	[[ -s "$tmp" ]] || {
		rm -f "$tmp"
		return 1
	}
	chmod 600 "$tmp"
	mv -f "$tmp" "$dest"
	return 0
}

cmd_export() {
	local ref="${1:-}"
	local forced="" message="" last=false out="" sid db dir written=0 skipped=0 failed=0 opt val step
	[[ -n "$ref" ]] || die "usage: export <session-id|latest> [--message ID | --last] [--out DIR] [--db PATH]"
	shift
	while [[ $# -gt 0 ]]; do
		local opt="$1"
		local val="${2:-}"
		step=2
		case "$opt" in
		--message) message="$val" ;;
		--last) last=true; step=1 ;;
		--out) out="$val" ;;
		--db) forced="$val" ;;
		*) unknown_option "$opt" ;;
		esac
		shift "$step" || shift
	done
	[[ -z "$message" ]] || valid_id "$message" || die "not a message id: $message"
	sid="$(resolve_session "$ref" "$forced")"
	db="$(find_session_db "$sid" "$forced")"
	local rows
	rows="$(image_rows "$db" "$sid")"
	[[ -n "$rows" ]] || {
		print_info "session $sid has no images"
		return 0
	}
	if [[ "$last" == true ]]; then
		message="$(printf '%s\n' "$rows" | tail -n 1 | cut -f 2)"
	fi
	if [[ -n "$message" ]]; then
		rows="$(printf '%s\n' "$rows" | awk -F '\t' -v m="$message" '$2 == m')"
		[[ -n "$rows" ]] || die "message $message has no images in session $sid"
	fi
	dir="${out:-${ATTACH_ROOT}/${sid}}"
	(umask 077 && mkdir -p "$dir") || die "cannot create $dir"
	[[ -n "$out" ]] || chmod 700 "$dir"
	while IFS=$'\t' read -r part msg stamp mime kind _bytes n; do
		local dest
		dest="${dir}/${stamp}-${msg}-${n}.$(ext_for "$mime")"
		if [[ -s "$dest" ]]; then
			skipped=$((skipped + 1))
			printf '%s\n' "$dest"
			continue
		fi
		if write_part "$db" "$part" "$dest" "$kind"; then
			written=$((written + 1))
			printf '%s\n' "$dest"
		else
			failed=$((failed + 1))
			print_warning "could not export $part ($kind) from message $msg"
		fi
	done <<<"$rows"
	touch "$dir"
	print_info "session $sid: $written written, $skipped already exported, $failed failed, in $dir"
	[[ -n "$out" ]] || cmd_cleanup --quiet
	if [[ "$failed" -gt 0 ]]; then
		return 1
	fi
	return 0
}

cmd_cleanup() {
	local days="$RETENTION_DAYS" dry_run=false quiet=false removed=0 dir opt val step
	while [[ $# -gt 0 ]]; do
		local opt="$1"
		local val="${2:-}"
		step=1
		case "$opt" in
		--days) days="$val"; step=2 ;;
		--dry-run) dry_run=true ;;
		--quiet) quiet=true ;;
		*) unknown_option "$opt" ;;
		esac
		shift "$step" || shift
	done
	valid_days "$days"
	[[ -d "$ATTACH_ROOT" && ! -L "$ATTACH_ROOT" ]] || return 0
	# Direct child folders only, never symlinks; mtime is refreshed by each export.
	while IFS= read -r -d '' dir; do
		[[ -L "$dir" ]] && continue
		removed=$((removed + 1))
		if [[ "$dry_run" == true ]]; then
			printf 'would remove %s\n' "$dir"
		else
			rm -rf -- "$dir"
			[[ "$quiet" == true ]] || printf 'removed %s\n' "$dir"
		fi
	done < <(find "$ATTACH_ROOT" -mindepth 1 -maxdepth 1 -type d -mmin "+$((days * 1440))" -print0)
	if [[ "$quiet" != true || "$removed" -gt 0 ]]; then
		print_info "cleanup: $removed export folder(s) older than $days days$([[ "$dry_run" == true ]] && echo ' (dry run)')"
	fi
	return 0
}

main() {
	local command="${1:-help}"
	[[ $# -gt 0 ]] && shift
	case "$command" in
	locations) require_tools && cmd_locations ;;
	sessions) require_tools && cmd_sessions "$@" ;;
	list) require_tools && cmd_list "$@" ;;
	export) require_tools && cmd_export "$@" ;;
	cleanup) cmd_cleanup "$@" ;;
	help | -h | --help) usage ;;
	*)
		usage
		return 1
		;;
	esac
	return $?
}

main "$@"
