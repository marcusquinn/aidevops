#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
# Exercise actual installers and all five setup entrypoints in an isolated HOME.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ROOT=$(mktemp -d)
trap 'rm -rf "$ROOT"' EXIT
export HOME="$ROOT/home"
INSTALL_DIR="$ROOT/source"
mkdir -p "$HOME/.config/aidevops" "$HOME/.aidevops/logs" \
	"$INSTALL_DIR/.agents/scripts/setup" "$INSTALL_DIR/.agents/hooks"
for file in guard-rollout-cache-lib.sh git-hooks-path-lib.sh install-pre-push-guards.sh \
	install-canonical-guard.sh install-task-id-guard.sh repo-verify-config-lib.sh \
	repo-verify-lock.py portable-stat.sh shared-constants.sh pre-commit-hook.sh; do
	cp "$SCRIPT_DIR/$file" "$INSTALL_DIR/.agents/scripts/"
done
cp "$SCRIPT_DIR"/../hooks/*.sh "$INSTALL_DIR/.agents/hooks/"
for guard in privacy complexity repo_verify canonical task_id; do
	cp "$SCRIPT_DIR/setup/_${guard}_guard.sh" "$INSTALL_DIR/.agents/scripts/setup/"
	# shellcheck source=/dev/null
	source "$INSTALL_DIR/.agents/scripts/setup/_${guard}_guard.sh"
done

print_info() {
	local message="$1"
	printf '%s\n' "$message"
	return 0
}
print_warning() {
	local message="$1"
	printf 'WARN: %s\n' "$message" >&2
	return 0
}
print_error() {
	local message="$1"
	printf 'ERROR: %s\n' "$message" >&2
	return 0
}
setup_track_configured() { return 0; }
setup_track_skipped() { return 0; }

repos="$HOME/.config/aidevops/repos.json"
printf '{"initialized_repos":[' >"$repos"
for ((i = 0; i < 100; i++)); do
	repo="$ROOT/repo-$i"
	git init -q "$repo"
	# Include effective relative and absolute hooksPath repositories.
	if ((i % 3 == 0)); then
		git -C "$repo" config core.hooksPath .beads/hooks
	elif ((i % 3 == 1)); then
		git -C "$repo" config core.hooksPath "$repo/custom-hooks"
	fi
	printf '{"features":{"code_quality":true},"verify":{"lint":"true"}}\n' >"$repo/.aidevops.json"
	((i == 0)) || printf ',' >>"$repos"
	printf '{"path":"%s","features":["code-quality"]}' "$repo" >>"$repos"
done
printf ']}\n' >>"$repos"

run_stages() {
	local stage="" start=0 elapsed=0
	for stage in privacy complexity repo_verify canonical task_id; do
		start=$SECONDS
		"setup_${stage}_guard"
		elapsed=$((SECONDS - start))
		printf '%s\tpid=%s\tphase=setup_%s_guard\tstatus=done\telapsed=%ss\n' \
			"$(date -u +%FT%TZ)" "$$" "$stage" "$elapsed" \
			>>"$HOME/.aidevops/logs/setup-stage-timings.log"
	done
	return 0
}

run_stages >"$ROOT/cold.log"
start=$SECONDS
run_stages >"$ROOT/warm.log"
elapsed=$((SECONDS - start))
printf '100-repo warm rollout: %ss total\n' "$elapsed"
while IFS= read -r line; do printf '%s\n' "$line"; done <"$ROOT/warm.log"
[[ "$elapsed" -le 10 ]]
[[ $(grep -c 'current=100$' "$ROOT/warm.log") -eq 5 ]]

# Fingerprints cover installer, sourced resolver and hook source contents.
printf '\n# installer revision\n' >>"$INSTALL_DIR/.agents/scripts/install-pre-push-guards.sh"
setup_privacy_guard >"$ROOT/changed.log"
grep -q 'current=0$' "$ROOT/changed.log"
setup_privacy_guard >"$ROOT/current.log"
grep -q 'current=100$' "$ROOT/current.log"
printf '\n# template revision\n' >>"$INSTALL_DIR/.agents/hooks/privacy-guard-pre-push.sh"
setup_privacy_guard >"$ROOT/template.log"
grep -q 'current=0$' "$ROOT/template.log"
printf '\n# resolver revision\n' >>"$INSTALL_DIR/.agents/scripts/git-hooks-path-lib.sh"
setup_privacy_guard >"$ROOT/resolver.log"
grep -q 'current=0$' "$ROOT/resolver.log"

hook="$ROOT/repo-0/.beads/hooks/pre-push"
rm "$hook"
setup_privacy_guard >"$ROOT/deleted.log"
grep -q 'current=99$' "$ROOT/deleted.log"
printf '\n# modified but still managed\n' >>"$hook"
setup_privacy_guard >"$ROOT/modified.log"
grep -q 'current=99$' "$ROOT/modified.log"
chmod -x "$hook"
setup_privacy_guard >"$ROOT/mode.log"
grep -q 'current=99$' "$ROOT/mode.log"
printf '#!/bin/sh\nexit 0\n' >"$hook"
setup_privacy_guard >"$ROOT/unmanaged.log"
grep -q 'conflict=1 .*current=99$' "$ROOT/unmanaged.log"
[[ $(<"$hook") == $'#!/bin/sh\nexit 0' ]]

# Restore and converge, then ensure changed opt-out and registration are not
# hidden by an otherwise current dispatcher receipt.
rm "$hook"
run_stages >"$ROOT/restored.log"
printf '{"features":{"code_quality":false}}\n' >"$ROOT/repo-0/.aidevops.json"
setup_repo_verify_guard >"$ROOT/disabled.log"
grep -q 'skipped=1 .*current=99$' "$ROOT/disabled.log"
jq '(.initialized_repos[] | select(.path | endswith("repo-1"))).features = []' "$repos" >"$ROOT/repos.json"
mv "$ROOT/repos.json" "$repos"
setup_repo_verify_guard >"$ROOT/registration.log"
grep -q 'registered=1 .*current=98$' "$ROOT/registration.log"

# A failed write must never certify a truncated executable as current.
rm -f "${hook}.aidevops-current"
if (ulimit -f 1; cd "$ROOT/repo-0" && bash "$INSTALL_DIR/.agents/scripts/install-pre-push-guards.sh" install --guard privacy >/dev/null 2>&1); then
	printf 'FAIL: oversized hook write unexpectedly succeeded\n' >&2
	exit 1
fi
[[ ! -f "${hook}.aidevops-current" ]]

printf 'PASS: warm timing, fingerprints, hooksPath, missing/changed/unmanaged hooks and migration invalidation\n'
