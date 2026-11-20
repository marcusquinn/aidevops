#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
"""Ceremony lines for remote-adapter approvals (e.g. Google Ads).

The operator sees the exact executable payload that apply or rollback will send,
never prose alone. Callers validate shapes first; these renderers only format.
"""

from __future__ import annotations

import json
from typing import Any, Dict, List


def _canonical(value: Any) -> str:
    return json.dumps(value, sort_keys=True)


def plan_operation_lines(actions: List[Dict[str, Any]], operations: List[Any]) -> List[str]:
    """One block per action: summary, recorded before/after state and the forward operation."""
    lines: List[str] = []
    for item, operation in zip(actions, operations):
        lines.append(f"- APPLY {item.get('id')} [{item.get('kind')}] {item.get('summary')}")
        lines.append(f"    before:    {_canonical(item.get('before'))}")
        lines.append(f"    after:     {_canonical(item.get('after'))}")
        lines.append(f"    operation: {_canonical(operation)}")
    return lines


def receipt_inverse_lines(actions: List[Dict[str, Any]]) -> List[str]:
    """One block per action in rollback send order: restored state and the inverse operation."""
    lines: List[str] = []
    for item in reversed(actions):
        lines.append(f"- REVERT {item.get('id')} [{item.get('kind')}] {item.get('summary')}")
        lines.append(f"    restore:   {_canonical(item.get('before'))}")
        lines.append(f"    operation: {_canonical(item.get('inverse'))}")
    return lines
