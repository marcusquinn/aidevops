"""Aggregate normalized session and observability intervals."""

from __future__ import annotations

from session_time_common import DAY_MS, classify, duration, union


def population_with_observability(sessions, obs_rows):
    population = {row["session_id"]: row for row in sessions}
    for session_id, obs in obs_rows.items():
        if session_id in population:
            continue
        population[session_id] = {
            "session_id": session_id,
            "title": "observability-only headless session",
            "directory": obs["directory"],
            "human": [],
            "machine": [],
            "first": min(left for left, _ in obs["intervals"]),
            "last": max(right for _, right in obs["intervals"]),
        }
    return population


def empty_totals():
    return {
        "human": {"interactive": [], "worker": []},
        "machine": {"interactive": 0, "worker": 0},
        "counts": {"interactive": 0, "worker": 0},
        "first": [],
        "last": [],
    }


def accumulate_row(totals, row, obs_rows, since, now):
    session_id = row["session_id"]
    human = union(row.get("human", []), since, now)
    machine_source = row.get("machine", []) + obs_rows.get(session_id, {}).get("intervals", [])
    machine = union(machine_source, since, now)
    if not human and not machine and row.get("last", 0) < since:
        return
    session_type = classify(row.get("title", ""), row.get("directory", ""))
    totals["counts"][session_type] += 1
    totals["human"][session_type].extend(human)
    totals["machine"][session_type] += sum(right - left for left, right in machine)
    totals["first"].append(max(since, row.get("first", since)))
    totals["last"].append(min(now, row.get("last", now)))


def observed_days(totals):
    if not totals["first"] or not totals["last"]:
        return 0
    elapsed = max(0, max(totals["last"]) - min(totals["first"]))
    return round(elapsed / DAY_MS, 1)


def hours(milliseconds):
    return round(milliseconds / 3600000, 1)


def totals_payload(totals, obs_rows, since, now, sources_ok):
    interactive_human = duration(totals["human"]["interactive"], since, now)
    worker_human = duration(totals["human"]["worker"], since, now)
    total_human = duration(totals["human"]["interactive"] + totals["human"]["worker"], since, now)
    interactive_machine = totals["machine"]["interactive"]
    worker_machine = totals["machine"]["worker"]
    return {
        "interactive_sessions": totals["counts"]["interactive"],
        "interactive_human_hours": hours(interactive_human),
        "interactive_machine_hours": hours(interactive_machine),
        "worker_sessions": totals["counts"]["worker"],
        "worker_human_hours": hours(worker_human),
        "worker_machine_hours": hours(worker_machine),
        "total_human_hours": hours(total_human),
        "total_machine_hours": hours(interactive_machine + worker_machine),
        "total_sessions": totals["counts"]["interactive"] + totals["counts"]["worker"],
        "observed_days": observed_days(totals),
        "status": "ok" if sources_ok else "unavailable",
        "provenance": "session-message-intervals+observability-request-intervals" if obs_rows else "session-message-intervals",
        "human_attention_semantics": "unioned wall-clock intervals",
        "machine_work_semantics": "additive per-session generation intervals",
    }


def aggregate(sessions, obs_rows, since, now, sources_ok):
    population = population_with_observability(sessions, obs_rows)
    totals = empty_totals()
    for row in population.values():
        accumulate_row(totals, row, obs_rows, since, now)
    return totals_payload(totals, obs_rows, since, now, sources_ok)
