#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_ROOT="$(mktemp -d -t aidevops-signing-test.XXXXXX)"
TEST_HOME="${TEST_ROOT}/home"
FAKE_BIN="${TEST_ROOT}/bin"
CALL_LOG="${TEST_ROOT}/calls.log"
GIT_CALL_LOG="${TEST_ROOT}/git-calls.log"
PUBLIC_KEY=''

cleanup() {
	rm -rf "$TEST_ROOT"
	return 0
}
trap cleanup EXIT

mkdir -p "${TEST_HOME}/.ssh" "$FAKE_BIN"
ssh-keygen -t ed25519 -N '' -C aidevops-headless-signing -q -f "${TEST_HOME}/.ssh/id_ed25519_signing"
PUBLIC_KEY=$(<"${TEST_HOME}/.ssh/id_ed25519_signing.pub")
printf 'export SSH_AUTH_SOCK=%q\nexport SSH_AGENT_PID=%q\n' \
	"${TEST_ROOT}/agent.sock" "12345" >"${TEST_HOME}/.ssh/agent.env"

cat >"${FAKE_BIN}/git" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"${AIDEVOPS_SIGNING_TEST_GIT_CALL_LOG:?}"
# GH#33066: simulate a command guard blocking config reads, or an unset key.
[[ -z "${AIDEVOPS_SIGNING_TEST_GIT_EXIT:-}" ]] || exit "$AIDEVOPS_SIGNING_TEST_GIT_EXIT"
case "$*" in
*gpg.format*) printf 'ssh\n' ;;
*user.signingkey*) printf '%s/.ssh/id_ed25519.pub\n' "$HOME" ;;
*user.email*) printf 'aidevops-test@example.invalid\n' ;;
*commit.gpgsign* | *tag.gpgsign*) printf 'true\n' ;;
esac
exit 0
EOF

cat >"${FAKE_BIN}/ssh-add" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"${AIDEVOPS_SIGNING_TEST_CALL_LOG:?}"
case "${1:-}" in
-l) exit 0 ;;
-L)
	[[ "${SSH_AUTH_SOCK:-}" == "${AIDEVOPS_SIGNING_TEST_SOCKET:?}" ]] || exit 1
	[[ "${AIDEVOPS_SIGNING_TEST_NOT_LOADED:-0}" == 0 || -f "${AIDEVOPS_SIGNING_TEST_CALL_LOG}.loaded" ]] || exit 1
	printf '%s\n' "${AIDEVOPS_SIGNING_TEST_PUBLIC_KEY:?}"
	exit 0
	;;
*)
	[[ "${AIDEVOPS_SIGNING_TEST_LOAD_FAIL:-0}" == 0 ]] || exit 1
	if [[ "${AIDEVOPS_SIGNING_TEST_SKIP_LOAD:-0}" == 0 ]]; then
		: >"${AIDEVOPS_SIGNING_TEST_CALL_LOG}.loaded"
	fi
	exit 0
	;;
esac
EOF
chmod 700 "${FAKE_BIN}/git" "${FAKE_BIN}/ssh-add"

export AIDEVOPS_SIGNING_TEST_CALL_LOG="$CALL_LOG"
export AIDEVOPS_SIGNING_TEST_GIT_CALL_LOG="$GIT_CALL_LOG"
export AIDEVOPS_SIGNING_TEST_SOCKET="${TEST_ROOT}/agent.sock"
export AIDEVOPS_SIGNING_TEST_PUBLIC_KEY="$PUBLIC_KEY"

check_output=$(HOME="$TEST_HOME" PATH="${FAKE_BIN}:$PATH" \
	"${SCRIPT_DIR}/signing-setup.sh" check)
if [[ "$check_output" != *"[OK] Key is loaded in ssh-agent"* ]] || \
	[[ "$check_output" != *"[OK] Passphrase-less signing key exists:"* ]] || \
	[[ "$check_output" != *"Default Git signing key is separate from the headless worker key"* ]] || \
	[[ "$check_output" == *"Key not loaded in ssh-agent"* ]]; then
	printf 'FAIL check did not source agent.env and match the loaded public key\n%s\n' "$check_output"
	exit 1
fi

: >"$GIT_CALL_LOG"
headless_output=$(HOME="$TEST_HOME" PATH="${FAKE_BIN}:$PATH" \
	"${SCRIPT_DIR}/signing-setup.sh" headless-setup)
if [[ "$headless_output" != *"Preserved default interactive Git signing key"* ]] || \
	[[ "$headless_output" != *"process-scoped Git config"* ]]; then
	printf 'FAIL headless setup did not report separated key roles\n%s\n' "$headless_output"
	exit 1
fi
if grep -qF "config --global user.signingkey ${TEST_HOME}/.ssh/id_ed25519_signing.pub" "$GIT_CALL_LOG"; then
	printf 'FAIL headless setup replaced the global interactive signing key\n'
	exit 1
fi

: >"$CALL_LOG"
agent_output=$(HOME="$TEST_HOME" PATH="${FAKE_BIN}:$PATH" \
	"${SCRIPT_DIR}/signing-setup.sh" agent-start)
if [[ "$agent_output" != *"Signing key already loaded in ssh-agent"* ]]; then
	printf 'FAIL agent-start did not recognize the loaded signing key\n%s\n' "$agent_output"
	exit 1
fi
if grep -qF "${TEST_HOME}/.ssh/id_ed25519_signing" "$CALL_LOG"; then
	printf 'FAIL agent-start redundantly loaded an existing signing key\n'
	exit 1
fi

blocked_output=$(AIDEVOPS_SIGNING_TEST_GIT_EXIT=42 HOME="$TEST_HOME" PATH="${FAKE_BIN}:$PATH" \
	"${SCRIPT_DIR}/signing-setup.sh" check)
if [[ "$blocked_output" == *"not set"* ]] || \
	[[ "$blocked_output" == *"Run: aidevops signing setup"* ]] || \
	[[ "$blocked_output" != *"unreadable (git config exit 42)"* ]]; then
	printf 'FAIL blocked config reads were reported as unset\n%s\n' "$blocked_output"
	exit 1
fi

unset_output=$(AIDEVOPS_SIGNING_TEST_GIT_EXIT=1 HOME="$TEST_HOME" PATH="${FAKE_BIN}:$PATH" \
	"${SCRIPT_DIR}/signing-setup.sh" check)
if [[ "$unset_output" != *"gpg.format:      not set"* ]] || \
	[[ "$unset_output" != *"Run: aidevops signing setup"* ]]; then
	printf 'FAIL genuinely unset config was not reported as unset\n%s\n' "$unset_output"
	exit 1
fi

load_output=$(AIDEVOPS_SIGNING_TEST_NOT_LOADED=1 HOME="$TEST_HOME" PATH="${FAKE_BIN}:$PATH" \
	"${SCRIPT_DIR}/signing-setup.sh" agent-start)
if [[ "$load_output" != *"[OK] Loaded signing key into ssh-agent:"* ]]; then
	printf 'FAIL agent-start did not confirm a successful key load\n%s\n' "$load_output"
	exit 1
fi
rm "${CALL_LOG}.loaded"

if unconfirmed_output=$(AIDEVOPS_SIGNING_TEST_NOT_LOADED=1 AIDEVOPS_SIGNING_TEST_SKIP_LOAD=1 \
	HOME="$TEST_HOME" PATH="${FAKE_BIN}:$PATH" "${SCRIPT_DIR}/signing-setup.sh" agent-start); then
	printf 'FAIL agent-start accepted ssh-add success without the expected public key\n'
	exit 1
fi
if [[ "$unconfirmed_output" != *"[ERROR] Headless signing key is not present"* ]] || \
	[[ "$unconfirmed_output" == *"[OK] Loaded"* ]]; then
	printf 'FAIL agent-start did not diagnose an unconfirmed load\n%s\n' "$unconfirmed_output"
	exit 1
fi

mv "${TEST_HOME}/.ssh/id_ed25519_signing" "${TEST_ROOT}/unencrypted"
mv "${TEST_HOME}/.ssh/id_ed25519_signing.pub" "${TEST_ROOT}/unencrypted.pub"
ssh-keygen -t ed25519 -N 'x' -C aidevops-headless-signing -q -f "${TEST_HOME}/.ssh/id_ed25519_signing"
encrypted_output=$(HOME="$TEST_HOME" PATH="${FAKE_BIN}:$PATH" "${SCRIPT_DIR}/signing-setup.sh" check)
if [[ "$encrypted_output" != *"[WARN] Headless signing key is encrypted or unreadable:"* ]] || \
	[[ "$encrypted_output" != *"aidevops signing headless-setup"* ]] || \
	[[ "$encrypted_output" != *"ssh-add \"${TEST_HOME}/.ssh/id_ed25519_signing\""* ]] || \
	[[ "$encrypted_output" == *"[OK] Passphrase-less"* ]]; then
	printf 'FAIL check did not diagnose the encrypted headless key\n%s\n' "$encrypted_output"
	exit 1
fi
if failed_output=$(AIDEVOPS_SIGNING_TEST_NOT_LOADED=1 AIDEVOPS_SIGNING_TEST_LOAD_FAIL=1 \
	HOME="$TEST_HOME" PATH="${FAKE_BIN}:$PATH" "${SCRIPT_DIR}/signing-setup.sh" agent-start); then
	printf 'FAIL agent-start accepted a failed ssh-add\n'
	exit 1
fi
if [[ "$failed_output" != *"[ERROR] Could not load headless signing key"* ]] || \
	[[ "$failed_output" != *"aidevops signing headless-setup"* ]] || \
	[[ "$failed_output" != *"ssh-add \"${TEST_HOME}/.ssh/id_ed25519_signing\""* ]] || \
	[[ "$failed_output" == *"[OK] Loaded"* ]]; then
	printf 'FAIL agent-start did not explain ssh-add failure and remediation\n%s\n' "$failed_output"
	exit 1
fi

# Exercise real ssh-add against an isolated agent. A sentinel identity keeps the
# existing agent reusable even before the target key has been loaded.
ssh-keygen -t ed25519 -N '' -q -f "${TEST_ROOT}/sentinel"
ssh-agent bash -s -- "$TEST_HOME" "$SCRIPT_DIR" "$TEST_ROOT" <<'EOF'
set -euo pipefail
export HOME="$1"
script_dir="$2"
test_root="$3"
export SSH_ASKPASS_REQUIRE=force SSH_ASKPASS=/bin/false
ssh-add "${test_root}/sentinel" >/dev/null 2>&1
printf 'export SSH_AUTH_SOCK=%q\nexport SSH_AGENT_PID=%q\n' \
	"$SSH_AUTH_SOCK" "$SSH_AGENT_PID" >"${HOME}/.ssh/agent.env"
if output=$("${script_dir}/signing-setup.sh" agent-start </dev/null); then
	printf 'FAIL real ssh-add accepted an encrypted key without a passphrase\n'
	exit 1
fi
[[ "$output" == *"[ERROR] Could not load headless signing key"* ]]
[[ "$output" == *"aidevops signing headless-setup"* ]]
[[ "$output" != *"[OK] Loaded"* ]]
mv "${test_root}/unencrypted" "${HOME}/.ssh/id_ed25519_signing"
mv "${test_root}/unencrypted.pub" "${HOME}/.ssh/id_ed25519_signing.pub"
output=$("${script_dir}/signing-setup.sh" agent-start </dev/null)
[[ "$output" == *"[OK] Loaded signing key into ssh-agent:"* ]]
output=$("${script_dir}/signing-setup.sh" agent-start </dev/null)
[[ "$output" == *"Signing key already loaded in ssh-agent"* ]]
printf 'PASS real ssh-agent rejects encrypted keys and loads passphrase-less keys idempotently\n'
EOF

printf 'PASS encrypted keys warn and failed/unconfirmed loads return errors with remediation\n'
printf 'PASS passphrase-less keys pass the probe and confirmed loads report success\n'
printf 'PASS signing check sources persisted agent state and matches public keys\n'
printf 'PASS blocked config reads are unknown, not unset; exit 1 remains unset\n'
printf 'PASS agent-start avoids duplicate key loads\n'
printf 'PASS headless setup preserves the global interactive signing key\n'
