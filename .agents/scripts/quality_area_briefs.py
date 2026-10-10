#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
"""Plan and publish disjoint quality-sweep briefs using standard-library APIs."""

import argparse
from collections import Counter, defaultdict
from datetime import date
import hashlib
import json
import os
from pathlib import Path
import re
import tempfile

from quality_area_publish import check_ready, is_noise, load, noise_checks, publish, run
from quality_area_findings import (
    cell, core_files, exact, fetch_codacy, fetch_sonar, matches, normalize, repository,
)


def file_owner(config, path, rows, core):
    areas = config["areas"]
    upstream = config.get("upstream", {})
    if path in core:
        owner = upstream["area"]
        area = next(area for area in areas if area["id"] == owner)
        if area["repo"] != upstream["repo"]:
            raise ValueError("Upstream area must target the source repository")
        return owner
    if path in config.get("hotspots", {}):
        return config["hotspots"][path]
    return next((area["id"] for area in areas if any(matches(area, row) for row in rows)),
                config.get("default_area"))


def classify(config, findings, root):
    names = [area["id"] for area in config["areas"]]
    if len(set(names)) != len(names) or any(not re.fullmatch(r"[a-z0-9-]+", name) for name in names):
        raise ValueError("Area ids must be unique lowercase slugs")
    core = core_files(config, root)
    noise = list(noise_checks(config, root))
    files = defaultdict(list)
    for finding in findings:
        files[finding["file"]].append(finding)
    grouped, dropped = defaultdict(list), []
    for path, rows in sorted(files.items()):
        kept = []
        for row in rows:
            (dropped if is_noise(row, noise) else kept).append(row)
        if not kept:
            continue
        owner = file_owner(config, path, kept, core)
        if owner not in names:
            raise ValueError("Unmapped finding file or unknown area; refusing partial coverage")
        grouped[owner].extend(kept)
    return grouped, dropped


def brief(area, rows, scope, dependencies):
    counts = defaultdict(Counter)
    for row in rows:
        counts[row["file"]][row["source"] + ":" + row["rule"]] += 1
    targets = "\n".join(f"- `EDIT: {path}` — " + (
        cell(", ".join(f"{rule}: {count}" for rule, count in sorted(counts[path].items())))
        or "committed generated output; regenerate from this area's sources") for path in scope)
    scope_lines = "\n".join(f"- `{path}`" for path in scope)
    refs = ", ".join(f"`{path}`" for path in scope)
    commands = area["verification"]
    if not isinstance(commands, list) or not commands or not all(isinstance(c, str) for c in commands):
        raise ValueError("Each area requires repository-specific verification commands")
    verification = "\n".join(commands)
    table = "\n".join("| " + " | ".join(cell(row[key]) for key in ("file", "line", "source", "rule", "message")) + " |" for row in rows)
    return BRIEF_TEMPLATE.format(
        title=cell(area["title"]), created=date.today().isoformat(),
        dependencies=", ".join(dependencies) or "N/A because this area has no overlapping predecessor",
        count=len(rows), targets=targets, refs=refs, verification=verification,
        scope_lines=scope_lines, table=table)


# Template section contract, without invented pre-flight claims or task ids.
BRIEF_TEMPLATE = """<!-- aidevops:brief-schema=v2 -->

# {title}

## Origin

- **Created:** {created}
- **Conversation context:** Quality sweep from SonarCloud and Codacy open findings.
- **Blocked by:** {dependencies}

## What

Resolve the {count} captured findings in this area and regenerate the scoped committed outputs.

## Why

Reduce live quality debt while keeping each source file owned by one worker.

## Tier

**Selected tier:** `tier:standard`

**Tier rationale:** Known analyzer findings and exact targets; preserve behavior while choosing local refactors.

## PR Conventions

Leaf issue: use a closing keyword for this issue only.

## How (Approach)

### Files to Modify

{targets}

### Complete Write Surface

- **Callers/readers:** {refs}; inspect their callers before changing public interfaces.
- **Writers/mutation paths:** {refs}; only the exact Files Scope is authorized.
- **Existing verification/tests:** {refs}; the commands below exercise this area.
- **Schemas/config:** N/A because this sweep does not authorize schema or analyzer configuration changes.
- **Generated/deployed mirrors:** {refs}; regenerate the listed outputs, do not edit them by hand.
- **Migrations/backfills:** N/A because behavior-preserving quality refactoring needs no data migration.
- **Cleanup/rollback paths:** {refs}; revert this area's commit to roll back.

### Implementation Steps

1. Reproduce the captured rules using the repository analyzer configuration and inspect callers of the scoped files.
2. Resolve the table's findings with behavior-preserving refactors; do not disable rules or broaden scope.
3. Regenerate the listed committed outputs and run the verification commands.

### Hazards and Compatibility

- **Concurrency/atomicity:** Shared outputs require the predecessor dependencies to finish before dispatch.
- **Migration/rollback:** No migration; revert the area commit if verification regresses.
- **Mixed-version/backward compatibility:** Preserve existing APIs and user-visible behavior.
- **Idempotency/retry:** Recheck current findings before changing code; skip already-fixed rows.
- **Partial failure/recovery:** Keep coherent commits and report unresolved rows rather than suppressing them.

### Verification Before Dispatch

```bash
{verification}
```

- **Surface mapping:** These area-specific commands cover the scoped sources, generated outputs and regression guarantee.
- **Broad verification trigger:** N/A because no shared tooling or release changes are authorized.

### Files Scope

{scope_lines}

## Acceptance Criteria

- [ ] The captured findings are resolved and the area verification commands pass.
- [ ] Existing public behavior is preserved; no analyzer rules are disabled and no unscoped files are changed.

## Captured Findings

<details>
<summary>Full findings table ({count} findings)</summary>

| File | Line | Source | Rule | Message |
| --- | --- | --- | --- | --- |
{table}

</details>
"""


def plan(config, grouped, output, repo):
    plans = []
    titles = set()
    for area in config["areas"]:
        rows = grouped.get(area["id"], [])
        if not rows:
            continue
        target = repository(area.get("repo", repo))
        title_key = (target, area["title"])
        if title_key in titles:
            raise ValueError("Area titles must be unique within a repository")
        titles.add(title_key)
        scope = sorted({row["file"] for row in rows} | {exact(p) for p in area.get("generated", [])})
        dependencies = [item["id"] for item in plans
                        if item["repo"] == target and set(item["scope"]) & set(scope)]
        path = output / (area["id"] + ".md")
        contract = json.dumps([target, scope, dependencies, area["verification"]], sort_keys=True)
        digest = hashlib.sha256(contract.encode()).hexdigest()
        marker = f"<!-- aidevops:quality-area:{area['id']}:{digest} -->"
        path.write_text(brief(area, rows, scope, dependencies) + "\n" + marker + "\n")
        check_ready(path)
        plans.append(dict(id=area["id"], repo=target, title=area["title"], scope=scope,
                          dependencies=dependencies, brief=str(path), count=len(rows),
                          marker=marker,
                          status="status:blocked" if dependencies else "status:available",
                          sources=dict(Counter(row["source"] for row in rows))))
    return plans


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repo", required=True, help="GitHub owner/repo")
    parser.add_argument("--repo-path", required=True, type=Path, help="Local target checkout")
    parser.add_argument("--areas", required=True, type=Path, help="Trusted JSON area map")
    parser.add_argument("--sonar-key", help="SonarCloud component key (required live)")
    parser.add_argument("--dry-run", action="store_true", help="Validate briefs and print plan without GitHub writes")
    parser.add_argument("--offline", action="store_true", help="Use saved service response arrays, not network or secrets")
    parser.add_argument("--sonar-input", type=Path, help="JSON array of SonarCloud issue objects")
    parser.add_argument("--codacy-input", type=Path, help="JSON array of Codacy issue objects")
    args = parser.parse_args()
    repo = repository(args.repo)
    root = args.repo_path.resolve(strict=True)
    config = load(args.areas)
    # Verify downstream files against the actual checkout before briefing.
    tracked = set(run(["git", "ls-files"], root).splitlines())
    if args.offline:
        if not args.sonar_input or not args.codacy_input:
            parser.error("--offline requires both saved response arrays")
        sonar, codacy = load(args.sonar_input), load(args.codacy_input)
    else:
        if not args.sonar_key:
            parser.error("live mode requires --sonar-key")
        sonar, codacy = fetch_sonar(args.sonar_key), fetch_codacy(repo)
    findings = normalize(sonar, "sonarcloud") + normalize(codacy, "codacy")
    if any(row["file"] not in tracked for row in findings):
        raise ValueError("Service finding references a file absent from checkout HEAD")
    grouped, dropped = classify(config, findings, root)
    for area in config["areas"]:
        if area.get("repo", repo) == repo and any(p not in tracked for p in area.get("generated", [])):
            raise ValueError("Generated output is not an exact committed file")
    temporary = Path(os.environ.get("AIDEVOPS_TEMP_DIR", str(Path.home() / ".aidevops/.agent-workspace/tmp")))
    temporary.mkdir(parents=True, exist_ok=True)
    output = Path(tempfile.mkdtemp(prefix="quality-area-briefs-", dir=temporary))
    os.chmod(output, 0o700)
    plans = plan(config, grouped, output, repo)
    report = dict(areas=plans, sources=dict(Counter(row["source"] for row in findings)),
                  dropped=dict(Counter(row["source"] + ":" + row["rule"] for row in dropped)))
    (output / "plan.json").write_text(json.dumps(report, indent=2) + "\n")
    print(json.dumps(report, indent=2), flush=True)
    if not args.dry_run:
        publish(plans)


if __name__ == "__main__":
    try:
        main()
    except (ValueError, KeyError, OSError, TypeError) as error:
        # KeyError/OSError details may expose raw service text or private paths.
        message = str(error) if isinstance(error, ValueError) else type(error).__name__
        raise SystemExit("Quality area briefs failed: " + message) from None
