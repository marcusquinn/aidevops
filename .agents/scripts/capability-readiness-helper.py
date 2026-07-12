#!/usr/bin/env python3
"""Query, probe, route, and validate aidevops capability readiness."""

from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
from typing import Any

SCRIPT_DIR = Path(__file__).resolve().parent
AGENTS_DIR = SCRIPT_DIR.parent
DEFAULT_REGISTRY = AGENTS_DIR / "configs" / "capability-registry.json"
STATES = {"true", "false", "unknown", "not_applicable"}


def load_json(path: Path) -> dict[str, Any]:
    with path.open(encoding="utf-8") as handle:
        return json.load(handle)


def capability_for(registry: dict[str, Any], requested: str) -> dict[str, Any] | None:
    key = requested.casefold()
    for capability in registry["capabilities"]:
        names = [capability["name"], *capability.get("aliases", [])]
        if key in (name.casefold() for name in names):
            return capability
    return None


def runtime_name(explicit: str | None) -> str:
    if explicit:
        return explicit
    return os.environ.get("AIDEVOPS_RUNTIME", "unknown").casefold()


def probe_value(spec: dict[str, Any], agents_dir: Path) -> str:
    if "command" in spec:
        return "true" if shutil.which(spec["command"]) else "false"
    if "command_check" in spec:
        if not shutil.which(spec["command_check"][0]):
            return "false"
        result = subprocess.run(spec["command_check"], capture_output=True, check=False, timeout=10)
        return "true" if result.returncode == 0 else "false"
    if "path" in spec:
        return "true" if (agents_dir / spec["path"]).exists() else "false"
    if "path_home" in spec:
        return "true" if (Path.home() / spec["path_home"]).exists() else "false"
    if "env_any" in spec:
        return "true" if any(os.environ.get(name) for name in spec["env_any"]) else "false"
    if "env_all" in spec:
        return "true" if all(os.environ.get(name) for name in spec["env_all"]) else "false"
    if "tool" in spec:
        visible = [item.strip() for item in os.environ.get("AIDEVOPS_VISIBLE_TOOLS", "").split(",") if item.strip()]
        if not visible:
            return "unknown"
        pattern = "^" + re.escape(spec["tool"]).replace(r"\*", ".*") + "$"
        return "true" if any(re.match(pattern, item) for item in visible) else "false"
    return "unknown"


def assess(capability: dict[str, Any], registry: dict[str, Any], runtime: str, fixture: dict[str, Any] | None) -> dict[str, Any]:
    readiness = {dimension: "unknown" for dimension in registry["dimensions"]}
    readiness["catalogued"] = "true"
    readiness["runtime_compatible"] = "true" if runtime in capability["runtimes"] else ("unknown" if runtime == "unknown" else "false")
    for dimension, spec in capability.get("probes", {}).items():
        readiness[dimension] = probe_value(spec, AGENTS_DIR)
    if capability.get("mcp"):
        readiness["configured"] = readiness["configured"] if readiness["configured"] != "unknown" else "unknown"
        readiness["enabled"] = readiness["enabled"] if readiness["enabled"] != "unknown" else "unknown"
    if fixture:
        overrides = fixture.get("capabilities", {}).get(capability["name"], {})
        for dimension, value in overrides.items():
            if dimension in readiness and value in STATES:
                readiness[dimension] = value
    missing = [dimension for dimension in capability["required"] if readiness[dimension] != "true"]
    result = dict(capability)
    result["readiness"] = readiness
    result["route_ready"] = not missing
    result["missing_required"] = missing
    result["runtime"] = runtime
    return result


def validate(registry: dict[str, Any]) -> list[str]:
    errors: list[str] = []
    names: set[str] = set()
    aliases: set[str] = set()
    dimensions = set(registry.get("dimensions", []))
    agent_index = (AGENTS_DIR / "subagent-index.toon").read_text(encoding="utf-8")
    mcp_source = (AGENTS_DIR / "plugins" / "opencode-aidevops" / "mcp-registry.mjs").read_text(encoding="utf-8")
    for capability in registry.get("capabilities", []):
        name = capability.get("name", "")
        if name in names:
            errors.append(f"duplicate capability: {name}")
        names.add(name)
        for alias in capability.get("aliases", []):
            if alias in aliases or alias in names:
                errors.append(f"duplicate alias: {alias}")
            aliases.add(alias)
        if not re.search(rf"^{re.escape(capability.get('owner', ''))},", agent_index, re.MULTILINE):
            errors.append(f"unknown owner: {capability.get('owner')} ({name})")
        for entry in capability.get("entry_points", []):
            if not (AGENTS_DIR / entry).is_file():
                errors.append(f"invalid entry point: {entry} ({name})")
        for dimension in capability.get("required", []):
            if dimension not in dimensions:
                errors.append(f"unknown readiness dimension: {dimension} ({name})")
            if dimension not in capability.get("probes", {}) and dimension not in {"catalogued", "runtime_compatible"}:
                errors.append(f"required claim has no probe: {dimension} ({name})")
        mcp = capability.get("mcp")
        if mcp and not re.search(rf'name:\s*["\']{re.escape(mcp)}["\']', mcp_source):
            errors.append(f"unknown MCP: {mcp} ({name})")
    return errors


def generate(registry: dict[str, Any], output: Path) -> None:
    lines = ["<!-- Generated by capability-readiness-helper.py; do not edit. -->", "", "# Capability Registry", "", f"Catalogued capabilities: **{len(registry['capabilities'])}**", "", "| Capability | Owner | Runtimes | Mandatory readiness | Fallback |", "|---|---|---|---|---|"]
    for item in registry["capabilities"]:
        lines.append(f"| `{item['name']}` | {item['owner']} | {', '.join(item['runtimes'])} | {', '.join(item['required'])} | `{item['fallback']}` |")
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text("\n".join(lines) + "\n", encoding="utf-8")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--registry", type=Path, default=DEFAULT_REGISTRY)
    parser.add_argument("--fixture", type=Path)
    sub = parser.add_subparsers(dest="command", required=True)
    query = sub.add_parser("query")
    query.add_argument("capability", nargs="?")
    query.add_argument("--runtime", choices=["opencode", "claude-code"])
    route = sub.add_parser("route")
    route.add_argument("capability")
    route.add_argument("--runtime", choices=["opencode", "claude-code"])
    sub.add_parser("check")
    generate_parser = sub.add_parser("generate")
    generate_parser.add_argument("--output", type=Path, default=AGENTS_DIR / "reference" / "capability-registry.md")
    args = parser.parse_args()
    registry = load_json(args.registry)
    fixture = load_json(args.fixture) if args.fixture else None
    if args.command == "check":
        errors = validate(registry)
        print(json.dumps({"valid": not errors, "errors": errors}, indent=2))
        return 0 if not errors else 1
    if args.command == "generate":
        generate(registry, args.output)
        return 0
    requested = getattr(args, "capability", None)
    selected = capability_for(registry, requested) if requested else None
    if requested and not selected:
        print(json.dumps({"error": "unknown_capability", "requested": requested}))
        return 2
    runtime = runtime_name(getattr(args, "runtime", None))
    results = [assess(selected, registry, runtime, fixture)] if selected else [assess(item, registry, runtime, fixture) for item in registry["capabilities"]]
    if args.command == "route":
        result = results[0]
        decision = "route" if result["route_ready"] else "fallback"
        print(json.dumps({"decision": decision, "capability": result["name"], "owner": result["owner"] if decision == "route" else None, "fallback": None if decision == "route" else result["fallback"], "reason": None if decision == "route" else "mandatory readiness is false or unknown", "coverage_impact": result["missing_required"], "readiness": result["readiness"]}, indent=2))
        return 0 if decision == "route" else 3
    print(json.dumps({"schema_version": registry["schema_version"], "runtime": runtime, "capabilities": results}, indent=2))
    return 0


if __name__ == "__main__":
    sys.exit(main())
