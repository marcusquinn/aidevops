#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# GH#32377: explicit child repository ownership must fail before mutation.
set -euo pipefail

scripts_dir="$(cd "${BASH_SOURCE[0]%/*}/.." && pwd)"
fixture_root=$(mktemp -d)
trap 'rm -rf "$fixture_root"' EXIT

# shellcheck source=../task-target-repo-lib.sh
source "$scripts_dir/task-target-repo-lib.sh"
mkdir -p "$fixture_root/coord/todo/tasks" "$fixture_root/site/todo/tasks"
/usr/bin/git -C "$fixture_root/coord" init --quiet
/usr/bin/git -C "$fixture_root/site" init --quiet
/usr/bin/git -C "$fixture_root/coord" remote add origin https://github.com/owner/coord.git
/usr/bin/git -C "$fixture_root/site" remote add origin https://github.com/owner/site.git
printf '%s\n' '- [ ] t1 child task' >"$fixture_root/coord/TODO.md"
printf '%s\n' '- [ ] t1 child task' >"$fixture_root/site/TODO.md"
brief="$fixture_root/coord/todo/tasks/t1-brief.md"
printf '%s\n' '## How' "- **Target repository:** \`owner/site\`" "- **Parent:** \`owner/coord#12\`" >"$brief"

[[ $(task_brief_target_repo "$brief") == owner/site ]]
if task_require_target_repo "$(task_brief_target_repo "$brief")" owner/coord "$brief" 2>/dev/null; then
	printf 'FAIL: coordination repository accepted a site child\n' >&2
	exit 1
fi
task_require_target_repo "$(task_brief_target_repo "$brief")" owner/site "$brief"
if "$scripts_dir/claim-task-id.sh" --title child --repo-path "$fixture_root/coord" --brief-file "$brief" --dry-run >/dev/null 2>&1; then
	printf 'FAIL: claim accepted mismatched brief before allocation\n' >&2
	exit 1
fi
if "$scripts_dir/claim-task-id.sh" --title child --repo-path "$fixture_root/coord" --target-repo owner/site --dry-run >/dev/null 2>&1; then
	printf 'FAIL: claim accepted mismatched explicit target\n' >&2
	exit 1
fi
[[ ! -e "$fixture_root/coord/.task-counter" ]]

# Source the orchestrator for the publication preflight without invoking gh.
# shellcheck source=../issue-sync-helper.sh
source "$scripts_dir/issue-sync-helper.sh"
if _push_validate_targets owner/coord "$fixture_root/coord" t1 2>/dev/null; then
	printf 'FAIL: push accepted mismatched child\n' >&2
	exit 1
fi
_push_validate_targets owner/site "$fixture_root/coord" t1
cp "$brief" "$fixture_root/site/todo/tasks/t1-brief.md"
_push_validate_targets owner/site "$fixture_root/site" t1
printf '%s\n' '## How' "- **Parent:** \`owner/coord#12\`" >"$fixture_root/site/todo/tasks/t1-brief.md"
_push_validate_targets owner/site "$fixture_root/site" t1
printf '%s\n' '## How' "- **Target repository:** \`owner/site\`" "- **Target repository:** \`owner/coord\`" >"$fixture_root/site/todo/tasks/t1-brief.md"
if _push_validate_targets owner/site "$fixture_root/site" t1 2>/dev/null; then
	printf 'FAIL: duplicate targets accepted\n' >&2
	exit 1
fi
printf '%s' "- **Target repository:** \`owner/coord\`" >"$fixture_root/site/todo/tasks/t1-brief.md"
if _push_validate_targets owner/site "$fixture_root/site" t1 2>/dev/null; then
	printf 'FAIL: unterminated final target line bypassed validation\n' >&2
	exit 1
fi
printf 'PASS: declared target rejects wrong allocation and publication, retains parent and absent-metadata compatibility\n'
