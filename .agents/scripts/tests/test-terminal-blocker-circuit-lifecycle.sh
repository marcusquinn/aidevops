#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# Lifecycle admission-refusal classification and backfill cases for the
# terminal-blocker circuit. Sourced by test-terminal-blocker-circuit.sh (shares
# its fixtures, print_result and TEST_* state); not executable standalone.

if [[ -n "${_TBC_LIFECYCLE_TESTS_LOADED:-}" ]]; then
	return 0 2>/dev/null || exit 0
fi
_TBC_LIFECYCLE_TESTS_LOADED=1

test_lifecycle_refusal_classification() {
	local status=0
	if ! (
		# shellcheck source=../headless-runtime-result.sh
		source "${SCRIPT_DIR}/headless-runtime-result.sh"
		export HOME="${TEST_ROOT}/admission-home"
		mkdir -p "$HOME"
		local discovered_session=ses_refused_fixture
		local _WORKER_ISOLATED_DB_PATH="${HOME}/runtime.db"
		local AIDEVOPS_TERMINAL_BLOCKER_EXPLICIT_REASON=false
		local AIDEVOPS_TERMINAL_BLOCKER_MISSING_SECRETS=""
		local AIDEVOPS_TERMINAL_BLOCKER_FINGERPRINT=""
		# Exercise the real plugin catch path, not a model-authored marker.
		node --input-type=module - "$SCRIPT_DIR" <<'JS' || exit 1
import { pathToFileURL } from 'node:url';
const { admitToolOwner } = await import(pathToFileURL(process.argv[2] + '/../plugins/opencode-aidevops/lifecycle-admission.mjs'));
process.env.WORKER_ISSUE_NUMBER = '42';
try {
  admitToolOwner({ scriptsDir: process.env.HOME, input: { tool: 'bash', sessionID: 'ses_refused_fixture' },
    output: { args: { workdir: process.env.HOME, command: 'git status' } }, bash: true });
  process.exit(1);
} catch (error) {
  if (!error.message.includes('lifecycle owner admission is unavailable')) throw error;
}
JS
		python3 - "$_WORKER_ISOLATED_DB_PATH" <<'PY' || exit 1
import sqlite3
import sys
with sqlite3.connect(sys.argv[1]) as db:
    db.executescript("CREATE TABLE session(id TEXT, parent_id TEXT); CREATE TABLE part(session_id TEXT, data TEXT); INSERT INTO session VALUES ('ses_refused_fixture', NULL);")
PY
		gh_issue_edit_safe() { return 0; }
		AIDEVOPS_TERMINAL_BLOCKER_FINGERPRINT=$(_terminal_blocker_hash v2:unknown)
		_run_result_classify_lifecycle_refusal || exit 1
		[[ "$(_terminal_blocker_reason "$AIDEVOPS_TERMINAL_BLOCKER_FINGERPRINT")" == runner_capability_unmet ]] || exit 1
		_hrff_blocked_exit_holds && exit 1
		# Explicit permission, scope and secret holds must remain untouched.
		local reason=""
		for reason in permission_required files_scope_excluded runner_capability_unmet; do
			AIDEVOPS_TERMINAL_BLOCKER_EXPLICIT_REASON=true
			AIDEVOPS_TERMINAL_BLOCKER_FINGERPRINT=$(_terminal_blocker_hash "v2:${reason}")
			_run_result_classify_lifecycle_refusal && exit 1
		done
		AIDEVOPS_TERMINAL_BLOCKER_EXPLICIT_REASON=false
		AIDEVOPS_TERMINAL_BLOCKER_FINGERPRINT=$(_terminal_blocker_hash v2:unknown)
		_hrff_lifecycle_refusal_only ses_other && exit 1
		AIDEVOPS_TERMINAL_BLOCKER_MISSING_SECRETS=EXAMPLE_SECRET
		_run_result_classify_lifecycle_refusal && exit 1
		AIDEVOPS_TERMINAL_BLOCKER_MISSING_SECRETS=""
		# Child policy evidence vetoes a parent's infrastructure-only inference.
		python3 - "$_WORKER_ISOLATED_DB_PATH" "$HOME" <<'PY' || exit 1
import json
import sqlite3
import sys
from pathlib import Path
with sqlite3.connect(sys.argv[1]) as db:
    db.execute("INSERT INTO session VALUES ('ses_child', 'ses_refused_fixture')")
path = next((Path(sys.argv[2]) / '.aidevops/logs/lifecycle-admission').glob('*.jsonl'))
with path.open('a') as log:
    log.write(json.dumps({'schema':1,'session':'ses_child','outcome':'refused','reason':'runtime-owner-unresolved'}) + '\n')
PY
		_run_result_classify_lifecycle_refusal && exit 1
		# Remove that policy evidence: a completed child tool alone also vetoes.
		python3 - "$_WORKER_ISOLATED_DB_PATH" "$HOME" <<'PY' || exit 1
import json
import sqlite3
import sys
from pathlib import Path
path = next((Path(sys.argv[2]) / '.aidevops/logs/lifecycle-admission').glob('*.jsonl'))
events = [json.loads(line) for line in path.read_text().splitlines()]
path.write_text('\n'.join(json.dumps(e) for e in events if e.get('session') != 'ses_child') + '\n')
with sqlite3.connect(sys.argv[1]) as db:
    db.execute("INSERT INTO part VALUES (?, ?)", ('ses_child', '{"type":"tool","state":{"status":"completed"}}'))
PY
		_run_result_classify_lifecycle_refusal && exit 1
		exit 0
	); then status=1; fi
	print_result "structured plugin refusal with zero completed tools stays available; successful children and policy holds do not" "$status"
	return 0
}

test_lifecycle_refusal_backfill() {
	local status=0
	if ! (
		# shellcheck source=../terminal-blocker-recovery-helper.sh
		source "${SCRIPT_DIR}/terminal-blocker-recovery-helper.sh"
		export HOME="${TEST_ROOT}/backfill-home"
		export AIDEVOPS_HEADLESS_METRICS_FILE="${HOME}/metrics.jsonl"
		export TERMINAL_BLOCKER_NOW_EPOCH=1793319000
		TBR_ROOT="${HOME}/queue-root" TBR_EXCERPT_DIR="${HOME}/excerpts"
		mkdir -p "$TBR_EXCERPT_DIR" "${HOME}/.aidevops/logs/lifecycle-admission"
		local tb_fixture_comments='[]' fixture='' revision='' fingerprint='' original='' queue_file=''
		local projected=0 receipts=0 rc=0
		fixture='{"state":"open","title":"Fix helper","body":"original","updated_at":"2026-10-30T00:00:00Z","labels":[{"name":"status:blocked"}]}'
		revision=$(terminal_blocker_task_revision "$fixture" owner/repo 42 "$TEST_ROOT" unknown)
		fingerprint=$(_terminal_blocker_hash v2:unknown)
		original=$(jq -nc --arg r "$revision" --arg f "$fingerprint" '[{id:10,body:("<!-- aidevops:terminal-blocker-observation revision="+$r+" blocker="+$f+" -->"),author_association:"MEMBER",created_at:"2026-10-30T00:00:00Z"}]')
		tb_fixture_comments="$original"
		terminal_blocker_fetch_issue() { printf '%s\n' "$fixture"; return 0; }
		terminal_blocker_fetch_trusted_comments() { printf '%s\n' "$tb_fixture_comments"; return 0; }
		set_issue_status() { projected=$((projected + 1)); return 0; }
		_tbr_post_rearm_receipt() {
			local marker="$3"
			receipts=$((receipts + 1))
			tb_fixture_comments=$(jq -c --arg body "$marker" '. + [{id:20,body:$body,author_association:"MEMBER",created_at:"2026-10-30T00:10:00Z"}]' <<<"$tb_fixture_comments")
			return 0
		}
		python3 - "$HOME" <<'PY' || exit 1
import json
import sys
from pathlib import Path
home = Path(sys.argv[1])
excerpt = home / 'excerpts/issue-42-20261030T000000Z-1.log'
excerpt.write_text(json.dumps({'type':'tool_use','part':{'state':{'status':'error','error':'BLOCKED: lifecycle owner admission is unavailable; no write authorized'}}}) + '\n')
(home / 'metrics.jsonl').write_text(json.dumps({'ts':1793318390,'role':'worker','repo_slug':'owner/repo','issue_number':'42','result':'blocked','output_file':str(excerpt)}) + '\n')
(home / '.aidevops/logs/lifecycle-admission/2026-10-30.jsonl').write_text('\n'.join(json.dumps({'schema':1,'ts':ts*1000,'session':'ses_healthy','outcome':outcome,'status':'coverage-gap'}) for ts,outcome in [(1793318400,'refused'),(1793318990,'passed')]) + '\n')
PY
		# Wrong repository and a still-refusing runtime cannot release the hold.
		_tbr_lifecycle_recovered other/repo 42 "$(jq -c '.[0]' <<<"$original")" && exit 1
		# Excluded/non-repository successes are not linked-worktree health proof.
		local health_status=""
		for health_status in excluded-unregistered not-applicable coverage-gap; do
			python3 - "$HOME" "$health_status" <<'PY' || exit 1
import json
import sys
from pathlib import Path
path = Path(sys.argv[1]) / '.aidevops/logs/lifecycle-admission/2026-10-30.jsonl'
events = [json.loads(line) for line in path.read_text().splitlines()]
events[-1]['status'] = sys.argv[2]
path.write_text('\n'.join(json.dumps(e) for e in events) + '\n')
PY
			if [[ "$health_status" != coverage-gap ]]; then
				_tbr_lifecycle_recovered owner/repo 42 "$(jq -c '.[0]' <<<"$original")" && exit 1
			fi
		done
		TERMINAL_BLOCKER_NOW_EPOCH=1793318450 _tbr_release_circuit_hold owner/repo 42 "$fixture" "$tb_fixture_comments" && exit 1
		[[ "$projected" -eq 0 ]] || exit 1
		TEST_BLOCKED_BY=unresolved
		_tbr_release_circuit_hold owner/repo 42 "$fixture" "$tb_fixture_comments" && exit 1
		[[ "$projected" -eq 0 ]] || exit 1
		TEST_BLOCKED_BY=resolved
		# Real rearm entry path must release even though the unknown hold is active.
		tbr_enqueue owner/repo 42 unknown || exit 1
		queue_file="${TBR_ROOT}/queue/owner--repo--42.json"
		_tbr_check_entry "$queue_file" rearm || rc=$?
		[[ "$rc" -eq 1 && ! -f "$queue_file" && "$projected" -eq 1 && "$receipts" -eq 1 ]] || exit 1
		_tbr_release_circuit_hold owner/repo 42 "$fixture" "$tb_fixture_comments" || exit 1
		[[ "$projected" -eq 1 && "$receipts" -eq 1 ]] || exit 1
		# Reusing the same excerpt cannot wake explicit policy or secret classes.
		local reason="" variant=""
		for reason in permission_required files_scope_excluded runner_capability_unmet; do
			fingerprint=$(_terminal_blocker_hash "v2:${reason}")
			revision=$(terminal_blocker_task_revision "$fixture" owner/repo 42 "$TEST_ROOT" "$reason")
			variant=$(jq -c --arg f "$fingerprint" --arg r "$revision" '.[0].body |= (sub("blocker=[a-f0-9]{24}"; "blocker="+$f) | sub("revision=[a-f0-9]{24}"; "revision="+$r))' <<<"$original")
			_tbr_release_circuit_hold owner/repo 42 "$fixture" "$variant" && exit 1
		done
		[[ "$projected" -eq 1 ]] || exit 1
		exit 0
	); then status=1; fi
	print_result "repo-bound admission-refusal backfill releases an active unknown hold once after health recovery only" "$status"
	return 0
}
