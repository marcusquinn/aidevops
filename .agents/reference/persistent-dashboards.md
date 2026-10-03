<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Persistent Dashboard Issues

The stats process (`stats-wrapper.sh`) keeps a few issues open on each managed repository as live status surfaces. This file defines what they contain, who reads them, and how they are maintained. The quality bar: every line must be accurate, safe to publish, and useful to a reader who is not the operator.

## Inventory

| Issue | Generator | Labels | Refresh |
|-------|-----------|--------|---------|
| `[Supervisor:<login>] …` / `[Contributor:<login>] …` | `stats-health-dashboard*.sh` | `persistent`, `source:health-dashboard`, `supervisor`\|`contributor`, `operator:<canonical>` | Hourly while active; hourly heartbeat while idle |
| `Code Audit Routines — …` | `stats-quality-sweep*.sh` | `persistent`, `quality-review`, `source:quality-sweep` | Daily sweep (resumable across runs) |

One health dashboard exists per canonical operator per repository. The quality dashboard is one per repository. Supervisor dashboards and the quality dashboard are pinned; GitHub allows at most three pins.

## Audience

On public repositories, assume the reader is a collaborator or a member of the public, not the operator:

- **Title**: the headline. Health: repository-wide open PRs, issues assigned to the operator, local workers, change time. Quality: Qlty grade and smell count, Sonar gate, quality-debt backlog.
- **Body**: current state only, plus a one-line statement that the issue is a status surface, not a task.
- **Comments**: kept to a minimum. The quality sweep edits one rolling findings comment in place. Superseded automation comments are hidden as *outdated* (`_minimize_superseded_dashboard_comments`, bounded per run). Hiding is reversible, so the audit trail stays readable.

## Publication rules (privacy and security)

Dashboards must never publish:

- which provider credentials an operator holds, or how they are stored. Show only `Model access: available|unavailable`;
- raw telemetry records: session, worker, run and attempt IDs, PIDs, models, providers or per-run load. Show only time, issue, outcome and duration;
- host fingerprinting: core counts, free memory, process counts. Show only `Host pressure: CPU <level> · memory <level>`;
- identity aliases or local OS account names. Aliases are dedup metadata only;
- evidence from other repositories. Diagnostics read shared logs, so filter them to the dashboard's own `repo_slug`, because another repository may be private;
- local filesystem paths. `privacy_redact_public_text_from_inventory` sanitizes the health body before every write.

Health dashboards publish only under the GitHub login the scheduler verified for the cycle. They never publish under a `whoami` fallback or `unknown-runner`.

Sections with no data are left out, not rendered as `_… unavailable._` placeholders.

## Lifecycle

- **Never dispatchable.** `persistent`, `supervisor`, `contributor` and `quality-review` block dispatch (`reference/dispatch-blockers.md`). On each refresh, both generators remove task lifecycle labels (`auto-dispatch`, `no-auto-dispatch`, `status:*`, `tier:*`). `needs-maintainer-review` is never removed by this normalization (trust boundary).
- **Dedup.** Health: canonical identity, aliases and `operator:*` labels (`_find_health_issue`, hourly `_periodic_health_issue_dedup`). Quality: label search, then a title-prefix fallback, failing closed on API errors (`_ensure_quality_issue`). The `Code Audit Routines` title prefix is invariant.
- **Staleness.** Each operator's `dashboard-freshness-check.sh` alerts on its own stale dashboard after 48h. A supervisor closes other operators' dashboards whose `last_refresh:` marker is older than `HEALTH_STALE_DASHBOARD_SECONDS` (default 14 days, minimum 7) via `_archive_stale_operator_dashboards`. Before closing, it strips `persistent` so the issue-sync reopen workflow does not revive the issue. If the operator's stats process runs again, it recreates a fresh dashboard.

## Changing a dashboard

1. Edit the renderer: `_build_health_issue_body` / `_gather_worker_zero_diagnostics`, or `_build_quality_issue_body` / `_build_quality_issue_title`.
2. Keep the `| Open PRs | N |`, `| Assigned Issues | N |` and `| Active Workers | N |` rows and the `last_refresh:` marker byte-stable. Title refresh and freshness checks parse them.
3. Transport multi-line fields NUL-delimited. Newline-delimited transport shifted later fields (GH#32730).
4. Verify with `tests/test-stats-worker-zero-diagnostics.sh`, `tests/test-health-dashboard-identity-aliases.sh` and `tests/test-stats-quality-sweep-issues.sh`, then check a locally rendered body against the rules above.
