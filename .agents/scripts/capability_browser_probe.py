"""Live readiness for the explicitly selected repository Playwright transport."""

# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn

from __future__ import annotations

import json
import os
from pathlib import Path
import re
import shutil
import subprocess
from typing import Any
from urllib.parse import SplitResult, urlsplit


def is_credential_free_origin(parsed: SplitResult) -> bool:
    """Keep authority, resource and port checks independently reviewable."""
    if parsed.scheme not in {"https", "http"} or not parsed.hostname:
        return False
    if parsed.username is not None or parsed.password is not None:
        return False
    if parsed.path not in {"", "/"} or parsed.query or parsed.fragment:
        return False
    return parsed.port is None or 0 < parsed.port <= 65535


def validate_browser_target(target: str | None) -> None:
    """Accept an origin/hostname for scope only; never contact it in this probe."""
    if not target or len(target) > 2048:
        raise ValueError("Browser readiness requires a target origin or hostname")
    if re.fullmatch(r"[A-Za-z0-9](?:[A-Za-z0-9.-]*[A-Za-z0-9])?", target):
        return
    try:
        valid = is_credential_free_origin(urlsplit(target))
        valid = valid and not any(character.isspace() for character in target)
    except ValueError:
        valid = False
    if not valid:
        raise ValueError("Browser readiness target must be a credential-free origin or hostname")


def playwright_live_evidence(
    workdir: Path, target: str | None, operation: str, scripts_dir: Path,
) -> tuple[dict[str, str], dict[str, Any]]:
    validate_browser_target(target)
    project = workdir.resolve()
    if not project.is_dir() or not (project / "package.json").is_file():
        raise ValueError("Playwright readiness requires an existing package workdir")
    evidence = {"enabled": "false", "tool_visible": "false", "reachable": "false"}
    scope: dict[str, Any] = {
        "target": target, "operation": operation, "transport": "playwright",
        "workdir": str(project), "browser": "bundled-chromium",
        "target_contacted": False, "authenticated": False,
        "probe": "isolated-blank-page-and-close",
    }
    node = shutil.which("node")
    if not node:
        return evidence, {**scope, "reason": "node_unavailable"}
    # No credentials, Node preloads, browser/module overrides or npm downloads.
    environment = {
        name: os.environ[name]
        for name in ("PATH", "HOME", "TMPDIR", "TEMP", "TMP", "SystemRoot", "LOCALAPPDATA", "PLAYWRIGHT_BROWSERS_PATH")
        if name in os.environ
    }
    try:
        result = subprocess.run(  # nosec B603
            [node, str(scripts_dir / "browser-readiness-probe.mjs")],
            cwd=project, env=environment, capture_output=True, text=True,
            check=False, timeout=35,
        )
        payload = json.loads(result.stdout)
    except (OSError, subprocess.TimeoutExpired, json.JSONDecodeError):
        return evidence, {**scope, "reason": "probe_unavailable"}
    if not isinstance(payload, dict) or payload.get("schema") != "aidevops.playwright-readiness/v1":
        return evidence, {**scope, "reason": "invalid_probe_result"}
    evidence["enabled"] = "true" if payload.get("packageImportable") is True else "false"
    evidence["tool_visible"] = "true" if payload.get("runnerAvailable") is True else "false"
    if result.returncode == 0 and payload.get("roundTrip") is True and payload.get("closed") is True:
        evidence["reachable"] = "true"
    # Project/library diagnostics are untrusted; emit only finite status fields.
    reasons = {"ready", "package_unavailable", "browser_failed", "cleanup_failed"}
    reason = payload.get("reason")
    scope["reason"] = reason if isinstance(reason, str) and reason in reasons else "invalid_probe_result"
    scope["closed"] = payload.get("closed") is True
    return evidence, scope
