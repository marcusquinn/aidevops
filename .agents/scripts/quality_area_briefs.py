#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
"""Plan and publish disjoint quality-sweep briefs using standard-library APIs."""

import argparse
from collections import Counter, defaultdict
from datetime import date
import hashlib
import html
import json
import os
from pathlib import Path
import re
import subprocess
import tempfile
from urllib.error import HTTPError, URLError
from urllib.parse import urlencode, quote
from urllib.request import Request, urlopen

SCRIPTS = Path(__file__).resolve().parent


def run(argv, cwd=None):
    """Never execute service text or area selectors as shell syntax."""
    result = subprocess.run(argv, cwd=cwd, text=True, capture_output=True, check=False)
    if result.returncode:
        # External stderr can include secrets, service text or private paths.
        raise ValueError(f"Command failed: {Path(argv[0]).name} (exit {result.returncode})")
    return result.stdout


def load(path):
    return json.loads(Path(path).read_text())


def exact(path):
    if not isinstance(path, str) or not re.fullmatch(
        r"[A-Za-z0-9_.()\[\]-]+(?:/[A-Za-z0-9_.()\[\]-]+)*", path
    ) or any(part in (".", "..", ".git") for part in path.split("/")):
        raise ValueError("Expected an exact repository-relative path")
    return path


def repository(value):
    if not re.fullmatch(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+", value):
        raise ValueError("Expected owner/repository")
    return value


def request_json(url, headers, payload=None):
    body = None if payload is None else json.dumps(payload).encode()
    request = Request(url, data=body, headers={**headers, "Content-Type": "application/json"})
    try:
        with urlopen(request, timeout=60) as response:
            return json.load(response)
    except HTTPError as error:
        raise ValueError(f"Service request failed (HTTP {error.code})") from None
    except URLError:
        raise ValueError("Service request failed (network)") from None


def fetch_sonar(key):
    findings = []
    headers = {}
    if os.environ.get("SONAR_TOKEN"):
        headers["Authorization"] = "Bearer " + os.environ["SONAR_TOKEN"]
    page = 1
    while True:
        query = urlencode(dict(componentKeys=key, types="CODE_SMELL", resolved="false", ps=500, p=page))
        data = request_json("https://sonarcloud.io/api/issues/search?" + query, headers)
        rows = data["issues"]
        findings.extend(rows)
        total = data.get("total", data.get("paging", {}).get("total"))
        if total is None:
            raise ValueError("SonarCloud response has no total")
        if page * 500 >= total:
            return findings
        if not rows:
            raise ValueError("SonarCloud pagination ended before total")
        page += 1


def fetch_codacy(repo):
    token = os.environ.get("CODACY_API_TOKEN")
    if not token:
        raise ValueError("CODACY_API_TOKEN is required for live findings")
    org, name = repo.split("/")
    base = ("https://api.codacy.com/api/v3/analysis/organizations/gh/"
            f"{quote(org, safe='')}/repositories/{quote(name, safe='')}/issues/search")
    rows, seen, cursor = [], set(), None
    while True:
        query = {"limit": 1000}
        if cursor:
            query["cursor"] = cursor
        data = request_json(base + "?" + urlencode(query), {"api-token": token}, {})
        rows.extend(data["data"])
        cursor = data.get("pagination", {}).get("cursor")
        if not cursor:
            return rows
        if cursor in seen:
            raise ValueError("Codacy repeated its pagination cursor")
        seen.add(cursor)


def normalize(rows, source):
    result = []
    for row in rows:
        if source == "sonarcloud":
            path = row["component"].split(":", 1)[-1]
            rule, tool = row["rule"], "sonarcloud"
            line = row.get("line", row.get("textRange", {}).get("startLine", 0))
        else:
            path = row["filePath"]
            pattern = row.get("patternInfo", {})
            rule = pattern["id"]
            tool = pattern.get("toolId", pattern.get("tool", "codacy"))
            if isinstance(tool, dict):
                tool = tool.get("name", tool.get("id", "codacy"))
            line = row.get("lineNumber", row.get("line", 0))
        result.append(dict(file=exact(path), line=int(line or 0), source=source,
                           rule=str(rule), tool=str(tool), message=str(row.get("message", ""))))
    return result


def noise_checks(config, root):
    """Require config evidence and an actual same-config local analyzer result."""
    checks = {}
    for entry in config.get("disabled_rules", []):
        path = root / exact(entry["config"])
        content = path.read_bytes()
        if entry["config_contains"] not in content.decode():
            raise ValueError("Disabled rule is not evidenced in repository config")
        argv = entry["local_check"]
        if not isinstance(argv, list) or not argv or not all(isinstance(x, str) for x in argv):
            raise ValueError("local_check must be a trusted argv array")
        cache_key = tuple(argv)
        if cache_key not in checks:
            checks[cache_key] = json.loads(run(argv, root))
        evidence = checks[cache_key]
        if evidence["config_sha256"] != hashlib.sha256(content).hexdigest():
            raise ValueError("Local analyzer result used a different config")
        yield entry, evidence["findings"]


def matches(area, finding):
    return (any(finding["file"].startswith(prefix) for prefix in area.get("prefixes", []))
            or finding["rule"] in area.get("rules", [])
            or finding["tool"] in area.get("tools", []))


def classify(config, findings, root):
    areas = config["areas"]
    names = [area["id"] for area in areas]
    if len(set(names)) != len(names) or any(not re.fullmatch(r"[a-z0-9-]+", name) for name in names):
        raise ValueError("Area ids must be unique lowercase slugs")
    by_id = {area["id"]: area for area in areas}
    upstream = config.get("upstream", {})
    core = set(upstream.get("files", []))
    if upstream.get("files_file"):
        core.update(line.strip() for line in (root / exact(upstream["files_file"])).read_text().splitlines()
                    if line.strip() and not line.lstrip().startswith("#"))
    for path in core:
        exact(path)
    noise = list(noise_checks(config, root))
    files = defaultdict(list)
    for finding in findings:
        files[finding["file"]].append(finding)
    grouped, dropped = defaultdict(list), []
    for path, rows in sorted(files.items()):
        # Ownership is decided before filtering: all rules on a hotspot/core
        # file stay with that owner, even when other rules match other areas.
        if path in core:
            owner = upstream["area"]
            if by_id[owner]["repo"] != upstream["repo"]:
                raise ValueError("Upstream area must target the source repository")
        elif path in config.get("hotspots", {}):
            owner = config["hotspots"][path]
        else:
            owner = next((area["id"] for area in areas if any(matches(area, row) for row in rows)),
                         config.get("default_area"))
        if owner not in by_id:
            raise ValueError("Unmapped finding file or unknown area; refusing partial coverage")
        for row in rows:
            disabled = any(entry["source"] == row["source"] and entry["rule"] == row["rule"]
                           and not any(local["file"] == path and local["rule"] == row["rule"]
                                       for local in local_rows)
                           for entry, local_rows in noise)
            if disabled:
                dropped.append(row)
            else:
                grouped[owner].append(row)
    return grouped, dropped


def cell(value):
    # Escape both HTML and markdown table/control syntax from untrusted APIs.
    return html.escape(str(value), quote=True).replace("|", "&#124;").replace("`", "&#96;").replace("\n", " ").replace("\r", " ")


def brief(area, rows, scope, dependencies):
    counts = defaultdict(Counter)
    for row in rows:
        counts[row["file"]][row["source"] + ":" + row["rule"]] += 1
    targets = "\n".join(f"- `EDIT: {path}` — " + cell(dict(counts[path])) for path in scope)
    scope_lines = "\n".join(f"- `{path}`" for path in scope)
    refs = ", ".join(f"`{path}`" for path in scope)
    commands = area["verification"]
    if not isinstance(commands, list) or not commands or not all(isinstance(c, str) for c in commands):
        raise ValueError("Each area requires repository-specific verification commands")
    verification = "\n".join(commands)
    table = "\n".join("| " + " | ".join(cell(row[key]) for key in ("file", "line", "source", "rule", "message")) + " |" for row in rows)
    # Template section contract, without invented pre-flight claims or task ids.
    return f"""<!-- aidevops:brief-schema=v2 -->

# {cell(area['title'])}

## Origin

- **Created:** {date.today().isoformat()}
- **Conversation context:** Quality sweep from SonarCloud and Codacy open findings.
- **Blocked by:** {', '.join(dependencies) or 'N/A because this area has no overlapping predecessor'}

## What

Resolve the {len(rows)} captured findings in this area and regenerate the scoped committed outputs.

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
<summary>Full findings table ({len(rows)} findings)</summary>

| File | Line | Source | Rule | Message |
| --- | --- | --- | --- | --- |
{table}

</details>
"""


def plan(config, grouped, output, repo):
    plans = []
    for area in config["areas"]:
        rows = grouped.get(area["id"], [])
        if not rows:
            continue
        target = repository(area.get("repo", repo))
        scope = sorted({row["file"] for row in rows} | {exact(p) for p in area.get("generated", [])})
        dependencies = [item["id"] for item in plans
                        if item["repo"] == target and set(item["scope"]) & set(scope)]
        path = output / (area["id"] + ".md")
        path.write_text(brief(area, rows, scope, dependencies))
        result = run(["bash", str(SCRIPTS / "verify-brief-helper.sh"), "check-readiness", str(path)])
        if "WORKER_READY=true" not in result:
            raise ValueError("Brief failed worker readiness")
        plans.append(dict(id=area["id"], repo=target, title=area["title"], scope=scope,
                          dependencies=dependencies, brief=str(path), count=len(rows),
                          sources=dict(Counter(row["source"] for row in rows))))
    return plans


def gh(*args):
    return run(["gh", *args])


def write(*args):
    return run(["bash", str(SCRIPTS / "gh-write-helper.sh"), *args])


def open_issues(repo):
    pages = json.loads(gh("api", "--paginate", "--slurp", f"repos/{repo}/issues?state=open&per_page=100"))
    return [issue for page in pages for issue in page if "pull_request" not in issue]


def publish(plans):
    known, numbers = {}, {}
    for item in plans:
        repo = item["repo"]
        if repo not in known:
            known[repo] = open_issues(repo)
        matches_title = [issue for issue in known[repo] if issue["title"] == item["title"]]
        if len(matches_title) > 1:
            raise ValueError("Ambiguous duplicate issue titles")
        if matches_title:
            issue = matches_title[0]
            # Never hijack an unrelated/claimed issue with an identical title.
            if "<!-- aidevops:quality-area:" + item["id"] + " -->" not in issue["body"]:
                raise ValueError("Existing title lacks this area's ownership marker")
            if issue["assignees"] or any(label["name"] in ("status:in-progress", "status:claimed") for label in issue["labels"]):
                raise ValueError("Existing area is owned by an active worker")
            number = issue["number"]
            print(f"existing_issue={repo}#{number}", flush=True)
        else:
            # All new issues start held and without auto-dispatch. A partial
            # failure must never expose overlapping workers to the queue.
            url = write("issue", "create", "--repo", repo, "--title", item["title"],
                        "--body-file", item["brief"], "--label", "status:blocked", "--label", "tier:standard").strip().splitlines()[-1]
            number = int(url.rstrip("/").split("/")[-1])
            print(f"created_issue={repo}#{number}", flush=True)
        item["number"] = number
        numbers[item["id"]] = number
        # Hold deduped issues too, before any relationship mutations.
        write("issue", "edit", str(number), "--repo", repo, "--add-label", "status:blocked",
              "--remove-label", "status:available", "--remove-label", "auto-dispatch")
    for item in plans:
        repo, number = item["repo"], item["number"]
        endpoint = f"repos/{repo}/issues/{number}/dependencies/blocked_by"
        for predecessor in item["dependencies"]:
            previous = numbers[predecessor]
            current = json.loads(gh("api", "--paginate", "--slurp", endpoint))
            if not any(edge["number"] == previous for page in current for edge in page):
                database_id = json.loads(gh("api", f"repos/{repo}/issues/{previous}"))["id"]
                gh("api", "-X", "POST", endpoint, "-F", f"issue_id={database_id}")
            edges = json.loads(gh("api", "--paginate", "--slurp", endpoint))
            if not any(edge["number"] == previous for page in edges for edge in page):
                raise ValueError("Native blockedBy relationship was not verified")
            write("issue", "edit", str(number), "--repo", repo, "--add-label", f"blocked-by:{previous}")
        # Check all native edges, including edges left by a previous run.
        edges = json.loads(gh("api", "--paginate", "--slurp", endpoint))
        blocked = any(edge.get("state", "open") == "open" for page in edges for edge in page)
        status = "status:blocked" if blocked else "status:available"
        write("issue", "edit", str(number), "--repo", repo, "--add-label", status,
              "--remove-label", "status:available" if blocked else "status:blocked", "--add-label", "auto-dispatch")


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
    for item in plans:
        path = Path(item["brief"])
        path.write_text(path.read_text() + f"\n<!-- aidevops:quality-area:{item['id']} -->\n")
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
