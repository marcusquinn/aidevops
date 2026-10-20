#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Claude Code transcript reader for the compaction replay hook (GH#35189).

Companion of compaction_user_input_replay.py. Returns every real user prompt
from a Claude Code JSONL transcript, oldest first. Tool results, compaction
summaries, sidechains, meta entries and host-generated output are excluded;
slash-command and `!` bash wrappers are normalized to what the user typed.
Images become labels because hook context cannot re-attach them.

Installed alongside the hook in ~/.aidevops/hooks/. Standard library only.
"""
import json
import re
from pathlib import Path

COMMAND_RE = re.compile(r"<command-name>\s*(.*?)\s*</command-name>", re.DOTALL)
COMMAND_ARGS_RE = re.compile(r"<command-args>(.*?)</command-args>", re.DOTALL)
BASH_INPUT_RE = re.compile(r"^<bash-input>(.*?)</bash-input>\s*$", re.DOTALL)
# Slash-command wrappers start the block; tags quoted mid-text stay verbatim.
COMMAND_PREFIXES = ("<command-name>", "<command-message>")
HOST_WRAPPER_PREFIXES = (
    "<local-command-stdout>",
    "<local-command-stderr>",
    "<local-command-caveat>",
    "<bash-stdout>",
    "<bash-stderr>",
    "<system-reminder>",
    "<user-memory-input>",
)
EXCLUDED_FLAGS = ("isMeta", "isCompactSummary", "isSidechain", "isVisibleInTranscriptOnly", "toolUseResult")


def _content_blocks(content):
    if isinstance(content, str):
        return [{"type": "text", "text": content}]
    if not isinstance(content, list):
        return []
    return [block for block in content if isinstance(block, dict)]


def _command_text(stripped: str) -> str:
    command = COMMAND_RE.search(stripped)
    if not command:
        return ""
    args = COMMAND_ARGS_RE.search(stripped)
    return f"{command.group(1)} {args.group(1).strip() if args else ''}".strip()


def _prompt_text(text: str) -> str:
    """Normalize host wrappers; return '' for host-generated output."""
    stripped = text.strip()
    if stripped.startswith(HOST_WRAPPER_PREFIXES):
        return ""
    command = _command_text(stripped) if stripped.startswith(COMMAND_PREFIXES) else ""
    if command:
        return command
    bash = BASH_INPUT_RE.match(stripped)
    return f"! {bash.group(1).strip()}" if bash else stripped


def _image_note(block) -> str:
    source = block.get("source")
    mime = (source.get("media_type") if isinstance(source, dict) else "") or "image"
    return f"[Attached {mime} — not re-attachable after compaction in Claude Code; ask the user to attach it again if it matters]"


def _user_blocks(entry):
    """Content blocks of a real user entry, or None when excluded."""
    if not isinstance(entry, dict) or entry.get("type") != "user":
        return None
    if any(entry.get(flag) for flag in EXCLUDED_FLAGS):
        return None
    message = entry.get("message")
    blocks = _content_blocks(message.get("content")) if isinstance(message, dict) else []
    return None if any(block.get("type") == "tool_result" for block in blocks) else blocks


def prompt_entry(entry):
    """Return {'text', 'notes', 'created'} for a real user prompt, else None."""
    blocks = _user_blocks(entry)
    if not blocks:
        return None
    texts = [_prompt_text(str(block.get("text", ""))) for block in blocks if block.get("type") == "text"]
    text = "\n\n".join(t for t in texts if t)
    notes = [_image_note(block) for block in blocks if block.get("type") == "image"]
    if not text and not notes:
        return None
    return {"text": text, "notes": notes, "created": str(entry.get("timestamp") or "")}


def _parse_line(raw: str):
    if '"user"' not in raw:
        return None
    try:
        return prompt_entry(json.loads(raw))
    except ValueError:
        return None


def collect_prompts(transcript_path: str) -> list:
    """Every real user prompt in the transcript, oldest first.

    Consecutive identical prompts (same text and attachments) collapse: Claude
    Code logs a resubmitted prompt again under a new uuid after an API error.
    """
    entries = []
    with Path(transcript_path).expanduser().open("r", encoding="utf-8", errors="replace") as handle:
        for raw in handle:
            prompt = _parse_line(raw)
            repeated = prompt and entries and prompt["text"] and (
                (entries[-1]["text"], entries[-1]["notes"]) == (prompt["text"], prompt["notes"])
            )
            if prompt and not repeated:
                entries.append(prompt)
    return entries
