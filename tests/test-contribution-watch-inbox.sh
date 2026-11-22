#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# test-contribution-watch-inbox.sh
#
# Fixture check for the contribution-watch inbox (GH#37174): one fresh human
# reply, one bot-only follow-up, one closed thread, one owner-last thread.
# The session-start count is 1 and `status` lists only the fresh reply; after
# `status` shows it the session-start count is 0.
#
# Usage: bash tests/test-contribution-watch-inbox.sh
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HELPER="$REPO_DIR/.agents/scripts/contribution-watch-helper.sh"
UPDATE_CHECK="$REPO_DIR/.agents/scripts/aidevops-update-check.sh"

TMP_HOME="$(mktemp -d)"
trap 'rm -rf "$TMP_HOME"' EXIT
mkdir -p "$TMP_HOME/bin" "$TMP_HOME/.aidevops/cache" "$TMP_HOME/.aidevops/logs"
# shellcheck disable=SC2016
printf '#!/usr/bin/env bash\n[[ "$1 $2" == "api user" ]] && echo owner && exit 0\nexit 1\n' >"$TMP_HOME/bin/gh"
chmod +x "$TMP_HOME/bin/gh"

STATE="$TMP_HOME/.aidevops/cache/contribution-watch.json"
cat >"$STATE" <<'JSON'
{"last_scan":"2026-11-08T03:00:00Z","items":{
 "ext/a#1":{"type":"pr","title":"fresh","role":"author","state":"open","last_our_comment":"2026-11-07T02:00:00Z","last_any_comment":"2026-11-08T02:42:06Z","last_notified":"2026-11-08T02:42:06Z"},
 "ext/b#2":{"type":"pr","title":"bot only","role":"author","state":"open","last_our_comment":"2026-11-06T20:09:30Z","last_any_comment":"2026-11-06T20:09:30Z","last_notified":""},
 "ext/c#3":{"type":"pr","title":"merged","role":"author","state":"closed","closed_at":"2026-11-06T18:00:00Z","last_our_comment":"","last_any_comment":"2026-11-06T17:47:10Z","last_notified":""},
 "ext/d#4":{"type":"issue","title":"owner last","role":"commenter","state":"open","last_our_comment":"2026-11-05T00:00:00Z","last_any_comment":"2026-11-05T00:00:00Z","last_notified":""}
}}
JSON

# Same extraction as the session-start check, via its jq filter.
count() {
	local filter
	# shellcheck disable=SC2016
	filter=$(sed -n '/cw_count=\$(jq/,/cw_state" 2>\/dev\/null)/p' "$UPDATE_CHECK" | sed -e '1d' -e '$d')
	jq -r --arg user owner "$filter" "$STATE"
	return 0
}

fail=0
c1=$(count)
[[ "$c1" == "1" ]] || { echo "FAIL: session-start count before status = $c1 (want 1)"; fail=1; }

out=$(HOME="$TMP_HOME" PATH="$TMP_HOME/bin:$PATH" bash "$HELPER" status)
echo "$out" | rg -q 'ext/a#1' || { echo "FAIL: fresh reply not listed"; fail=1; }
for k in 'ext/b#2' 'ext/c#3' 'ext/d#4'; do
	if echo "$out" | rg -q "$k"; then echo "FAIL: $k should not be listed"; fail=1; fi
done

c2=$(count)
[[ "$c2" == "0" ]] || { echo "FAIL: session-start count after status = $c2 (want 0)"; fail=1; }

if [[ "$fail" -eq 0 ]]; then echo "PASS: contribution-watch inbox fixture"; fi
exit "$fail"
