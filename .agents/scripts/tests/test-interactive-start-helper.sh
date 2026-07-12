#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

set -uo pipefail

scripts_dir="$(cd "$(dirname "$0")/.." && pwd)"
helper="${scripts_dir}/interactive-start-helper.sh"
full_loop_helper="${scripts_dir}/full-loop-helper.sh"
test_root=$(mktemp -d)
trap 'rm -rf "$test_root"' EXIT
stub_dir="${test_root}/bin"
call_log="${test_root}/calls"
mkdir -p "$stub_dir"
: >"$call_log"
export CALL_LOG="$call_log"

headless_out=$(AIDEVOPS_INTERACTIVE_ISSUE_IMPLEMENTATION=1 \
	"$full_loop_helper" start "GH#42 local fix" --headless 2>&1)
headless_rc=$?
if [[ $headless_rc -eq 0 ]] || [[ "$headless_out" != *"cannot enter headless/remote worker routing"* ]]; then
	printf 'FAIL interactive issue marker entered headless routing\n' >&2
	exit 1
fi

for command_name in interactive-session-helper.sh pre-edit-check.sh full-loop-helper.sh; do
	cat >"${stub_dir}/${command_name}" <<'STUB'
#!/usr/bin/env bash
printf '%s marker=%s args=%s\n' "${0##*/}" "${AIDEVOPS_INTERACTIVE_ISSUE_IMPLEMENTATION:-0}" "$*" >>"$CALL_LOG"
exit 0
STUB
	chmod +x "${stub_dir}/${command_name}"
done

PATH="${stub_dir}:$PATH" "$helper" --issue 42 --repo owner/repo --task "local fix" || exit 1

if ! grep -Fq 'interactive-session-helper.sh marker=1 args=claim 42 owner/repo --implementing' "$call_log"; then
	printf 'FAIL ordinary issue start did not claim as local implementation\n' >&2
	exit 1
fi
if ! grep -Fq 'full-loop-helper.sh marker=1 args=start GH#42 local fix --background' "$call_log"; then
	printf 'FAIL local asynchronous loop did not inherit implementation marker\n' >&2
	exit 1
fi

: >"$call_log"
PATH="${stub_dir}:$PATH" "$helper" --issue 43 --repo owner/repo --task "queued fix" --auto-dispatch || exit 1
if ! grep -Fq 'interactive-session-helper.sh marker=1 args=claim 43 owner/repo --implementing' "$call_log"; then
	printf 'FAIL auto-dispatch issue was not taken over locally\n' >&2
	exit 1
fi

printf 'PASS interactive issue starts remain local\n'
exit 0
