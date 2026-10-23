#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
# Fixture test: orphaned in_progress job inside a completed run (GH#35538).
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="${HERE}/../pulse-stale-queued-runs.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "${TMP}/bin" "${TMP}/home/.config/aidevops"
export HOME="${TMP}/home"
export GH_LOG="${TMP}/gh.log"
export RUN_CONC='"success"'
printf '{"initialized_repos":[{"slug":"o/r","pulse":true}]}' >"${HOME}/.config/aidevops/repos.json"

cat >"${TMP}/bin/gh" <<'EOF'
#!/usr/bin/env bash
ep="${*: -1}"
printf '%s\n' "$*" >>"$GH_LOG"
case "$ep" in
repos/o/r) echo '{"permissions":{"push":true}}' ;;
repos/o/r/actions/runs\?status=queued*) echo '{"workflow_runs":[]}' ;;
repos/o/r/pulls*) echo '[{"number":7,"head":{"sha":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}}]' ;;
repos/o/r/commits/*/check-runs*) echo '{"check_runs":[{"id":11,"status":"in_progress","conclusion":null,"app":{"slug":"github-actions"},"started_at":"2020-01-01T00:00:00Z"}]}' ;;
repos/o/r/actions/jobs/11) echo '{"status":"in_progress","started_at":"2020-01-01T00:00:00Z","completed_at":null,"run_id":99,"runner_name":"rn"}' ;;
repos/o/r/actions/runs/99/rerun) echo '{}' ;;
repos/o/r/actions/runs/99) printf '{"id":99,"conclusion":%s}' "$RUN_CONC" ;;
repos/o/r/actions/runners*) echo '{"runners":[{"name":"rn","status":"online","busy":false}]}' ;;
*) exit 1 ;;
esac
EOF
chmod +x "${TMP}/bin/gh"
export PATH="${TMP}/bin:${PATH}"

pulse_rest_core_priority_allows_next() {
	return 0
}
export -f pulse_rest_core_priority_allows_next

reruns() {
	grep -c 'POST.*runs/99/rerun' "$GH_LOG" || true
	return 0
}
scan() {
	rm -f "${HOME}/.aidevops/.agent-workspace/pulse/stale-queued-runs/o/r/last-scan"
	bash -c "source '$SCRIPT'; pulse_stale_queued_runs_scan" >/dev/null
	return 0
}
fail() {
	printf 'FAIL: %s\n' "$1" >&2
	return 1
}

RUN_CONC=null scan
[[ "$(reruns)" == 0 ]] || fail "in_progress run must not be rerun"
scan
[[ "$(reruns)" == 1 ]] || fail "completed run with orphan job must rerun once"
scan
[[ "$(reruns)" == 1 ]] || fail "second pass on same run must be a no-op"
printf 'PASS\n'
