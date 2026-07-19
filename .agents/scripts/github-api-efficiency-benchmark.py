#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Compare privacy-safe GitHub API baseline and canary evidence."""

from __future__ import annotations

import argparse
import json
import math
from pathlib import Path
import re
import sys

from github_api_efficiency_inputs import BenchmarkInputError, build_window
from github_api_efficiency_io import AtomicWriteError, atomic_write_text
from github_api_efficiency_report import (
    EXIT_INCONCLUSIVE,
    EXIT_REGRESSION,
    STATUS_OK,
    STATUS_REGRESSION,
    Thresholds,
    build_result,
    render_markdown,
)


_LABEL_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._ -]{0,63}$")


def _atomic_write(path: Path, content: str) -> None:
    try:
        atomic_write_text(path, content)
    except AtomicWriteError as exc:
        raise BenchmarkInputError(str(exc)) from exc


def _parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=("compare",))
    parser.add_argument("--baseline-report", required=True, type=Path)
    parser.add_argument("--baseline-evidence", required=True, type=Path)
    parser.add_argument("--baseline-label", required=True)
    parser.add_argument("--canary-report", required=True, type=Path)
    parser.add_argument("--canary-evidence", required=True, type=Path)
    parser.add_argument("--canary-label", required=True)
    parser.add_argument("--json-out", required=True, type=Path)
    parser.add_argument("--markdown-out", required=True, type=Path)
    parser.add_argument("--max-window-ratio", type=float, default=1.25)
    parser.add_argument("--max-cycle-rate-change-pct", type=float, default=25.0)
    parser.add_argument("--min-attempt-reduction-pct", type=float, default=5.0)
    parser.add_argument("--max-graphql-point-increase-pct", type=float, default=0.0)
    parser.add_argument("--max-error-rate-increase-points", type=float, default=0.0)
    parser.add_argument("--max-latency-increase-pct", type=float, default=20.0)
    parser.add_argument("--max-burst-increase-pct", type=float, default=10.0)
    parser.add_argument("--canary-not-before", type=int, required=True)
    return parser


def _thresholds(args: argparse.Namespace) -> Thresholds:
    values = (
        args.max_window_ratio,
        args.max_cycle_rate_change_pct,
        args.min_attempt_reduction_pct,
        args.max_graphql_point_increase_pct,
        args.max_error_rate_increase_points,
        args.max_latency_increase_pct,
        args.max_burst_increase_pct,
    )
    invalid = any(not math.isfinite(value) or value < 0 for value in values)
    if invalid or args.max_window_ratio < 1 or args.canary_not_before <= 0:
        raise BenchmarkInputError(
            "thresholds must be finite and non-negative; "
            "max-window-ratio must be at least 1 and "
            "canary-not-before must be positive"
        )
    return Thresholds(*values, args.canary_not_before)


def _validate_labels(args: argparse.Namespace) -> None:
    labels = (args.baseline_label, args.canary_label)
    labels_are_safe = all(_LABEL_RE.fullmatch(label) for label in labels)
    if labels[0] == labels[1] or not labels_are_safe:
        raise BenchmarkInputError(
            "labels must be distinct safe text of at most 64 characters"
        )


def _canonical_path(path: Path) -> Path:
    try:
        return path.resolve(strict=False)
    except (OSError, RuntimeError) as exc:
        raise BenchmarkInputError("could not resolve an input or output path") from exc


def _validate_cli_paths(args: argparse.Namespace) -> None:
    _validate_labels(args)
    input_paths = (
        args.baseline_report,
        args.baseline_evidence,
        args.canary_report,
        args.canary_evidence,
    )
    inputs = {_canonical_path(path) for path in input_paths}
    outputs = (
        _canonical_path(args.json_out),
        _canonical_path(args.markdown_out),
    )
    if outputs[0] == outputs[1] or any(path in inputs for path in outputs):
        raise BenchmarkInputError(
            "output paths must be distinct from each other and every input"
        )


def main() -> int:
    args = _parser().parse_args()
    try:
        _validate_cli_paths(args)
        thresholds = _thresholds(args)
        baseline = build_window(
            args.baseline_label, args.baseline_report, args.baseline_evidence
        )
        canary = build_window(
            args.canary_label, args.canary_report, args.canary_evidence
        )
        result = build_result(baseline, canary, thresholds)
        json_content = json.dumps(
            result, indent=2, sort_keys=True, allow_nan=False
        ) + "\n"
        markdown_content = render_markdown(result)
        _atomic_write(args.json_out, json_content)
        _atomic_write(args.markdown_out, markdown_content)
    except BenchmarkInputError as exc:
        print(f"github-api-efficiency-benchmark: {exc}", file=sys.stderr)
        return EXIT_INCONCLUSIVE
    print(f"{result['status']}: {len(result['reasons'])} decision reason(s)")
    if result["status"] == STATUS_OK:
        return 0
    if result["status"] == STATUS_REGRESSION:
        return EXIT_REGRESSION
    return EXIT_INCONCLUSIVE


if __name__ == "__main__":
    raise SystemExit(main())
