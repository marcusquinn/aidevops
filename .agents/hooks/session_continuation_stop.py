#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Claude Code Stop hook: keep going while tracked todos remain open.

Claude Code counterpart of the OpenCode session-continuation guard
(.agents/plugins/opencode-aidevops/session-continuation-guard.mjs). When an
interactive session tries to end its turn while the latest TodoWrite state
still has pending or in_progress items, the hook blocks the stop once with a
one-sentence nudge: continue the next open todo, or state the blocker.

Allow the stop (print nothing, exit 0) when any of these hold:
  - stop_hook_active is true (Claude Code is already continuing from a block)
  - the per-session block cap is reached (AIDEVOPS_STOP_HOOK_MAX_BLOCKS, default 2)
  - headless/worker session (pulse-supervised workers have their own watchdog)
  - AIDEVOPS_STOP_HOOK_DISABLE=1 (user override)
  - the latest user message asks to stop/pause
  - no TodoWrite state, or every todo is completed/cancelled
  - the final assistant message asks the user a question or reports a blocker
  - any input/transcript parse error (fail-open)

Installed by: install-hooks-helper.sh (setup.sh) and update-claude-settings.py
Location: ~/.aidevops/hooks/session_continuation_stop.py
Configured in: ~/.claude/settings.json (hooks.Stop)
Standard library only.
"""
import hashlib
import json
import os
import re
import sys
from pathlib import Path

DEFAULT_MAX_BLOCKS = 2
MAX_TRANSCRIPT_BYTES = 8 * 1024 * 1024
TERMINAL_STATUSES = {"completed", "cancelled", "canceled"}
WORKER_ENV_KEYS = (
    "FULL_LOOP_HEADLESS",
    "AIDEVOPS_HEADLESS",
    "OPENCODE_HEADLESS",
    "CLAUDE_HEADLESS",
    "HEADLESS",
    "GITHUB_ACTIONS",
)
TRUTHY = {"1", "true", "yes"}
USER_STOP_RE = re.compile(
    r"^\s*(?:please\s+)?(?:stop|pause|halt|abort|cancel|wait|hold on|enough)\b"
    r"|\b(?:stop|pause) (?:here|now|there|working|for now)\b"
    r"|\b(?:that's|that is) (?:all|enough)\b"
    r"|\b(?:don't|do not) (?:continue|proceed|keep going)\b"
    r"|\blet'?s (?:stop|pause)\b",
    re.IGNORECASE,
)
BLOCKER_RE = re.compile(
    r"\bBLOCKED\b|\bblocker\b|\bblocked (?:on|by)\b"
    r"|\b(?:need|needs|require|requires|waiting (?:for|on)) (?:your|user|human|maintainer)\b"
    r"|\b(?:cannot|can't|unable to) (?:continue|proceed)\b",
    re.IGNORECASE,
)


def _is_headless() -> bool:
    """Return True for worker/headless/SDK sessions."""
    if os.environ.get("AIDEVOPS_WORKER_ID", ""):
        return True
    if os.environ.get("CLAUDE_CODE_ENTRYPOINT", "").startswith("sdk"):
        return True
    return any(os.environ.get(key, "").lower() in TRUTHY for key in WORKER_ENV_KEYS)


def _content_text(content) -> str:
    """Return plain text from a message content string or block list."""
    if isinstance(content, str):
        return content
    if not isinstance(content, list):
        return ""
    parts = [
        str(block.get("text", ""))
        for block in content
        if isinstance(block, dict) and block.get("type") == "text"
    ]
    return "\n".join(parts)


def _scan_entry(entry, state: dict) -> None:
    """Update todos / last user text / last assistant text from one entry."""
    # Skip runtime meta entries and subagent (sidechain) turns.
    if not isinstance(entry, dict) or entry.get("isMeta") or entry.get("isSidechain"):
        return
    message = entry.get("message")
    if not isinstance(message, dict):
        return
    content = message.get("content")
    if entry.get("type") == "assistant":
        text = _content_text(content)
        if text.strip():
            state["assistant"] = text
        for block in content if isinstance(content, list) else []:
            if (
                isinstance(block, dict)
                and block.get("type") == "tool_use"
                and block.get("name") == "TodoWrite"
                and isinstance(block.get("input", {}).get("todos"), list)
            ):
                state["todos"] = block["input"]["todos"]
    elif entry.get("type") == "user":
        text = _content_text(content).strip()
        # Skip tool results and runtime-injected wrappers (<command-name>, reminders).
        if text and not text.startswith("<"):
            state["user"] = text


def _read_transcript(path: str) -> dict:
    """Parse the JSONL transcript; raise on unreadable input (caller fails open)."""
    state = {"todos": None, "user": "", "assistant": ""}
    transcript = Path(path).expanduser()
    size = transcript.stat().st_size
    with transcript.open("rb") as handle:
        if size > MAX_TRANSCRIPT_BYTES:
            handle.seek(size - MAX_TRANSCRIPT_BYTES)
            handle.readline()
        for raw in handle:
            try:
                _scan_entry(json.loads(raw), state)
            except (ValueError, TypeError, AttributeError):
                continue
    return state


def _open_todos(todos) -> list:
    if not isinstance(todos, list):
        return []
    return [
        str(todo.get("content") or todo.get("activeForm") or "unnamed todo")[:120]
        for todo in todos
        if isinstance(todo, dict)
        and str(todo.get("status", "")).lower() not in TERMINAL_STATUSES
    ]


def _hands_back_to_user(text: str) -> bool:
    """True when the final message asks a question or reports a blocker."""
    lines = [line.strip().rstrip("*_` ") for line in text.splitlines() if line.strip()]
    if any(line.endswith("?") for line in lines[-3:]):
        return True
    return bool(BLOCKER_RE.search(text))


def _state_file(session_id: str) -> Path:
    base = os.environ.get("AIDEVOPS_STOP_HOOK_STATE_DIR") or os.path.join(
        os.path.expanduser("~"), ".aidevops", ".agent-workspace", "tmp", "stop-hook"
    )
    digest = hashlib.sha256(session_id.encode("utf-8")).hexdigest()[:16]
    return Path(base) / f"{digest}.json"


def _block_count(session_id: str) -> int:
    try:
        return int(json.loads(_state_file(session_id).read_text()).get("blocks", 0))
    except (OSError, ValueError, TypeError, AttributeError):
        return 0


def _record_block(session_id: str, count: int) -> None:
    path = _state_file(session_id)
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps({"blocks": count}))


def _max_blocks() -> int:
    try:
        return max(0, int(os.environ.get("AIDEVOPS_STOP_HOOK_MAX_BLOCKS", DEFAULT_MAX_BLOCKS)))
    except ValueError:
        return DEFAULT_MAX_BLOCKS


def decide(payload: dict):
    """Return a block reason string, or None to allow the stop."""
    if payload.get("stop_hook_active") is True or _is_headless():
        return None
    if os.environ.get("AIDEVOPS_STOP_HOOK_DISABLE", "").lower() in TRUTHY:
        return None
    session_id = str(payload.get("session_id") or "")
    transcript_path = payload.get("transcript_path")
    if not session_id or not isinstance(transcript_path, str) or not transcript_path:
        return None
    blocks = _block_count(session_id)
    if blocks >= _max_blocks():
        return None
    state = _read_transcript(transcript_path)
    if USER_STOP_RE.search(state["user"]):
        return None
    open_todos = _open_todos(state["todos"])
    if not open_todos:
        return None
    final_text = payload.get("last_assistant_message")
    if not isinstance(final_text, str) or not final_text.strip():
        final_text = state["assistant"]
    if _hands_back_to_user(final_text):
        return None
    _record_block(session_id, blocks + 1)
    return (
        f"{len(open_todos)} todo(s) are still open, so continue with "
        f"\"{open_todos[0]}\", or state the blocker and list the remaining todos."
    )


def main() -> int:
    try:
        payload = json.load(sys.stdin)
        reason = decide(payload) if isinstance(payload, dict) else None
    except Exception:  # noqa: BLE001 - fail open on any error
        return 0
    if reason:
        print(json.dumps({"decision": "block", "reason": reason}))
    return 0


if __name__ == "__main__":
    sys.exit(main())
