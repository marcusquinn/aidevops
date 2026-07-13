#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)" || exit 1
REPO_DIR="$(cd "${SCRIPT_DIR}/../../.." && pwd)" || exit 1
SHIM="${REPO_DIR}/.agents/scripts/gh"
TMP=$(mktemp -d 2>/dev/null || mktemp -d -t gh-shim-native-resolution)
trap 'rm -rf "$TMP"' EXIT

PASS=0
FAIL=0

pass() {
	local message="$1"
	printf 'PASS: %s\n' "$message"
	PASS=$((PASS + 1))
	return 0
}

fail() {
	local message="$1"
	printf 'FAIL: %s\n' "$message" >&2
	FAIL=$((FAIL + 1))
	return 0
}

mkdir -p \
	"$TMP/runtime-bundles/old/agents/scripts" \
	"$TMP/home/.aidevops/agents/scripts" \
	"$TMP/repo/.agents/scripts" \
	"$TMP/home/.aidevops/bin" \
	"$TMP/native-linux" \
	"$TMP/native-homebrew"

for shim_path in \
	"$TMP/runtime-bundles/old/agents/scripts/gh" \
	"$TMP/home/.aidevops/agents/scripts/gh" \
	"$TMP/repo/.agents/scripts/gh"; do
	cp "$SHIM" "$shim_path"
	chmod +x "$shim_path"
done
ln -s "$TMP/home/.aidevops/agents/scripts/gh" "$TMP/home/.aidevops/bin/gh"

cat >"$TMP/native-linux/gh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$@" >>"$NATIVE_GH_LOG"
exit 0
EOF
chmod +x "$TMP/native-linux/gh"
cp "$TMP/native-linux/gh" "$TMP/native-homebrew/gh"

run_case() {
	local name="$1"
	local entry="$2"
	local command_one="$3"
	local command_two="${4:-}"
	local expected_one="$command_one"
	local count=0
	: >"$TMP/native.log"
	if NATIVE_GH_LOG="$TMP/native.log" PATH="$TMP/runtime-bundles/old/agents/scripts:$TMP/home/.aidevops/agents/scripts:$TMP/repo/.agents/scripts:$TMP/home/.aidevops/bin:$TMP/native-linux:/usr/bin:/bin" \
		"$entry" "$command_one" ${command_two:+"$command_two"}; then
		count=$(wc -l <"$TMP/native.log" | tr -d ' ')
		if [[ $count -ge 1 ]] && [[ "$(sed -n '1p' "$TMP/native.log")" == "$expected_one" ]]; then
			pass "$name reaches native gh without selecting another shim"
		else
			fail "$name expected native invocation, log=$(tr '\n' ';' <"$TMP/native.log")"
		fi
	else
		fail "$name returned non-zero"
	fi
	return 0
}

run_case "runtime-bundle ordinary passthrough" "$TMP/runtime-bundles/old/agents/scripts/gh" "--version"
run_case "installed ordinary passthrough" "$TMP/home/.aidevops/agents/scripts/gh" "--version"
run_case "repository intercepted command" "$TMP/repo/.agents/scripts/gh" "issue" "view"

: >"$TMP/native.log"
if NATIVE_GH_LOG="$TMP/native.log" AIDEVOPS_GH_SHIM_DISABLE=1 \
	PATH="$TMP/runtime-bundles/old/agents/scripts:$TMP/home/.aidevops/agents/scripts:$TMP/repo/.agents/scripts:$TMP/home/.aidevops/bin:$TMP/native-linux:/usr/bin:/bin" \
	"$TMP/runtime-bundles/old/agents/scripts/gh" --version; then
	if [[ $(wc -l <"$TMP/native.log" | tr -d ' ') -eq 1 ]]; then
		pass "bypass reaches native gh exactly once"
	else
		fail "bypass did not invoke native gh exactly once"
	fi
else
	fail "bypass returned non-zero"
fi

: >"$TMP/native.log"
if NATIVE_GH_LOG="$TMP/native.log" PATH="$TMP/runtime-bundles/old/agents/scripts:$TMP/native-homebrew:/usr/bin:/bin" \
	"$TMP/runtime-bundles/old/agents/scripts/gh" --version && [[ -s "$TMP/native.log" ]]; then
	pass "Homebrew-style native fixture resolves after managed shim"
else
	fail "Homebrew-style native fixture was not resolved"
fi

: >"$TMP/native.log"
workers=0
while [[ $workers -lt 8 ]]; do
	NATIVE_GH_LOG="$TMP/native.log" PATH="$TMP/runtime-bundles/old/agents/scripts:$TMP/home/.aidevops/agents/scripts:$TMP/native-linux:/usr/bin:/bin" \
		"$TMP/runtime-bundles/old/agents/scripts/gh" --version &
	workers=$((workers + 1))
done
wait
if [[ $(wc -l <"$TMP/native.log" | tr -d ' ') -eq 8 ]]; then
	pass "concurrent hot-deployment fixture has one native exec per invocation"
else
	fail "concurrent fixture produced an unexpected native invocation count"
fi

printf 'Results: %s passed, %s failed\n' "$PASS" "$FAIL"
[[ $FAIL -eq 0 ]] || exit 1
exit 0
