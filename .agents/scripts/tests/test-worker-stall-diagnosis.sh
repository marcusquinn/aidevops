#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${SCRIPT_DIR}/worker-lifecycle-common.sh"

fail() {
	local message="$1"
	printf 'FAIL: %s\n' "$message" >&2
	return 1
}

assert_eq() {
	local expected="$1"
	local actual="$2"
	local message="$3"
	if [[ "$expected" != "$actual" ]]; then
		fail "$message (expected=$expected actual=$actual)"
	fi
	return 0
}

tmp_dir="$(mktemp -d)"
cleanup() {
	rm -rf "$tmp_dir"
	return 0
}
trap cleanup EXIT

mkdir -p "${tmp_dir}/home/.local/share/opencode"

sqlite3 "${tmp_dir}/home/.local/share/opencode/opencode.db" <<'SQL'
CREATE TABLE session (
  id TEXT PRIMARY KEY,
  project_id TEXT NOT NULL,
  parent_id TEXT,
  slug TEXT NOT NULL,
  directory TEXT NOT NULL,
  title TEXT NOT NULL,
  version TEXT NOT NULL,
  share_url TEXT,
  summary_additions INTEGER,
  summary_deletions INTEGER,
  summary_files INTEGER,
  summary_diffs TEXT,
  revert TEXT,
  permission TEXT,
  time_created INTEGER NOT NULL,
  time_updated INTEGER NOT NULL,
  time_compacting INTEGER,
  time_archived INTEGER,
  workspace_id TEXT
);
CREATE TABLE message (
  id TEXT PRIMARY KEY,
  session_id TEXT NOT NULL,
  time_created INTEGER NOT NULL,
  time_updated INTEGER NOT NULL,
  data TEXT NOT NULL
);
INSERT INTO session (id, project_id, slug, directory, title, version, time_created, time_updated)
VALUES ('s1', 'p1', 'slug', '/tmp', 't1438: worker stall diagnosis', '1', strftime('%s','now'), strftime('%s','now'));
INSERT INTO message (id, session_id, time_created, time_updated, data)
VALUES
  ('m1', 's1', strftime('%s','now') - 30, strftime('%s','now') - 30, '{"role":"assistant","type":"reasoning"}'),
  ('m2', 's1', strftime('%s','now') - 10, strftime('%s','now') - 10, '{"role":"assistant","type":"tool-result"}');
SQL

log_file="${tmp_dir}/worker.log"
cat >"$log_file" <<'EOF'
{"type":"tool-result","summary":{"title":"Ran tests"}}
429 Too Many Requests from provider
EOF

export HOME="${tmp_dir}/home"

evidence="$(_collect_worker_stall_evidence "t1438" "$log_file" 180 5)"
IFS=$'\t' read -r recent_count classification excerpt <<<"$evidence"
assert_eq "2" "$recent_count" "recent transcript activity should be counted"
assert_eq "rate_limited" "$classification" "rate limit tail should be classified"
[[ "$excerpt" == *"Too Many Requests"* ]] || fail "excerpt should include the recent log tail"

title="$(_extract_session_title_from_cmd 'opencode run --title "Issue #42: Fix auth" "/full-loop Fix issue #42"')"
assert_eq "Issue #42: Fix auth" "$title" "quoted --title extraction should preserve spaces"

empty_log="${tmp_dir}/empty.log"
: >"$empty_log"
no_activity="$(_collect_worker_stall_evidence "missing-task" "$empty_log" 60 3)"
IFS=$'\t' read -r recent_count classification excerpt <<<"$no_activity"
assert_eq "0" "$recent_count" "missing task should report zero recent messages"
assert_eq "empty_log" "$classification" "empty log should be classified explicitly"

printf 'PASS: worker stall diagnosis helpers\n'
