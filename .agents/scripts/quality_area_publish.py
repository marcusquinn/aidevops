#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
"""Readiness and held-issue publication adapters for quality-area sweeps."""

import hashlib
import json
import os
from pathlib import Path
import re
import subprocess

from quality_area_findings import exact

SCRIPTS = Path(__file__).resolve().parent


def load(path):
    return json.loads(Path(path).read_text())


def run(argv, cwd=None, env=None):
    """Execute only internal tooling or trusted operator argv, never API text."""
    result = subprocess.run(  # nosec B603 - trusted argv, no shell or service commands
        argv, cwd=cwd, env=env, shell=False, text=True, capture_output=True, check=False)
    if result.returncode:
        # External stderr can contain secrets, service text or private paths.
        raise ValueError(f"Command failed: {Path(argv[0]).name} (exit {result.returncode})")
    return result.stdout


def gh(*args):
    return run(["gh", *args])


def write(*args):
    # Held publication omits auto-dispatch but retains worker ownership intent.
    env = {**os.environ, "AIDEVOPS_GH_SKIP_AUTO_ASSIGNMENT": "1"}
    return run(["bash", str(SCRIPTS / "gh-write-helper.sh"), *args], env=env)


def open_issues(repo):
    pages = json.loads(gh("api", "--paginate", "--slurp", f"repos/{repo}/issues?state=open&per_page=100"))
    return [issue for page in pages for issue in page if "pull_request" not in issue]


def check_ready(path):
    result = run(["bash", str(SCRIPTS / "verify-brief-helper.sh"), "check-readiness", str(path)])
    if "WORKER_READY=true" not in result.splitlines():
        raise ValueError("Brief failed worker readiness")


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


def is_noise(row, noise):
    for entry, local_rows in noise:
        if entry["source"] != row["source"] or entry["rule"] != row["rule"]:
            continue
        if not any(local["file"] == row["file"] and local["rule"] == row["rule"] for local in local_rows):
            return True
    return False


def check_unclaimed(issue):
    if issue.get("state", "open") != "open" or issue["assignees"] or any(
        label["name"] in ("status:in-progress", "status:claimed", "status:in-review")
        for label in issue["labels"]
    ):
        raise ValueError("Existing area is closed or owned by an active worker")


def match_existing(item, issues):
    matches = [issue for issue in issues if issue["title"] == item["title"]]
    if len(matches) > 1:
        raise ValueError("Ambiguous duplicate issue titles")
    if not matches:
        return None
    issue = matches[0]
    if item["marker"] not in (issue["body"] or ""):
        raise ValueError("Existing area contract differs; use new sweep titles for changed scope/order")
    check_unclaimed(issue)
    return issue


def validate_contracts(plans):
    known = {}
    for item in plans:
        item.pop("existing", None)
        item.pop("released", None)
        if len(Path(item["brief"]).read_text()) > 60000:
            raise ValueError("Brief exceeds safe GitHub body limit; split this area before publishing")
        repo = item["repo"]
        if repo not in known:
            known[repo] = open_issues(repo)
        item["existing"] = match_existing(item, known[repo])
    by_id = {item["id"]: item for item in plans}
    for item in plans:
        if item["existing"] and any(not by_id[name]["existing"] for name in item["dependencies"]):
            raise ValueError("Existing successor has a missing/closed predecessor; finish the earlier sweep first")


def prepare_item(item):
    repo = item["repo"]
    issue = item["existing"]
    if issue:
        number = issue["number"]
        print(f"existing_issue={repo}#{number}", flush=True)
        # Released issues are immutable on retries; a worker may claim them
        # after our read, so do not change their body or labels.
        item["released"] = any(label["name"] == "auto-dispatch" for label in issue["labels"])
    else:
        url = write("issue", "create", "--repo", repo, "--title", item["title"],
                    "--body-file", item["brief"], "--label", "status:blocked", "--label", "tier:standard").strip().splitlines()[-1]
        number = int(url.rstrip("/").split("/")[-1])
        print(f"created_issue={repo}#{number}", flush=True)
    item["number"] = number
    if not item.get("released"):
        check_unclaimed(json.loads(gh("api", f"repos/{repo}/issues/{number}")))
        write("issue", "edit", str(number), "--repo", repo, "--add-label", "status:blocked",
              "--remove-label", "status:available", "--remove-label", "auto-dispatch")


def dependency_edges(endpoint):
    pages = json.loads(gh("api", "--paginate", "--slurp", endpoint))
    return [edge for page in pages for edge in page]


def install_dependencies(item, numbers, endpoint):
    repo = item["repo"]
    for predecessor in item["dependencies"]:
        previous = numbers[predecessor]
        if not any(edge["number"] == previous for edge in dependency_edges(endpoint)):
            database_id = json.loads(gh("api", f"repos/{repo}/issues/{previous}"))["id"]
            gh("api", "-X", "POST", endpoint, "-F", f"issue_id={database_id}")
        if not any(edge["number"] == previous for edge in dependency_edges(endpoint)):
            raise ValueError("Native blockedBy relationship was not verified")


def publish_body(item, numbers):
    path = Path(item["brief"])
    dependency_text = ", ".join(f"blocked-by:#{numbers[name]}" for name in item["dependencies"])
    body = re.sub(r"^- \*\*Blocked by:\*\* .*$",
                  "- **Blocked by:** " + (dependency_text or "N/A because this area has no overlapping predecessor"),
                  path.read_text(), flags=re.MULTILINE)
    path.write_text(body)
    check_ready(path)
    write("issue", "edit", str(item["number"]), "--repo", item["repo"], "--body-file", str(path))


def release_item(item, endpoint):
    # Include unrelated native blockers, not only edges owned by this sweep.
    blocked = any(edge.get("state", "open") == "open" for edge in dependency_edges(endpoint))
    repo, number = item["repo"], item["number"]
    check_unclaimed(json.loads(gh("api", f"repos/{repo}/issues/{number}")))
    status = "status:blocked" if blocked else "status:available"
    write("issue", "edit", str(number), "--repo", repo, "--add-label", status,
          "--remove-label", "status:available" if blocked else "status:blocked", "--add-label", "auto-dispatch")


def publish(plans):
    # Validate the entire sweep before any mutation; hold all unreleased items
    # before changing relationships. Partial failure leaves successors held.
    validate_contracts(plans)
    for item in plans:
        prepare_item(item)
    numbers = {item["id"]: item["number"] for item in plans}
    for item in plans:
        if item.get("released"):
            continue
        repo, number = item["repo"], item["number"]
        check_unclaimed(json.loads(gh("api", f"repos/{repo}/issues/{number}")))
        endpoint = f"repos/{repo}/issues/{number}/dependencies/blocked_by"
        install_dependencies(item, numbers, endpoint)
        publish_body(item, numbers)
        release_item(item, endpoint)
