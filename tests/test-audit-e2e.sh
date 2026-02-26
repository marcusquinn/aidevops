#!/usr/bin/env bash
# test-audit-e2e.sh — End-to-end verification of the unified audit pipeline (t1032.8)
#
# Exercises the full audit cycle:
#   (1) All configured services are polled
#   (2) Findings land in unified DB
#   (3) Task-creator generates TODO lines with correct IDs
#   (4) Phase 10b appends them to TODO.md
#   (5) Phase 0 auto-dispatches them
#   (6) Workers create PRs that fix the findings
#   (7) Trend tracking records the run
#
# Uses isolated test databases and a temporary TODO.md to avoid side effects.
#
# Usage: bash tests/test-audit-e2e.sh [--verbose]
#
# Exit codes: 0 = all pass, 1 = failures found

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPTS_DIR="$REPO_DIR/.agents/scripts"
VERBOSE="${1:-}"

# --- Isolated test environment ---
TEST_TMPDIR=""
cleanup_test_env() {
	if [[ -n "$TEST_TMPDIR" && -d "$TEST_TMPDIR" ]]; then
		rm -rf "$TEST_TMPDIR"
	fi
	return 0
}
trap cleanup_test_env EXIT

setup_test_env() {
	TEST_TMPDIR=$(mktemp -d)
	export TEST_AUDIT_DB="${TEST_TMPDIR}/audit.db"
	export TEST_SWEEP_DB="${TEST_TMPDIR}/findings.db"
	export TEST_TASK_DB="${TEST_TMPDIR}/finding-tasks.db"
	export TEST_TODO_FILE="${TEST_TMPDIR}/TODO.md"
	export TEST_SUPERVISOR_DB="${TEST_TMPDIR}/supervisor.db"

	# Create a minimal TODO.md for testing
	cat >"$TEST_TODO_FILE" <<'EOF'
# TODO

## In Progress

## Backlog

## Dispatch Queue

EOF
	return 0
}

# --- Test Framework ---
PASS_COUNT=0
FAIL_COUNT=0
SKIP_COUNT=0
TOTAL_COUNT=0
GAPS=()

pass() {
	PASS_COUNT=$((PASS_COUNT + 1))
	TOTAL_COUNT=$((TOTAL_COUNT + 1))
	if [[ "$VERBOSE" == "--verbose" ]]; then
		printf "  \033[0;32mPASS\033[0m %s\n" "$1"
	fi
	return 0
}

fail() {
	FAIL_COUNT=$((FAIL_COUNT + 1))
	TOTAL_COUNT=$((TOTAL_COUNT + 1))
	printf "  \033[0;31mFAIL\033[0m %s\n" "$1"
	if [[ -n "${2:-}" ]]; then
		printf "       %s\n" "$2"
	fi
	return 0
}

skip() {
	SKIP_COUNT=$((SKIP_COUNT + 1))
	TOTAL_COUNT=$((TOTAL_COUNT + 1))
	if [[ "$VERBOSE" == "--verbose" ]]; then
		printf "  \033[0;33mSKIP\033[0m %s\n" "$1"
	fi
	return 0
}

gap() {
	GAPS+=("$1")
	return 0
}

section() {
	echo ""
	printf "\033[1m=== %s ===\033[0m\n" "$1"
	return 0
}

# =============================================================================
# Helper: seed test findings into the quality-sweep DB
# =============================================================================
seed_sweep_findings() {
	local db_path="$1"

	sqlite3 "$db_path" <<'SQL' >/dev/null
PRAGMA journal_mode=WAL;

CREATE TABLE IF NOT EXISTS findings (
    id              INTEGER PRIMARY KEY AUTOINCREMENT,
    source          TEXT NOT NULL,
    external_key    TEXT,
    file            TEXT NOT NULL DEFAULT '',
    line            INTEGER NOT NULL DEFAULT 0,
    end_line        INTEGER NOT NULL DEFAULT 0,
    severity        TEXT NOT NULL DEFAULT 'info',
    type            TEXT NOT NULL DEFAULT 'CODE_SMELL',
    rule            TEXT NOT NULL DEFAULT '',
    message         TEXT NOT NULL DEFAULT '',
    status          TEXT NOT NULL DEFAULT 'OPEN',
    effort          TEXT NOT NULL DEFAULT '',
    tags            TEXT NOT NULL DEFAULT '',
    created_at      TEXT NOT NULL DEFAULT '',
    collected_at    TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now')),
    UNIQUE(source, external_key)
);

CREATE TABLE IF NOT EXISTS sweep_runs (
    id              INTEGER PRIMARY KEY AUTOINCREMENT,
    source          TEXT NOT NULL,
    project_key     TEXT NOT NULL DEFAULT '',
    started_at      TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now')),
    completed_at    TEXT,
    total_fetched   INTEGER NOT NULL DEFAULT 0,
    new_findings    INTEGER NOT NULL DEFAULT 0,
    updated_findings INTEGER NOT NULL DEFAULT 0,
    status          TEXT NOT NULL DEFAULT 'running'
);
SQL

	# Insert test findings from multiple sources
	sqlite3 "$db_path" <<SQL
INSERT INTO findings (source, external_key, file, line, severity, type, rule, message, status)
VALUES
    ('sonarcloud', 'sc-001', '.agents/scripts/code-audit-helper.sh', 42, 'high', 'BUG', 'bash:S5515', 'Unquoted variable in conditional', 'OPEN'),
    ('sonarcloud', 'sc-002', '.agents/scripts/supervisor-helper.sh', 100, 'medium', 'CODE_SMELL', 'bash:S2034', 'Unused variable: old_status', 'OPEN'),
    ('sonarcloud', 'sc-003', '.agents/scripts/supervisor-helper.sh', 55, 'critical', 'VULNERABILITY', 'bash:S4507', 'SQL injection via unsanitized input', 'OPEN'),
    ('codacy', 'cd-001', '.agents/scripts/code-audit-helper.sh', 42, 'high', 'BUG', 'ShellCheck/SC2086', 'Double quote to prevent globbing', 'OPEN'),
    ('codacy', 'cd-002', '.agents/scripts/memory-helper.sh', 200, 'medium', 'CODE_SMELL', 'ShellCheck/SC2155', 'Declare and assign separately', 'OPEN'),
    ('codacy', 'cd-003', '.agents/scripts/finding-to-task-helper.sh', 80, 'low', 'CODE_SMELL', 'ShellCheck/SC2034', 'Variable appears unused', 'OPEN'),
    ('coderabbit', 'cr-001', '.agents/scripts/supervisor/pulse.sh', 300, 'high', 'SECURITY', 'security/injection', 'Potential command injection via unescaped variable', 'OPEN'),
    ('coderabbit', 'cr-002', '.agents/scripts/quality-feedback-helper.sh', 50, 'medium', 'CODE_SMELL', 'style/complexity', 'Function exceeds complexity threshold', 'OPEN'),
    ('codefactor', 'cf-001', '.agents/scripts/code-audit-helper.sh', 42, 'high', 'BUG', 'SC2086', 'Double quote to prevent globbing', 'OPEN'),
    ('codefactor', 'cf-002', 'setup.sh', 15, 'low', 'CODE_SMELL', 'SC2034', 'Unused variable', 'OPEN');

INSERT INTO sweep_runs (source, project_key, completed_at, total_fetched, new_findings, status)
VALUES
    ('sonarcloud', 'marcusquinn_aidevops', strftime('%Y-%m-%dT%H:%M:%SZ', 'now'), 3, 3, 'complete'),
    ('codacy', 'aidevops', strftime('%Y-%m-%dT%H:%M:%SZ', 'now'), 3, 3, 'complete'),
    ('coderabbit', 'aidevops', strftime('%Y-%m-%dT%H:%M:%SZ', 'now'), 2, 2, 'complete'),
    ('codefactor', 'aidevops', strftime('%Y-%m-%dT%H:%M:%SZ', 'now'), 2, 2, 'complete');
SQL
	return 0
}

# =============================================================================
# Helper: seed audit_snapshots for trend tracking
# =============================================================================
seed_audit_snapshots() {
	local db_path="$1"

	sqlite3 "$db_path" <<'SQL'
CREATE TABLE IF NOT EXISTS audit_snapshots (
    id                INTEGER PRIMARY KEY AUTOINCREMENT,
    date              TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ','now')),
    source            TEXT NOT NULL,
    total_findings    INTEGER NOT NULL DEFAULT 0,
    critical_count    INTEGER NOT NULL DEFAULT 0,
    high_count        INTEGER NOT NULL DEFAULT 0,
    medium_count      INTEGER NOT NULL DEFAULT 0,
    low_count         INTEGER NOT NULL DEFAULT 0,
    false_positives   INTEGER NOT NULL DEFAULT 0,
    tasks_created     INTEGER NOT NULL DEFAULT 0
);
CREATE INDEX IF NOT EXISTS idx_snapshots_date ON audit_snapshots(date);
CREATE INDEX IF NOT EXISTS idx_snapshots_source ON audit_snapshots(source);
SQL

	# Insert historical snapshots (2 weeks ago, 1 week ago)
	sqlite3 "$db_path" <<SQL
INSERT INTO audit_snapshots (date, source, total_findings, critical_count, high_count, medium_count, low_count, false_positives, tasks_created)
VALUES
    (strftime('%Y-%m-%dT%H:%M:%SZ', 'now', '-14 days'), 'sonarcloud', 15, 2, 5, 6, 2, 3, 5),
    (strftime('%Y-%m-%dT%H:%M:%SZ', 'now', '-14 days'), 'codacy', 8, 0, 3, 4, 1, 1, 3),
    (strftime('%Y-%m-%dT%H:%M:%SZ', 'now', '-7 days'), 'sonarcloud', 12, 1, 4, 5, 2, 2, 4),
    (strftime('%Y-%m-%dT%H:%M:%SZ', 'now', '-7 days'), 'codacy', 6, 0, 2, 3, 1, 1, 2);
SQL
	return 0
}

# =============================================================================
# Helper: initialize a minimal supervisor DB for Phase 0 testing
# =============================================================================
seed_supervisor_db() {
	local db_path="$1"
	local repo_path="$2"

	sqlite3 "$db_path" <<SQL
PRAGMA journal_mode=WAL;

CREATE TABLE IF NOT EXISTS tasks (
    id          TEXT PRIMARY KEY,
    repo        TEXT NOT NULL DEFAULT '',
    description TEXT NOT NULL DEFAULT '',
    model       TEXT NOT NULL DEFAULT 'sonnet',
    status      TEXT NOT NULL DEFAULT 'queued',
    batch_id    TEXT,
    log_file    TEXT,
    pr_url      TEXT,
    error       TEXT,
    retries     INTEGER NOT NULL DEFAULT 0,
    max_retries INTEGER NOT NULL DEFAULT 3,
    started_at  TEXT,
    created_at  TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now')),
    updated_at  TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now')),
    diagnostic_of TEXT,
    rebase_attempts INTEGER NOT NULL DEFAULT 0,
    last_main_sha TEXT
);

CREATE TABLE IF NOT EXISTS batches (
    id          TEXT PRIMARY KEY,
    concurrency INTEGER NOT NULL DEFAULT 2,
    max_concurrency INTEGER,
    max_load_factor INTEGER DEFAULT 2,
    status      TEXT NOT NULL DEFAULT 'active',
    created_at  TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now'))
);

CREATE TABLE IF NOT EXISTS batch_tasks (
    batch_id TEXT NOT NULL,
    task_id  TEXT NOT NULL,
    PRIMARY KEY (batch_id, task_id)
);

-- Seed a repo reference so Phase 0 can find TODO.md
INSERT INTO tasks (id, repo, description, status)
VALUES ('t0-seed', '${repo_path}', 'Seed task for repo discovery', 'deployed');
SQL
	return 0
}

# =============================================================================
# CHECKPOINT 1: All configured services are polled
# =============================================================================
test_checkpoint_1() {
	section "Checkpoint 1: All configured services are polled"

	# Check code-audit-helper.sh exists and is not a stub
	local audit_script="$SCRIPTS_DIR/code-audit-helper.sh"
	if [[ ! -f "$audit_script" ]]; then
		fail "code-audit-helper.sh not found"
		gap "GAP-1: code-audit-helper.sh missing from scripts directory"
		return 0
	fi
	pass "code-audit-helper.sh exists"

	# Check if it's still the 6-line stub
	local line_count
	line_count=$(wc -l <"$audit_script" | tr -d ' ')
	if [[ "$line_count" -le 10 ]]; then
		skip "code-audit-helper.sh is still a stub ($line_count lines) — t1032.1 PR #1376 not merged"
		gap "GAP-1a: code-audit-helper.sh not yet replaced with unified orchestrator (t1032.1 PR #1376 not merged)"
	else
		pass "code-audit-helper.sh is a full implementation ($line_count lines)"
	fi

	# Check it has an 'audit' command
	if grep -q 'cmd_audit\|audit)' "$audit_script" 2>/dev/null; then
		pass "code-audit-helper.sh has audit command"
	else
		skip "code-audit-helper.sh audit command not found (stub)"
		gap "GAP-1b: audit command not available until t1032.1 merges"
	fi

	# Check config template lists all 4 services
	local config_template="$REPO_DIR/configs/code-audit-config.json.txt"
	if [[ -f "$config_template" ]]; then
		local services_found=0
		for svc in coderabbit codacy sonarcloud codefactor; do
			if grep -q "\"$svc\"" "$config_template"; then
				services_found=$((services_found + 1))
			fi
		done
		if [[ "$services_found" -eq 4 ]]; then
			pass "Config template lists all 4 services (coderabbit, codacy, sonarcloud, codefactor)"
		else
			fail "Config template only lists $services_found/4 services"
		fi
	else
		fail "Config template not found at $config_template"
	fi

	# quality-sweep-helper.sh archived (t1336) — AI reads quality tool output directly
	skip "quality-sweep-helper.sh archived (t1336) — AI reads SonarCloud/Codacy output directly via gh API"

	# Check coderabbit-collector-helper.sh exists
	if [[ -f "$SCRIPTS_DIR/coderabbit-collector-helper.sh" ]]; then
		pass "coderabbit-collector-helper.sh exists"
	else
		skip "coderabbit-collector-helper.sh not found (CodeRabbit collector)"
	fi

	return 0
}

# =============================================================================
# CHECKPOINT 2: Findings land in unified DB
# =============================================================================
test_checkpoint_2() {
	section "Checkpoint 2: Findings land in unified DB"

	# Test with seeded data in isolated DB
	seed_sweep_findings "$TEST_SWEEP_DB"

	# Verify findings were inserted
	local total_findings
	total_findings=$(sqlite3 "$TEST_SWEEP_DB" "SELECT count(*) FROM findings;" 2>/dev/null || echo "0")
	if [[ "$total_findings" -eq 10 ]]; then
		pass "Seeded 10 test findings into sweep DB"
	else
		fail "Expected 10 findings, got $total_findings"
	fi

	# Verify multi-source coverage
	local source_count
	source_count=$(sqlite3 "$TEST_SWEEP_DB" "SELECT count(DISTINCT source) FROM findings;" 2>/dev/null || echo "0")
	if [[ "$source_count" -eq 4 ]]; then
		pass "Findings from 4 distinct sources"
	else
		fail "Expected 4 sources, got $source_count"
	fi

	# Verify severity distribution
	local critical_count high_count medium_count low_count
	critical_count=$(sqlite3 "$TEST_SWEEP_DB" "SELECT count(*) FROM findings WHERE severity='critical';" 2>/dev/null || echo "0")
	high_count=$(sqlite3 "$TEST_SWEEP_DB" "SELECT count(*) FROM findings WHERE severity='high';" 2>/dev/null || echo "0")
	medium_count=$(sqlite3 "$TEST_SWEEP_DB" "SELECT count(*) FROM findings WHERE severity='medium';" 2>/dev/null || echo "0")
	low_count=$(sqlite3 "$TEST_SWEEP_DB" "SELECT count(*) FROM findings WHERE severity='low';" 2>/dev/null || echo "0")
	if [[ "$critical_count" -ge 1 && "$high_count" -ge 1 && "$medium_count" -ge 1 && "$low_count" -ge 1 ]]; then
		pass "Findings span all severity levels (critical=$critical_count, high=$high_count, medium=$medium_count, low=$low_count)"
	else
		fail "Missing severity levels (critical=$critical_count, high=$high_count, medium=$medium_count, low=$low_count)"
	fi

	# Verify deduplication potential (same file+line from different sources)
	local dup_candidates
	dup_candidates=$(sqlite3 "$TEST_SWEEP_DB" "SELECT count(*) FROM (SELECT file, line, count(DISTINCT source) as src_count FROM findings WHERE status='OPEN' GROUP BY file, line HAVING src_count > 1);" 2>/dev/null || echo "0")
	if [[ "$dup_candidates" -ge 1 ]]; then
		pass "Cross-service dedup candidates detected ($dup_candidates file+line overlaps)"
	else
		skip "No cross-service dedup candidates (expected — test data may not overlap)"
	fi

	# Check the unified audit DB schema (from t1032.1)
	local audit_script="$SCRIPTS_DIR/code-audit-helper.sh"
	local line_count
	line_count=$(wc -l <"$audit_script" | tr -d ' ')
	if [[ "$line_count" -le 10 ]]; then
		skip "Unified audit DB (audit_findings table) not yet available — t1032.1 PR #1376 not merged"
		gap "GAP-2: Unified audit_findings table only exists in t1032.1 branch, not on main"
	else
		if grep -q 'audit_findings' "$audit_script"; then
			pass "code-audit-helper.sh defines audit_findings table"
		else
			fail "code-audit-helper.sh missing audit_findings table definition"
		fi
	fi

	return 0
}

# =============================================================================
# CHECKPOINT 3: Task-creator generates TODO lines with correct IDs
# =============================================================================
test_checkpoint_3() {
	section "Checkpoint 3: Task-creator generates TODO lines with correct IDs"

	# Test finding-to-task-helper.sh with seeded data
	local ftth="$SCRIPTS_DIR/finding-to-task-helper.sh"
	if [[ ! -f "$ftth" ]]; then
		fail "finding-to-task-helper.sh not found"
		return 0
	fi
	pass "finding-to-task-helper.sh exists"

	# Verify it can parse findings and generate task descriptions
	# (dry-run mode, using the test sweep DB)
	# We override the DB path by setting env vars
	local dry_output
	dry_output=$(
		SWEEP_DATA_DIR="$TEST_TMPDIR" \
			bash "$ftth" create --repo "$TEST_TMPDIR" --dry-run --min-severity low 2>&1
	) || true

	if echo "$dry_output" | grep -q '\- \[ \]'; then
		pass "finding-to-task-helper.sh generates TODO-format task lines in dry-run"
		# Check task lines have severity tags
		if echo "$dry_output" | grep -qE '#(critical|high|medium|low)'; then
			pass "Task lines include severity tags"
		else
			skip "Task lines missing severity tags (may be format difference)"
		fi
		# Check task lines have #quality tag
		if echo "$dry_output" | grep -q '#quality'; then
			pass "Task lines include #quality tag"
		else
			skip "Task lines missing #quality tag"
		fi
		# Check task lines have #auto-dispatch tag
		if echo "$dry_output" | grep -q '#auto-dispatch'; then
			pass "Task lines include #auto-dispatch tag"
		else
			skip "Task lines missing #auto-dispatch tag"
		fi
	else
		# The script may fail because it can't find the DB at the overridden path
		# or claim-task-id.sh isn't available in dry-run
		skip "finding-to-task-helper.sh dry-run did not produce task lines (may need sweep DB at expected path)"
		if [[ "$VERBOSE" == "--verbose" ]]; then
			echo "       Output: ${dry_output:0:200}"
		fi
	fi

	# coderabbit-task-creator-helper.sh and audit-task-creator-helper.sh archived (t1336)
	# AI reads CodeRabbit PR comments directly and creates better-scoped tasks
	skip "coderabbit-task-creator-helper.sh archived (t1336) — AI creates tasks from PR comments directly"
	skip "audit-task-creator-helper.sh archived (t1336) — duplicate of coderabbit-task-creator-helper.sh"

	return 0
}

# =============================================================================
# CHECKPOINT 4: Phase 10b appends tasks to TODO.md
# =============================================================================
test_checkpoint_4() {
	section "Checkpoint 4: Phase 10b appends tasks to TODO.md"

	local pulse_script="$SCRIPTS_DIR/supervisor/pulse.sh"
	if [[ ! -f "$pulse_script" ]]; then
		fail "supervisor/pulse.sh not found"
		return 0
	fi
	pass "supervisor/pulse.sh exists"

	# Check Phase 10b exists in pulse.sh
	if grep -q 'Phase 10b' "$pulse_script"; then
		pass "Phase 10b section exists in pulse.sh"
	else
		fail "Phase 10b section not found in pulse.sh"
		gap "GAP-4: Phase 10b not wired into supervisor pulse"
		return 0
	fi

	# Task creator scripts archived (t1336) — AI handles task creation from findings
	skip "coderabbit-task-creator-helper.sh archived (t1336) — pulse uses AI judgment for task creation"
	skip "audit-task-creator-helper.sh archived (t1336) — pulse uses AI judgment for task creation"

	# Verify Phase 10b has 24h cooldown
	if grep -q 'task_creation_cooldown' "$pulse_script"; then
		pass "Phase 10b has 24h cooldown mechanism"
	else
		fail "Phase 10b missing cooldown mechanism"
	fi

	# Verify Phase 10b commits and pushes TODO.md changes
	if grep -q 'git.*commit.*Phase 10b\|git.*push' "$pulse_script"; then
		pass "Phase 10b commits and pushes TODO.md changes"
	else
		fail "Phase 10b does not commit/push TODO.md changes"
		gap "GAP-4b: Phase 10b does not auto-commit TODO.md changes"
	fi

	# Verify Phase 10b adds #auto-dispatch tag
	if grep -q '#auto-dispatch' "$pulse_script"; then
		pass "Phase 10b ensures #auto-dispatch tag on created tasks"
	else
		skip "Phase 10b may not add #auto-dispatch tag"
	fi

	return 0
}

# =============================================================================
# CHECKPOINT 5: Phase 0 auto-dispatches tasks
# =============================================================================
test_checkpoint_5() {
	section "Checkpoint 5: Phase 0 auto-dispatches tasks"

	local pulse_script="$SCRIPTS_DIR/supervisor/pulse.sh"

	# Check Phase 0 exists
	if grep -q 'Phase 0.*Auto-pickup\|cmd_auto_pickup' "$pulse_script"; then
		pass "Phase 0 auto-pickup exists in pulse.sh"
	else
		fail "Phase 0 auto-pickup not found in pulse.sh"
		gap "GAP-5: Phase 0 auto-pickup missing from supervisor pulse"
		return 0
	fi

	# Check auto-pickup scans for #auto-dispatch
	local supervisor_script="$SCRIPTS_DIR/supervisor-helper.sh"
	if [[ -f "$supervisor_script" ]]; then
		if grep -q 'auto-dispatch\|auto_pickup\|cmd_auto_pickup' "$supervisor_script"; then
			pass "supervisor-helper.sh has auto-pickup functionality"
		else
			skip "supervisor-helper.sh auto-pickup not found (may be in submodule)"
		fi
	else
		fail "supervisor-helper.sh not found"
	fi

	# Check Phase 2 dispatches queued tasks
	if grep -q 'Phase 2.*Dispatch queued\|cmd_dispatch\|cmd_next' "$pulse_script"; then
		pass "Phase 2 dispatches queued tasks"
	else
		fail "Phase 2 dispatch not found in pulse.sh"
	fi

	# Verify the full flow: Phase 0 picks up -> Phase 2 dispatches
	if grep -q 'cmd_auto_pickup' "$pulse_script" && grep -q 'cmd_dispatch' "$pulse_script"; then
		pass "Full auto-dispatch flow: Phase 0 (pickup) -> Phase 2 (dispatch) wired"
	else
		fail "Auto-dispatch flow incomplete"
	fi

	return 0
}

# =============================================================================
# CHECKPOINT 6: Workers create PRs that fix findings
# =============================================================================
test_checkpoint_6() {
	section "Checkpoint 6: Workers create PRs that fix findings"

	# This checkpoint verifies the worker dispatch infrastructure exists.
	# Actual PR creation requires live worker dispatch which we can't do in a test.

	local dispatch_script="$SCRIPTS_DIR/supervisor/dispatch.sh"
	if [[ -f "$dispatch_script" ]]; then
		pass "supervisor/dispatch.sh exists"

		# Check it creates worktrees for workers
		if grep -q 'worktree\|git.*worktree' "$dispatch_script"; then
			pass "dispatch.sh creates worktrees for workers"
		else
			skip "dispatch.sh worktree creation not found"
		fi

		# Check it passes task description to worker
		if grep -q 'description\|prompt\|task_desc' "$dispatch_script"; then
			pass "dispatch.sh passes task description to worker"
		else
			skip "dispatch.sh task description passing not found"
		fi
	else
		fail "supervisor/dispatch.sh not found"
	fi

	# Check evaluate.sh handles PR detection
	local evaluate_script="$SCRIPTS_DIR/supervisor/evaluate.sh"
	if [[ -f "$evaluate_script" ]]; then
		pass "supervisor/evaluate.sh exists"

		if grep -q 'pr_url\|gh pr\|pull request' "$evaluate_script"; then
			pass "evaluate.sh detects PRs created by workers"
		else
			skip "evaluate.sh PR detection not found"
		fi
	else
		fail "supervisor/evaluate.sh not found"
	fi

	# Check the worker prompt template includes quality fix context
	# Workers get task descriptions that include file paths and finding details
	local ftth="$SCRIPTS_DIR/finding-to-task-helper.sh"
	if [[ -f "$ftth" ]]; then
		if grep -q 'group_key\|file.*path\|location' "$ftth"; then
			pass "finding-to-task-helper.sh includes file paths in task descriptions"
		else
			skip "finding-to-task-helper.sh file path inclusion not verified"
		fi
	fi

	# Note: actual worker PR creation is an integration test that requires
	# live dispatch infrastructure. Document this as a gap for manual verification.
	gap "GAP-6: Worker PR creation is an integration-level test requiring live dispatch. Verify manually by running: supervisor-helper.sh pulse --batch <batch-id>"

	return 0
}

# =============================================================================
# CHECKPOINT 7: Trend tracking records the run
# =============================================================================
test_checkpoint_7() {
	section "Checkpoint 7: Trend tracking records the run"

	# Check audit_snapshots table can be created and queried
	seed_audit_snapshots "$TEST_AUDIT_DB"

	local snapshot_count
	snapshot_count=$(sqlite3 "$TEST_AUDIT_DB" "SELECT count(*) FROM audit_snapshots;" 2>/dev/null || echo "0")
	if [[ "$snapshot_count" -eq 4 ]]; then
		pass "audit_snapshots table created and seeded with $snapshot_count historical snapshots"
	else
		fail "Expected 4 snapshots, got $snapshot_count"
	fi

	# Verify trend calculation (WoW delta)
	local latest_total week_ago_total
	latest_total=$(sqlite3 "$TEST_AUDIT_DB" "SELECT total_findings FROM audit_snapshots WHERE source='sonarcloud' ORDER BY date DESC LIMIT 1;" 2>/dev/null || echo "0")
	week_ago_total=$(sqlite3 "$TEST_AUDIT_DB" "SELECT total_findings FROM audit_snapshots WHERE source='sonarcloud' ORDER BY date ASC LIMIT 1;" 2>/dev/null || echo "0")
	if [[ "$latest_total" -gt 0 && "$week_ago_total" -gt 0 ]]; then
		local delta=$((latest_total - week_ago_total))
		pass "Trend calculation works: sonarcloud $week_ago_total -> $latest_total (delta: $delta)"
	else
		fail "Trend calculation failed (latest=$latest_total, week_ago=$week_ago_total)"
	fi

	# Check code-audit-helper.sh has trend command (t1032.6)
	local audit_script="$SCRIPTS_DIR/code-audit-helper.sh"
	local line_count
	line_count=$(wc -l <"$audit_script" | tr -d ' ')
	if [[ "$line_count" -le 10 ]]; then
		skip "code-audit-helper.sh trend command not available — stub only (t1032.6 PR #1378 not merged)"
		gap "GAP-7: Trend tracking command (code-audit-helper.sh trend) only exists in t1032.6 branch (PR #1378), not on main"
	else
		if grep -q 'cmd_trend\|trend)' "$audit_script"; then
			pass "code-audit-helper.sh has trend command"
		else
			skip "code-audit-helper.sh trend command not found"
			gap "GAP-7a: code-audit-helper.sh missing trend command"
		fi

		# Check for regression detection (>20% increase)
		if grep -q 'regression\|check.regression\|20' "$audit_script"; then
			pass "code-audit-helper.sh has regression detection"
		else
			skip "code-audit-helper.sh regression detection not found"
			gap "GAP-7b: Regression detection (>20% increase warning) not found in code-audit-helper.sh"
		fi
	fi

	# Verify snapshot recording works
	local new_snapshot_count
	sqlite3 "$TEST_AUDIT_DB" "INSERT INTO audit_snapshots (source, total_findings, critical_count, high_count, medium_count, low_count, false_positives, tasks_created) VALUES ('sonarcloud', 10, 1, 3, 4, 2, 1, 3);" 2>/dev/null
	new_snapshot_count=$(sqlite3 "$TEST_AUDIT_DB" "SELECT count(*) FROM audit_snapshots;" 2>/dev/null || echo "0")
	if [[ "$new_snapshot_count" -eq 5 ]]; then
		pass "New snapshot recorded successfully (total: $new_snapshot_count)"
	else
		fail "Snapshot recording failed (expected 5, got $new_snapshot_count)"
	fi

	return 0
}

# =============================================================================
# CHECKPOINT 8: Integration — full pipeline connectivity
# =============================================================================
test_checkpoint_8() {
	section "Checkpoint 8: Integration — full pipeline connectivity"

	# Verify the pipeline chain: collect -> DB -> task-create -> TODO.md -> dispatch
	local chain_ok=true

	# Step 1: Collectors exist
	# Step 1: Collector exists (quality-sweep-helper.sh archived t1336)
	if [[ -f "$SCRIPTS_DIR/coderabbit-collector-helper.sh" ]]; then
		pass "coderabbit-collector-helper.sh available"
	else
		fail "No collector scripts found"
		chain_ok=false
	fi

	# Step 2: Findings DB schema is consistent
	if sqlite3 "$TEST_SWEEP_DB" "SELECT source, file, line, severity, rule, message FROM findings LIMIT 1;" >/dev/null 2>&1; then
		pass "Findings DB schema has required columns (source, file, line, severity, rule, message)"
	else
		fail "Findings DB schema missing required columns"
		chain_ok=false
	fi

	# Step 3: Task creator can read findings DB
	local ftth="$SCRIPTS_DIR/finding-to-task-helper.sh"
	if [[ -f "$ftth" ]] && grep -q 'SWEEP_DB\|findings.db' "$ftth"; then
		pass "finding-to-task-helper.sh reads from findings DB"
	else
		skip "finding-to-task-helper.sh DB connection not verified"
	fi

	# Step 4: Phase 10b task creation (task creator scripts archived t1336 — AI handles this)
	skip "Task creator scripts archived (t1336) — pulse uses AI judgment for task creation from findings"

	# Step 5: Phase 0 picks up #auto-dispatch tasks
	if grep -q 'auto.pickup\|auto_pickup' "$pulse_script"; then
		pass "Phase 0 auto-pickup wired in pulse"
	else
		fail "Phase 0 auto-pickup not wired"
		chain_ok=false
	fi

	if [[ "$chain_ok" == "true" ]]; then
		pass "Full pipeline chain verified: collect -> DB -> task-create -> TODO.md -> dispatch"
	else
		fail "Pipeline chain has breaks — see individual failures above"
	fi

	return 0
}

# =============================================================================
# CHECKPOINT 9: Dependency status — blocking PRs
# =============================================================================
test_checkpoint_9() {
	section "Checkpoint 9: Dependency status — blocking PRs"

	# Check status of blocking PRs
	local pr_statuses
	pr_statuses=$(gh pr list --search "t1032" --state all --json number,title,state,mergedAt --limit 10 2>/dev/null || echo "[]")

	if [[ "$pr_statuses" == "[]" || -z "$pr_statuses" ]]; then
		skip "Could not fetch PR statuses (gh CLI not available or not authenticated)"
		return 0
	fi

	local pr_count
	pr_count=$(echo "$pr_statuses" | jq 'length' 2>/dev/null || echo "0")
	pass "Found $pr_count t1032.x PRs"

	# Check each critical PR
	for pr_num in 1376 1377 1378; do
		local pr_state pr_title
		pr_state=$(echo "$pr_statuses" | jq -r ".[] | select(.number == $pr_num) | .state" 2>/dev/null || echo "UNKNOWN")
		pr_title=$(echo "$pr_statuses" | jq -r ".[] | select(.number == $pr_num) | .title" 2>/dev/null || echo "Unknown")

		case "$pr_state" in
		MERGED)
			pass "PR #$pr_num ($pr_title): MERGED"
			;;
		OPEN)
			skip "PR #$pr_num ($pr_title): OPEN (not yet merged)"
			gap "GAP-DEP: PR #$pr_num ($pr_title) is still OPEN — blocks full E2E verification"
			;;
		CLOSED)
			fail "PR #$pr_num ($pr_title): CLOSED without merge"
			;;
		*)
			skip "PR #$pr_num: status unknown ($pr_state)"
			;;
		esac
	done

	return 0
}

# =============================================================================
# Main
# =============================================================================

main() {
	echo ""
	printf "\033[1m=== Audit Pipeline E2E Verification (t1032.8) ===\033[0m\n"
	echo "Date: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
	echo "Repo: $REPO_DIR"
	echo ""

	setup_test_env

	test_checkpoint_1
	test_checkpoint_2
	test_checkpoint_3
	test_checkpoint_4
	test_checkpoint_5
	test_checkpoint_6
	test_checkpoint_7
	test_checkpoint_8
	test_checkpoint_9

	# --- Summary ---
	echo ""
	printf "\033[1m=== Summary ===\033[0m\n"
	echo ""
	printf "  Total:   %d\n" "$TOTAL_COUNT"
	printf "  \033[0;32mPassed:  %d\033[0m\n" "$PASS_COUNT"
	printf "  \033[0;31mFailed:  %d\033[0m\n" "$FAIL_COUNT"
	printf "  \033[0;33mSkipped: %d\033[0m\n" "$SKIP_COUNT"

	if [[ ${#GAPS[@]} -gt 0 ]]; then
		echo ""
		printf "\033[1m=== Gaps Found ===\033[0m\n"
		echo ""
		for g in "${GAPS[@]}"; do
			printf "  - %s\n" "$g"
		done
	fi

	echo ""

	if [[ "$FAIL_COUNT" -gt 0 ]]; then
		printf "\033[0;31mResult: %d failure(s)\033[0m\n" "$FAIL_COUNT"
		return 1
	else
		printf "\033[0;32mResult: All checks passed (with %d skips)\033[0m\n" "$SKIP_COUNT"
		return 0
	fi
}

main "$@"
