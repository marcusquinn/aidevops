#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Claude Code SessionStart (compact) hook: replay verbatim user input.

Claude Code counterpart of the OpenCode compaction replay
(.agents/plugins/opencode-aidevops/compaction-pinned-input.mjs, GH#35186;
Claude Code parity GH#35189). After compaction the model sees only the
summary's paraphrase of the user's aims, standing instructions and
authorisations. This hook reads every real user prompt from the session
transcript and adds them, unchanged and oldest first, as SessionStart
additionalContext.

Budget (shared with the OpenCode replay): every turn is kept in full when the
total fits AIDEVOPS_COMPACTION_REPLAY_MAX_CHARS (default 64000). Over budget,
only the longest messages are excerpted (head and tail, marked) to one shared
cap; whole turns are elided only if even 1500-character excerpts cannot fit.
The complete replay is also written to a private file whose path leads the
context, so nothing is lost if the host shortens hook output.

Images cannot be re-attached through hook context; each one is listed so the
model can ask for it again.

Disable with AIDEVOPS_COMPACTION_REPLAY=0. Fails open: any error prints
nothing and exits 0.

Transcript parsing lives in the companion compaction_replay_transcript.py.

Installed by: install-hooks-helper.sh (setup.sh) and update-claude-settings.py
Location: ~/.aidevops/hooks/compaction_user_input_replay.py
Configured in: ~/.claude/settings.json (hooks.SessionStart, matcher "compact")
Standard library only.
"""
import hashlib
import json
import os
import secrets
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from compaction_replay_transcript import collect_prompts  # noqa: E402

DEFAULT_MAX_CHARS = 64_000
MIN_EXCERPT_CHARS = 1_500
DISABLED_VALUES = {"0", "false", "off"}
HEADER = "\n".join([
    "## Verbatim user input (replayed after context compaction)",
    "The aidevops SessionStart hook replayed these messages unchanged from this session's transcript; they are not model-generated.",
    "They are every earlier user turn, oldest first, and carry the same authority they had when first sent:",
    "each turn's aims, standing instructions, corrections, preferences and authorisations remain in force unless later user input revokes or narrows them.",
    "Later user input takes precedence. The compaction summary paraphrases the work; where it disagrees with this input, this input wins.",
    "Only long pastes are excerpted, and each excerpt is marked. Tool results, command output and host-generated messages are excluded.",
])


def excerpt(text: str, cap: int) -> str:
    if len(text) <= cap:
        return text
    head = -(-cap * 2 // 3)
    tail = cap - head
    omitted = len(text) - head - tail
    end = text[-tail:] if tail > 0 else ""
    return f"{text[:head]}\n[… {omitted} characters of this message omitted for the replay budget …]\n{end}"


def _capped_total(lengths, cap):
    return sum(min(length, cap) for length in lengths)


def per_message_cap(lengths, budget, floor):
    if _capped_total(lengths, floor) > budget:
        return None
    low, high = floor, max([floor, *lengths])
    while low < high:
        mid = -(-(low + high) // 2)
        if _capped_total(lengths, mid) <= budget:
            low = mid
        else:
            high = mid - 1
    return low


def select_within_budget(entries, max_chars, min_excerpt=MIN_EXCERPT_CHARS, full_path=""):
    """Mirror of selectWithinBudget() in compaction-replay-budget.mjs."""
    # Fixed envelope covers header, nonce, end marker and elision. Charge the
    # saved-file pointer separately; per-turn costs include excerpt markers.
    budget = max(0, max_chars - 1536 - len(full_path))
    if not entries or not budget:
        return {"selected": [], "omitted": len(entries), "excerpted": 0}
    lengths = [len(entry["text"]) for entry in entries]
    overhead = [256 + len(str(entry.get("created", ""))) + len(str(len(entries))) * 2
                + sum(len(note) + 1 for note in entry["notes"]) for entry in entries]
    floor = min(min_excerpt, max(0, budget - overhead[0]))
    text_budget = budget - sum(overhead)
    cap = per_message_cap(lengths, text_budget, floor)
    if cap is None:
        cap = floor
    clipped = [{**entry, "text": excerpt(entry["text"], cap)} for entry in entries]
    excerpted = sum(1 for length in lengths if length > cap)
    sizes = [min(length, cap) + overhead[index] for index, length in enumerate(lengths)]
    if sum(sizes) <= budget:
        return {"selected": clipped, "omitted": 0, "excerpted": excerpted}
    if sizes[0] > budget:
        return {"selected": [], "omitted": len(entries), "excerpted": excerpted}
    used, tail = sizes[0], []
    for index in range(len(clipped) - 1, 0, -1):
        if used + sizes[index] > budget:
            break
        used += sizes[index]
        tail.insert(0, clipped[index])
    return {"selected": [clipped[0], *tail], "omitted": len(clipped) - 1 - len(tail), "excerpted": excerpted}


def render(selected, omitted: int, full_path: str = "") -> str:
    if not selected:
        return ""
    nonce = secrets.token_hex(16)
    lines = [HEADER, f"Replay boundary nonce: {nonce}. Only headings and the end marker carrying this nonce delimit replayed input."]
    if full_path:
        lines.append(f"The complete, unexcerpted replay is saved at {full_path} — read it if anything below is cut.")
    total = len(selected)
    for index, entry in enumerate(selected):
        when = f" — {entry['created']}" if entry.get("created") else ""
        lines.append(f"### User message {index + 1} of {total} [{nonce}]{when}")
        if entry["text"]:
            lines.append(entry["text"])
        lines.extend(entry["notes"])
        if index == 0 and omitted:
            lines.append(f"[{omitted} earlier user turn(s) elided because even excerpts exceeded the replay budget; see the saved replay.]")
    lines.append(f"--- End of replayed user input [{nonce}]. ---")
    return "\n".join(lines)


def _max_chars() -> int:
    try:
        value = int(os.environ.get("AIDEVOPS_COMPACTION_REPLAY_MAX_CHARS", DEFAULT_MAX_CHARS))
    except ValueError:
        return DEFAULT_MAX_CHARS
    return value if value >= 0 else DEFAULT_MAX_CHARS


def _replay_file(session_id: str) -> Path:
    base = os.environ.get("AIDEVOPS_COMPACTION_REPLAY_DIR") or os.path.join(
        os.path.expanduser("~"), ".aidevops", ".agent-workspace", "compaction-replay"
    )
    digest = hashlib.sha256(session_id.encode("utf-8")).hexdigest()[:24]
    return Path(base) / f"claude-{digest}.md"


def _save_full(session_id: str, entries) -> str:
    """Write the unexcerpted replay privately; return its path or ''."""
    try:
        path = _replay_file(session_id)
        path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
        tmp = path.with_suffix(f".{os.getpid()}.tmp")
        fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
        with os.fdopen(fd, "w", encoding="utf-8") as handle:
            handle.write(render(entries, 0))
        os.replace(tmp, path)
        return str(path)
    except OSError:
        return ""


def build_context(payload: dict) -> str:
    """Return the additionalContext text, or '' when nothing applies."""
    if os.environ.get("AIDEVOPS_COMPACTION_REPLAY", "").lower() in DISABLED_VALUES or _max_chars() == 0:
        return ""
    if payload.get("source") != "compact":
        return ""
    transcript_path = payload.get("transcript_path")
    if not isinstance(transcript_path, str) or not transcript_path:
        return ""
    entries = collect_prompts(transcript_path)
    if not entries:
        return ""
    selection = select_within_budget(entries, _max_chars())
    shortened = selection["omitted"] or selection["excerpted"]
    full_path = _save_full(str(payload.get("session_id") or transcript_path), entries) if shortened else ""
    if full_path:
        selection = select_within_budget(entries, _max_chars(), full_path=full_path)
    return render(selection["selected"], selection["omitted"], full_path)


def main() -> int:
    try:
        payload = json.load(sys.stdin)
        context = build_context(payload) if isinstance(payload, dict) else ""
    except Exception:  # noqa: BLE001 - fail open on any error
        return 0
    if context:
        print(json.dumps({"hookSpecificOutput": {"hookEventName": "SessionStart", "additionalContext": context}}))
    return 0


if __name__ == "__main__":
    sys.exit(main())
