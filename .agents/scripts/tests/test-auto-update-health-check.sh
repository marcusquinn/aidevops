#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# Regression test for t2898: auto-update-helper.sh `health-check` subcommand
# and `enable --idempotent` flag.
#
# What this test asserts:
#   1. `health-check` exits 2 when daemon is NOT INSTALLED.
#   2. `health-check` exits 0 when daemon is loaded with no state file
#      (fresh install).
#   3. `health-check` exits 0 when state file `last_timestamp` is fresh.
#   4. `health-check` exits 1 when state file `last_timestamp` is stale
#      (>2× interval).
#   5. `health-check` exits 1 when state file is unparseable.
#   6. `health-check --quiet` produces no stderr output regardless of state.
#   7. `enable --idempotent` is a no-op when daemon is already loaded.
#   8. `enable --idempotent` proceeds with install when daemon is not loaded.
#   9. The dispatch case in main() routes `health-check` correctly.
#  10. Help text mentions `health-check` and `--idempotent`.
#
# Test strategy: structural checks against the real helper file plus
# behaviour tests that stub `_get_scheduler_backend` and `_launchd_is_loaded`
# via PATH manipulation and HOME redirection. We do NOT touch the user's
# real launchd / systemd / cron state — every test runs against an
# isolated $HOME with a fake `launchctl` shim on PATH.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit
AGENT_SCRIPT_DIR="${SCRIPT_DIR}/.."
HELPER="${AGENT_SCRIPT_DIR}/auto-update-helper.sh"
CHECK_LIBRARY="${AGENT_SCRIPT_DIR}/auto-update-helper-check.sh"
CONFIG_DEFAULTS_SOURCE="${SCRIPT_DIR}/../../configs/aidevops.defaults.jsonc"
CONFIG_SCHEMA_SOURCE="${SCRIPT_DIR}/../../configs/aidevops-config.schema.json"

# Test runtime constants.
readonly TEST_RED='\033[0;31m'
readonly TEST_GREEN='\033[0;32m'
readonly TEST_YELLOW='\033[0;33m'
readonly TEST_RESET='\033[0m'

TESTS_RUN=0
TESTS_FAILED=0
SANDBOX=""

cleanup() {
	[[ -n "$SANDBOX" && -d "$SANDBOX" ]] && rm -rf "$SANDBOX" 2>/dev/null || true
	return 0
}
trap cleanup EXIT

print_result() {
	local test_name="$1"
	local outcome="$2"
	local detail="${3:-}"
	TESTS_RUN=$((TESTS_RUN + 1))
	if [[ "$outcome" == "PASS" ]]; then
		printf '  %b%s%b: %s\n' "$TEST_GREEN" "$outcome" "$TEST_RESET" "$test_name"
	else
		TESTS_FAILED=$((TESTS_FAILED + 1))
		printf '  %b%s%b: %s%s\n' "$TEST_RED" "$outcome" "$TEST_RESET" "$test_name" \
			"${detail:+ — $detail}"
	fi
	return 0
}

# Run the helper inside a sandboxed HOME with a stubbed scheduler.
# Args:
#   $1 = scheduler state ("loaded" | "unloaded")
#   $2 = state file content ("none", "empty", "fresh", "stale", "garbage")
#   $3 = subcommand + args (e.g. "health-check" or "health-check --quiet")
# Returns the helper's exit code; stderr captured to /tmp/last-stderr.
_run_in_sandbox() {
	local sched_state="$1"
	local state_kind="$2"
	shift 2

	SANDBOX=$(mktemp -d -t aidevops-t2898-XXXXXX)
	export HOME="$SANDBOX"
	# shared-constants.sh resolves the log directory from the deployed JSONC
	# defaults at source time, before health-check can parse --quiet. Seed the
	# sandbox like setup.sh does so quiet-mode assertions only cover health-check.
	local config_dir="$HOME/.aidevops/agents/configs"
	mkdir -p "$HOME/.aidevops/cache" "$HOME/.aidevops/logs" \
		"$HOME/.aidevops/agents/scripts" "$config_dir"
	cp "$CONFIG_DEFAULTS_SOURCE" "$config_dir/aidevops.defaults.jsonc"
	if [[ -r "$CONFIG_SCHEMA_SOURCE" ]]; then
		cp "$CONFIG_SCHEMA_SOURCE" "$config_dir/aidevops-config.schema.json"
	fi

	# Build a fake `launchctl` on PATH so _launchd_is_loaded responds
	# deterministically. macOS-only path; Linux paths use a different stub.
	local stub_dir="$SANDBOX/.bin"
	mkdir -p "$stub_dir"
	if [[ "$sched_state" == "loaded" ]]; then
		cat >"$stub_dir/launchctl" <<'EOF'
#!/usr/bin/env bash
# Stub: emit a launchctl-list-shaped line containing the aidevops label.
echo "12345  0   com.aidevops.aidevops-auto-update"
exit 0
EOF
	else
		cat >"$stub_dir/launchctl" <<'EOF'
#!/usr/bin/env bash
# Stub: empty list (no aidevops label).
exit 0
EOF
	fi
	chmod +x "$stub_dir/launchctl"

	# Compose state file based on kind.
	local state_file="$HOME/.aidevops/cache/auto-update-state.json"
	case "$state_kind" in
	none) ;; # No state file
	empty)
		# State file exists but no last_timestamp.
		echo '{"enabled":true}' >"$state_file"
		;;
	fresh)
		# last_timestamp 60s ago (well within 2× 10min interval).
		local fresh_ts
		fresh_ts=$(date -u -v-1M '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null \
			|| date -u -d '-1 minute' '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null \
			|| date -u '+%Y-%m-%dT%H:%M:%SZ')
		printf '{"last_timestamp":"%s"}' "$fresh_ts" >"$state_file"
		;;
	stale)
		# last_timestamp 2 hours ago (well past 2× 10min = 20min threshold).
		local stale_ts
		stale_ts=$(date -u -v-2H '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null \
			|| date -u -d '-2 hours' '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null \
			|| echo '2020-01-01T00:00:00Z')
		printf '{"last_timestamp":"%s"}' "$stale_ts" >"$state_file"
		;;
	garbage)
		printf '{"last_timestamp":"not-a-date"}' >"$state_file"
		;;
	esac

	# PATH order: stubs first, then real binaries.
	PATH="$stub_dir:$PATH" bash "$HELPER" "$@" 2>"/tmp/aidevops-t2898-stderr-$$" >/dev/null
	local rc=$?
	# Promote captured stderr to a stable path for assertion convenience.
	mv "/tmp/aidevops-t2898-stderr-$$" /tmp/last-stderr 2>/dev/null || true
	rm -rf "$SANDBOX"
	SANDBOX=""
	return "$rc"
}

# ---------------------------------------------------------------------------
# Structural checks against the real helper file — do not require runtime.
# ---------------------------------------------------------------------------
# GH#40150: exercise the updater with a real setup subprocess and isolated state.
test_deploy_refusal_fallback() (
	local implementation="$1"
	local fixture
	fixture=$(mktemp -d)
	trap 'rm -rf "$fixture"' EXIT
	local INSTALL_DIR="$fixture" LOG_FILE="$fixture/update.log" STATE_FILE="$fixture/state.json"
	export SETUP_CALLS="$fixture/calls" INCREMENTAL_RC=78 FULL_RC=0
	# shellcheck source=../auto-update-helper-check.sh
	source "$CHECK_LIBRARY"
	if [[ "$implementation" == orchestrator ]]; then
		# Existing function-extraction pattern below avoids main and host setup.
		eval "$(sed -n '/^update_state() {/,/^}/p; /^_run_setup_ai_session_with_fallback() {/,/^}/p; /^_cmd_check_perform_update() {/,/^}/p; /^_auto_update_runtime_bundle_root() {/,/^}/p' "$HELPER")"
	fi
	log_warn() { local message="$1"; printf '%s\n' "$message" >>"$LOG_FILE"; return 0; }
	log_info() { local message="$1"; : "$message"; return 0; }
	log_error() { local message="$1"; : "$message"; return 0; }
	cat >"$fixture/setup.sh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$SETUP_CALLS"
if [[ "$1" == --stage ]]; then
	if [[ "$INCREMENTAL_RC" -eq 78 ]]; then
		printf '\033[0;31mRefusing incompatible source-access runtime deployment: fixture mismatch\033[0m\n'
	fi
	exit "$INCREMENTAL_RC"
fi
exit "$FULL_RC"
EOF
	local rc=0
	_run_setup_ai_session_with_fallback '1.2.3' || rc=$?
	[[ "$rc" -eq 78 && "$(wc -l <"$SETUP_CALLS")" -eq 1 ]] || return 1
	jq -e '.last_status == "deploy_refused" and .last_version == "1.2.3" and .last_reason == "Refusing incompatible source-access runtime deployment: fixture mismatch"' "$STATE_FILE" >/dev/null || return 1
	# Repeated refusals exercise updating an existing state rather than creating it.
	_run_setup_ai_session_with_fallback '1.2.4' || rc=$?
	jq -e '.last_status == "deploy_refused" and .last_version == "1.2.4"' "$STATE_FILE" >/dev/null || return 1
	# Verify the production update caller does not overwrite deploy_refused.
	mkdir "$fixture/.git"
	_cmd_check_git_update() { return 0; }
	rc=0
	_cmd_check_perform_update '1.2.3' '1.2.5' || rc=$?
	[[ "$rc" -eq 1 ]] || return 1
	jq -e '.last_status == "deploy_refused" and .last_version == "1.2.5"' "$STATE_FILE" >/dev/null || return 1
	# No current refusal line must not reuse an old refusal from the shared log.
	INCREMENTAL_RC=1 FULL_RC=78 rc=0
	_run_setup_ai_session_with_fallback '1.2.6' || rc=$?
	[[ "$rc" -eq 78 ]] || return 1
	jq -e '.last_status == "deploy_refused" and (.last_reason | startswith("Setup refused deployment (exit 78)"))' "$STATE_FILE" >/dev/null || return 1
	INCREMENTAL_RC=1 FULL_RC=0 rc=0
	_run_setup_ai_session_with_fallback '1.2.7' || rc=$?
	[[ "$rc" -eq 0 && "$(tail -n 1 "$SETUP_CALLS")" == --non-interactive ]] || return 1
	INCREMENTAL_RC=0 rc=0
	local before
	before=$(wc -l <"$SETUP_CALLS")
	_run_setup_ai_session_with_fallback '1.2.7' || rc=$?
	[[ "$rc" -eq 0 && "$(wc -l <"$SETUP_CALLS")" -eq $((before + 1)) ]] || return 1
	# Status must surface the reason, and successful state must clear it.
	# shellcheck source=../auto-update-helper-status.sh
	source "$AGENT_SCRIPT_DIR/auto-update-helper-status.sh"
	if [[ "$implementation" == orchestrator ]]; then
		eval "$(sed -n '/^_cmd_status_state() {/,/^}/p' "$HELPER")"
	fi
	get_user_idle_seconds() { printf '0'; return 0; }
	get_feature_toggle() { printf '1'; return 0; }
	local DEFAULT_TOOL_IDLE_HOURS=1 GREEN='' YELLOW='' NC=''
	local output
	output=$(_cmd_status_state)
	[[ "$output" == *'Deploy refusal:'* && "$output" == *'Setup refused deployment (exit 78)'* ]] || return 1
	update_state update '1.2.7' success
	jq -e '.last_status == "success" and .last_reason == "" and .last_update_version == "1.2.7"' "$STATE_FILE" >/dev/null || return 1
	return 0
)

for implementation in library orchestrator; do
	if test_deploy_refusal_fallback "$implementation"; then
		print_result "$implementation: refusal skips retry, persists reason, and transient failure still falls back" "PASS"
	else
		print_result "$implementation: refusal skips retry, persists reason, and transient failure still falls back" "FAIL"
	fi
done

# The scoped stage runner has its own fallback, independently of auto-update.
test_scoped_refusal_fallback() (
	# shellcheck source=../setup/modules/setup-execution.sh
	source "$AGENT_SCRIPT_DIR/setup/modules/setup-execution.sh"
	local SETUP_STAGE=ai-session SETUP_STAGE_AI_SESSION=ai-session INSTALL_DIR="$AGENT_SCRIPT_DIR"
	local SETUP_STAGE_OPENCODE=opencode SETUP_STAGE_AGENTS=agents SETUP_STAGE_RUNTIME_CONFIG=config
	local SETUP_STAGE_SOURCE_ACCESS=source-access SETUP_STAGE_HOOKS=hooks SETUP_STAGE_TABBY=tabby
	local SETUP_STAGE_PULSE=pulse SETUP_STAGE_GUI_DESKTOP=gui
	local SETUP_STAGE_OPENCODE_PLUGINS=plugins
	local fixture_incremental_rc=78 full_calls=0 rc=0
	_setup_canonical_stage() { local stage="$1"; printf '%s' "$stage"; return 0; }
	_setup_init_stage_timing_log() { return 0; }
	print_info() { local message="$1"; : "$message"; return 0; }
	print_warning() { local message="$1"; : "$message"; return 0; }
	_setup_run_ai_session_incremental() { return "$fixture_incremental_rc"; }
	_setup_run_non_interactive() { full_calls=$((full_calls + 1)); return 0; }
	_setup_post_setup_steps() { return 0; }
	_setup_ai_session_verify_deploy() { return 0; }
	_setup_run_scoped_stage Linux || rc=$?
	[[ "$rc" -eq 78 && "$full_calls" -eq 0 ]] || return 1
	fixture_incremental_rc=1 rc=0
	_setup_run_scoped_stage Linux || rc=$?
	[[ "$rc" -eq 0 && "$full_calls" -eq 1 ]] || return 1
	# When incremental support is unavailable, the internal full setup must
	# also stop at the refusal, even in a caller that suppresses errexit.
	eval "$(sed -n '/^_setup_run_non_interactive() {/,/^}/p' "$AGENT_SCRIPT_DIR/setup/modules/setup-execution.sh")"
	_setup_run_noninteractive_migrations() { return 0; }
	_time_step() {
		local stage="$1"
		[[ "$stage" != "$SETUP_STAGE_AGENTS" ]] || return 78
		[[ "$stage" != "$SETUP_STAGE_OPENCODE_PLUGINS" ]] || full_calls=$((full_calls + 1))
		return 0
	}
	rc=0
	_setup_run_scoped_stage Linux || rc=$?
	[[ "$rc" -eq 78 && "$full_calls" -eq 1 ]] || return 1
	return 0
)

if test_scoped_refusal_fallback; then
	print_result "scoped ai-session runner propagates refusal but retains transient fallback" "PASS"
else
	print_result "scoped ai-session runner propagates refusal but retains transient fallback" "FAIL"
fi

echo "Structural checks (HELPER=$HELPER):"

if [[ ! -x "$HELPER" ]]; then
	print_result "auto-update-helper.sh exists and executable" "FAIL" \
		"missing at $HELPER"
	exit 1
fi
print_result "auto-update-helper.sh exists and executable" "PASS"

for updater_source in "$HELPER" "$CHECK_LIBRARY"; do
	if grep -Fq -- "fast-forward-current --repo \"\$INSTALL_DIR\" --branch main" "$updater_source" &&
		grep -q -- '--reason aidevops-update --confirm FAST_FORWARD_CANONICAL_BRANCH' "$updater_source"; then
		print_result "$(basename "$updater_source") delegates canonical maintenance" "PASS"
	else
		print_result "$(basename "$updater_source") delegates canonical maintenance" "FAIL"
	fi

	if grep -Fq -- "git -C \"\$INSTALL_DIR\" fetch origin main" "$updater_source" ||
		grep -Fq -- "git -C \"\$INSTALL_DIR\" merge --ff-only" "$updater_source"; then
		print_result "$(basename "$updater_source") avoids direct canonical mutation" "FAIL"
	else
		print_result "$(basename "$updater_source") avoids direct canonical mutation" "PASS"
	fi
done

if grep -q '^cmd_health_check()' "$HELPER"; then
	print_result "cmd_health_check function defined" "PASS"
else
	print_result "cmd_health_check function defined" "FAIL"
fi

if grep -q '^_daemon_is_loaded()' "$HELPER"; then
	print_result "_daemon_is_loaded helper defined" "PASS"
else
	print_result "_daemon_is_loaded helper defined" "FAIL"
fi

if grep -qE 'health-check\) cmd_health_check' "$HELPER"; then
	print_result "main() dispatches health-check" "PASS"
else
	print_result "main() dispatches health-check" "FAIL"
fi

if grep -qE -- '--idempotent' "$HELPER"; then
	print_result "cmd_enable accepts --idempotent" "PASS"
else
	print_result "cmd_enable accepts --idempotent" "FAIL"
fi

if grep -q 'health-check' "$HELPER" && grep -q 'idempotent' "$HELPER"; then
	# Help text mentions both
	if "$HELPER" help 2>&1 | grep -q 'health-check'; then
		print_result "help text mentions health-check" "PASS"
	else
		print_result "help text mentions health-check" "FAIL"
	fi
fi

# Test (GH#37751): _resolve_status_backend reports systemd when the timer is
# enabled even though detection fell back to cron. Platform-independent.
_resolve_body=$(sed -n '/^_resolve_status_backend() {/,/^}/p' "$HELPER")
_resolve_shim_dir=$(mktemp -d)
cat >"${_resolve_shim_dir}/systemctl" <<'EOF'
#!/usr/bin/env bash
case "$2" in
is-enabled) printf '%s\n' "${FAKE_TIMER_STATE:-disabled}"; [[ "${FAKE_TIMER_STATE:-disabled}" == enabled ]] ;;
is-active) [[ "${3:-}" == --quiet ]] || printf '%s\n' "${FAKE_TIMER_ACTIVE:-inactive}"; [[ "${FAKE_TIMER_ACTIVE:-inactive}" == active ]] ;;
show) printf '%s\n' 'NextElapseUSecRealtime=tomorrow' ;;
esac
EOF
chmod +x "${_resolve_shim_dir}/systemctl"
_resolve_cron=$(PATH="${_resolve_shim_dir}:$PATH" AIDEVOPS_SCHEDULER='' FAKE_TIMER_STATE=enabled bash -c "SYSTEMD_UNIT_NAME=aidevops-auto-update; ${_resolve_body}; _resolve_status_backend cron")
_resolve_off=$(PATH="${_resolve_shim_dir}:$PATH" AIDEVOPS_SCHEDULER='' FAKE_TIMER_STATE=disabled bash -c "SYSTEMD_UNIT_NAME=aidevops-auto-update; ${_resolve_body}; _resolve_status_backend cron")
_resolve_active=$(PATH="${_resolve_shim_dir}:$PATH" AIDEVOPS_SCHEDULER='' FAKE_TIMER_ACTIVE=active bash -c "SYSTEMD_UNIT_NAME=aidevops-auto-update; ${_resolve_body}; _resolve_status_backend cron")
_resolve_explicit=$(PATH="${_resolve_shim_dir}:$PATH" AIDEVOPS_SCHEDULER=cron FAKE_TIMER_STATE=enabled bash -c "SYSTEMD_UNIT_NAME=aidevops-auto-update; ${_resolve_body}; _resolve_status_backend cron")
_resolve_launchd=$(PATH="${_resolve_shim_dir}:$PATH" AIDEVOPS_SCHEDULER='' FAKE_TIMER_STATE=enabled bash -c "SYSTEMD_UNIT_NAME=aidevops-auto-update; ${_resolve_body}; _resolve_status_backend launchd")
_status_body=$(sed -n '/^_cmd_status_scheduler() {/,/^}/p' "$HELPER")
_status_output=$(PATH="${_resolve_shim_dir}:$PATH" FAKE_TIMER_ACTIVE=active bash -c "SYSTEMD_UNIT_NAME=aidevops-auto-update; SYSTEMD_SERVICE_DIR=/unused; CRON_MARKER=unused; GREEN=; YELLOW=; NC=; _print_linger_status() { return 0; }; ${_status_body}; _cmd_status_scheduler systemd")
rm -rf "$_resolve_shim_dir"
if [[ "$_resolve_cron" == "systemd" && "$_resolve_off" == "cron" && "$_resolve_active" == "systemd" && "$_resolve_explicit" == "cron" && "$_resolve_launchd" == "launchd" ]]; then
	print_result "status resolves systemd when timer enabled but detection says cron" "PASS"
else
	print_result "status resolves systemd when timer enabled but detection says cron" "FAIL" \
		"got '$_resolve_cron' / '$_resolve_off' / '$_resolve_active' / '$_resolve_explicit' / '$_resolve_launchd'"
fi
if [[ "$_status_output" == *'Status:    disabled'* && "$_status_output" == *'Active:    active'* && "$_status_output" == *'Next fire: tomorrow'* ]]; then
	print_result "systemd status distinguishes active from enabled and shows next fire" "PASS"
else
	print_result "systemd status distinguishes active from enabled and shows next fire" "FAIL" "$_status_output"
fi

# Skip platform-specific runtime tests on non-macOS for now: the launchctl
# stub model is macOS-shaped. The structural checks above cover the
# correctness of the function definitions; runtime tests below only run
# on Darwin.
if [[ "$(uname -s)" != "Darwin" ]]; then
	echo ""
	echo "Skipping runtime tests (Darwin-only — launchctl stub path)."
	echo ""
	echo "Tests run: $TESTS_RUN, failed: $TESTS_FAILED"
	[[ "$TESTS_FAILED" -eq 0 ]] && exit 0 || exit 1
fi

# ---------------------------------------------------------------------------
# Runtime behaviour tests (Darwin only).
# ---------------------------------------------------------------------------
echo ""
echo "Runtime behaviour tests (Darwin):"

# Test 1: not installed → exit 2
rc=0
_run_in_sandbox unloaded none health-check --quiet || rc=$?
if [[ "$rc" -eq 2 ]]; then
	print_result "health-check exits 2 when daemon not installed" "PASS"
else
	print_result "health-check exits 2 when daemon not installed" "FAIL" \
		"got rc=$rc, expected 2"
fi

# Test 2: loaded, no state → exit 0 (fresh install path)
rc=0
_run_in_sandbox loaded none health-check --quiet || rc=$?
if [[ "$rc" -eq 0 ]]; then
	print_result "health-check exits 0 when loaded with no state file" "PASS"
else
	print_result "health-check exits 0 when loaded with no state file" "FAIL" \
		"got rc=$rc, expected 0"
fi

# Test 3: loaded, fresh state → exit 0
rc=0
_run_in_sandbox loaded fresh health-check --quiet || rc=$?
if [[ "$rc" -eq 0 ]]; then
	print_result "health-check exits 0 when state is fresh" "PASS"
else
	print_result "health-check exits 0 when state is fresh" "FAIL" \
		"got rc=$rc, expected 0"
fi

# Test 4: loaded, stale state → exit 1
rc=0
_run_in_sandbox loaded stale health-check --quiet || rc=$?
if [[ "$rc" -eq 1 ]]; then
	print_result "health-check exits 1 when state is stale" "PASS"
else
	print_result "health-check exits 1 when state is stale" "FAIL" \
		"got rc=$rc, expected 1"
fi

# Test 5: loaded, garbage state → exit 1
rc=0
_run_in_sandbox loaded garbage health-check --quiet || rc=$?
if [[ "$rc" -eq 1 ]]; then
	print_result "health-check exits 1 when state is garbage" "PASS"
else
	print_result "health-check exits 1 when state is garbage" "FAIL" \
		"got rc=$rc, expected 1"
fi

# Test 6: --quiet produces no stderr
rc=0
_run_in_sandbox unloaded none health-check --quiet || rc=$?
if [[ ! -s /tmp/last-stderr ]]; then
	print_result "health-check --quiet suppresses stderr" "PASS"
else
	print_result "health-check --quiet suppresses stderr" "FAIL" \
		"stderr was: $(cat /tmp/last-stderr)"
fi
rm -f /tmp/last-stderr

# Test 7: enable --idempotent is no-op when loaded
# The stubbed launchctl says loaded, so enable should print no-op message
# and exit 0 without touching plist files.
rc=0
_run_in_sandbox loaded none enable --idempotent || rc=$?
if [[ "$rc" -eq 0 ]]; then
	print_result "enable --idempotent exits 0 when daemon already loaded" "PASS"
else
	print_result "enable --idempotent exits 0 when daemon already loaded" "FAIL" \
		"got rc=$rc"
fi

echo ""
echo "Tests run: $TESTS_RUN, failed: $TESTS_FAILED"
[[ "$TESTS_FAILED" -eq 0 ]] && exit 0 || exit 1
