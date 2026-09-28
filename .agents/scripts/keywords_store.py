#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Append-only observation history, spend ledger, rollup and SQLite index."""

from __future__ import annotations

import datetime as _dt
import os
import sqlite3
from collections import defaultdict
from pathlib import Path

import keywords_hub as hub
import keywords_registry as reg
import keywords_toon as toon

OBS_FIELDS = ["observed_at", "target_id", "query_id", "phrase", "platform", "surface", "locale", "device",
              "position", "url", "mentioned", "recommended", "cited", "source", "status"]
SPEND_FIELDS = ["at", "provider", "operation", "estimate_usd", "cost_usd", "note"]
PLATFORM_ORDER = ["google", "bing", "github", "npm", "pypi", "youtube"]


def now() -> str:
    return _dt.datetime.now(_dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def write_observations(prop: str, rows: list[dict], source: str) -> Path | None:
    """Write one immutable history shard per run (no merge conflicts)."""
    if not rows:
        return None
    stamp = _dt.datetime.now(_dt.timezone.utc)
    path = (hub.property_dir(prop) / "history" / stamp.strftime("%Y/%m")
            / f"{stamp.strftime('%Y%m%dT%H%M%SZ')}-{source}-{os.getpid()}.toon")
    toon.dump(path, {"schema": "aidevops.keywords.history/v1", "property": prop},
              [("observations", OBS_FIELDS, rows)], {"position"})
    return path


def read_history(prop: str) -> list[dict]:
    rows: list[dict] = []
    for path in sorted((hub.property_dir(prop) / "history").glob("*/*/*.toon")):
        table = toon.load(path)["tables"].get("observations")
        if table:
            rows.extend(table["rows"])
    return sorted(rows, key=lambda row: row.get("observed_at", ""))


def _ledger_path(prop: str, month: str) -> Path:
    return hub.property_dir(prop) / "spend" / f"{month}.toon"


def month_spend(prop: str, month: str | None = None) -> tuple[float, list[dict]]:
    month = month or _dt.date.today().strftime("%Y-%m")
    path = _ledger_path(prop, month)
    if not path.is_file():
        return 0.0, []
    rows = toon.load(path)["tables"].get("spend", {"rows": []})["rows"]
    total = sum(float(row.get("cost_usd") or row.get("estimate_usd") or 0) for row in rows)
    return total, rows


def budget_limit(front: dict) -> float:
    value = front.get("budget_usd_month") or os.environ.get("AIDEVOPS_KEYWORDS_MONTHLY_BUDGET_USD") or "1"
    return float(value)


def check_budget(prop: str, front: dict, estimate: float) -> tuple[bool, str]:
    spent, _rows = month_spend(prop)
    limit = budget_limit(front)
    ok = spent + estimate <= limit + 1e-9
    verdict = "allowed" if ok else "refused"
    return ok, f"{verdict}: spent ${spent:.4f} + estimate ${estimate:.4f} vs budget ${limit:.2f}/month"


def record_spend(prop: str, entry: dict) -> None:
    """Append a ledger row: provider, operation, estimate_usd, cost_usd (None = unknown), note."""
    month = _dt.date.today().strftime("%Y-%m")
    _total, rows = month_spend(prop, month)
    cost = entry.get("cost_usd")
    rows.append({"at": now(), "provider": entry.get("provider", ""), "operation": entry.get("operation", ""),
                 "estimate_usd": f"{float(entry.get('estimate_usd') or 0):.4f}",
                 "cost_usd": "" if cost is None else f"{float(cost):.4f}", "note": entry.get("note", "")})
    toon.dump(_ledger_path(prop, month), {"schema": "aidevops.keywords.spend/v1", "property": prop},
              [("spend", SPEND_FIELDS, rows)], {"estimate_usd", "cost_usd"})


def _latest_by_target(history: list[dict]) -> dict[str, list[dict]]:
    grouped: dict[str, list[dict]] = defaultdict(list)
    for row in history:
        if row.get("target_id") and row.get("position") not in ("", None):
            grouped[row["target_id"]].append(row)
    return grouped


def _platform_rank(row: dict) -> int:
    platform = row.get("platform", "")
    return PLATFORM_ORDER.index(platform) if platform in PLATFORM_ORDER else len(PLATFORM_ORDER)


def _trend(previous: float | None, latest: float) -> str:
    if previous is None:
        return "new"
    if latest <= 0 < previous:
        return "lost"
    if latest == previous:
        return "flat"
    return "up" if 0 < latest < previous or previous <= 0 < latest else "down"


def _target_rollup(rows: list[dict]) -> dict[str, str]:
    platform = min(rows, key=_platform_rank)["platform"]
    series = [row for row in rows if row["platform"] == platform]
    positions = [float(row["position"]) for row in series]
    ranked = [value for value in positions if value > 0]
    previous = positions[-2] if len(positions) > 1 else None
    return {"last_position": f"{positions[-1]:g}", "best_position": f"{min(ranked):g}" if ranked else "",
            "trend": _trend(previous, positions[-1]), "last_checked": series[-1]["observed_at"][:10],
            "ranking_url": series[-1].get("url", "")}


def _query_rollup(history: list[dict]) -> dict[str, dict[str, str]]:
    stats: dict[str, list[dict]] = defaultdict(list)
    for row in history:
        if row.get("query_id") and row.get("status") == "complete":
            stats[row["query_id"]].append(row)
    result = {}
    for query_id, rows in stats.items():
        mentions = sum(row.get("mentioned") == "true" for row in rows)
        cites = sum(row.get("cited") == "true" for row in rows)
        result[query_id] = {"mention_rate": f"{mentions / len(rows):.2f}", "citation_rate": f"{cites / len(rows):.2f}",
                            "last_checked": rows[-1]["observed_at"][:10]}
    return result


def rollup(prop: str, registry: dict) -> int:
    """Update rollup columns on registry rows from history; returns rows changed."""
    history = read_history(prop)
    changed = 0
    for target_id, rows in _latest_by_target(history).items():
        row = reg.find(registry["targets"], target_id)
        if row is not None:
            row.update({key: value for key, value in _target_rollup(rows).items() if value or key != "ranking_url"})
            changed += 1
    for query_id, values in _query_rollup(history).items():
        row = reg.find(registry["queries"], query_id)
        if row is not None:
            row.update(values)
            changed += 1
    return changed


def _striking(row: dict) -> bool:
    try:
        return 4 <= float(row.get("last_position") or 0) <= 20
    except ValueError:
        return False


def summary(prop: str, registry: dict, front: dict) -> dict:
    """Striking-distance targets, movers and spend for one property."""
    targets = [row for row in registry["targets"] if row.get("status") != "retired"]
    movers = [row for row in targets if row.get("trend") in {"up", "down", "lost"}]
    spent, _rows = month_spend(prop)
    return {"property": prop, "targets": len(targets), "queries": len(registry["queries"]),
            "striking_distance": [f"{row['id']} {row['phrase']} #{row['last_position']}"
                                  for row in filter(_striking, targets)],
            "movers": [f"{row['id']} {row['phrase']} {row['trend']} #{row['last_position']}" for row in movers],
            "spent_usd_this_month": round(spent, 4), "budget_usd": budget_limit(front)}


def _load_property(pdir: Path) -> dict[str, list[dict]]:
    tables = {name: reg.load_table(pdir / "keywords" / f"{name}.toon", name) for name in reg.TABLES}
    tables["observations"] = read_history(pdir.name)
    tables["spend"] = [row for path in sorted((pdir / "spend").glob("*.toon"))
                       for row in toon.load(path)["tables"].get("spend", {"rows": []})["rows"]]
    return tables


def _columns(name: str) -> list[str]:
    fields = {"observations": OBS_FIELDS, "spend": SPEND_FIELDS}.get(name)
    return fields or reg.TABLES[name]["fields"]


INDEX_TABLES = list(reg.TABLES) + ["observations", "spend"]


def _create_tables(connection: sqlite3.Connection) -> None:
    for name in INDEX_TABLES:
        columns = ", ".join(f'"{column}" TEXT' for column in ["property"] + _columns(name))
        connection.execute(f'DROP TABLE IF EXISTS "{name}"')
        connection.execute(f'CREATE TABLE "{name}" ({columns})')


def _property_dirs() -> list[Path]:
    return sorted(path for path in hub.data_root().glob("*") if path.is_dir() and not path.name.startswith("."))


def _insert(connection: sqlite3.Connection, prop: str, name: str, rows: list[dict]) -> None:
    if name not in INDEX_TABLES:
        raise ValueError(f"unknown index table: {name}")
    fields = _columns(name)
    marks = ", ".join("?" for _ in range(len(fields) + 1))
    # Table name is checked against the fixed INDEX_TABLES list; values are bound parameters.
    statement = f'INSERT INTO "{name}" VALUES ({marks})'  # nosec B608
    connection.executemany(statement, [[prop] + [row.get(field, "") for field in fields] for row in rows])


def build_index(db_path: Path | None = None) -> dict[str, int]:
    """Rebuild the derived SQLite index from every property in the data root."""
    db_path = Path(db_path or hub.store_dir() / "index.db")
    db_path.parent.mkdir(parents=True, exist_ok=True)
    counts = dict.fromkeys(INDEX_TABLES, 0)
    with sqlite3.connect(db_path) as connection:
        _create_tables(connection)
        for pdir in _property_dirs():
            for name, rows in _load_property(pdir).items():
                _insert(connection, pdir.name, name, rows)
                counts[name] += len(rows)
    return counts
