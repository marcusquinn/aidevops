#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
"""Manual, offline-only journal for paired Jev pilot evaluations."""

import argparse
import contextlib
import hashlib
import json
import os
import re
import stat
import sys
from pathlib import Path

SCHEMA = "aidevops.jev-evaluation/v1"
PILOT_SCHEMA = "aidevops.jev-pilot/v1"
UNKNOWN = None
OUTCOMES = {"accepted", "rejected", "unknown"}
PROVENANCE = {"operator_reviewed", "author_synthetic", "unreviewed"}
METRICS = {"repair_seconds", "end_to_end_seconds", "input_tokens", "total_cost_usd"}


@contextlib.contextmanager
def private_directory():
    if os.name != "posix":
        raise ValueError("Private journal storage requires POSIX directory descriptors")
    root = Path.home() / ".aidevops" / ".agent-workspace" / "work" / "jev-evaluation"
    current = Path(root.anchor)
    for component in root.parts[1:]:
        current /= component
        try:
            current.mkdir(mode=0o700)
        except FileExistsError:
            pass
        metadata = current.lstat()
        if not stat.S_ISDIR(metadata.st_mode) or stat.S_ISLNK(metadata.st_mode):
            raise ValueError("Private journal storage contains a non-directory path")
        if (current / ".git").exists() or (current / ".git").is_symlink():
            raise ValueError("Private journal records cannot be stored in Git")
    directory_fd = os.open(current, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    try:
        os.fchmod(directory_fd, 0o700)
        yield directory_fd, root
    finally:
        os.close(directory_fd)


def opaque(value, field):
    if not isinstance(value, str) or not re.fullmatch(r"[A-Za-z0-9_.-]{1,80}", value):
        raise ValueError(f"{field} must be an opaque identifier")
    return value


def metric(value, field):
    if value is UNKNOWN:
        return UNKNOWN
    if type(value) not in (int, float) or value < 0:
        raise ValueError(f"{field} must be a non-negative number or null (unknown)")
    return value


def load_json(path):
    with Path(path).open("rb") as stream:
        raw = stream.read(65537)
    if len(raw) > 65536:
        raise ValueError("Input exceeds byte budget")
    return json.loads(raw)


def pilot_metadata(path):
    report = load_json(path)
    if not isinstance(report, dict) or report.get("schema") != PILOT_SCHEMA:
        raise ValueError("Selected report is not an aidevops.jev-pilot/v1 report")
    return {
        "corpus_sha256": opaque(report.get("corpus_sha256"), "corpus_sha256"),
        "rubric": opaque(report.get("rubric"), "rubric"),
        "model": opaque(report.get("model"), "model"),
    }


def validate_record(data, report=None):
    allowed = {"task_id", "task_category", "route", "accepted_outcome", "label_provenance",
               "corpus_sha256", "rubric", "model", "metrics", "missing_evidence", "misclassification"}
    if not isinstance(data, dict) or set(data) - allowed:
        raise ValueError("Invalid journal fields")
    required = {"task_id", "task_category", "route", "accepted_outcome", "label_provenance", "metrics"}
    if not required <= set(data):
        raise ValueError("Missing required journal fields")
    record = {key: opaque(data[key], key) for key in ("task_id", "task_category", "route")}
    if data["accepted_outcome"] not in OUTCOMES or data["label_provenance"] not in PROVENANCE:
        raise ValueError("Invalid outcome or label provenance")
    record.update(accepted_outcome=data["accepted_outcome"], label_provenance=data["label_provenance"])
    metrics = data["metrics"]
    if not isinstance(metrics, dict) or set(metrics) - METRICS:
        raise ValueError("Invalid metric fields")
    record["metrics"] = {name: metric(metrics.get(name), name) for name in METRICS}
    for name in ("missing_evidence", "misclassification"):
        if name in data and type(data[name]) is not bool:
            raise ValueError(f"{name} must be boolean")
        record[name] = data.get(name, False)
    metadata = report or {name: data.get(name) for name in ("corpus_sha256", "rubric", "model")}
    record.update({name: opaque(metadata.get(name), name) for name in ("corpus_sha256", "rubric", "model")})
    record.update(schema=SCHEMA, measurement_boundary="operator-observed end-to-end workflow; null means unknown",
                  collection="manual invocation only; no session, repository, or network observation")
    return record


def record_key(record):
    identity = {name: record[name] for name in ("task_id", "task_category", "route", "corpus_sha256", "rubric", "model")}
    return hashlib.sha256(json.dumps(identity, sort_keys=True).encode()).hexdigest()


def save_record(record):
    name = record_key(record) + ".json"
    with private_directory() as (directory_fd, root):
        fd = os.open(name, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600, dir_fd=directory_fd)
        with os.fdopen(fd, "w", encoding="utf-8") as stream:
            json.dump(record, stream, indent=2, sort_keys=True, allow_nan=False)
            stream.write("\n")
    return str(root / name)


def load_record(path):
    record = load_json(path)
    if not isinstance(record, dict) or record.get("schema") != SCHEMA:
        raise ValueError("Selected file is not an aidevops.jev-evaluation/v1 record")
    return validate_record({key: record[key] for key in (
        "task_id", "task_category", "route", "accepted_outcome", "label_provenance", "corpus_sha256",
        "rubric", "model", "metrics", "missing_evidence", "misclassification")})


def compare(baseline, pilot):
    fields = ("task_id", "task_category", "corpus_sha256", "rubric", "model")
    mismatches = [field for field in fields if baseline[field] != pilot[field]]
    reviewed = all(row["label_provenance"] == "operator_reviewed" for row in (baseline, pilot))
    accepted = all(row["accepted_outcome"] != "unknown" for row in (baseline, pilot))
    valid = not mismatches and reviewed and accepted
    deltas = {}
    if valid:
        for name in METRICS:
            left, right = baseline["metrics"][name], pilot["metrics"][name]
            deltas[name] = UNKNOWN if UNKNOWN in (left, right) else right - left
    return {"status": "comparable" if valid else "not_comparable", "mismatched_fields": mismatches,
            "operator_reviewed": reviewed, "accepted_outcomes_known": accepted, "deltas": deltas,
            "conclusion": "no_value_claim; inspect preserved evidence and quality before any live comparison"}


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    subparsers = parser.add_subparsers(dest="command", required=True)
    record_parser = subparsers.add_parser("record", help="Manually record one opaque task outcome")
    record_parser.add_argument("--input", required=True, help="Local JSON with opaque IDs and observations")
    record_parser.add_argument("--pilot-report", help="Explicit local aidevops.jev-pilot/v1 report")
    subparsers.add_parser("status", help="Show private journal record count")
    compare_parser = subparsers.add_parser("compare", help="Compare two explicitly selected records")
    compare_parser.add_argument("--baseline", required=True)
    compare_parser.add_argument("--pilot", required=True)
    args = parser.parse_args(argv)
    try:
        if args.command == "record":
            report = pilot_metadata(args.pilot_report) if args.pilot_report else None
            path = save_record(validate_record(load_json(args.input), report))
            print(json.dumps({"status": "recorded", "private_record": path, "manual_only": True}))
        elif args.command == "status":
            with private_directory() as (directory_fd, _):
                count = len([name for name in os.listdir(directory_fd) if name.endswith(".json")])
            print(json.dumps({"status": "local_only", "records": count, "manual_only": True}))
        else:
            print(json.dumps(compare(load_record(args.baseline), load_record(args.pilot))))
        return 0
    except (OSError, ValueError, TypeError, json.JSONDecodeError):
        print(json.dumps({"status": "blocked", "reason": "invalid_input_or_private_storage"}))
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
