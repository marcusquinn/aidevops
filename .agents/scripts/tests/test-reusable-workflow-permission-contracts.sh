#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# Verify every canonical reusable-workflow caller grants its exact permission union.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)" || exit 1

python3 - "$REPO_ROOT" <<'PYEOF'
from __future__ import annotations

import pathlib
import os
import re
import shlex
import subprocess
import sys
import tempfile

try:
    import yaml
except ImportError as exc:
    raise SystemExit("FAIL: PyYAML is required for workflow permission contract tests") from exc


ROOT = pathlib.Path(sys.argv[1])
CALLER_DIR = ROOT / ".agents" / "templates" / "workflows"
REUSABLE_DIR = ROOT / ".github" / "workflows"
REMOTE_USES_PATTERN = re.compile(
    r"^marcusquinn/aidevops/\.github/workflows/([^/@]+\.ya?ml)@"
)
LOCAL_USES_PATTERN = re.compile(r"^\./\.github/workflows/([^/]+\.ya?ml)$")
LEVELS = {"none": 0, "read": 1, "write": 2}


def load_mapping(path: pathlib.Path, revision: str | None = None) -> dict:
    if revision is None:
        value = yaml.safe_load(path.read_text(encoding="utf-8"))
    else:
        result = subprocess.run(
            ["git", "show", f"{revision}:{path.relative_to(ROOT).as_posix()}"],
            cwd=ROOT, check=True, capture_output=True, text=True,
        )
        value = yaml.safe_load(result.stdout)
    if not isinstance(value, dict):
        raise ValueError(f"{path}: workflow root must be a mapping")
    return value


def explicit_permissions(value: object, context: str) -> dict[str, str]:
    if value is None:
        raise ValueError(f"{context}: permissions must be an explicit mapping")
    if not isinstance(value, dict):
        raise ValueError(f"{context}: permissions must be an explicit mapping")
    normalized: dict[str, str] = {}
    for permission, level in value.items():
        if not isinstance(permission, str) or level not in LEVELS:
            raise ValueError(f"{context}: unsupported permission {permission}={level}")
        if level != "none":
            normalized[permission] = level
    return normalized


def reusable_path_for_uses(
    uses: str, reusable_dir: pathlib.Path = REUSABLE_DIR
) -> pathlib.Path | None:
    local_match = LOCAL_USES_PATTERN.match(uses)
    if local_match:
        return reusable_dir / local_match.group(1)
    remote_match = REMOTE_USES_PATTERN.match(uses)
    if remote_match:
        return reusable_dir / remote_match.group(1)
    return None


def merge_permission_union(
    target: dict[str, str], additions: dict[str, str]
) -> None:
    for permission, level in additions.items():
        if LEVELS[level] > LEVELS.get(target.get(permission, "none"), 0):
            target[permission] = level


def reusable_permission_union(
    workflow_path: pathlib.Path,
    reusable_dir: pathlib.Path = REUSABLE_DIR,
    active: set[pathlib.Path] | None = None,
    revision: str | None = None,
) -> dict[str, str]:
    resolved_path = workflow_path.resolve()
    active = set() if active is None else active
    if resolved_path in active:
        raise ValueError(f"{workflow_path}: recursive reusable-workflow cycle")
    active.add(resolved_path)
    workflow = load_mapping(workflow_path, revision)
    context = str(workflow_path)
    top = (
        explicit_permissions(workflow["permissions"], f"{context}: top level")
        if "permissions" in workflow
        else None
    )
    required: dict[str, str] = {}
    jobs = workflow.get("jobs", {}) or {}
    if not isinstance(jobs, dict) or not jobs:
        raise ValueError(f"{context}: jobs must be a non-empty mapping")
    try:
        for job_name, job in jobs.items():
            if not isinstance(job, dict):
                raise ValueError(f"{context}: job {job_name} must be a mapping")
            permissions = explicit_permissions(
                job.get("permissions") if "permissions" in job else top,
                f"{context}: job {job_name}",
            )
            merge_permission_union(required, permissions)
            uses = job.get("uses")
            if isinstance(uses, str):
                nested_path = reusable_path_for_uses(uses, reusable_dir)
                if nested_path is not None:
                    nested_required = reusable_permission_union(
                        nested_path, reusable_dir, active, revision
                    )
                    if permissions != nested_required:
                        raise ValueError(
                            f"{context}: job {job_name} permissions={permissions}; "
                            f"nested_union={nested_required} from {nested_path.name}"
                        )
                    merge_permission_union(required, nested_required)
        return required
    finally:
        active.remove(resolved_path)


def discover_caller_paths(
    caller_dir: pathlib.Path, workflow_dir: pathlib.Path
) -> list[pathlib.Path]:
    return sorted(
        set(caller_dir.glob("*-caller.yml"))
        | set(caller_dir.glob("*-caller.yaml"))
        | set(workflow_dir.glob("*.yml"))
        | set(workflow_dir.glob("*.yaml"))
    )


def assert_discovery_contract() -> None:
    with tempfile.TemporaryDirectory() as temp_dir:
        root = pathlib.Path(temp_dir)
        caller_dir = root / "callers"
        workflow_dir = root / "workflows"
        caller_dir.mkdir()
        workflow_dir.mkdir()
        yaml_caller = caller_dir / "fixture-caller.yaml"
        nested_reusable = workflow_dir / "outer-reusable.yaml"
        inner_reusable = workflow_dir / "inner-reusable.yaml"
        yaml_caller.write_text("jobs: {}\n", encoding="utf-8")
        nested_reusable.write_text(
            "jobs:\n  nested:\n    permissions:\n      issues: read\n"
            "    uses: ./.github/workflows/inner-reusable.yaml\n",
            encoding="utf-8",
        )
        inner_reusable.write_text(
            "jobs:\n  leaf:\n    permissions:\n      issues: read\n    runs-on: ubuntu-latest\n    steps: []\n",
            encoding="utf-8",
        )
        discovered = set(discover_caller_paths(caller_dir, workflow_dir))
        if yaml_caller not in discovered or nested_reusable not in discovered:
            raise AssertionError(
                "caller discovery must include .yaml and reusable-to-reusable workflows"
            )
        nested_union = reusable_permission_union(nested_reusable, workflow_dir)
        if nested_union != {"issues": "read"}:
            raise AssertionError(
                f"nested reusable permission union was not propagated: {nested_union}"
            )
        implicit_reusable = workflow_dir / "implicit-reusable.yml"
        implicit_reusable.write_text(
            "jobs:\n  leaf:\n    runs-on: ubuntu-latest\n    steps: []\n",
            encoding="utf-8",
        )
        try:
            reusable_permission_union(implicit_reusable, workflow_dir)
        except ValueError as exc:
            if "permissions must be an explicit mapping" not in str(exc):
                raise
        else:
            raise AssertionError("implicit repository-default permissions were accepted")
        nested_reusable.write_text(
            "jobs:\n  nested:\n    permissions:\n      contents: read\n"
            "    uses: ./.github/workflows/inner-reusable.yaml\n",
            encoding="utf-8",
        )
        try:
            reusable_permission_union(nested_reusable, workflow_dir)
        except ValueError:
            pass
        else:
            raise AssertionError("insufficient intermediate permissions were accepted")


def permission_increased(before: dict[str, str], after: dict[str, str]) -> bool:
    return any(LEVELS[level] > LEVELS.get(before.get(key, "none"), 0)
               for key, level in after.items())


def names_rollout(body: str, name: str) -> bool:
    # Parse only text; PR bodies are untrusted data, never shell input.
    for line in body.splitlines():
        try:
            words = shlex.split(line.replace("`", " "))
        except ValueError:
            # Ordinary prose can contain unmatched quotes (for example repo's).
            # Preserve quoted single-token arguments without executing shell input.
            words = [
                word[1:-1] if len(word) >= 2 and word[0] in "\"'" and word[-1] == word[0]
                else word
                for word in line.replace("`", " ").split()
            ]
        for index, word in enumerate(words):
            if pathlib.PurePosixPath(word).name not in (
                "sync-workflows", "sync-workflows-helper.sh"
            ):
                continue
            args = words[index + 1:]
            if "--apply" in args and any(
                arg == "--workflow" and offset + 1 < len(args)
                and args[offset + 1] == name
                for offset, arg in enumerate(args)
            ):
                return True
    return False


def rollout_failures(name: str, callers: list[str], changed: set[str], body: str) -> list[str]:
    failures = [f"{name}: permission increase requires updating {caller}"
                for caller in callers if caller not in changed]
    if not callers:
        failures.append(f"{name}: permission increase has no matching caller template")
    if not names_rollout(body, name):
        failures.append(
            f"{name}: permission increase requires a named rollout in the PR body: "
            f"aidevops sync-workflows --apply --workflow {name}. "
            "Put the command on its own line. After editing the PR body, close/reopen "
            "the PR or push a new commit to re-run the check; rerunning an existing "
            "run uses the original PR body."
        )
    return failures


def assert_rollout_contract() -> None:
    caller = ".agents/templates/workflows/fixture-caller.yml"
    command = "`aidevops sync-workflows --apply --workflow fixture`"
    with tempfile.TemporaryDirectory() as temp_dir:
        reusable = pathlib.Path(temp_dir) / "fixture-reusable.yml"
        existing_job = (
            "jobs:\n  existing:\n    permissions:\n"
            "      contents: write\n      actions: read\n    steps: []\n"
        )
        reusable.write_text(existing_job, encoding="utf-8")
        before = reusable_permission_union(reusable)
        for extra_permissions in (
            "      contents: read\n",
            "      contents: write\n      actions: read\n",
        ):
            reusable.write_text(
                existing_job + "  added:\n    permissions:\n" + extra_permissions
                + "    steps: []\n", encoding="utf-8",
            )
            after = reusable_permission_union(reusable)
            assert before == after
            assert not permission_increased(before, after)
        for extra_permissions in ("      actions: write\n", "      issues: read\n"):
            reusable.write_text(
                existing_job + "  added:\n    permissions:\n" + extra_permissions
                + "    steps: []\n", encoding="utf-8",
            )
            after = reusable_permission_union(reusable)
            assert permission_increased(before, after)
            failures = rollout_failures("fixture", [caller], set(), "none")
            assert len(failures) == 2  # Both caller update and named rollout are required.
            assert not rollout_failures("fixture", [caller], {caller}, command)
    assert permission_increased({"contents": "read"}, {"contents": "write"})
    assert permission_increased({}, {"actions": "read"})
    assert not permission_increased({"contents": "write"}, {"contents": "read"})
    assert not rollout_failures("fixture", [caller], {caller}, command)
    assert rollout_failures("fixture", [caller], set(), command)
    assert rollout_failures("fixture", [caller], {caller}, "roll out later")
    assert rollout_failures("fixture", [caller], {caller}, command.replace("fixture", "other"))
    assert rollout_failures("fixture", [caller], {caller}, command.replace("--apply", "--json"))
    assert names_rollout("sync-workflows-helper.sh --workflow fixture --apply", "fixture")
    prose_command = f"each repo's main: {command}"
    assert names_rollout(prose_command, "fixture")
    assert not rollout_failures("fixture", [caller], {caller}, prose_command)
    assert not names_rollout(prose_command.replace("--workflow fixture", "--workflow other"), "fixture")
    assert not names_rollout(prose_command.replace("--apply", "--json"), "fixture")
    assert names_rollout('aidevops sync-workflows --apply --workflow "fixture"', "fixture")
    for quote in ('"', "'"):
        quoted_prose = prose_command.replace("workflow fixture", f"workflow {quote}fixture{quote}")
        assert names_rollout(quoted_prose, "fixture")
        assert not rollout_failures("fixture", [caller], {caller}, quoted_prose)
        assert not names_rollout(quoted_prose.replace("fixture", "other"), "fixture")
        assert not names_rollout(quoted_prose.replace("--apply", "--json"), "fixture")


def check_permission_rollouts() -> list[str]:
    base = os.environ.get("BASE_SHA", "")
    head = os.environ.get("HEAD_SHA", "")
    if not base and not head:
        print("SKIP permission rollout diff (BASE_SHA/HEAD_SHA not supplied)")
        return []
    if not all(re.fullmatch(r"[0-9a-fA-F]{40}", ref) for ref in (base, head)):
        return ["permission rollout diff requires full BASE_SHA and HEAD_SHA commit IDs"]
    base = subprocess.run(
        ["git", "merge-base", base, head], cwd=ROOT,
        check=True, capture_output=True, text=True,
    ).stdout.strip()
    changed = set(subprocess.run(
        ["git", "diff", "--name-only", base, head, "--"], cwd=ROOT,
        check=True, capture_output=True, text=True,
    ).stdout.splitlines())
    base_paths = set(subprocess.run(
        ["git", "ls-tree", "-r", "--name-only", base, "--", ".github/workflows"],
        cwd=ROOT, check=True, capture_output=True, text=True,
    ).stdout.splitlines())
    head_paths = subprocess.run(
        ["git", "ls-tree", "-r", "--name-only", head, "--",
         ".github/workflows", ".agents/templates/workflows"],
        cwd=ROOT, check=True, capture_output=True, text=True,
    ).stdout.splitlines()
    reusables = [ROOT / path for path in head_paths
                 if re.fullmatch(r"\.github/workflows/[^/]+-reusable\.ya?ml", path)]
    templates = [ROOT / path for path in head_paths
                 if re.fullmatch(r"\.agents/templates/workflows/[^/]+-caller\.ya?ml", path)]
    failures: list[str] = []
    for path in reusables:
        relative = path.relative_to(ROOT).as_posix()
        if relative not in base_paths:
            continue  # New workflows have no installed callers to migrate.
        before = reusable_permission_union(path, revision=base)
        after = reusable_permission_union(path, revision=head)
        # Installed callers already grant the union, so only union growth needs a rollout.
        if not permission_increased(before, after):
            continue
        callers = []
        for caller in templates:
            jobs = load_mapping(caller, head).get("jobs", {}) or {}
            if any(reusable_path_for_uses(job.get("uses", "")) == path
                   for job in jobs.values() if isinstance(job, dict)):
                callers.append(caller.relative_to(ROOT).as_posix())
        # Roll out the installed caller, not an internal reusable filename
        # (issue-sync also calls issue-sync-artifact-maintenance-reusable).
        body = os.environ.get("PR_BODY", "")
        if not callers:
            failures.extend(rollout_failures(path.stem.removesuffix("-reusable"), [], changed, body))
        for caller in callers:
            name = pathlib.PurePosixPath(caller).stem.removesuffix("-caller")
            failures.extend(rollout_failures(name, [caller], changed, body))
    return failures


def main() -> int:
    checked = 0
    failures: list[str] = []
    assert_discovery_contract()
    assert_rollout_contract()
    try:
        failures.extend(check_permission_rollouts())
    except (OSError, ValueError, subprocess.CalledProcessError, yaml.YAMLError) as exc:
        failures.append(f"permission rollout diff: {exc}")
    caller_paths = discover_caller_paths(CALLER_DIR, REUSABLE_DIR)
    for caller_path in caller_paths:
        try:
            caller = load_mapping(caller_path)
            caller_top = (
                explicit_permissions(
                    caller["permissions"], f"{caller_path}: top level"
                )
                if "permissions" in caller
                else None
            )
            jobs = caller.get("jobs", {}) or {}
            if not isinstance(jobs, dict):
                raise ValueError(f"{caller_path}: jobs must be a mapping")
            for job_name, job in jobs.items():
                if not isinstance(job, dict):
                    continue
                uses = job.get("uses")
                if not isinstance(uses, str):
                    continue
                reusable_path = reusable_path_for_uses(uses)
                if reusable_path is None:
                    continue
                required = reusable_permission_union(reusable_path)
                granted = explicit_permissions(
                    job.get("permissions") if "permissions" in job else caller_top,
                    f"{caller_path}: calling job {job_name}",
                )
                checked += 1
                if granted != required:
                    failures.append(
                        f"{caller_path.name}:{job_name}: caller={granted}; "
                        f"required_union={required} from {reusable_path.name}"
                    )
                else:
                    print(f"PASS {caller_path.name} -> {reusable_path.name}")
        except (OSError, ValueError, yaml.YAMLError) as exc:
            failures.append(str(exc))

    if checked == 0:
        failures.append("no canonical reusable-workflow caller pairs were found")
    if failures:
        for failure in failures:
            print(f"FAIL {failure}", file=sys.stderr)
        return 1
    print(f"PASS all {checked} reusable-workflow permission contract(s)")
    return 0


raise SystemExit(main())
PYEOF
