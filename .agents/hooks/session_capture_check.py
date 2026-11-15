# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""GH#35121 Capture Check for the Claude Code Stop hook.

Companion module of session_continuation_stop.py (installed alongside it by
install-hooks-helper.sh). Tracks files changed by this session's edit tools
and, when a closeout asks the user for nothing, reports which of them remain
uncommitted using live `git status` on those paths only. Unrelated dirty files
never count; every Git failure is skipped (fail-open). Never commits anything.

Closeout detection is ported from session-continuation-utils.mjs
(isUnaskedCloseout / isExplicitCompletionClaim); keep both in sync.
Standard library only.
"""
import os
import re
import subprocess
from pathlib import Path

WHAT_NEXT_RE = re.compile(r"\bWhat next\b", re.IGNORECASE)
NOT_DONE_RE = re.compile(
    r"\b(?:not|isn't|is not|aren't|are not)\s+(?:done|complete|completed|finished)\b",
    re.IGNORECASE,
)
COMPLETION_RE = re.compile(
    r"(?:^|[.!?]\s+)(?:FULL_LOOP_COMPLETE\b"
    r"|(?:the\s+)?(?:task|work|implementation|objective|issue|request)\s+(?:is|has been)\s+"
    r"(?:now\s+)?(?:done|complete|completed|finished)"
    r"|(?:all|everything)\s+(?:is|has been)\s+(?:done|complete|completed|finished))",
    re.IGNORECASE | re.MULTILINE,
)
EDIT_TOOLS = {"Edit", "Write", "MultiEdit", "NotebookEdit"}
MAX_EDITED_PATHS = 200
MAX_GIT_ROOTS = 8
GIT_TIMEOUT_SECONDS = 3
GIT_ERRORS = (OSError, subprocess.SubprocessError)


def record_edit(name, tool_input, edits: set) -> None:
    """Remember the file path of one successful-looking edit tool call."""
    if name not in EDIT_TOOLS or not isinstance(tool_input, dict):
        return
    path = tool_input.get("file_path") or tool_input.get("notebook_path")
    if isinstance(path, str) and path.strip() and len(edits) < MAX_EDITED_PATHS:
        edits.add(path.strip())


def is_unasked_closeout(stripped_text: str) -> bool:
    """A What next block or completion claim (code already stripped).

    The caller must first exclude texts that hand back to the user.
    """
    if not stripped_text.strip():
        return False
    completion = not NOT_DONE_RE.search(stripped_text) and COMPLETION_RE.search(stripped_text)
    return bool(WHAT_NEXT_RE.search(stripped_text) or completion)


def _git(cwd: str, args: list) -> str:
    return subprocess.run(
        ["git", "-C", cwd, *args],
        check=True,
        capture_output=True,
        text=True,
        timeout=GIT_TIMEOUT_SECONDS,
    ).stdout


def _root_of(directory: Path, cache: dict) -> str:
    if directory not in cache:
        try:
            cache[directory] = _git(str(directory), ["rev-parse", "--show-toplevel"]).strip()
        except GIT_ERRORS:
            cache[directory] = ""
    return cache[directory]


def _group_by_root(paths, cwd: str) -> dict:
    """Map each Git root to the repository-relative session paths inside it."""
    by_root: dict = {}
    cache: dict = {}
    for raw in sorted(paths):
        path = Path(cwd or ".", raw).expanduser()
        try:
            # Git reports canonical roots, so canonicalise (macOS /var -> /private/var).
            directory = path.parent.resolve(strict=True)
        except OSError:
            continue
        root = _root_of(directory, cache)
        if root and (root in by_root or len(by_root) < MAX_GIT_ROOTS):
            by_root.setdefault(root, []).append(os.path.relpath(directory / path.name, root))
    return by_root


def _changed_files(root: str, files: list) -> list:
    try:
        status = _git(root, ["status", "--porcelain=v1", "--untracked-files=all", "--", *files])
    except GIT_ERRORS:
        return []
    return [line[3:] for line in status.splitlines() if line.strip()]


def dirty_edits(paths, cwd: str) -> list:
    """Return [(root, [changed relative paths])] for roots with dirty session edits."""
    dirty = []
    for root, files in _group_by_root(paths, cwd).items():
        changed = _changed_files(root, files)
        if changed:
            dirty.append((root, changed))
    return dirty


def capture_reason(dirty: list) -> str:
    """One-sentence Capture Check nudge naming each root and its changes."""
    summary = "; ".join(
        f"{root} ({', '.join(files[:5])}{', …' if len(files) > 5 else ''})"
        for root, files in dirty
    )
    return (
        f"Your closeout asks for nothing but files this session edited remain "
        f"uncommitted in {summary}, so commit them if you hold commit authority, "
        "otherwise ask for bounded commit/PR approval under Needed from you, "
        "name each worktree's changes under Left to capture and keep Close at Not yet."
    )


def capture_block(edits: set, stripped_text: str, cwd: str):
    """Return the Capture Check reason, or None when nothing needs capturing."""
    if not edits or not is_unasked_closeout(stripped_text):
        return None
    dirty = dirty_edits(edits, cwd)
    return capture_reason(dirty) if dirty else None


# GH#37979: a numbered ask that only requests permission to file an issue,
# task or TODO. Ported to session-continuation-utils.mjs (asksFilingPermission).
NEEDED_BLOCK_RE = re.compile(
    r"Needed from you:.*?(?=Left to capture|\bClose(?: readiness)?:|\Z)",
    re.IGNORECASE | re.DOTALL,
)
NUMBERED_ASK_RE = re.compile(r"^[ \t]*(?:[-*][ \t]*)?\d+[.)][ \t]+", re.MULTILINE)
FILING_ASK_RE = re.compile(
    r"^\s*(?:[-*]\s*)?\d+[.)]\s*[*_]*\s*"
    r"(?:(?:should|shall|can|could|may) (?:I|we)|(?:do you )?want me to"
    r"|would you like me to|ok(?:ay)? to)?\s*"
    r"(?:file|capture|log|open|create|record|track)\s+(?:an?|the|another)?\s*"
    r"(?:(?:worker(?:-ready)?|follow-?up|local|actionable)\s+){0,3}"
    r"(?:issue|task|todo|ticket|follow-?up)s?\b",
    re.IGNORECASE | re.MULTILINE,
)
FILING_EXCLUDED_RE = re.compile(
    r"\bnot needed\b"
    r"|\b(?:and|then|also)\s+(?:also\s+)?(?:deploy|merge|release|publish|ship)\b"
    r"(?!\s+(?:pipelines?|process(?:es)?|workflows?|notes?|automation|tooling|scripts?|steps?"
    r"|docs?|documentation|system|infrastructure|checks?|gates?|jobs?|stages?|management|engineering)\b)"
    r"|\bor\s+(?:is|could|might)\s+(?:this|that|it)\s+(?:be\s+)?(?:expected|intended|normal)\b"
    r"|\bor\s+(?:is|are)\s+(?:it|this|that|they)\s+(?:unnecessary|not\s+(?:needed|necessary))\b"
    r"|\b(?:another|other|third-party|external|upstream)\s+(?:organi[sz]ations?|orgs?)\b"
    r"|\b(?:another|other|third[- ]party|external|upstream)\s+(?:repos?|repositories|repository)\b"
    r"|\b(?:secrets?|credentials?|spend|spending|billing)\b"
    r"|\bprivate[- ](?:data|repo)",
    re.IGNORECASE,
)
FILING_REASON = (
    "Your closeout asks permission to file an issue, task or TODO. Filing is "
    "already authorised: file it now under the capture rule in Framework Rules "
    "(deduplicate first) and cite the link in the body. Keep the ask only when "
    "the need itself is undecided, and then ask about the need."
)


def asks_filing_permission(text: str) -> bool:
    """GH#37979: the last Needed from you block only asks to file an item."""
    # Ignore fenced examples, but retain inline content for authority exclusions.
    text = re.sub(r"```.*?```", " ", text, flags=re.DOTALL)
    blocks = [match.group(0) for match in NEEDED_BLOCK_RE.finditer(text)]
    last = blocks[-1] if blocks else ""
    starts = [match.start() for match in NUMBERED_ASK_RE.finditer(last)]
    asks = [last[start:end] for start, end in zip(starts, starts[1:] + [len(last)])]
    return bool(asks) and not FILING_EXCLUDED_RE.search(last) and all(
        FILING_ASK_RE.match(re.sub(r"`[^`]*`", " ", ask)) for ask in asks
    )


def filing_block(text: str, state_file):
    """GH#37979: one-shot steer per session, tracked by a `.filing` marker
    beside the session's pathlib.Path `state_file`."""
    marker = state_file.with_suffix(".filing")
    if marker.exists() or not asks_filing_permission(text):
        return None
    marker.parent.mkdir(parents=True, exist_ok=True)
    marker.write_text("1")
    return FILING_REASON
