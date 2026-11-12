#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
# GH#36948: execute the async pressure path against isolated real Git trees.
# API, process evidence and physical-removal plumbing are fixture seams; proof,
# deferred-owner expiry, classification, rotation and native Git removal are real.
set -euo pipefail

SCRIPTS="$(cd "$(dirname "$0")/.." && pwd)"
ROOT=$(mktemp -d)
# GH#37500: Git reports physical worktree paths (macOS /var -> /private/var);
# path-keyed fixture seams such as the grace-period stub must match them.
ROOT=$(cd "$ROOT" && pwd -P)
trap 'rm -rf "$ROOT"' EXIT
trap 'cat "$ROOT/home/.aidevops/logs/cleanup_worktrees.log" >&2' ERR
export HOME="$ROOT/home" FIXTURE_ROOT="$ROOT" REAL_SCRIPTS="$SCRIPTS"
mkdir -p "$HOME/.config/aidevops" "$ROOT/scripts" "$ROOT/repo"
git -C "$ROOT/repo" init -q -b main
git -C "$ROOT/repo" -c user.name=Fixture -c user.email=fixture@example.invalid commit -qm initial --allow-empty
git -C "$ROOT/repo" update-ref refs/remotes/origin/main HEAD
for branch in contained squash dirty open live unproven hidden-open unknown fresh reused; do
	git -C "$ROOT/repo" worktree add -qb "$branch" "$ROOT/$branch"
done
printf 'preserve\n' >"$ROOT/dirty/wip"
git -C "$ROOT/squash" -c user.name=Fixture -c user.email=fixture@example.invalid commit -qm squash --allow-empty
git -C "$ROOT/unproven" -c user.name=Fixture -c user.email=fixture@example.invalid commit -qm unproven --allow-empty
git -C "$ROOT/reused" -c user.name=Fixture -c user.email=fixture@example.invalid commit -qm reused --allow-empty
printf '{"owner":{"pid":%s,"session":"fixture"},"aged":true}\n' "$$" >"$ROOT/squash.receipt"
printf '{"owner":{"pid":%s,"session":"fixture"},"aged":false}\n' "$$" >"$ROOT/live.receipt"
jq -n --arg path "$ROOT/repo" '{initialized_repos:[{path:$path}]}' >"$HOME/.config/aidevops/repos.json"
cp "$SCRIPTS/cleanup-worktrees-async-helper.sh" "$SCRIPTS/cleanup-worktrees-lock.sh" "$ROOT/scripts/"
cat >"$ROOT/scripts/shared-constants.sh" <<'STUB'
timeout_sec() {
	local seconds="$1"
	shift
	[[ "$seconds" -gt 0 ]] || return 1
	"$@"
	return $?
}
STUB
cat >"$ROOT/scripts/pulse-cleanup.sh" <<'STUB'
cleanup_worktrees() {
	CLEANUP_WORKTREES_REMOVED_COUNT=0
	return 0
}
STUB
cat >"$ROOT/scripts/worktree-helper.sh" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$REAL_SCRIPTS"
RED= GREEN= YELLOW= BLUE= BOLD= NC=
_WTAR_SKIPPED=skipped _WTAR_WH_CALLER=fixture
source "$REAL_SCRIPTS/worktree-clean-lib.sh"
log_worktree_removal_event() { return 0; }
_clean_preflight_main_worktree() { printf '%s\n' "$FIXTURE_ROOT/repo"; return 0; }
full_loop_reconcile_cleanup_receipts() { return 0; }
get_default_branch() { printf 'main\n'; return 0; }
_clean_fetch_remotes() { printf 'false\n'; return 0; }
_clean_build_merged_pr_branches() { printf 'squash\nreused\n'; return 0; }
_clean_build_exact_merged_pr_branches() { return 0; }
_clean_build_open_pr_branches() { printf 'open\n'; return 0; }
_clean_build_closed_pr_branches() { printf 'unexpected closed-PR query\n' >&2; return 1; }
_clean_repo_slug() { printf 'fixture/recovery\n'; return 0; }
gh_pr_list() {
	local head="${4:-}" state="${6:-}"
	if [[ "$state" == merged ]]; then
		if [[ "$head" == reused ]]; then git rev-parse origin/main; else git rev-parse "refs/heads/$head"; fi
		return 0
	fi
	case "$head" in
	unknown) return 1 ;;
	hidden-open | hold-*) printf '1\n' ;;
	*) printf '0\n' ;;
	esac
	return 0
}
_branch_has_active_interactive_claim() { return 1; }
is_worktree_owned_by_others() { return 1; }
worktree_is_in_grace_period() {
	local path="$1"
	[[ "$path" == "$FIXTURE_ROOT/fresh" ]] || return 1
	return 0
}
worktree_has_changes() {
	local path="$1" status=""
	status=$(git -C "$path" status --porcelain) || return 0
	[[ -n "$status" ]] || return 1
	return 0
}
full_loop_cleanup_receipt_for_worktree() {
	local path="$1"
	[[ ! -f "$path.receipt" ]] || printf '%s\n' "$path.receipt"
	return 0
}
full_loop_cleanup_owner_alive() { return 0; }
full_loop_cleanup_owner_lease_aged() {
	local receipt="$1"
	jq -e '.aged' "$receipt" >/dev/null || return 1
	return 0
}
unregister_worktree_if_owner_contract() { printf 'EXPIRED\n' >>"$FIXTURE_ROOT/expiry"; return 0; }
_clean_acquire_removal_lease() { return 0; }
_clean_remove_candidate_after_lease() {
	local path="$1"
	git worktree remove "$path" || return 1
	return 0
}
shift
cmd_clean "$@"
STUB
chmod +x "$ROOT/scripts/worktree-helper.sh"

extract_gate_function() {
	local name="$1"
	awk -v name="$name" '$0 ~ "^" name "\\(\\) \\{" {capture=1} capture {print} capture && /^}$/ {exit}' "$SCRIPTS/pulse-dispatch-core.sh"
	return 0
}
# shellcheck source=../disk-capacity-lib.sh
source "$SCRIPTS/disk-capacity-lib.sh"
eval "$(extract_gate_function _dispatch_registered_worktree_count)"
eval "$(extract_gate_function _dispatch_worktree_capacity_gate)"
_dispatch_launch_pressure_cleanup() { return 0; }
LOGFILE="$ROOT/gate.log"
_PULSE_DISPATCH_UNSIGNED_INTEGER_PATTERN='^[0-9]+$'
if _dispatch_worktree_capacity_gate "$ROOT/repo" 36948 fixture/recovery 10; then exit 1; fi

# Launch from outside the repo so the managed-repository inventory is exercised.
(
	cd "$ROOT"
	env AIDEVOPS_MAX_WORKTREES=10 CLEANUP_WORKTREES_ASYNC_CADENCE_MIN=0 \
		bash "$ROOT/scripts/cleanup-worktrees-async-helper.sh"
)
[[ ! -d "$ROOT/contained" && ! -d "$ROOT/squash" ]]
[[ -f "$ROOT/dirty/wip" && -d "$ROOT/open" && -d "$ROOT/live" && -d "$ROOT/unproven" ]]
[[ -s "$ROOT/expiry" ]]
count=$(git -C "$ROOT/repo" worktree list --porcelain | rg -c '^worktree ')
[[ "$count" -eq 9 ]]
_dispatch_worktree_capacity_gate "$ROOT/repo" 36948 fixture/recovery 10
[[ -d "$ROOT/hidden-open" && -d "$ROOT/unknown" && -d "$ROOT/fresh" && -d "$ROOT/reused" ]]
if rg -q 'unexpected closed-PR query' "$HOME/.aidevops/logs/cleanup_worktrees.log"; then exit 1; fi
printf 'PASS async pass reclaims contained and merged/expired trees; dirty/open/live/unproven preserved\n'
printf 'PASS dispatch gate reopens; exact open-PR, unavailable proof and fresh pre-work remain protected\n'

# With no safe trees left, pressure must be observable and dispatch stay closed.
(
	cd "$ROOT"
	env AIDEVOPS_MAX_WORKTREES=9 bash "$ROOT/scripts/cleanup-worktrees-async-helper.sh"
)
if _dispatch_worktree_capacity_gate "$ROOT/repo" 36948 fixture/recovery 9; then exit 1; fi
rg -q 'capacity-stuck: gate closed, zero safe removals' "$HOME/.aidevops/logs/cleanup_worktrees.log"
printf 'PASS closed gate with zero safe candidates produces capacity-stuck diagnostic\n'

# Twenty guarded early candidates must not starve a safe later candidate.
rm -f "$ROOT/repo/.git/aidevops-capacity-clean.cursor"
for ((i = 0; i < 21; i++)); do
	git -C "$ROOT/repo" worktree add -qb "hold-$i" "$ROOT/hold-$i"
done
git -C "$ROOT/repo" worktree add -qb zz-reclaim "$ROOT/zz-reclaim"
(
	cd "$ROOT"
	env AIDEVOPS_MAX_WORKTREES=8 bash "$ROOT/scripts/cleanup-worktrees-async-helper.sh"
)
[[ -d "$ROOT/zz-reclaim" ]]
(
	cd "$ROOT"
	env AIDEVOPS_MAX_WORKTREES=8 bash "$ROOT/scripts/cleanup-worktrees-async-helper.sh"
)
[[ ! -d "$ROOT/zz-reclaim" && -d "$ROOT/hold-20" ]]
printf 'PASS candidate limit and rotating cursor prevent protected-prefix starvation\n'

if (cd "$ROOT/repo" && bash "$ROOT/scripts/worktree-helper.sh" clean --auto --capacity --force-merged); then exit 1; fi
[[ -f "$ROOT/dirty/wip" ]]
printf 'PASS capacity mode refuses force-merged\n'
