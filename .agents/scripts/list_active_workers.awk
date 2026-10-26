# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# list_active_workers.awk — Deduplicate and filter active worker processes.
#
# Extracted from list_active_worker_processes() in worker-lifecycle-common.sh
# to reduce shell nesting depth (GH#17561).
#
# Input: ps axwwo uid,pid,stat,etime,command output (t2190: `ww` keeps Linux
# procps from truncating the command column to the terminal width when piped,
# which would strip --role worker, /full-loop, --session-key issue-NNN, and
# --dir <path> substrings past position 80 and defeat the patterns below).
# Output: one line per logical worker: "pid etime command..."
#
# Deduplication key: namespaced issue/session identity|worktree_dir
# Preference: outer launchers (headless-runtime-helper.sh) over child processes.
# Watchdog mode adds ppid after pid in the snapshot and validates executable
# prefixes, ancestry and live runtime ownership BEFORE logical deduplication.

function is_launcher(cmd) {
    return cmd ~ /^(([^[:space:]]*\/)?(bash|sh)[[:space:]]+)?([^[:space:]]*\/)?headless-runtime-helper\.sh[[:space:]]+run([[:space:]]|$)/
}

function is_runtime(cmd) {
    return cmd ~ /^(([^[:space:]]*\/)?(node|bun)[[:space:]]+)?([^[:space:]]*\/)?\.?opencode[[:space:]]+run([[:space:]]|$)/ || cmd ~ /^([^[:space:]]*\/)?(claude|Claude)([[:space:]]|$)/
}

# Return true only if the whole known ancestry avoids non-worker launchers.
function safe_ancestry(pid, current, steps) {
    current = pid
    for (steps = 0; steps <= NR; steps++) {
        if (blocked[current]) return 0
        if (!(current in parent)) return 1
        current = parent[current]
    }
    return 0
}

# Every node from a live runtime to the candidate root must be runner-owned.
function has_runtime(root, pid, current, steps) {
    for (pid in runtime) {
        current = pid
        for (steps = 0; steps <= NR; steps++) {
            if (blocked[current]) break
            if (!(current in parent)) break
            if (current == root) return 1
            current = parent[current]
        }
    }
    return 0
}

function remember(key, identity, rank, output) {
    if (identity != "" && key in seen) {
        if (rank > seen_launcher_rank[key]) {
            seen_lines[key] = output
            seen_launcher_rank[key] = rank
        }
    } else if (identity != "") {
        seen[key] = 1
        seen_lines[key] = output
        seen_launcher_rank[key] = rank
        key_order[++key_count] = key
    } else {
        no_issue_lines[++no_issue_count] = output
    }
}

{
    # GH#31934: logical worker inventory is runner-local. Filter on the
    # effective numeric UID before identity/worktree deduplication so a foreign
    # process with the same issue/session cannot suppress an owned process.
    if ($1 != effective_uid) next

    stat_column = watchdog ? 4 : 3
    time_column = stat_column + 1
    cmd = ""
    for (i = time_column + 1; i <= NF; i++) cmd = cmd (cmd == "" ? "" : " ") $i
    stat = $stat_column
    metadata = cmd
    role = ""
    if (watchdog && is_launcher(cmd)) {
        # Launcher prompt arguments are opaque, not identity or role evidence.
        sub(/[[:space:]]+--prompt(-file)?[[:space:]].*$/, "", metadata)
    }
    if (match(metadata, /--role[[:space:]]+[^[:space:]]+/)) {
        role = substr(metadata, RSTART, RLENGTH)
        sub(/^--role[[:space:]]+/, "", role)
    }
    if (watchdog) {
        parent[$2] = $3
        if (is_launcher(cmd) && role != "worker") blocked[$2] = 1
        # Preserve stopped ancestors as exclusions rather than making their
        # still-live children look like unrelated legacy workers.
        if (stat ~ /^[ZT]/) {
            blocked[$2] = 1
            next
        }
        if (is_runtime(cmd)) runtime[$2] = 1
        # Never infer executable ownership from text embedded in a prompt.
        if (!is_launcher(cmd) && !is_runtime(cmd)) next
        if (role != "" && role != "worker") next
    }

    is_headless_wrapper = ($0 ~ /(^|[[:space:]\/])headless-runtime-helper\.sh([[:space:]]|$)/ && $0 ~ /(^|[[:space:]])run([[:space:]]|$)/ && $0 ~ /--role[[:space:]]+worker/)
    if (watchdog) is_headless_wrapper = is_launcher(cmd) && role == "worker"
    has_worker_prompt = ($0 ~ /\/full-loop/ || $0 ~ /\/review-issue-pr/)
    has_worker_binary = ($0 ~ /(^|[[:space:]\/])(\.?opencode|claude|Claude)([[:space:]]|$)/ || $0 ~ /(^|[[:space:]\/])headless-runtime-helper\.sh([[:space:]]|$)/)

    if (!(has_worker_prompt || is_headless_wrapper)) next
    if ($0 ~ /(^|[[:space:]])\/pulse([[:space:]]|$)/) next
    if ($0 ~ /Supervisor Pulse/) next
    if (!has_worker_binary) next

    # $3 is the stat column (e.g., S, SN, Ss, Z, Zs, T, TN)
    # Exclude zombies (Z*) and stopped processes (T*)
    if (stat ~ /^[ZT]/) next

    # Build output line: pid, etime, command (skip stat)
    line = $2 " " $time_column " " cmd

    # Extract issue number for dedup (matches "Issue #NNN" or "issue-NNN")
    issue = ""
    if (match(metadata, /[Ii]ssue[[:space:]]*#([0-9]+)/) || match(metadata, /issue-([0-9]+)/)) {
        rest = substr(metadata, RSTART, RLENGTH)
        gsub(/[^0-9]/, "", rest)
        issue = rest
    }
    # Fallback: extract from --session-key issue-NNN when no Issue #/issue- marker
    if (issue == "" && match(metadata, /--session-key[[:space:]]+issue-([0-9]+)/)) {
        rest = substr(metadata, RSTART, RLENGTH)
        gsub(/[^0-9]/, "", rest)
        issue = rest
    }
    if (watchdog && issue == "" && (match(metadata, /GH#[0-9]+/) || match(metadata, /#[0-9]+:/))) {
        issue = substr(metadata, RSTART, RLENGTH)
        gsub(/[^0-9]/, "", issue)
    }
    # Issue workers retain their canonical issue identity even when one process
    # in the chain exposes it only through --session-key.
    worker_identity = ""
    if (issue != "") {
        worker_identity = "issue:" issue
    } else if (match(metadata, /--session-key[[:space:]]+[^[:space:]]+/)) {
        session_key = substr(metadata, RSTART, RLENGTH)
        sub(/--session-key[[:space:]]+/, "", session_key)
        worker_identity = "session:" session_key
    }

    # Extract --dir path for dedup key (same identity in different repos or
    # worktrees = different logical workers).
    dir = ""
    if (match(metadata, /--dir[[:space:]]+[^[:space:]]+/)) {
        dir = substr(metadata, RSTART, RLENGTH)
        sub(/--dir[[:space:]]+/, "", dir)
    }
    if (watchdog) {
        if (issue == "" || dir == "") {
            blocked[$2] = 1
            next
        }
        if (match(metadata, /--session-key[[:space:]]+issue-[0-9]+([[:space:]]|$)/)) {
            session_issue = substr(metadata, RSTART, RLENGTH)
            sub(/^.*issue-/, "", session_issue)
            sub(/[[:space:]]+$/, "", session_issue)
            if (session_issue != issue) {
                blocked[$2] = 1
                next
            }
        }
    }
    dedup_key = worker_identity "|" dir

    # Prefer outer launchers over child processes for the same identity+dir.
    launcher_rank = 0
    if ($0 ~ /(^|[[:space:]\/])headless-runtime-helper\.sh([[:space:]]|$)/ && $0 ~ /--role[[:space:]]+worker/) {
        launcher_rank = 2
    } else if ($0 ~ /sandbox-exec-helper\.sh/) {
        launcher_rank = 1
    }

    if (watchdog) {
        candidate_order[++candidate_count] = $2
        candidate_key[$2] = dedup_key
        candidate_identity[$2] = worker_identity
        candidate_rank[$2] = launcher_rank
        candidate_line[$2] = line
    } else {
        remember(dedup_key, worker_identity, launcher_rank, line)
    }
}
END {
    if (watchdog) {
        for (i = 1; i <= candidate_count; i++) {
            pid = candidate_order[i]
            if (safe_ancestry(pid) && has_runtime(pid)) {
                remember(candidate_key[pid], candidate_identity[pid], candidate_rank[pid], candidate_line[pid])
            }
        }
    }
    for (i = 1; i <= key_count; i++) {
        print seen_lines[key_order[i]]
    }
    for (i = 1; i <= no_issue_count; i++) {
        print no_issue_lines[i]
    }
}
