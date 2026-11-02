#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
# Local Git integration coverage; GitHub and helper side effects are isolated.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(mktemp -d)"
trap 'rm -rf "$ROOT"' EXIT
export HOME="$ROOT/home"
export AIDEVOPS_WORKTREE_BASE_DIR="$ROOT/worktrees"
export PR_STATE="$ROOT/prs.json" CALLS="$ROOT/calls"
SCRIPTS="$HOME/.aidevops/agents/scripts"
mkdir -p "$SCRIPTS" "$HOME/.config/aidevops" "$ROOT/bin" "$AIDEVOPS_WORKTREE_BASE_DIR"
export PATH="$ROOT/bin:$PATH"
printf '[]\n' >"$PR_STATE"
touch "$CALLS"
cp "$SCRIPT_DIR/../badges-sync-helper.sh" "$SCRIPT_DIR/../badges-check-helper.sh" \
	"$SCRIPT_DIR/../workflow-release-ref.sh" "$SCRIPT_DIR/../headless-signing-lib.sh" "$SCRIPTS/"
chmod +x "$SCRIPTS/"*.sh

# Production orchestration calls these public helper interfaces. Worktrees and
# commits/pushes below are real; publication is only recorded in local files.
cat >"$SCRIPTS/shared-gh-wrappers.sh" <<'STUB'
gh_create_pr() {
	local head="" opt
	while [[ $# -gt 0 ]]; do
		opt="$1"; shift
		case "$opt" in
		--head) head="$1"; shift ;;
		--body-file) [[ "$1" == '-' ]]; shift; cat >/dev/null ;;
		*) shift ;;
		esac
	done
	jq -n --arg head "$head" '[{headRefName:$head,title:"chore: aidevops badge sync",url:"test-pr"}]' >"$PR_STATE"
	printf 'create\n' >>"$CALLS"
	printf 'test-pr\n'
	return 0
}
STUB
cat >"$ROOT/bin/gh" <<'STUB'
#!/usr/bin/env bash
set -eu
case "$1 $2" in
'api repos/marcusquinn/aidevops/releases/latest') printf 'v3.39.45\n' ;;
'api repos/marcusquinn/aidevops/commits/v3.39.45') printf '%040d\n' 1 ;;
'api repos/'*'/pulls?'*) [[ "${FAIL_QUERY:-0}" != 1 ]]; jq '.[]' "$PR_STATE" ;;
'api repos/'*) printf 'trunk\n' ;;
*) exit 1 ;;
esac
STUB
cat >"$SCRIPTS/worktree-helper.sh" <<'STUB'
#!/usr/bin/env bash
set -eu
case "$1" in
add)
	printf 'add\n' >>"$CALLS"
	[[ "$4" == --base && "$5" == origin/trunk ]]
	# Match the real helper's isolated fresh-base fetch, not a canonical pull.
	git worktree add --detach "${3}-fetch" HEAD
	git -C "${3}-fetch" fetch origin trunk
	git worktree remove "${3}-fetch"
	git worktree add -b "$2" "$3" "$5"
	;;
remove) printf 'remove\n' >>"$CALLS"; git worktree remove "$2" ;;
*) exit 1 ;;
esac
STUB
cat >"$SCRIPTS/readme-badges-helper.sh" <<'STUB'
#!/usr/bin/env bash
set -eu
case "$1" in
starter-owned) grep -q STARTER "$2" ;;
check) grep -q CURRENT "$2" || exit 3 ;;
inject) printf '<!-- aidevops:badges:start -->\nCURRENT\n' >"$2" ;;
*) exit 1 ;;
esac
STUB
cat >"$SCRIPTS/repo-metrics-helper.sh" <<'STUB'
#!/usr/bin/env bash
set -eu
[[ "${FAIL_METRICS:-0}" != 1 ]]
shift
while [[ $# -gt 1 ]]; do
	case "$1" in
	--output-dir) out="$2"; shift 2 ;;
	--badge-dir) badges="$2"; shift 2 ;;
	*) shift ;;
	esac
done
mkdir -p "$out" "$badges"
printf '{}\n' >"$out/repo-metrics.json"
touch "$out/repo-metrics.md" "$badges/loc.svg" "$badges/languages.svg" "$badges/dependencies.svg"
STUB
chmod +x "$ROOT/bin/gh" "$SCRIPTS/"*.sh
mkdir -p "$HOME/.aidevops/agents/templates/workflows"
cp "$SCRIPT_DIR/../../templates/workflows/loc-badge-caller.yml" \
	"$HOME/.aidevops/agents/templates/workflows/loc-badge-caller.yml"

git init -q --bare "$ROOT/remote.git"
git init -q -b trunk "$ROOT/canonical"
CANONICAL="$ROOT/canonical"
git -C "$CANONICAL" config user.name 'Badge Test'
git -C "$CANONICAL" config user.email 'test@example.invalid'
git -C "$CANONICAL" config commit.gpgsign false
printf '<!-- aidevops:badges:start -->\nDRIFTED\n' >"$CANONICAL/README.md"
git -C "$CANONICAL" add README.md
git -C "$CANONICAL" commit -qm initial
git -C "$CANONICAL" remote add origin "$ROOT/remote.git"
git -C "$CANONICAL" push -q -u origin trunk
git -C "$ROOT/remote.git" symbolic-ref HEAD refs/heads/trunk
git -C "$CANONICAL" remote set-head origin trunk
git -C "$CANONICAL" checkout -qb personal-work
printf 'staged\n' >"$CANONICAL/staged.txt"
git -C "$CANONICAL" add staged.txt
printf 'dirty\n' >>"$CANONICAL/README.md"
printf 'untracked\n' >"$CANONICAL/untracked.txt"

register_repo() {
	local slug="$1" extra="${2:-}"
	[[ -n "$extra" ]] || extra='{}'
	jq -n --arg slug "$slug" --arg path "$CANONICAL" --argjson extra "$extra" \
		'{initialized_repos: [({slug:$slug,path:$path,maintenance:true,maintainer:"marcusquinn"} + $extra)]}' >"$HOME/.config/aidevops/repos.json"
	return 0
}

snapshot() {
	git -C "$CANONICAL" symbolic-ref HEAD
	git -C "$CANONICAL" rev-parse HEAD
	git -C "$CANONICAL" status --porcelain=v1
	git -C "$CANONICAL" diff
	git -C "$CANONICAL" diff --cached
	git -C "$CANONICAL" hash-object untracked.txt
	return 0
}

register_repo marcusquinn/test
before="$(snapshot)"
bash "$SCRIPTS/badges-sync-helper.sh" --apply --repo marcusquinn/test --json >"$ROOT/result"
[[ "$(jq -r .outcome "$ROOT/result")" == APPLIED ]]
[[ "$(snapshot)" == "$before" ]]
head="$(jq -r '.[0].headRefName' "$PR_STATE")"
git -C "$CANONICAL" show "$head:README.md" | grep CURRENT >/dev/null
git -C "$CANONICAL" cat-file -e "$head:docs/metrics/repo-metrics.json"
git -C "$CANONICAL" cat-file -e "$head:.github/workflows/loc-badge.yml"
caller="$(git -C "$CANONICAL" show "$head:.github/workflows/loc-badge.yml")"
[[ "$caller" == *'loc-badge-reusable.yml@0000000000000000000000000000000000000001 # v3.39.45'* ]]
[[ "$caller" == *'aidevops_ref: 0000000000000000000000000000000000000001 # v3.39.45'* ]]
[[ "$(git -C "$CANONICAL" worktree list --porcelain | grep -c '^worktree ')" == 1 ]]
printf 'PASS dirty/off-default canonical preserved; README, metrics and workflow published together; worktree removed\n'

bash "$SCRIPTS/badges-sync-helper.sh" --apply --json >"$ROOT/result"
[[ "$(jq -r .outcome "$ROOT/result")" == SKIPPED ]]
[[ "$(grep -c '^create$' "$CALLS")" == 1 ]]
printf 'PASS rerun deduplicates existing sync PR\n'

for extra in '{"local_only":true}' '{"contributed":true}' '{"role":"contributor"}' '{"maintenance":false}'; do
	register_repo marcusquinn/test "$extra"
	bash "$SCRIPTS/badges-sync-helper.sh" --apply --json >"$ROOT/result"
	[[ ! -s "$ROOT/result" ]]
done
register_repo external/test
bash "$SCRIPTS/badges-sync-helper.sh" --apply --json >"$ROOT/result"
[[ ! -s "$ROOT/result" ]]
printf 'PASS weekly selection excludes local-only, contributed, contributor, dormant and external repos\n'

# Apply the generated commit on the *remote*, not the dirty canonical checkout.
git -C "$ROOT/remote.git" update-ref refs/heads/trunk "$(git -C "$CANONICAL" rev-parse "$head")"
printf '[]\n' >"$PR_STATE"
register_repo marcusquinn/test
bash "$SCRIPTS/badges-sync-helper.sh" --apply --json >"$ROOT/result"
[[ "$(jq -r .outcome "$ROOT/result")" == SKIPPED ]]
[[ "$(snapshot)" == "$before" ]]
[[ "$(grep -c '^create$' "$CALLS")" == 1 ]]
printf 'PASS stale dirty detector result revalidated against current remote default; no PR\n'

FAIL_QUERY=1 bash "$SCRIPTS/badges-sync-helper.sh" --apply --json >"$ROOT/result" && exit 1
[[ "$(jq -r .outcome "$ROOT/result")" == FAILED ]]
[[ ! -d "$CANONICAL/.git/aidevops-badges-sync.lock" ]]
[[ "$(snapshot)" == "$before" ]]
printf 'PASS API query failure is not treated as an absent PR; lock released\n'

# Starter-owned is rechecked at the remote worktree, even when local detection
# says DRIFTED. Simulate a concurrent default-branch ownership change.
git clone -q "$ROOT/remote.git" "$ROOT/upstream"
git -C "$ROOT/upstream" config user.name 'Badge Test'
git -C "$ROOT/upstream" config user.email 'test@example.invalid'
git -C "$ROOT/upstream" config commit.gpgsign false
printf '<!-- aidevops:badges:start -->\nSTARTER\n' >"$ROOT/upstream/README.md"
git -C "$ROOT/upstream" commit -qam starter
git -C "$ROOT/upstream" push -q
bash "$SCRIPTS/badges-sync-helper.sh" --apply --json >"$ROOT/result"
[[ "$(jq -r .outcome "$ROOT/result")" == SKIPPED ]]
[[ "$(grep -c '^create$' "$CALLS")" == 1 ]]
[[ "$(snapshot)" == "$before" ]]
printf 'PASS remote starter-owned blocks remain untouched\n'

mkdir "$CANONICAL/.git/aidevops-badges-sync.lock"
bash "$SCRIPTS/badges-sync-helper.sh" --apply --json >"$ROOT/result"
[[ "$(jq -r .outcome "$ROOT/result")" == SKIPPED ]]
rmdir "$CANONICAL/.git/aidevops-badges-sync.lock"
printf 'PASS concurrent repository lock prevents another sync transaction\n'

# A JSON file alone does not prove all metrics assets are current.
printf '<!-- aidevops:badges:start -->\nCURRENT\n' >"$ROOT/upstream/README.md"
git -C "$ROOT/upstream" rm -q docs/metrics/badges/languages.svg
git -C "$ROOT/upstream" commit -qam missing-asset
git -C "$ROOT/upstream" push -q
FAIL_METRICS=1 bash "$SCRIPTS/badges-sync-helper.sh" --apply --json >"$ROOT/result" && exit 1
[[ "$(jq -r .outcome "$ROOT/result")" == FAILED ]]
[[ "$(grep -c '^create$' "$CALLS")" == 1 ]]
[[ "$(git -C "$CANONICAL" worktree list --porcelain | grep -c '^worktree ')" == 2 ]]
[[ "$(snapshot)" == "$before" ]]
printf 'PASS metrics failure retains recoverable worktree without publishing a PR\n'

retained_branch() {
	git -C "$CANONICAL" worktree list --porcelain | sed -n 's#^branch refs/heads/\(chore/badges-sync-.*\)#\1#p'
	return 0
}

# GH#36491: the retained worktree is recovered and published, not skipped.
retained_before="$(retained_branch)"
adds_before="$(grep -c '^add$' "$CALLS")"
bash "$SCRIPTS/badges-sync-helper.sh" --apply --json >"$ROOT/result"
[[ "$(jq -r .outcome "$ROOT/result")" == APPLIED ]]
head="$(jq -r '.[0].headRefName' "$PR_STATE")"
[[ -n "$retained_before" && "$head" == "$retained_before" ]]
[[ "$(grep -c '^add$' "$CALLS")" == "$adds_before" ]]
git -C "$CANONICAL" cat-file -e "$head:docs/metrics/badges/languages.svg"
[[ "$(git -C "$CANONICAL" worktree list --porcelain | grep -c '^worktree ')" == 1 ]]
[[ "$(snapshot)" == "$before" ]]
printf 'PASS retained recovery worktree regenerated and published without allocating another\n'

# A retained worktree holding anything beyond declared outputs is never reset.
printf '[]\n' >"$PR_STATE"
blocked_tree="$AIDEVOPS_WORKTREE_BASE_DIR/blocked-recovery"
git -C "$CANONICAL" worktree add -q -b chore/badges-sync-99999999999999-blocked "$blocked_tree" origin/trunk
printf 'operator note\n' >"$blocked_tree/notes.txt"
adds_before="$(grep -c '^add$' "$CALLS")"
bash "$SCRIPTS/badges-sync-helper.sh" --apply --json >"$ROOT/result" && exit 1
[[ "$(jq -r .outcome "$ROOT/result")" == BLOCKED-RETAINED ]]
[[ "$(jq -r .detail "$ROOT/result")" == *'notes.txt'* ]]
[[ "$(<"$blocked_tree/notes.txt")" == 'operator note' ]]
[[ "$(grep -c '^add$' "$CALLS")" == "$adds_before" ]]
[[ "$(snapshot)" == "$before" ]]
printf 'PASS retained worktree with non-regenerable content is BLOCKED-RETAINED, untouched, and fails the run\n'
# Explicit fixture cleanup of the operator-owned worktree.
git -C "$CANONICAL" worktree remove --force "$blocked_tree"

printf '[]\n' >"$PR_STATE"
git -C "$ROOT/upstream" rm -q README.md .github/workflows/loc-badge.yml
git -C "$ROOT/upstream" commit -qm missing-readme
git -C "$ROOT/upstream" push -q
register_repo marcusquinn/test '{"workflow_reusable_ref":"@main"}'
bash "$SCRIPTS/badges-sync-helper.sh" --apply --workflow-only --json >"$ROOT/result"
[[ "$(jq -r .outcome "$ROOT/result")" == APPLIED ]]
head="$(jq -r '.[0].headRefName' "$PR_STATE")"
git -C "$CANONICAL" cat-file -e "$head:.github/workflows/loc-badge.yml"
caller="$(git -C "$CANONICAL" show "$head:.github/workflows/loc-badge.yml")"
[[ "$caller" == *'loc-badge-reusable.yml@main'* ]]
[[ "$caller" == *'aidevops_ref: main'* ]]
[[ "$(snapshot)" == "$before" ]]
printf 'PASS workflow-only publication tolerates missing remote README\n'

# Reject a real push before it reaches the bare remote, just like readiness gates.
printf '[]\n' >"$PR_STATE"
cat >"$CANONICAL/.git/hooks/pre-push" <<'HOOK'
#!/usr/bin/env bash
printf 'JS_TOOL_READINESS=blocked:snapshot-incomplete-installed-inventory (eslint tsc)\n' >&2
printf 'JS_TOOL_READINESS_HINT=restore approved worktree-local dependencies\n' >&2
exit 1
HOOK
chmod +x "$CANONICAL/.git/hooks/pre-push"
adds_before="$(grep -c '^add$' "$CALLS")"
creates_before="$(grep -c '^create$' "$CALLS")"
bash "$SCRIPTS/badges-sync-helper.sh" --apply --workflow-only --json >"$ROOT/result" && exit 1
[[ "$(jq -r .outcome "$ROOT/result")" == BLOCKED-READINESS ]]
[[ "$(jq -r .detail "$ROOT/result")" == *'JS_TOOL_READINESS_HINT=restore approved worktree-local dependencies'* ]]
[[ "$(git -C "$CANONICAL" worktree list --porcelain | grep -c '^worktree ')" == 2 ]]
first_retained="$(jq -r '.detail | sub(".*retained recovery worktree: "; "")' "$ROOT/result")"
# The retry recovers the same worktree and retries publication; a persistent
# block stays a failure instead of a silent success skip (GH#36491).
bash "$SCRIPTS/badges-sync-helper.sh" --apply --workflow-only --json >"$ROOT/result" && exit 1
[[ "$(jq -r .outcome "$ROOT/result")" == BLOCKED-READINESS ]]
retained="$(jq -r '.detail | sub(".*retained recovery worktree: "; "")' "$ROOT/result")"
[[ -d "$retained" && "$(cd "$retained" && pwd -P)" == "$(cd "$first_retained" && pwd -P)" ]]
[[ "$(git -C "$retained" log -1 --format=%s)" == 'chore: refresh aidevops badges, metrics and workflow' ]]
[[ "$(git -C "$CANONICAL" worktree list --porcelain | grep -c '^worktree ')" == 2 ]]
[[ "$(grep -c '^add$' "$CALLS")" == "$((adds_before + 1))" ]]
[[ "$(grep -c '^create$' "$CALLS")" == "$creates_before" ]]
[[ "$(snapshot)" == "$before" ]]
printf 'PASS readiness push rejection preserves hint, reuses one retained worktree, and keeps failing across retries\n'
rm -f "$CANONICAL/.git/hooks/pre-push"

# GH#36491: an unavailable signer blocks before any worktree work. The global
# interactive key below is unusable without a prompt. The fixture HOME owns the
# global config; the repository-level commit.gpgsign=false is overridden here.
git config --global gpg.format ssh
git config --global user.signingkey "$ROOT/interactive-key.pub"
export GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=commit.gpgsign GIT_CONFIG_VALUE_0=true
retained_head="$(git -C "$retained" rev-parse HEAD)"
adds_before="$(grep -c '^add$' "$CALLS")"
bash "$SCRIPTS/badges-sync-helper.sh" --apply --workflow-only --json >"$ROOT/result" && exit 1
[[ "$(jq -r .outcome "$ROOT/result")" == BLOCKED-SIGNING ]]
[[ "$(jq -r .detail "$ROOT/result")" == *'aidevops signing headless-setup'* ]]
[[ "$(git -C "$retained" rev-parse HEAD)" == "$retained_head" ]]
[[ "$(grep -c '^add$' "$CALLS")" == "$adds_before" ]]
[[ "$(grep -c '^create$' "$CALLS")" == "$creates_before" ]]
printf 'PASS unavailable signing is BLOCKED-SIGNING with no worktree changes\n'

# With the dedicated headless key in a live agent, the commit is signed with
# it even though the global default is still the interactive key.
mkdir -p "$HOME/.ssh"
ssh-keygen -q -t ed25519 -N '' -C aidevops-headless-signing -f "$HOME/.ssh/id_ed25519_signing"
# Unix socket paths are length-limited; keep the agent socket short.
AGENT_DIR="$(mktemp -d /tmp/aidv-bs.XXXXXX)"
trap '[[ -z "${SSH_AGENT_PID:-}" ]] || kill "$SSH_AGENT_PID" 2>/dev/null || true; rm -rf "$ROOT" "$AGENT_DIR"' EXIT
eval "$(ssh-agent -s -a "$AGENT_DIR/agent.sock")" >/dev/null
ssh-add -q "$HOME/.ssh/id_ed25519_signing" 2>/dev/null
bash "$SCRIPTS/badges-sync-helper.sh" --apply --workflow-only --json >"$ROOT/result"
[[ "$(jq -r .outcome "$ROOT/result")" == APPLIED ]]
head="$(jq -r '.[0].headRefName' "$PR_STATE")"
printf 'test@example.invalid %s\n' "$(<"$HOME/.ssh/id_ed25519_signing.pub")" >"$ROOT/allowed-signers"
# Verify on the published remote copy; the canonical fixture stays read-only.
git -C "$ROOT/remote.git" -c gpg.ssh.allowedSignersFile="$ROOT/allowed-signers" verify-commit "$head" 2>/dev/null
[[ "$(git config --global user.signingkey)" == "$ROOT/interactive-key.pub" ]]
[[ "$(git -C "$CANONICAL" worktree list --porcelain | grep -c '^worktree ')" == 1 ]]
[[ "$(grep -c '^add$' "$CALLS")" == "$adds_before" ]]
printf 'PASS retained worktree published with a commit signed by the dedicated headless key\n'
unset GIT_CONFIG_COUNT GIT_CONFIG_KEY_0 GIT_CONFIG_VALUE_0

# Routine wiring uses the same no-filter selector exercised above.
# shellcheck source=../routines/core-routines.sh
source "$SCRIPT_DIR/../routines/core-routines.sh"
get_core_routine_entries | grep -F 'r921|x|README badges — remediate managed repo drift|repeat:weekly(sun@08:10)|~5m|scripts/badges-sync-helper.sh --apply --json|script' >/dev/null
describe_r921 linux | grep 'maintained-repository selector' >/dev/null
printf 'PASS weekly pulse routine is enabled and documented\n'
