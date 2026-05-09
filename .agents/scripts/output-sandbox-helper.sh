#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# output-sandbox-helper.sh - SQLite-backed raw-output store with compact summaries

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
# shellcheck source=shared-constants.sh
source "${SCRIPT_DIR}/shared-constants.sh"

LOG_PREFIX="OUTPUT-SANDBOX"

SANDBOX_ROOT="${AIDEVOPS_OUTPUT_SANDBOX_DIR:-${HOME}/.aidevops/.agent-workspace/output-sandbox}"
SANDBOX_DB="${AIDEVOPS_OUTPUT_SANDBOX_DB:-${SANDBOX_ROOT}/output-sandbox.db}"
RAW_DIR="${AIDEVOPS_OUTPUT_SANDBOX_RAW_DIR:-${SANDBOX_ROOT}/raw}"
DEFAULT_SUMMARY_LINES="${AIDEVOPS_OUTPUT_SANDBOX_SUMMARY_LINES:-20}"
DEFAULT_RETENTION_DAYS="${AIDEVOPS_OUTPUT_SANDBOX_RETENTION_DAYS:-14}"

usage() {
	cat <<'EOF'
Usage:
  output-sandbox-helper.sh init
  output-sandbox-helper.sh run [--tag TAG] [--summary-lines N] -- COMMAND [ARGS...]
  output-sandbox-helper.sh store [--command TEXT] [--exit-code N] [--tag TAG] < output.txt
  output-sandbox-helper.sh show OUTPUT_ID [--offset N] [--limit N]
  output-sandbox-helper.sh cleanup [--max-age-days N]
  output-sandbox-helper.sh stats

Stores noisy command output outside assistant context and returns a compact,
auditable pointer. Exact/verbatim/security-sensitive commands are bypassed.
EOF
	return 0
}

ensure_dirs() {
	mkdir -p "$RAW_DIR"
	return 0
}

init_db() {
	ensure_dirs
	python3 - "$SANDBOX_DB" <<'PY'
import sqlite3, sys
db_path = sys.argv[1]
conn = sqlite3.connect(db_path)
conn.execute("PRAGMA journal_mode=WAL")
conn.execute("PRAGMA busy_timeout=5000")
conn.execute("""
CREATE TABLE IF NOT EXISTS outputs (
  id TEXT PRIMARY KEY,
  created_at TEXT NOT NULL,
  command TEXT NOT NULL,
  cwd TEXT NOT NULL,
  repo TEXT NOT NULL,
  exit_code INTEGER NOT NULL,
  tag TEXT NOT NULL,
  raw_path TEXT NOT NULL,
  byte_count INTEGER NOT NULL,
  line_count INTEGER NOT NULL,
  sensitive INTEGER NOT NULL DEFAULT 0,
  summary TEXT NOT NULL
)
""")
conn.execute("CREATE INDEX IF NOT EXISTS idx_outputs_created_at ON outputs(created_at)")
conn.execute("CREATE INDEX IF NOT EXISTS idx_outputs_tag ON outputs(tag)")
conn.commit()
conn.close()
PY
	return 0
}

repo_slug() {
	local cwd="$1"
	git -C "$cwd" remote get-url origin 2>/dev/null |
		sed -E 's#^git@[^:]+:##; s#^https?://[^/]+/##; s#\.git$##' || true
	return 0
}

make_output_id() {
	python3 - <<'PY'
import secrets, time
print(f"out_{int(time.time())}_{secrets.token_hex(4)}")
PY
	return 0
}

looks_sensitive_file() {
	local path="$1"
	if grep -Eiq '(BEGIN ((RSA|DSA|EC|OPENSSH) )?PRIVATE KEY|aws_secret_access_key|api[_-]?key[=:][[:space:]]*[A-Za-z0-9_./+=-]{20,}|token[=:][[:space:]]*[A-Za-z0-9_./+=-]{24,}|password[=:][^[:space:]]{8,}|gh[pousr]_[A-Za-z0-9_]{20,})' "$path" 2>/dev/null; then
		return 0
	fi
	return 1
}

redact_file() {
	local src="$1"
	local dest="$2"
	python3 - "$src" "$dest" <<'PY'
import re, sys
src, dest = sys.argv[1], sys.argv[2]
data = open(src, 'r', encoding='utf-8', errors='replace').read()
patterns = [
    r'-----BEGIN [A-Z ]*PRIVATE KEY-----.*?-----END [A-Z ]*PRIVATE KEY-----',
    r'(?i)(aws_secret_access_key\s*[=:]\s*)\S+',
    r'(?i)((?:api[_-]?key|token|password)\s*[=:]\s*)\S+',
    r'gh[pousr]_[A-Za-z0-9_]{20,}',
]
for pat in patterns:
    data = re.sub(pat, lambda m: (m.group(1) if m.groups() else '') + '[REDACTED]', data, flags=re.S)
open(dest, 'w', encoding='utf-8').write(data)
PY
	return 0
}

summarize_file() {
	local path="$1"
	local max_lines="$2"
	local sensitive="$3"
	if [[ "$sensitive" == "1" ]]; then
		printf 'summary suppressed: sensitive patterns were redacted before storage\n'
		return 0
	fi
	python3 - "$path" "$max_lines" <<'PY'
import sys
path = sys.argv[1]
limit = int(sys.argv[2])
with open(path, 'r', encoding='utf-8', errors='replace') as fh:
    lines = fh.read().splitlines()
if len(lines) <= limit:
    print('\n'.join(lines))
else:
    head = max(1, limit // 2)
    tail = max(1, limit - head)
    kept = lines[:head] + [f"... omitted {len(lines) - head - tail} line(s); use show for exact output ..."] + lines[-tail:]
    print('\n'.join(kept))
PY
	return 0
}

record_output() {
	local output_id="$1"
	local command_text="$2"
	local cwd="$3"
	local exit_code="$4"
	local tag="$5"
	local raw_path="$6"
	local byte_count="$7"
	local line_count="$8"
	local sensitive="$9"
	local summary_file="${10}"
	local repo
	repo=$(repo_slug "$cwd")
	python3 - "$SANDBOX_DB" "$output_id" "$command_text" "$cwd" "$repo" "$exit_code" "$tag" "$raw_path" "$byte_count" "$line_count" "$sensitive" "$summary_file" <<'PY'
import sqlite3, sys
db, oid, command, cwd, repo, exit_code, tag, raw_path, byte_count, line_count, sensitive, summary_file = sys.argv[1:]
summary = open(summary_file, 'r', encoding='utf-8', errors='replace').read()
conn = sqlite3.connect(db)
conn.execute("PRAGMA journal_mode=WAL")
conn.execute("PRAGMA busy_timeout=5000")
conn.execute("""
INSERT OR REPLACE INTO outputs
(id, created_at, command, cwd, repo, exit_code, tag, raw_path, byte_count, line_count, sensitive, summary)
VALUES (?, datetime('now'), ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
""", (oid, command, cwd, repo, int(exit_code), tag, raw_path, int(byte_count), int(line_count), int(sensitive), summary))
conn.commit()
conn.close()
PY
	return 0
}

should_bypass_command() {
	local command_text="$1"
	case "$command_text" in
	cat\ * | head\ * | tail\ * | less\ * | more\ * | git\ diff* | *" --json"* | *" security "* | *secret* | *credential*)
		return 0
		;;
	esac
	return 1
}

print_receipt() {
	local output_id="$1"
	local exit_code="$2"
	local raw_path="$3"
	local byte_count="$4"
	local line_count="$5"
	local sensitive="$6"
	local summary_file="$7"
	printf 'output_id: %s\n' "$output_id"
	printf 'exit_code: %s\n' "$exit_code"
	printf 'bytes: %s\n' "$byte_count"
	printf 'lines: %s\n' "$line_count"
	printf 'raw_path: %s\n' "$raw_path"
	printf 'sensitive_redacted: %s\n' "$sensitive"
	printf 'summary:\n'
	sed 's/^/  /' "$summary_file"
	return 0
}

cmd_store() {
	local command_text="stdin"
	local exit_code="0"
	local tag="manual"
	while [[ $# -gt 0 ]]; do
		local opt="$1"
		case "$opt" in
		--command) local command_value="$2"; command_text="$command_value"; shift 2 ;;
		--exit-code) local exit_value="$2"; exit_code="$exit_value"; shift 2 ;;
		--tag) local tag_value="$2"; tag="$tag_value"; shift 2 ;;
		*) log_error "Unknown store option: $opt"; return 1 ;;
		esac
	done
	init_db
	local output_id raw_path tmp_input summary_file byte_count line_count sensitive
	output_id=$(make_output_id)
	raw_path="${RAW_DIR}/${output_id}.txt"
	tmp_input="${raw_path}.tmp"
	summary_file="${raw_path}.summary"
	cat >"$tmp_input"
	sensitive=0
	if looks_sensitive_file "$tmp_input"; then
		sensitive=1
		redact_file "$tmp_input" "$raw_path"
		rm -f "$tmp_input"
	else
		mv "$tmp_input" "$raw_path"
	fi
	byte_count=$(wc -c <"$raw_path" | tr -d ' ')
	line_count=$(wc -l <"$raw_path" | tr -d ' ')
	summarize_file "$raw_path" "$DEFAULT_SUMMARY_LINES" "$sensitive" >"$summary_file"
	record_output "$output_id" "$command_text" "$PWD" "$exit_code" "$tag" "$raw_path" "$byte_count" "$line_count" "$sensitive" "$summary_file"
	print_receipt "$output_id" "$exit_code" "$raw_path" "$byte_count" "$line_count" "$sensitive" "$summary_file"
	return 0
}

cmd_run() {
	local tag="run"
	local summary_lines="$DEFAULT_SUMMARY_LINES"
	while [[ $# -gt 0 ]]; do
		local opt="$1"
		case "$opt" in
		--tag) local tag_value="$2"; tag="$tag_value"; shift 2 ;;
		--summary-lines) local summary_value="$2"; summary_lines="$summary_value"; shift 2 ;;
		--) shift; break ;;
		*) break ;;
		esac
	done
	if [[ $# -eq 0 ]]; then
		log_error "run requires a command after --"
		return 1
	fi
	local command_text="$*"
	if should_bypass_command "$command_text"; then
		printf 'output_sandbox: bypass exact/verbatim command\n' >&2
		"$@"
		return $?
	fi
	init_db
	local output_id raw_path summary_file exit_code byte_count line_count sensitive
	output_id=$(make_output_id)
	raw_path="${RAW_DIR}/${output_id}.txt"
	summary_file="${raw_path}.summary"
	set +e
	"$@" >"$raw_path" 2>&1
	exit_code=$?
	set -e
	sensitive=0
	if looks_sensitive_file "$raw_path"; then
		sensitive=1
		local redacted_path="${raw_path}.redacted"
		redact_file "$raw_path" "$redacted_path"
		mv "$redacted_path" "$raw_path"
	fi
	byte_count=$(wc -c <"$raw_path" | tr -d ' ')
	line_count=$(wc -l <"$raw_path" | tr -d ' ')
	summarize_file "$raw_path" "$summary_lines" "$sensitive" >"$summary_file"
	record_output "$output_id" "$command_text" "$PWD" "$exit_code" "$tag" "$raw_path" "$byte_count" "$line_count" "$sensitive" "$summary_file"
	print_receipt "$output_id" "$exit_code" "$raw_path" "$byte_count" "$line_count" "$sensitive" "$summary_file"
	return "$exit_code"
}

cmd_show() {
	local output_id="$1"
	shift || true
	local offset="1"
	local limit="120"
	while [[ $# -gt 0 ]]; do
		local opt="$1"
		case "$opt" in
		--offset) local offset_value="$2"; offset="$offset_value"; shift 2 ;;
		--limit) local limit_value="$2"; limit="$limit_value"; shift 2 ;;
		*) log_error "Unknown show option: $opt"; return 1 ;;
		esac
	done
	init_db
	python3 - "$SANDBOX_DB" "$output_id" "$offset" "$limit" <<'PY'
import sqlite3, sys
db, oid, offset, limit = sys.argv[1], sys.argv[2], int(sys.argv[3]), int(sys.argv[4])
conn = sqlite3.connect(db)
row = conn.execute("SELECT raw_path, sensitive FROM outputs WHERE id = ?", (oid,)).fetchone()
conn.close()
if not row:
    print(f"output not found: {oid}", file=sys.stderr)
    sys.exit(1)
raw_path, sensitive = row
if sensitive:
    print("output was redacted before storage; showing redacted raw output", file=sys.stderr)
with open(raw_path, 'r', encoding='utf-8', errors='replace') as fh:
    lines = fh.read().splitlines()
start = max(0, offset - 1)
for number, line in enumerate(lines[start:start + limit], start=start + 1):
    print(f"{number}: {line}")
PY
	return 0
}

cmd_cleanup() {
	local max_age_days="$DEFAULT_RETENTION_DAYS"
	while [[ $# -gt 0 ]]; do
		local opt="$1"
		case "$opt" in
		--max-age-days) local days_value="$2"; max_age_days="$days_value"; shift 2 ;;
		*) log_error "Unknown cleanup option: $opt"; return 1 ;;
		esac
	done
	init_db
	python3 - "$SANDBOX_DB" "$max_age_days" <<'PY'
import os, sqlite3, sys
db, days = sys.argv[1], int(sys.argv[2])
conn = sqlite3.connect(db)
rows = conn.execute("SELECT id, raw_path FROM outputs WHERE created_at < datetime('now', ?)", (f'-{days} days',)).fetchall()
for oid, raw_path in rows:
    for path in (raw_path, raw_path + '.summary'):
        try:
            os.remove(path)
        except FileNotFoundError:
            pass
conn.executemany("DELETE FROM outputs WHERE id = ?", [(oid,) for oid, _ in rows])
conn.commit()
conn.execute('VACUUM')
conn.close()
print(f"deleted: {len(rows)}")
PY
	return 0
}

cmd_stats() {
	init_db
	python3 - "$SANDBOX_DB" <<'PY'
import os, sqlite3, sys
db = sys.argv[1]
conn = sqlite3.connect(db)
count, bytes_total = conn.execute('SELECT COUNT(*), COALESCE(SUM(byte_count), 0) FROM outputs').fetchone()
sensitive = conn.execute('SELECT COUNT(*) FROM outputs WHERE sensitive = 1').fetchone()[0]
conn.close()
print(f"outputs: {count}")
print(f"raw_bytes: {bytes_total}")
print(f"sensitive_redacted: {sensitive}")
print(f"db_path: {db}")
print(f"db_bytes: {os.path.getsize(db) if os.path.exists(db) else 0}")
PY
	return 0
}

main() {
	local command="${1:-help}"
	shift || true
	case "$command" in
	init) init_db ;;
	run) cmd_run "$@" ;;
	store) cmd_store "$@" ;;
	show) [[ $# -ge 1 ]] || { log_error "show requires OUTPUT_ID"; return 1; }; cmd_show "$@" ;;
	cleanup) cmd_cleanup "$@" ;;
	stats) cmd_stats ;;
	help | --help | -h) usage ;;
	*) log_error "Unknown command: $command"; usage; return 1 ;;
	esac
	return $?
}

main "$@"
