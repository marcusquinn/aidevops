#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
"""Byte-exact content evidence for deterministic routine PR admission.

Callers fetch each blob from the Git blobs API by the object ID recorded in a
complete tree pinned to the verified commit, so the content is bound to that
regular tree entry without re-deriving Git object IDs here.
"""
import base64
import json
from pathlib import Path
import re
import sys

BADGE_START = b"<!-- aidevops:badges:start -->"
BADGE_END = b"<!-- aidevops:badges:end -->"


def blob(value):
    """Decode a Git blob API response; reject truncated or non-base64 evidence."""
    if value is None:
        return b""
    if value.get("encoding") != "base64":
        raise ValueError("not a complete base64 blob")
    data = base64.b64decode("".join(value["content"].split()), validate=True)
    if len(data) != value["size"]:
        raise ValueError("blob evidence truncated")
    return data


def outside_badges(data, required):
    if data.count(BADGE_START) == data.count(BADGE_END) == 0 and not required:
        return data
    if data.count(BADGE_START) != 1 or data.count(BADGE_END) != 1:
        raise ValueError("ambiguous badge block")
    start, end = data.index(BADGE_START), data.index(BADGE_END)
    if end < start:
        raise ValueError("reversed badge block")
    return data[:start] + data[end + len(BADGE_END):]


def validate_readme(head, base):
    head_outside = outside_badges(head, True)
    base_outside = outside_badges(base, False)
    if BADGE_START not in base and BADGE_END not in base:
        # Match inject_block's first-install whitespace exactly, without
        # stripping/normalising any existing README content.
        block = head[head.index(BADGE_START):head.index(BADGE_END) + len(BADGE_END)]
        heading = re.search(rb"^# .*\n", base, re.M)
        if heading:
            offset = heading.end()
            expected = base[:offset] + b"\n" + block + b"\n" + base[offset:]
        else:
            expected = block + b"\n\n" + base
        if head != expected:
            raise ValueError("README differs from deterministic block insertion")
    elif head_outside != base_outside:
        raise ValueError("README changed outside badge block")
    return ""


def validate_workflow(head, template):
    # Reproduce the installer's two substitutions, including optional tag comment.
    match = re.search(rb"^      aidevops_ref: ([0-9a-f]{40})(?: # [^\r\n]+)?$", head, re.M)
    if not match:
        raise ValueError("workflow must pin a commit")
    ref_line = match.group(0).split(b": ", 1)[1]
    expected = Path(template).read_bytes()
    expected = re.sub(rb"^([ \t]*uses:.*loc-badge-reusable.yml)@[^\s]+.*$",
                      lambda m: m[1] + b"@" + ref_line, expected, flags=re.M)
    expected = re.sub(rb"^(      aidevops_ref:).*$",
                      lambda m: m[1] + b" " + ref_line, expected, flags=re.M)
    if head != expected:
        raise ValueError("workflow differs from canonical template")
    return match[1].decode()


def validate(path, template, evidence):
    head, base = blob(evidence["head"]), blob(evidence["base"])
    if path == "README.md":
        return validate_readme(head, base)
    return validate_workflow(head, template)


# --- sync-workflows (GH#39793) ------------------------------------------------
# A pure port of sync-workflows-helper.sh _render_template_with_target,
# _inject_mirror_read_secret, _inject_runner_in_content and
# _rewrite_content_branch_filter. It only reads bytes: nothing from the PR is
# executed, and the template comes from a main-reachable aidevops commit.
SYNC_WORKFLOWS = {
    "issue-sync", "review-bot-gate", "review-bot-gate-fork-review",
    "maintainer-gate", "loc-badge", "issue-triage-gate",
}
# Workflows whose reusable fetches framework helpers from the configured repo.
SYNC_HELPER_WORKFLOWS = {
    "issue-sync", "review-bot-gate", "review-bot-gate-fork-review",
    "loc-badge", "issue-triage-gate",
}
DEFAULT_REPO = b"marcusquinn/aidevops"
REPO_RE = re.compile(rb"^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$")
RUNNER_RE = re.compile(rb"^[A-Za-z0-9._-]+$")
BRANCH_RE = re.compile(rb"^[A-Za-z0-9._/-]+$")
PIN = rb"[0-9a-f]{40}(?: # v[0-9]+\.[0-9]+\.[0-9]+)?"
REF_RE = re.compile(rb"^[ \t]*uses:[ \t]*[^ \t@]+/\.github/workflows/[^ \t@]+@(" + PIN + rb")$", re.M)
READ_SECRET = (b"      AIDEVOPS_READ_TOKEN: "
               b"${{ secrets.AIDEVOPS_READ_TOKEN }}")


def sync_ref(head):
    """Return the one 40-hex framework ref (with optional release comment) that
    every executable `uses:` line pins. aidevops_ref lines, when a template has
    them, are covered by the exact re-render comparison."""
    found = set(REF_RE.findall(head))
    if len(found) != 1:
        raise ValueError("workflow must pin one framework commit on every uses line")
    return found.pop()


def inject_mirror(text, repo):
    if not re.search(rb"^      aidevops_ref:", text, re.M):
        raise ValueError("mirror render needs aidevops_ref")
    text = re.sub(rb"^(      aidevops_ref:.*)$",
                  lambda m: b"      aidevops_repository: " + repo + b"\n" + m[1],
                  text, flags=re.M)
    blocks = len(re.findall(rb"^    secrets:( inherit)?$", text, re.M))
    tokens = len(re.findall(rb"^      AIDEVOPS_READ_TOKEN:", text, re.M))
    if blocks > 0 and tokens >= blocks:
        return text
    pattern = rb"^    secrets: inherit$" if re.search(
        rb"^    secrets: inherit$", text, re.M) else rb"^    secrets:$"
    return re.sub(pattern, lambda m: b"    secrets:\n" + READ_SECRET, text, flags=re.M)


def inject_runner(text, runner):
    if re.search(rb"^    with:$", text, re.M):
        return re.sub(rb"^(    with:)$",
                      lambda m: m[1] + b"\n      runner: " + runner, text, flags=re.M)
    return re.sub(rb"^(    uses:[ \t]*[^ \t]+/\.github/workflows/.+)$",
                  lambda m: m[1] + b"\n    with:\n      runner: " + runner,
                  text, flags=re.M)


def render_sync(template, name, ref, policy, base):
    repo = policy["repo"].encode()
    if not REPO_RE.match(repo):
        raise ValueError("invalid reusable repository policy")
    runner = policy.get("runner")
    if runner is None:
        previous = re.search(rb"^      runner: (.+)$", base or b"", re.M)
        runner = previous[1].decode() if previous else None
    text = re.sub(rb"^([ \t]*uses:[ \t]*)marcusquinn/aidevops(/\.github/workflows/[^@\s]+)@\S+",
                  lambda m: m[1] + repo + m[2] + b"@" + ref, template, flags=re.M)
    text = re.sub(rb"marcusquinn/aidevops(/\.github/workflows/\S+)",
                  lambda m: repo + m[1], text)
    text = re.sub(rb"^(      aidevops_ref:).*$", lambda m: m[1] + b" " + ref, text, flags=re.M)
    if repo != DEFAULT_REPO and name in SYNC_HELPER_WORKFLOWS:
        text = inject_mirror(text.rstrip(b"\n") + b"\n", repo)
    text = text.rstrip(b"\n") + b"\n"
    if runner is not None:
        runner = runner.encode() if isinstance(runner, str) else runner
        if not RUNNER_RE.match(runner):
            raise ValueError("runner policy is not a plain label")
        text = inject_runner(text, runner).rstrip(b"\n") + b"\n"
    branch = policy["base_branch"].encode()
    if not BRANCH_RE.match(branch):
        raise ValueError("unsupported base branch name")
    if branch != b"main":
        text = re.sub(rb"^([ \t]+branches:) \[main\]$",
                      lambda m: m[1] + b" [" + branch + b"]", text, flags=re.M)
    return text.rstrip(b"\n") + b"\n"


def validate_sync(name, evidence):
    if name not in SYNC_WORKFLOWS:
        raise ValueError("unknown managed workflow")
    head = blob(evidence["head"])
    base = blob(evidence["base"]) if evidence.get("base") is not None else None
    ref = sync_ref(head)
    if render_sync(blob(evidence["template"]), name, ref, evidence["policy"], base) != head:
        raise ValueError("workflow differs from exact trusted re-render")
    return ref[:40].decode()


if __name__ == "__main__":
    try:
        if sys.argv[1] == "--sync-ref":
            print(sync_ref(blob(json.load(sys.stdin)["head"]))[:40].decode())
        elif sys.argv[1] == "--sync-validate":
            print(validate_sync(sys.argv[2], json.load(sys.stdin)))
        else:
            print(validate(sys.argv[1], sys.argv[2], json.load(sys.stdin)))
    except (ValueError, KeyError, TypeError, OSError, IndexError) as error:
        print(f"Routine content refused: {error}", file=sys.stderr)
        sys.exit(1)
