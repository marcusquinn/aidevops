#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
"""Text rendering for autonomy_report.py results."""


def display(value, percent=False):
    if value is None:
        return "n/a"
    return f"{value:.1%}" if percent else str(value)


def print_text(result):
    print("Weekly autonomy outcomes (completed UTC weeks)")
    print("Week | Scope | Worker | Interactive | All | Interactive share (<15%) | Worker waste (<5%)")
    for row in result["rows"]:
        print(" | ".join([row["week_start"], row["scope"], str(row["worker"]),
                          str(row["interactive"]), str(row["all"]),
                          display(row["interactive_share"], True), display(row["worker_waste"], True)]))
    print("\nLatest-week lead times (hours; worker issue→merge p90 target <24h)")
    print("Scope | Origin | PR sample | Issue n | Issue p50/p90 | PR p50/p90")
    for row in result["lead_times"]:
        issue, pr = row["issue_created_to_merged"], row["pr_opened_to_merged"]
        print(f'{row["scope"]} | {row["origin"]} | {row["sample_size"]} | {issue["n"]} | '
              f'{display(issue["p50_hours"])}/{display(issue["p90_hours"])} | '
              f'{display(pr["p50_hours"])}/{display(pr["p90_hours"])}')
    print("\nQueue health now")
    print("Scope | Available | Idle 7d (pulse on/off/unregistered) | Blocked | Stale 14d | Hold PRs | Maintainer review")
    for row in result["queue"]:
        split = row["available_idle_7d_by_pulse"]
        print(f'{row["scope"]} | {row["available"]} | {row["available_idle_7d"]} '
              f'({split["on"]}/{split["off"]}/{split["not_registered"]}) | {row["blocked"]} | '
              f'{row["blocked_stale_14d"]} | {row["hold_for_review"]} | {row["needs_maintainer_review"]}')
    print("\nTargets: " + "; ".join(f"{key}={value}" for key, value in result["targets"].items()))
    for note in result["notes"]:
        print("Note: " + note)
