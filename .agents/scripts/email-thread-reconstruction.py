#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""
email-thread-reconstruction.py - Reconstruct email conversation threads from message-id chains
Part of aidevops framework: https://aidevops.sh

Usage: email-thread-reconstruction.py <directory> [--output <file>]

Parses all .md files (converted emails) in a directory, builds thread trees from
message_id and in_reply_to headers, and adds thread metadata to frontmatter:
- thread_id: root message-id of the thread
- thread_position: position in thread (0 = root, 1+ = replies)
- thread_length: total messages in thread

Also generates a thread index file listing all emails in chronological order per thread.
"""

import os
import sys
from pathlib import Path
from collections import defaultdict
from datetime import datetime
import argparse

from email_frontmatter_utils import parse_frontmatter, update_frontmatter


def _build_message_id_index(emails) -> dict:
    """Build a lookup map from message_id to email dict."""
    return {
        email.get("message_id", "").strip(): email
        for email in emails
        if email.get("message_id", "").strip()
    }


def _classify_roots_and_children(emails, by_message_id):
    """Separate emails into root messages and child replies.

    Returns (roots, children) where children maps parent_id -> [child_emails].
    """
    children = defaultdict(list)
    roots = []

    for email in emails:
        msg_id = email.get("message_id", "").strip()
        in_reply_to = email.get("in_reply_to", "").strip()

        if not msg_id:
            roots.append(email)
            continue

        if not in_reply_to or in_reply_to not in by_message_id:
            roots.append(email)
        else:
            children[in_reply_to].append(email)

    return roots, children


def _traverse_thread(email, thread_list, children, position=0):
    """Recursively traverse thread tree, appending emails in order."""
    email["thread_position"] = position
    thread_list.append(email)

    msg_id = email.get("message_id", "")
    if msg_id in children:
        sorted_children = sorted(
            children[msg_id], key=lambda e: e.get("date_sent", "")
        )
        for child in sorted_children:
            _traverse_thread(child, thread_list, children, position + 1)


def _annotate_thread(thread_list, thread_id):
    """Set thread_id and thread_length on all emails in a thread."""
    length = len(thread_list)
    for email in thread_list:
        email["thread_length"] = length
        email["thread_id"] = thread_id


def build_thread_graph(emails):
    """Build a thread graph from email metadata.

    Args:
        emails: list of dicts with 'file', 'message_id', 'in_reply_to', 'date_sent'

    Returns:
        dict mapping thread_id (root message_id) to list of emails in thread order
    """
    by_message_id = _build_message_id_index(emails)
    roots, children = _classify_roots_and_children(emails, by_message_id)

    threads = {}
    for root in roots:
        thread_list = []
        _traverse_thread(root, thread_list, children)
        thread_id = root.get("message_id", "") or root["file"]
        _annotate_thread(thread_list, thread_id)
        threads[thread_id] = thread_list

    return threads


def generate_thread_index(threads, output_file):
    """Generate a thread index file listing all emails by thread.

    Format:
    # Email Threads Index

    ## Thread: <subject> (<thread_length> messages)
    Thread ID: <thread_id>

    1. [<subject>](<file>) - <from> - <date_sent>
    2. [<subject>](<file>) - <from> - <date_sent>
    ...
    """
    lines = ["# Email Threads Index", ""]
    lines.append(f"Generated: {datetime.now().strftime('%Y-%m-%d %H:%M:%S')}")
    lines.append(f"Total threads: {len(threads)}")
    lines.append("")

    # Resolve the output directory for computing relative paths to email files
    output_dir = Path(output_file).resolve().parent

    # Sort threads by date of first message
    sorted_threads = sorted(
        threads.items(),
        key=lambda t: t[1][0].get("date_sent", "") if t[1] else "",
        reverse=True,  # Most recent first
    )

    for thread_id, emails in sorted_threads:
        if not emails:
            continue

        root = emails[0]
        subject = root.get("subject", "No Subject")
        thread_length = root.get("thread_length", len(emails))

        msg_word = "message" if thread_length == 1 else "messages"
        lines.append(f"## Thread: {subject} ({thread_length} {msg_word})")
        lines.append(f"Thread ID: `{thread_id}`")
        lines.append("")

        for i, email in enumerate(emails, 1):
            # Compute relative path from index file location to email file
            # Use pathlib.as_posix() for portable forward-slash Markdown links
            file_path = Path(
                os.path.relpath(Path(email["file"]).resolve(), output_dir)
            ).as_posix()
            email_subject = email.get("subject", "No Subject")
            from_addr = email.get("from", "Unknown")
            date_sent = email.get("date_sent", "Unknown")
            position = email.get("thread_position", i - 1)

            # Indent replies
            indent = "  " * position
            lines.append(
                f"{indent}{i}. [{email_subject}]({file_path}) - {from_addr} - {date_sent}"
            )

        lines.append("")

    with open(output_file, "w", encoding="utf-8") as f:
        f.write("\n".join(lines) + "\n")

    return output_file


def _load_emails_from_dir(dir_path) -> list:
    """Parse frontmatter from all .md files in dir_path.

    Returns list of metadata dicts with 'file' key added, or empty list.
    """
    md_files = list(dir_path.glob("*.md"))
    if not md_files:
        print(f"WARNING: No .md files found in {dir_path}", file=sys.stderr)
        return []

    emails = []
    for md_file in md_files:
        metadata = parse_frontmatter(md_file)
        if metadata:
            metadata["file"] = str(md_file)
            emails.append(metadata)

    if not emails:
        print(
            f"WARNING: No emails with frontmatter found in {dir_path}",
            file=sys.stderr,
        )
    return emails


def _update_thread_frontmatter(threads) -> int:
    """Write thread_id, thread_position, thread_length into each email's frontmatter.

    Returns count of successfully updated files.
    """
    updated_count = 0
    for _tid, thread_emails in threads.items():
        for email in thread_emails:
            new_fields = {
                "thread_id": email["thread_id"],
                "thread_position": email["thread_position"],
                "thread_length": email["thread_length"],
            }
            if update_frontmatter(email["file"], new_fields):
                updated_count += 1
    return updated_count


def reconstruct_threads(directory, output_index=None):
    """Reconstruct email threads from a directory of converted emails.

    Args:
        directory: path to directory containing .md email files
        output_index: path to thread index file (default: directory/thread-index.md)

    Returns:
        dict with 'threads', 'updated_count', 'index_file'
    """
    dir_path = Path(directory)
    if not dir_path.is_dir():
        print(f"ERROR: Directory not found: {directory}", file=sys.stderr)
        sys.exit(1)

    emails = _load_emails_from_dir(dir_path)
    if not emails:
        return {"threads": {}, "updated_count": 0, "index_file": None}

    threads = build_thread_graph(emails)
    updated_count = _update_thread_frontmatter(threads)

    if output_index is None:
        output_index = dir_path / "thread-index.md"

    index_file = generate_thread_index(threads, output_index)

    return {
        "threads": threads,
        "updated_count": updated_count,
        "index_file": str(index_file),
    }


def main():
    parser = argparse.ArgumentParser(
        description="Reconstruct email conversation threads from message-id chains"
    )
    parser.add_argument("directory", help="Directory containing .md email files")
    parser.add_argument(
        "--output",
        "-o",
        help="Output thread index file (default: directory/thread-index.md)",
    )

    args = parser.parse_args()

    result = reconstruct_threads(args.directory, args.output)

    print(f"Processed {result['updated_count']} emails")
    print(f"Found {len(result['threads'])} threads")
    if result["index_file"]:
        print(f"Thread index: {result['index_file']}")


if __name__ == "__main__":
    main()
