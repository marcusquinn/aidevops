#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
# Real SSH keys and isolated Git config; GitHub reads are stubbed, never writes.
set -euo pipefail
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ROOT=$(mktemp -d)
trap 'rm -rf "$ROOT"' EXIT
git init -q "$ROOT/repo"
ssh-keygen -q -t ed25519 -N '' -f "$ROOT/key"
ssh-keygen -q -t ed25519 -N '' -f "$ROOT/other"
git -C "$ROOT/repo" config gpg.format ssh
git -C "$ROOT/repo" config user.signingkey "$ROOT/key"
KEY_JSON='[[]]'
API_FAIL=0
PUBLIC_ONLY=0
gh() {
	# Tokens without a key-read scope can still read the same login's public keys.
	if [[ "$PUBLIC_ONLY" -eq 1 ]]; then
		case "$*" in
		'api user --jq .login') printf 'operator\n' ;;
		'api --paginate --slurp users/operator/ssh_signing_keys' | 'api --paginate --slurp users/operator/gpg_keys') printf '%s\n' "$KEY_JSON" ;;
		'api --paginate --slurp user/ssh_signing_keys' | 'api --paginate --slurp user/gpg_keys')
			# Real gh (GH#34762) exits 1 but still writes the slurped error body
			# to stdout; concatenated with fallback pages it broke `.[][] | .key`.
			printf '[{"message":"Not Found","status":"404"}]\n'
			return 1
			;;
		*) return 1 ;;
		esac
		return 0
	fi
	[[ "$*" == 'api --paginate --slurp user/ssh_signing_keys' || "$*" == 'api --paginate --slurp user/gpg_keys' ]] || return 1
	[[ "$API_FAIL" -eq 0 ]] || return 1
	printf '%s\n' "$KEY_JSON"
	return 0
}
source "$SCRIPT_DIR/release-signing-helper.sh"
if release_signing_preflight "$ROOT/repo" 2>"$ROOT/err"; then
	printf 'FAIL unregistered SSH key accepted\n'
	exit 1
fi
grep -q 'not an authentication key' "$ROOT/err"
KEY_JSON=$(jq -nc --arg key "$(<"$ROOT/other.pub")" '[[{key:$key}]]')
if release_signing_preflight "$ROOT/repo" 2>/dev/null; then
	printf 'FAIL different registered key accepted\n'
	exit 1
fi
KEY_JSON=$(jq -nc --arg key "$(<"$ROOT/key.pub")" '[[],[{key:$key}]]')
release_signing_preflight "$ROOT/repo"
git -C "$ROOT/repo" config user.signingkey ../key
release_signing_preflight "$ROOT/repo"
git -C "$ROOT/repo" config user.signingkey "key::$(<"$ROOT/key.pub")"
release_signing_preflight "$ROOT/repo"
API_FAIL=1
if release_signing_preflight "$ROOT/repo" 2>/dev/null; then
	printf 'FAIL unavailable signing-key API accepted\n'
	exit 1
fi
API_FAIL=0
PUBLIC_ONLY=1
release_signing_preflight "$ROOT/repo" 2>"$ROOT/err"
if [[ -s "$ROOT/err" ]]; then
	printf 'FAIL successful public SSH fallback emitted diagnostics\n'
	exit 1
fi
KEY_JSON=$(jq -nc --arg key "$(<"$ROOT/other.pub")" '[[{key:$key}]]')
if release_signing_preflight "$ROOT/repo" 2>/dev/null; then
	printf 'FAIL public-listing fallback accepted a different key\n'
	exit 1
fi
PUBLIC_ONLY=0
KEY_JSON='[[]]'
printf 'PASS SSH registration preflight rejects absent/wrong keys and API errors, accepts paginated, inline and public-listing keys\n'

# Execute the production standalone tag path: failure must precede even tag
# inspection, bump verification, tag creation, or output announcing creation.
source "$SCRIPT_DIR/version-manager-release.sh"
REPO_ROOT="$ROOT/repo"
if create_git_tag 1.2.3 >"$ROOT/tag.log" 2>&1; then
	printf 'FAIL standalone tag accepted unregistered signer\n'
	exit 1
fi
[[ -z "$(git -C "$ROOT/repo" tag --list)" ]]
if grep -q 'Creating git tag:' "$ROOT/tag.log"; then
	printf 'FAIL tag creation reached before signer preflight\n'
	exit 1
fi
printf 'PASS unregistered signer stops standalone tagging without creating a ref\n'

# Load the real lane entrypoint in the current safe linked worktree. No lane,
# history or publication operation may run after a failed signing preflight.
source "$SCRIPT_DIR/full-loop-release-helper.sh" help >/dev/null
REPO_ROOT="$ROOT/repo"
history_calls=0
lane_calls=0
_full_loop_release_ensure_full_history() {
	history_calls=$((history_calls + 1))
	return 0
}
_full_loop_release_guard_competing_lane() {
	lane_calls=$((lane_calls + 1))
	return 0
}
if _full_loop_release_start_new test/repo 123 patch incremental '' 2>/dev/null; then
	printf 'FAIL release lane accepted unregistered signer\n'
	exit 1
fi
[[ "$history_calls" -eq 0 && "$lane_calls" -eq 0 ]]
printf 'PASS unregistered signer stops before any release history or lane mutation\n'

# GPG registration matches the actual primary/subkey IDs, not user identity.
gpg() {
	printf 'sec:u:255:22:0123456789ABCDEF:0:0:::::scSC:\nfpr:::::::::0000000000000000000000000123456789ABCDEF:\nssb:u:255:22:FEDCBA9876543210:0:0:::::s:\nfpr:::::::::000000000000000000000000FEDCBA9876543210:\n'
	if [[ "${AMBIGUOUS_SHORT:-0}" -eq 1 ]]; then
		printf 'sec:u:255:22:AAAAAAAA89ABCDEF:0:0:::::scSC:\nfpr:::::::::000000000000000000000000AAAAAAAA89ABCDEF:\n'
	fi
	return 0
}
git -C "$ROOT/repo" config gpg.format openpgp
git -C "$ROOT/repo" config user.signingkey 0123456789ABCDEF
KEY_JSON='[[{"key_id":"0123456789ABCDEF","subkeys":[{"key_id":"FEDCBA9876543210"}]}]]'
release_signing_preflight "$ROOT/repo"
PUBLIC_ONLY=1
release_signing_preflight "$ROOT/repo" 2>"$ROOT/err"
if [[ -s "$ROOT/err" ]]; then
	printf 'FAIL successful public GPG fallback emitted diagnostics\n'
	exit 1
fi
PUBLIC_ONLY=0
KEY_JSON='[[{"key_id":"AAAAAAAAAAAAAAAA","subkeys":[]}]]'
if release_signing_preflight "$ROOT/repo" 2>/dev/null; then
	printf 'FAIL unregistered GPG key accepted\n'
	exit 1
fi
git -C "$ROOT/repo" config user.signingkey '0123456789ABCDEF!'
KEY_JSON='[[{"key_id":"0123456789ABCDEF","subkeys":[]}]]'
release_signing_preflight "$ROOT/repo"
git -C "$ROOT/repo" config user.signingkey '89ABCDEF!'
release_signing_preflight "$ROOT/repo"
AMBIGUOUS_SHORT=1
if release_signing_preflight "$ROOT/repo" 2>/dev/null; then
	printf 'FAIL ambiguous forced OpenPGP short ID accepted\n'
	exit 1
fi
AMBIGUOUS_SHORT=0
git -C "$ROOT/repo" config user.signingkey '000000000000000000000000FEDCBA9876543210!'
KEY_JSON='[[{"key_id":"0123456789ABCDEF","subkeys":[{"key_id":"FEDCBA9876543210"}]}]]'
release_signing_preflight "$ROOT/repo"
git -C "$ROOT/repo" config --unset user.signingkey
if release_signing_preflight "$ROOT/repo" 2>/dev/null; then
	printf 'FAIL implicit OpenPGP signer accepted\n'
	exit 1
fi
git -C "$ROOT/repo" config gpg.format x509
if release_signing_preflight "$ROOT/repo" 2>/dev/null; then
	printf 'FAIL unsupported GitHub signing format accepted\n'
	exit 1
fi
printf 'PASS GPG registration and unsupported-format checks fail closed\n'
