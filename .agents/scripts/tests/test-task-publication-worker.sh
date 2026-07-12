#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

set -euo pipefail
# Fixture repositories are disposable; bypass interactive canonical-repo guards.
PATH="$(dirname "$(command -v node)"):/usr/bin:/bin:/usr/sbin:/sbin"
export PATH

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
COORDINATOR="${SCRIPT_DIR}/../task-coordinator.mjs"
WORKER="${SCRIPT_DIR}/../task-publication-worker-helper.sh"
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf "$TEST_ROOT"' EXIT
export AIDEVOPS_TASK_COORDINATOR_DB="${TEST_ROOT}/coordinator.db"

task_id=$(node "$COORDINATOR" allocate --operation-id worker-task | jq -r '.tasks[0].taskId')
fixture_sha="0000000000000000000000000000000000000000"

enqueue() {
	local operation_id="$1"
	local repository_id="$2"
	local repository_path="$3"
	local coalesce_key="${4:-planning}"
	node "$COORDINATOR" publication-intent --operation-id "$operation_id" --task-id "$task_id" \
		--repository-id "$repository_id" --repository-path "$repository_path" --coalesce-key "$coalesce_key" \
		--payload '{"paths":["TODO.md"]}' >/dev/null
	return 0
}

# Same-repository stress has one owner and coalesces an ordered compatible prefix.
for i in $(seq 1 20); do enqueue "same-${i}" repo-one /tmp/repo-one; done
for i in $(seq 1 12); do node "$COORDINATOR" lease-next --owner-id "owner-${i}" --lease-seconds 30 --max-active 4 >"${TEST_ROOT}/lease-${i}.json" & done
wait
[[ "$(jq -s '[.[] | select(.leased)] | length' "${TEST_ROOT}"/lease-*.json)" == "1" ]]
lease=$(jq -c 'select(.leased)' "${TEST_ROOT}"/lease-*.json)
[[ "$(jq '.batch | length' <<<"$lease")" == "20" ]]
[[ "$(jq -r '[.batch[].sequence] == ([.batch[].sequence] | sort)' <<<"$lease")" == "true" ]]

# Owner death is recoverable only after expiry and receives a higher fence.
old_token=$(jq -r '.fencingToken' <<<"$lease")
sleep 2
sqlite3 "$AIDEVOPS_TASK_COORDINATOR_DB" "UPDATE publication_leases SET expires_at=unixepoch()-1;"
recovered=$(node "$COORDINATOR" lease-next --owner-id recovered --lease-seconds 30 --max-active 4)
new_token=$(jq -r '.fencingToken' <<<"$recovered")
[[ "$new_token" -gt "$old_token" ]]
if node "$COORDINATOR" lease-finish --owner-id "$(jq -r '.ownerId' <<<"$lease")" --repository-id repo-one \
	--fencing-token "$old_token" --status published --evidence '{}' >/dev/null 2>&1; then
	printf 'FAIL stale owner completed a fenced batch\n' >&2
	exit 1
fi
node "$COORDINATOR" lease-finish --owner-id recovered --repository-id repo-one --fencing-token "$new_token" \
	--status published --evidence "{\"commitSha\":\"${fixture_sha}\"}" >/dev/null

# Independent repositories lease concurrently up to the machine cap.
enqueue multi-a repo-a /tmp/repo-a
enqueue multi-b repo-b /tmp/repo-b
enqueue multi-c repo-c /tmp/repo-c
for i in 1 2 3; do node "$COORDINATOR" lease-next --owner-id "multi-${i}" --lease-seconds 30 --max-active 2 >"${TEST_ROOT}/multi-${i}.json" & done
wait
[[ "$(jq -s '[.[] | select(.leased)] | length' "${TEST_ROOT}"/multi-*.json)" == "2" ]]
[[ "$(node "$COORDINATOR" publication-metrics | jq '.activeLeases')" == "2" ]]
for lease_file in "${TEST_ROOT}"/multi-*.json; do
	if [[ "$(jq -r '.leased' "$lease_file")" == "true" ]]; then
		node "$COORDINATOR" lease-finish --owner-id "$(jq -r '.ownerId' "$lease_file")" \
			--repository-id "$(jq -r '.repositoryId' "$lease_file")" --fencing-token "$(jq -r '.fencingToken' "$lease_file")" \
			--status published --evidence "{\"commitSha\":\"${fixture_sha}\"}" >/dev/null
	fi
done
remaining=$(node "$COORDINATOR" lease-next --owner-id remaining-owner --lease-seconds 30 --max-active 4)
node "$COORDINATOR" lease-finish --owner-id remaining-owner --repository-id "$(jq -r '.repositoryId' <<<"$remaining")" \
	--fencing-token "$(jq -r '.fencingToken' <<<"$remaining")" --status published --evidence "{\"commitSha\":\"${fixture_sha}\"}" >/dev/null

# Duplicate intake is idempotent and changed payload conflicts.
before=$(sqlite3 "$AIDEVOPS_TASK_COORDINATOR_DB" 'SELECT COUNT(*) FROM publication_queue;')
node "$COORDINATOR" publication-intent --operation-id multi-c --task-id "$task_id" --repository-id repo-c \
	--repository-path /tmp/repo-c --payload '{"paths":["TODO.md"]}' >/dev/null
[[ "$(sqlite3 "$AIDEVOPS_TASK_COORDINATOR_DB" 'SELECT COUNT(*) FROM publication_queue;')" == "$before" ]]
if node "$COORDINATOR" publication-intent --operation-id multi-c --task-id "$task_id" --repository-id repo-c \
	--repository-path /tmp/repo-c --payload '{"paths":["todo/other.md"]}' >/dev/null 2>&1; then
	printf 'FAIL changed duplicate publication was accepted\n' >&2
	exit 1
fi

# Every behavior-affecting parameter participates in operation idempotency.
for changed in \
	"--repository-id repo-other --repository-path /tmp/repo-c" \
	"--repository-id repo-c --repository-path /tmp/other" \
	"--repository-id repo-c --repository-path /tmp/repo-c --remote upstream" \
	"--repository-id repo-c --repository-path /tmp/repo-c --branch release" \
	"--repository-id repo-c --repository-path /tmp/repo-c --coalesce-key briefs" \
	"--repository-id repo-c --repository-path /tmp/repo-c --max-attempts 6"; do
	# shellcheck disable=SC2086
	if node "$COORDINATOR" publication-intent --operation-id multi-c --task-id "$task_id" $changed \
		--payload '{"paths":["TODO.md"]}' >/dev/null 2>&1; then
		printf 'FAIL behavior parameter omitted from idempotency hash: %s\n' "$changed" >&2
		exit 1
	fi
done

# Retry exhaustion becomes terminal with immutable attempt and terminal evidence.
node "$COORDINATOR" publication-intent --operation-id exhaust --task-id "$task_id" --repository-id repo-exhaust \
	--repository-path /tmp/repo-exhaust --max-attempts 1 --payload '{"paths":["TODO.md"]}' >/dev/null
exhaust=$(node "$COORDINATOR" lease-next --owner-id exhaust-owner --lease-seconds 30 --max-active 4)
node "$COORDINATOR" lease-finish --owner-id exhaust-owner --repository-id repo-exhaust \
	--fencing-token "$(jq -r '.fencingToken' <<<"$exhaust")" --status retryable --retry-after 1 \
	--evidence '{"failure":"bounded"}' >/dev/null
[[ "$(sqlite3 "$AIDEVOPS_TASK_COORDINATOR_DB" "SELECT status FROM publication_intents WHERE operation_id='exhaust';")" == "terminal" ]]
[[ "$(sqlite3 "$AIDEVOPS_TASK_COORDINATOR_DB" "SELECT COUNT(*) FROM terminal_evidence WHERE operation_id='exhaust';")" == "1" ]]

# A delayed retry at the repository head blocks later incompatible work.
enqueue hol-head repo-hol /tmp/repo-hol first
enqueue hol-later repo-hol /tmp/repo-hol second
hol=$(node "$COORDINATOR" lease-next --owner-id hol-owner --lease-seconds 30 --max-active 4)
[[ "$(jq '.batch | length' <<<"$hol")" == "1" ]]
node "$COORDINATOR" lease-finish --owner-id hol-owner --repository-id repo-hol \
	--fencing-token "$(jq -r '.fencingToken' <<<"$hol")" --status retryable --retry-after 60 --evidence '{"failure":"retry"}' >/dev/null
[[ "$(node "$COORDINATOR" lease-next --owner-id hol-bypass --lease-seconds 30 --max-active 4 | jq -r '.leased')" == "false" ]]
sqlite3 "$AIDEVOPS_TASK_COORDINATOR_DB" "UPDATE publication_queue SET available_at=unixepoch()-1 WHERE intent_id=(SELECT intent_id FROM publication_intents WHERE operation_id='hol-head');"
hol=$(node "$COORDINATOR" lease-next --owner-id hol-retry --lease-seconds 30 --max-active 4)
[[ "$(jq -r '.batch[0].payload.paths[0]' <<<"$hol")" == "TODO.md" ]]

# Lease completion is all-or-nothing when any evidence write fails.
sqlite3 "$AIDEVOPS_TASK_COORDINATOR_DB" "CREATE TRIGGER reject_atomic BEFORE INSERT ON publication_attempts BEGIN SELECT RAISE(ABORT,'fixture'); END;"
if node "$COORDINATOR" lease-finish --owner-id hol-retry --repository-id repo-hol \
	--fencing-token "$(jq -r '.fencingToken' <<<"$hol")" --status terminal --evidence '{"failure":"atomic"}' >/dev/null 2>&1; then
	printf 'FAIL atomic completion fixture unexpectedly succeeded\n' >&2
	exit 1
fi
[[ "$(sqlite3 "$AIDEVOPS_TASK_COORDINATOR_DB" "SELECT status FROM publication_intents WHERE operation_id='hol-head';")" == "retryable" ]]
[[ "$(sqlite3 "$AIDEVOPS_TASK_COORDINATOR_DB" "SELECT COUNT(*) FROM publication_leases WHERE repository_id='repo-hol';")" == "1" ]]
sqlite3 "$AIDEVOPS_TASK_COORDINATOR_DB" 'DROP TRIGGER reject_atomic;'
node "$COORDINATOR" lease-finish --owner-id hol-retry --repository-id repo-hol \
	--fencing-token "$(jq -r '.fencingToken' <<<"$hol")" --status terminal --evidence '{"failure":"confirmed"}' >/dev/null
hol_later=$(node "$COORDINATOR" lease-next --owner-id hol-later-owner --lease-seconds 30 --max-active 4)
node "$COORDINATOR" lease-finish --owner-id hol-later-owner --repository-id repo-hol \
	--fencing-token "$(jq -r '.fencingToken' <<<"$hol_later")" --status terminal --evidence '{"failure":"fixture-cleanup"}' >/dev/null

# End-to-end worker publication records the exact pushed commit, and an owner
# made stale immediately before push cannot mutate the remote.
git_root="${TEST_ROOT}/git"
mkdir -p "$git_root"
git init --bare --initial-branch=main "${git_root}/remote.git" >/dev/null 2>&1 || git init --bare "${git_root}/remote.git" >/dev/null 2>&1
git clone "${git_root}/remote.git" "${git_root}/work" >/dev/null 2>&1
printf '# Tasks\n' >"${git_root}/work/TODO.md"
printf 'base\n' >"${git_root}/work/README.md"
git -C "${git_root}/work" add TODO.md README.md
GIT_AUTHOR_NAME=Test GIT_AUTHOR_EMAIL=test@example.invalid GIT_COMMITTER_NAME=Test GIT_COMMITTER_EMAIL=test@example.invalid \
	git -C "${git_root}/work" commit -m seed >/dev/null
git -C "${git_root}/work" push origin main >/dev/null 2>&1
printf '%s\n' '- [ ] t001 worker publication' >>"${git_root}/work/TODO.md"
enqueue git-publish repo-git "${git_root}/work"
AIDEVOPS_PLANNING_VALIDATOR=/usr/bin/true "$WORKER" once
pushed_sha=$(git --git-dir="${git_root}/remote.git" rev-parse main)
recorded_sha=$(sqlite3 "$AIDEVOPS_TASK_COORDINATOR_DB" "SELECT json_extract(evidence_json,'$.commitSha') FROM terminal_evidence WHERE operation_id='git-publish';")
[[ "$recorded_sha" == "$pushed_sha" ]]

printf '%s\n' '- [ ] t002 stale publication' >>"${git_root}/work/TODO.md"
enqueue git-stale repo-git "${git_root}/work"
before_stale=$(git --git-dir="${git_root}/remote.git" rev-parse main)
stale_hook="${TEST_ROOT}/expire-lease.sh"
cat >"$stale_hook" <<'HOOK'
#!/usr/bin/env bash
sqlite3 "$AIDEVOPS_TASK_COORDINATOR_DB" "UPDATE publication_leases SET expires_at=unixepoch()-1 WHERE repository_id='repo-git';"
exit 0
HOOK
chmod +x "$stale_hook"
if AIDEVOPS_PLANNING_VALIDATOR=/usr/bin/true AIDEVOPS_PLANNING_BEFORE_PUSH_HOOK="$stale_hook" "$WORKER" once >/dev/null 2>&1; then
	printf 'FAIL stale publication worker reported success\n' >&2
	exit 1
fi
[[ "$(git --git-dir="${git_root}/remote.git" rev-parse main)" == "$before_stale" ]]
[[ "$(sqlite3 "$AIDEVOPS_TASK_COORDINATOR_DB" "SELECT status FROM publication_intents WHERE operation_id='git-stale';")" == "retryable" ]]
fence_ref=$(git --git-dir="${git_root}/remote.git" for-each-ref --format='%(refname)' refs/aidevops/publication-fences)
[[ -n "$fence_ref" ]]
stale_fence=$(git --git-dir="${git_root}/remote.git" rev-parse "$fence_ref")
AIDEVOPS_PLANNING_VALIDATOR=/usr/bin/true "$WORKER" once
after_recovery=$(git --git-dir="${git_root}/remote.git" rev-parse main)
[[ "$after_recovery" != "$before_stale" ]]
[[ "$(sqlite3 "$AIDEVOPS_TASK_COORDINATOR_DB" "SELECT json_extract(evidence_json,'$.commitSha') FROM terminal_evidence WHERE operation_id='git-stale';")" == "$after_recovery" ]]
recovered_fence=$(git --git-dir="${git_root}/remote.git" rev-parse "$fence_ref")
[[ "$recovered_fence" != "$stale_fence" ]]

# A resumed stale owner cannot atomically move the target after takeover, even
# when its target CAS expectation is current: the stale remote fence rejects all refs.
recovered_tree=$(git -C "${git_root}/work" rev-parse "${after_recovery}^{tree}")
stale_candidate=$(printf 'stale resumed candidate\n' |
	GIT_AUTHOR_NAME=Stale GIT_AUTHOR_EMAIL=stale@example.invalid GIT_COMMITTER_NAME=Stale GIT_COMMITTER_EMAIL=stale@example.invalid \
		git -C "${git_root}/work" commit-tree "$recovered_tree" -p "$after_recovery")
if git -C "${git_root}/work" push --atomic \
	--force-with-lease="refs/heads/main:${after_recovery}" --force-with-lease="${fence_ref}:${stale_fence}" \
	origin "${stale_candidate}:refs/heads/main" "${stale_fence}:${fence_ref}" >/dev/null 2>&1; then
	printf 'FAIL stale remote fence mutated target after takeover\n' >&2
	exit 1
fi
[[ "$(git --git-dir="${git_root}/remote.git" rev-parse main)" == "$after_recovery" ]]
[[ "$(git --git-dir="${git_root}/remote.git" rev-parse "$fence_ref")" == "$recovered_fence" ]]

# Active initialization lock ownership is never stolen based on age alone.
mkdir "${AIDEVOPS_TASK_COORDINATOR_DB}.init-lock"
printf '{"ownerToken":"active-test","pid":%s}\n' "$$" >"${AIDEVOPS_TASK_COORDINATOR_DB}.init-lock/owner.json"
if AIDEVOPS_COORDINATOR_INIT_LOCK_TIMEOUT_MS=100 node "$COORDINATOR" status >/dev/null 2>&1; then
	printf 'FAIL active initialization lock was bypassed\n' >&2
	exit 1
fi
[[ -d "${AIDEVOPS_TASK_COORDINATOR_DB}.init-lock" ]]
rm -rf "${AIDEVOPS_TASK_COORDINATOR_DB}.init-lock"
mkdir "${AIDEVOPS_TASK_COORDINATOR_DB}.init-lock"
printf '{"ownerToken":"dead-test","pid":99999999}\n' >"${AIDEVOPS_TASK_COORDINATOR_DB}.init-lock/owner.json"
AIDEVOPS_COORDINATOR_INIT_LOCK_TIMEOUT_MS=500 node "$COORDINATOR" status >/dev/null
[[ ! -d "${AIDEVOPS_TASK_COORDINATOR_DB}.init-lock" ]]
mkdir "${AIDEVOPS_TASK_COORDINATOR_DB}.init-lock"
AIDEVOPS_COORDINATOR_INIT_LOCK_ORPHAN_GRACE_MS=0 node "$COORDINATOR" status >/dev/null
[[ ! -d "${AIDEVOPS_TASK_COORDINATOR_DB}.init-lock" ]]
mkdir "${AIDEVOPS_TASK_COORDINATOR_DB}.init-lock"
printf 'not-json\n' >"${AIDEVOPS_TASK_COORDINATOR_DB}.init-lock/owner.json"
AIDEVOPS_COORDINATOR_INIT_LOCK_ORPHAN_GRACE_MS=0 node "$COORDINATOR" status >/dev/null
[[ ! -d "${AIDEVOPS_TASK_COORDINATOR_DB}.init-lock" ]]

# Fan-out reports any child failure rather than only the final wait status.
enqueue child-failure repo-child-failure "${TEST_ROOT}/missing-repository"
if AIDEVOPS_PUBLICATION_MAX_CONCURRENCY=3 "$WORKER" run >/dev/null 2>&1; then
	printf 'FAIL worker run ignored a failed child\n' >&2
	exit 1
fi

node "$COORDINATOR" verify | jq -e '.ok == true' >/dev/null
bash -n "$WORKER"
printf 'PASS publication lease stress, coalescing, fencing, persistence, concurrency, and idempotency\n'
