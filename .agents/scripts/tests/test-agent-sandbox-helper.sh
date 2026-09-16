#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn

set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HELPER="${TEST_DIR}/../agent-sandbox-helper.sh"
CONFIG="${TEST_DIR}/../../configs/agent-sandbox-backends.json"
SCHEMA="${TEST_DIR}/../../schemas/agent-sandbox-backends.schema.json"
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf "$TEST_ROOT"' EXIT

BIN_DIR="${TEST_ROOT}/bin"
MOCK_STATE="${TEST_ROOT}/mock-state"
MOCK_LOG="${TEST_ROOT}/container.log"
RECEIPT_DIR="${TEST_ROOT}/receipts"
WORKTREE="${TEST_ROOT}/worktree"
mkdir -p "$BIN_DIR" "$MOCK_STATE" "$WORKTREE"
: >"$MOCK_LOG"

cat >"${BIN_DIR}/container" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail

printf '%s\n' "$*" >>"$MOCK_LOG"
command_name="${1:-}"
shift || true

last_arg() {
	local value=""
	for value in "$@"; do :; done
	printf '%s\n' "$value"
}

case "$command_name" in
system)
	case "${1:-}" in
	version) printf '[{"appName":"container","version":"1.4.1","buildType":"release","commit":"fixture"}]\n' ;;
	status) printf '{"status":"running"}\n' ;;
	*) exit 2 ;;
	esac
	;;
network)
	subcommand="${1:-}"
	shift || true
	network_id=$(last_arg "$@")
	case "$subcommand" in
	inspect) [[ -f "${MOCK_STATE}/network-${network_id}" ]] ;;
	create) touch "${MOCK_STATE}/network-${network_id}" ;;
	delete) rm -f "${MOCK_STATE}/network-${network_id}" ;;
	*) exit 2 ;;
	esac
	;;
inspect)
	resource_id="${1:-}"
	[[ -f "${MOCK_STATE}/resource-${resource_id}" ]] || exit 1
	state=$(<"${MOCK_STATE}/resource-${resource_id}")
	printf '{"status":"%s"}\n' "$state"
	;;
create)
	[[ "${MOCK_CREATE_FAIL:-0}" != "1" ]] || exit 1
	resource_id=""
	while [[ $# -gt 0 ]]; do
		case "$1" in
		--name) resource_id="${2:-}"; shift 2 ;;
		*) shift ;;
		esac
	done
	[[ -n "$resource_id" ]]
	printf 'stopped\n' >"${MOCK_STATE}/resource-${resource_id}"
	;;
start)
	resource_id="${1:-}"
	[[ -f "${MOCK_STATE}/resource-${resource_id}" ]]
	printf 'running\n' >"${MOCK_STATE}/resource-${resource_id}"
	;;
stop)
	resource_id=$(last_arg "$@")
	[[ -f "${MOCK_STATE}/resource-${resource_id}" ]] || exit 0
	printf 'stopped\n' >"${MOCK_STATE}/resource-${resource_id}"
	;;
delete)
	resource_id=$(last_arg "$@")
	rm -f "${MOCK_STATE}/resource-${resource_id}"
	;;
exec)
	if [[ " $* " == *" timeout-me "* ]]; then
		sleep 5
		exit 0
	fi
	printf 'exec-ok\n'
	;;
*) exit 2 ;;
esac
MOCK
chmod +x "${BIN_DIR}/container"

git init "$WORKTREE" -q
git -C "$WORKTREE" config user.email test@example.invalid
git -C "$WORKTREE" config user.name "Sandbox Test"
printf 'fixture\n' >"${WORKTREE}/README.md"
git -C "$WORKTREE" add README.md
git -C "$WORKTREE" commit -qm init

export PATH="${BIN_DIR}:${PATH}"
export MOCK_STATE MOCK_LOG
export AIDEVOPS_SANDBOX_STATE_DIR="$RECEIPT_DIR"
export AIDEVOPS_SANDBOX_CONFIG="$CONFIG"
export AIDEVOPS_SANDBOX_OS=Darwin
export AIDEVOPS_SANDBOX_ARCH=arm64
export AIDEVOPS_SANDBOX_MACOS_MAJOR=26
export AIDEVOPS_SANDBOX_ALLOW_NON_LINKED_WORKTREE=1
export AIDEVOPS_SANDBOX_SESSION_ID=session-alpha
export AIDEVOPS_SANDBOX_NOW_EPOCH=1000

PASS=0
FAIL=0

pass() {
	printf 'PASS %s\n' "$1"
	PASS=$((PASS + 1))
	return 0
}

fail() {
	printf 'FAIL %s: %s\n' "$1" "$2" >&2
	FAIL=$((FAIL + 1))
	return 0
}

assert_jq() {
	local name="$1"
	local json="$2"
	local filter="$3"
	if jq -e "$filter" <<<"$json" >/dev/null; then
		pass "$name"
	else
		fail "$name" "$json"
	fi
	return 0
}

expect_rc() {
	local name="$1"
	local expected="$2"
	shift 2
	local rc=0
	set +e
	"$@" >/dev/null 2>&1
	rc=$?
	set -e
	if [[ "$rc" -eq "$expected" ]]; then
		pass "$name"
	else
		fail "$name" "expected rc=${expected}, got rc=${rc}"
	fi
	return 0
}

resolve_json=$(bash "$HELPER" resolve)
assert_jq "local execution remains the default" "$resolve_json" \
	'.backend == "local" and .sandboxed == false and .decision == "local-default"'
expect_rc "required sandbox rejects implicit local fallback" 3 \
	env AIDEVOPS_SANDBOX_REQUIRED=1 bash "$HELPER" resolve

capabilities_json=$(bash "$HELPER" capabilities --backend apple-container)
assert_jq "Apple capability probe requires a healthy supported host" "$capabilities_json" \
	'.runtime.available == true and .runtime.version == "1.4.1" and .definition.capabilities.recover == true'
bubbles_json=$(bash "$HELPER" capabilities --backend bubbles)
assert_jq "Bubbles reports capability-only fail-closed state" "$bubbles_json" \
	'.runtime.available == false and .definition.executable == false and .definition.capabilities.create == false'
cloudron_json=$(bash "$HELPER" capabilities --backend cloudron)
assert_jq "Cloudron does not fabricate sandbox lifecycle support" "$cloudron_json" \
	'.runtime.available == false and .definition.foundation_capabilities.dispatch == true and .definition.foundation_capabilities.nested_virtualization == false'
unavailable_json=$(AIDEVOPS_SANDBOX_OS=Linux bash "$HELPER" capabilities --backend apple-container)
assert_jq "unsupported Apple hosts are reported without fallback" "$unavailable_json" \
	'.runtime.available == false and .runtime.reason == "requires Darwin"'

create_args=(create --id agent-01 --backend apple-container --image fixture/image:1
	--worktree "$WORKTREE" --cpus 2 --memory 2G --command-timeout 1 --idle-timeout 60 --lease-ttl 60)
create_json=$(bash "$HELPER" "${create_args[@]}")
assert_jq "create publishes a generation-one stopped receipt" "$create_json" \
	'.state == "CREATED" and .lease.generation == 1 and .bounds.network_mode == "internal" and .bounds.storage_quota == false'

receipt_path="${RECEIPT_DIR}/agent-01.json"
create_count_before=$(grep -c '^create ' "$MOCK_LOG" || true)
bash "$HELPER" "${create_args[@]}" >/dev/null
create_count_after=$(grep -c '^create ' "$MOCK_LOG" || true)
if [[ "$create_count_before" -eq 1 && "$create_count_after" -eq 1 ]]; then
	pass "identical create replay is idempotent"
else
	fail "identical create replay is idempotent" "create counts ${create_count_before}/${create_count_after}"
fi
expect_rc "conflicting create replay fails closed" 5 bash "$HELPER" create --id agent-01 \
	--backend apple-container --image fixture/image:2 --worktree "$WORKTREE"

if grep -Fq 'session-alpha' "$receipt_path" || grep -Fq "$WORKTREE" "$receipt_path" ||
	grep -Fq 'fixture/image:1' "$receipt_path"; then
	fail "receipt excludes raw private identity and creation inputs" "sensitive input found"
else
	pass "receipt excludes raw private identity and creation inputs"
fi
receipt_mode=$(stat -f '%Lp' "$receipt_path" 2>/dev/null || stat -c '%a' "$receipt_path")
[[ "$receipt_mode" == "600" ]] && pass "receipt mode is 600" || fail "receipt mode is 600" "$receipt_mode"

start_json=$(bash "$HELPER" start --id agent-01)
assert_jq "start records running state and bounded runtime" "$start_json" \
	'.state == "RUNNING" and .runtime_expires_at_epoch == 1060'
exec_output=$(bash "$HELPER" exec --id agent-01 -- printf ok)
[[ "$exec_output" == "exec-ok" ]] && pass "exec forwards argv and output" || fail "exec forwards argv and output" "$exec_output"
status_json=$(bash "$HELPER" status --id agent-01)
assert_jq "status combines receipt and fresh backend state" "$status_json" \
	'.receipt.state == "RUNNING" and .backend_state == "running"'

expect_rc "live lease blocks another session" 5 \
	env AIDEVOPS_SANDBOX_SESSION_ID=session-beta bash "$HELPER" stop --id agent-01
expect_rc "snapshot fails closed when redaction-safe support is absent" 4 \
	bash "$HELPER" snapshot --id agent-01
expect_rc "Bubbles create is unsupported" 4 bash "$HELPER" create --id bubble-01 \
	--backend bubbles --image fixture/image:1 --worktree "$WORKTREE"
expect_rc "Cloudron create is unsupported" 4 bash "$HELPER" create --id cloudron-01 \
	--backend cloudron --image fixture/image:1 --worktree "$WORKTREE"
expect_rc "canonical Git checkouts are rejected as sandbox workspaces" 2 \
	env AIDEVOPS_SANDBOX_ALLOW_NON_LINKED_WORKTREE=0 bash "$HELPER" create --id canonical-01 \
	--backend apple-container --image fixture/image:1 --worktree "$WORKTREE"
touch "${MOCK_STATE}/network-aidevops-agent-fail-net"
expect_rc "failed create preserves a pre-existing private network" 1 \
	env MOCK_CREATE_FAIL=1 bash "$HELPER" create --id agent-fail --backend apple-container \
	--image fixture/image:1 --worktree "$WORKTREE"
if [[ -f "${MOCK_STATE}/network-aidevops-agent-fail-net" ]]; then
	pass "failed create does not delete pre-existing provider state"
else
	fail "failed create does not delete pre-existing provider state" "network was deleted"
fi

rm -f "${MOCK_STATE}/resource-aidevops-agent-01"
recover_json=$(AIDEVOPS_SANDBOX_SESSION_ID=session-beta AIDEVOPS_SANDBOX_NOW_EPOCH=1061 \
	bash "$HELPER" recover --id agent-01 --image fixture/image:1 --worktree "$WORKTREE")
assert_jq "stale-lease recovery fences ownership and recreates missing resource" "$recover_json" \
	'.state == "CREATED" and .lease.generation == 2 and .recovery_count == 1'

AIDEVOPS_SANDBOX_SESSION_ID=session-beta AIDEVOPS_SANDBOX_NOW_EPOCH=1061 \
	bash "$HELPER" start --id agent-01 >/dev/null
expect_rc "exec command timeout is enforced" 124 env AIDEVOPS_SANDBOX_SESSION_ID=session-beta \
	AIDEVOPS_SANDBOX_NOW_EPOCH=1061 bash "$HELPER" exec --id agent-01 -- timeout-me
destroy_json=$(AIDEVOPS_SANDBOX_SESSION_ID=session-beta AIDEVOPS_SANDBOX_NOW_EPOCH=1061 \
	bash "$HELPER" destroy --id agent-01)
assert_jq "destroy records terminal state" "$destroy_json" '.state == "DESTROYED"'
second_destroy=$(AIDEVOPS_SANDBOX_SESSION_ID=session-gamma bash "$HELPER" destroy --id agent-01)
assert_jq "destroy replay is idempotent after lease expiry or ownership change" "$second_destroy" '.state == "DESTROYED"'

jq -e '.default_backend == "local" and .backends["apple-container"].capabilities.snapshot == false' \
	"$CONFIG" >/dev/null && pass "backend registry is internally consistent" || fail "backend registry is internally consistent" "$CONFIG"
jq -e '.properties.backends.required | index("apple-container")' "$SCHEMA" >/dev/null &&
	pass "backend registry schema requires Apple adapter" || fail "backend registry schema requires Apple adapter" "$SCHEMA"

printf '\nRan %d checks, %d failed.\n' "$((PASS + FAIL))" "$FAIL"
[[ "$FAIL" -eq 0 ]]
