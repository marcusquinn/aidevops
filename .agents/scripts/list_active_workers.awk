# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# list_active_workers.awk — Deduplicate and filter active worker processes.
#
# Extracted from list_active_worker_processes() in worker-lifecycle-common.sh
# to reduce shell nesting depth (GH#17561).
#
# Input: ps axo pid,stat,etime,command output
# Output: one line per logical worker: "pid etime command..."
#
# Deduplication key: issue_number|worktree_dir
# Preference: outer launchers (headless-runtime-helper.sh) over child processes.
{
    is_headless_wrapper = ($0 ~ /(^|[[:space:]\/])headless-runtime-helper\.sh([[:space:]]|$)/ && $0 ~ /(^|[[:space:]])run([[:space:]]|$)/ && $0 ~ /--role[[:space:]]+worker/)
    has_worker_prompt = ($0 ~ /\/full-loop/ || $0 ~ /\/review-issue-pr/)
    has_worker_binary = ($0 ~ /(^|[[:space:]\/])\.?opencode([[:space:]]|$)/ || $0 ~ /(^|[[:space:]\/])headless-runtime-helper\.sh([[:space:]]|$)/)

    if (!(has_worker_prompt || is_headless_wrapper)) next
    if ($0 ~ /(^|[[:space:]])\/pulse([[:space:]]|$)/) next
    if ($0 ~ /Supervisor Pulse/) next
    if (!has_worker_binary) next

    # $2 is the stat column (e.g., S, SN, Ss, Z, Zs, T, TN)
    stat = $2
    # Exclude zombies (Z*) and stopped processes (T*)
    if (stat ~ /^[ZT]/) next

    # Build output line: pid, etime, command (skip stat)
    line = $1 " " $3
    for (i = 4; i <= NF; i++) line = line " " $i

    # Extract issue number for dedup (matches "Issue #NNN" or "issue-NNN")
    issue = ""
    if (match($0, /[Ii]ssue[[:space:]]*#([0-9]+)/) || match($0, /issue-([0-9]+)/)) {
        rest = substr($0, RSTART, RLENGTH)
        gsub(/[^0-9]/, "", rest)
        issue = rest
    }
    # Fallback: extract from --session-key issue-NNN when no Issue #/issue- marker
    if (issue == "" && match($0, /--session-key[[:space:]]+issue-([0-9]+)/)) {
        rest = substr($0, RSTART, RLENGTH)
        gsub(/[^0-9]/, "", rest)
        issue = rest
    }

    # Extract --dir path for dedup key (same issue in different repos
    # = different logical workers)
    dir = ""
    if (match($0, /--dir[[:space:]]+[^[:space:]]+/)) {
        dir = substr($0, RSTART, RLENGTH)
        sub(/--dir[[:space:]]+/, "", dir)
    }
    dedup_key = issue "|" dir

    # Prefer outer launchers over child processes for same issue+dir.
    launcher_rank = 0
    if ($0 ~ /(^|[[:space:]\/])headless-runtime-helper\.sh([[:space:]]|$)/ && $0 ~ /--role[[:space:]]+worker/) {
        launcher_rank = 2
    } else if ($0 ~ /sandbox-exec-helper\.sh/) {
        launcher_rank = 1
    }

    if (issue != "" && dedup_key in seen) {
        # Already have a line for this issue+dir — prefer outer launcher
        if (launcher_rank > seen_launcher_rank[dedup_key]) {
            seen_lines[dedup_key] = line
            seen_launcher_rank[dedup_key] = launcher_rank
        }
        # Otherwise skip (lower-rank child of existing launcher, or duplicate)
    } else if (issue != "") {
        seen[dedup_key] = 1
        seen_lines[dedup_key] = line
        seen_launcher_rank[dedup_key] = launcher_rank
        key_order[++key_count] = dedup_key
    } else {
        # No issue number found — print directly (edge case)
        no_issue_lines[++no_issue_count] = line
    }
}
END {
    for (i = 1; i <= key_count; i++) {
        print seen_lines[key_order[i]]
    }
    for (i = 1; i <= no_issue_count; i++) {
        print no_issue_lines[i]
    }
}
