#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_DIR="$(mktemp -d)"
trap 'rm -rf "$TEST_DIR"' EXIT
STATE_DB="$TEST_DIR/state.db"
AIDEVOPS_MODEL_ROUTING_TABLE="$TEST_DIR/routing.json"
export AIDEVOPS_MODEL_ROUTING_TABLE

printf '%s\n' '{"tiers":{"standard":{"models":["alpha/one","alpha/two","beta/one","gamma/one"],"round_robin":true},"simple":{"models":["beta/one","alpha/one"],"round_robin":true}}}' >"$AIDEVOPS_MODEL_ROUTING_TABLE"
sqlite3 "$STATE_DB" 'CREATE TABLE provider_rotation (role TEXT PRIMARY KEY, last_provider TEXT NOT NULL, updated_at TEXT);'

# shellcheck source=/dev/null
source "$SCRIPT_DIR/shared-model-tier.sh"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/headless-runtime-model.sh"

db_query() { sqlite3 -cmd '.timeout 5000' "$STATE_DB" "$1"; }
sql_escape() { printf '%s' "${1//\'/\'\'}"; }
extract_provider() { printf '%s' "${1%%/*}"; }
provider_auth_available() { return 0; }
provider_oauth_pool_available() { [[ "$1" != "${COOLING_PROVIDER:-}" ]]; }
model_backoff_active() { return 1; }
get_configured_models() {
	case "$1" in
	standard) printf '%s\n' alpha/one alpha/two beta/one gamma/one ;;
	simple) printf '%s\n' beta/one alpha/one ;;
	esac
}
_choose_model_tier_downgrade() { return 0; }
print_error() { printf '%s\n' "$1" >&2; }
print_warning() { printf '%s\n' "$1" >&2; }

assert_model() {
	local expected="$1" actual="$2" description="$3"
	if [[ "$expected" != "$actual" ]]; then
		printf 'FAIL %s: expected %s, got %s\n' "$description" "$expected" "$actual" >&2
		return 1
	fi
	printf 'PASS %s\n' "$description"
}

assert_model alpha/one "$(_choose_model_auto worker standard)" 'first healthy provider'
assert_model beta/one "$(_choose_model_auto worker standard)" 'second distinct provider'
assert_model gamma/one "$(_choose_model_auto worker standard)" 'third distinct provider'
assert_model alpha/one "$(_choose_model_auto worker standard)" 'cycle wraps'
assert_model beta/one "$(_choose_model_auto worker simple)" 'tier has independent rotation state'
assert_model alpha/one "$(_choose_model_auto worker standard exact-tier alpha/one)" 'initial model preference is preserved'
assert_model beta/one "$(_choose_model_auto worker standard)" 'preference does not consume a slot'
COOLING_PROVIDER=gamma
assert_model alpha/one "$(_choose_model_auto worker standard)" 'cooling provider skipped'
COOLING_PROVIDER=beta
assert_model gamma/one "$(_choose_model_auto worker standard)" 'unavailable provider skipped'
assert_model alpha/one "$(_choose_model_auto pulse standard)" 'other roles retain priority order'

# Two independent selectors must reserve different slots under a concurrent read.
export STATE_DB
export -f _reserve_worker_provider db_query sql_escape
bash -c '_reserve_worker_provider standard alpha beta gamma' >"$TEST_DIR/first" &
first_pid=$!
bash -c '_reserve_worker_provider standard alpha beta gamma' >"$TEST_DIR/second" &
second_pid=$!
wait "$first_pid"
wait "$second_pid"
first_result=$(<"$TEST_DIR/first")
second_result=$(<"$TEST_DIR/second")
if [[ "$first_result" == "$second_result" ]]; then
	printf 'FAIL concurrent selectors reserved the same provider: %s\n' "$first_result" >&2
	exit 1
fi
printf '%s\n' 'PASS concurrent selectors reserve different providers'
printf '%s\n' 'All provider rotation tests passed'
