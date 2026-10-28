#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf "$TEST_ROOT"' EXIT
export TEST_ROOT
export GH_AUDIT_LOG_FILE="$TEST_ROOT/audit.log"
export GH_AUDIT_QUIET=true
export PROTECTED_LABEL_FLAP_STATE_DIR="$TEST_ROOT/locks"
mkdir -p "$TEST_ROOT/framework/.agents/scripts"
cp "$SCRIPT_DIR/protected-label-guard.sh" "$TEST_ROOT/framework/.agents/scripts/"
printf '#!/usr/bin/env bash\nexec bash %q "$@"\n' "$SCRIPT_DIR/gh-audit-log-helper.sh" \
	>"$TEST_ROOT/framework/.agents/scripts/gh-audit-log-helper.sh"
chmod +x "$TEST_ROOT/framework/.agents/scripts/gh-audit-log-helper.sh"
printf '%s\n' 'test-version' >"$TEST_ROOT/framework/VERSION"
# The copied production reporter still runs: replace only its write transport.
cat >"$TEST_ROOT/framework/.agents/scripts/gh-write-helper.sh" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
body=$(cat)
printf '%s\n' "$body" >>"$TEST_ROOT/comment-bodies"
jq --arg body "$body" '. + [{body:$body, author_association:"OWNER",
created_at:(now | strftime("%Y-%m-%dT%H:%M:%SZ"))}]' "$TEST_ROOT/comments" >"$TEST_ROOT/comments.next"
mv "$TEST_ROOT/comments.next" "$TEST_ROOT/comments"
MOCK
chmod +x "$TEST_ROOT/framework/.agents/scripts/gh-write-helper.sh"
# shellcheck source=../protected-label-guard.sh
source "$TEST_ROOT/framework/.agents/scripts/protected-label-guard.sh"

gh() {
	local args="$*"
	case "$args" in
	*'/timeline?'*) [[ "${READ_FAIL:-0}" -eq 0 ]] || return 1; jq -c '.' "$TEST_ROOT/timeline" ;;
	*'/comments?'*) jq -cs '.' "$TEST_ROOT/comments" ;;
	*'/issues/42') jq -c '.' "$TEST_ROOT/live" ;;
	*) printf 'Unexpected gh invocation: %s\n' "$args" >&2; return 1 ;;
	esac
	return 0
}

gh_issue_edit_safe() {
	printf '%s\n' "$*" >>"$TEST_ROOT/edits"
	if [[ "$*" == *'--remove-label needs-maintainer-review'* && "${SIMULATE_PEER_MARKER:-0}" -eq 1 ]]; then
		printf '%s\n' '{"labels":[]}' >"$TEST_ROOT/live"
		jq -n '[{body:"<!-- aidevops:protected-label-flap:needs-maintainer-review:v1 -->",
			author_association:"OWNER", created_at:(now | strftime("%Y-%m-%dT%H:%M:%SZ"))}]' >"$TEST_ROOT/comments"
	fi
	# Only containment adds are expected in held scenarios.
	if [[ "$*" == *'--add-label needs-maintainer-review'* ]]; then
		printf '%s\n' '{"labels":[{"name":"needs-maintainer-review"}]}' >"$TEST_ROOT/live"
	fi
	return 0
}

reset_fixture() {
	printf '%s\n' '[]' >"$TEST_ROOT/comments"
	printf '%s\n' '{"labels":[{"name":"needs-maintainer-review"}]}' >"$TEST_ROOT/live"
	: >"$TEST_ROOT/edits"
	: >"$TEST_ROOT/comment-bodies"
	: >"$GH_AUDIT_LOG_FILE"
	READ_FAIL=0
	SIMULATE_PEER_MARKER=0
	return 0
}

timeline_fixture() {
	local count="$1" age="${2:-0}"
	# Two pages ensure cross-page transitions participate in the count.
	jq -n --argjson count "$count" --argjson age "$age" '
		[range(0;$count) | {id:., event:(if . % 2 == 0 then "labeled" else "unlabeled" end),
		label:{name:"needs-maintainer-review"}, actor:{login:("runner-" + (. % 2 | tostring))},
		created_at:((now - $age - 60 + .) | strftime("%Y-%m-%dT%H:%M:%SZ"))}]
		| [.[0:2], .[2:]]' >"$TEST_ROOT/timeline"
	return 0
}

held() {
	local operation="$1"
	if protected_label_edit 42 example/repo 'association=MEMBER; authority=repo-write' \
		"$operation" needs-maintainer-review --add-label auto-dispatch; then
		printf 'FAIL: flap was not held\n' >&2
		return 1
	fi
	return 0
}

reset_fixture
timeline_fixture 5
held --remove-label
held --add-label
held --remove-label
[[ ! -s "$TEST_ROOT/edits" ]]
[[ "$(jq 'length' "$TEST_ROOT/comments")" -eq 1 ]]
[[ "$(jq -sc '[.[] | select(.suspicious | index("protected_label_flap:needs-maintainer-review"))] | length' "$GH_AUDIT_LOG_FILE")" -eq 1 ]]
grep -q 'runner-0, runner-1' "$TEST_ROOT/comment-bodies"
grep -q 'aidevops test-version; decision: association=MEMBER; authority=repo-write' "$TEST_ROOT/comment-bodies"
printf 'PASS: applied label is held, with one marker and audit anomaly across repeat calls\n'

reset_fixture
timeline_fixture 4
printf '%s\n' '{"labels":[]}' >"$TEST_ROOT/live"
held --remove-label
held --remove-label
[[ "$(wc -l <"$TEST_ROOT/edits")" -eq 1 ]]
grep -q -- '--add-label needs-maintainer-review' "$TEST_ROOT/edits"
if grep -q -- '--remove-label' "$TEST_ROOT/edits"; then exit 1; fi
printf 'PASS: absent protected label is restored once, never removed\n'

reset_fixture
timeline_fixture 3
protected_label_edit 42 example/repo normal --remove-label needs-maintainer-review
[[ -s "$TEST_ROOT/edits" && ! -s "$TEST_ROOT/comment-bodies" ]]
reset_fixture
timeline_fixture 5 22000
protected_label_edit 42 example/repo normal --remove-label needs-maintainer-review
[[ -s "$TEST_ROOT/edits" ]]
printf 'PASS: below-threshold and out-of-window events do not create a hold\n'

reset_fixture
timeline_fixture 5
# Expired cooldown, with all old transitions preceding the marker.
jq -n '[{body:"<!-- aidevops:protected-label-flap:needs-maintainer-review:v1 -->",
author_association:"OWNER",created_at:((now-30) | strftime("%Y-%m-%dT%H:%M:%SZ"))}]' >"$TEST_ROOT/comments"
PROTECTED_LABEL_FLAP_COOLDOWN_SECONDS=1 protected_label_edit 42 example/repo normal --remove-label needs-maintainer-review
[[ -s "$TEST_ROOT/edits" ]]
printf 'PASS: expired cooldown ignores already-reported history\n'

reset_fixture
timeline_fixture 0
READ_FAIL=1
held --remove-label
[[ ! -s "$TEST_ROOT/edits" ]]
protected_label_edit 42 example/repo containment --add-label needs-maintainer-review
[[ -s "$TEST_ROOT/edits" ]]
printf 'PASS: unavailable history blocks removals but permits fail-closed containment\n'

reset_fixture
timeline_fixture 5
# Identical repeated event types are not oscillation.
jq 'map(map(.event = "labeled"))' "$TEST_ROOT/timeline" >"$TEST_ROOT/timeline.next"
mv "$TEST_ROOT/timeline.next" "$TEST_ROOT/timeline"
protected_label_edit 42 example/repo normal --remove-label needs-maintainer-review
[[ -s "$TEST_ROOT/edits" ]]
printf 'PASS: repeated same-direction events are not flaps\n'

reset_fixture
timeline_fixture 5
PROTECTED_LABEL_FLAP_LABELS=another-protected-label protected_label_edit 42 example/repo normal --remove-label needs-maintainer-review
[[ -s "$TEST_ROOT/edits" && ! -s "$TEST_ROOT/comment-bodies" ]]
printf 'PASS: protected label list is configurable\n'

reset_fixture
timeline_fixture 5
held --remove-label &
first_pid=$!
held --remove-label &
second_pid=$!
wait "$first_pid"
wait "$second_pid"
[[ "$(jq 'length' "$TEST_ROOT/comments")" -eq 1 ]]
[[ "$(jq -sc 'length' "$GH_AUDIT_LOG_FILE")" -eq 1 ]]
printf 'PASS: concurrent same-host publishers emit one marker and anomaly\n'

reset_fixture
timeline_fixture 3
SIMULATE_PEER_MARKER=1
held --remove-label
[[ "$(wc -l <"$TEST_ROOT/edits")" -eq 2 ]]
jq -e '.labels | any(.[]; .name == "needs-maintainer-review")' "$TEST_ROOT/live" >/dev/null
printf 'PASS: stale removal is compensated when a peer publishes a cooldown during the write\n'

reset_fixture
timeline_fixture 0
if protected_label_edit 42 example/repo normal --remove-label=needs-maintainer-review; then exit 1; fi
if protected_label_edit 42 example/repo normal --remove-label needs-maintainer-review,other; then exit 1; fi
[[ ! -s "$TEST_ROOT/edits" ]]
printf 'PASS: unsupported argument forms cannot bypass the guard\n'

for setting in PROTECTED_LABEL_FLAP_THRESHOLD PROTECTED_LABEL_FLAP_WINDOW_SECONDS PROTECTED_LABEL_FLAP_COOLDOWN_SECONDS; do
	reset_fixture
	timeline_fixture 0
	export "${setting}=invalid"
	protected_label_edit 42 example/repo containment --add-label needs-maintainer-review 2>"$TEST_ROOT/diagnostic"
	grep -q "invalid ${setting} value" "$TEST_ROOT/diagnostic"
	jq -e '.labels | any(.[]; .name == "needs-maintainer-review")' "$TEST_ROOT/live" >/dev/null
	: >"$TEST_ROOT/edits"
	held --remove-label 2>"$TEST_ROOT/diagnostic"
	grep -q "invalid ${setting} value" "$TEST_ROOT/diagnostic"
	[[ ! -s "$TEST_ROOT/edits" ]]
	unset "$setting"
done
printf 'PASS: each invalid setting names its diagnostic, permits containment and blocks removal\n'
