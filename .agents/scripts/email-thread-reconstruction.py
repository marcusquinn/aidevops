#!/usr/bin/env python3
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

import sys
import os
import re
from pathlib import Path
from collections import defaultdict, OrderedDict
from datetime import datetime
import argparse


def parse_frontmatter(md_file):
    """Extract YAML frontmatter from a markdown file.
    
    Returns dict of metadata, or None if no frontmatter found.
    """
    with open(md_file, 'r', encoding='utf-8') as f:
        content = f.read()
    
    # Check for YAML frontmatter delimiters
    if not content.startswith('---\n'):
        return None
    
    # Find the closing delimiter
    end_match = re.search(r'\n---\n', content[4:])
    if not end_match:
        return None
    
    frontmatter_text = content[4:4 + end_match.start()]
    
    # Parse YAML-like frontmatter (simple key: value pairs)
    metadata = {}
    for line in frontmatter_text.split('\n'):
        if ':' not in line:
            continue
        # Handle simple key: value (not nested structures)
        if line.startswith('  '):
            continue  # Skip nested items for now
        key, _, value = line.partition(':')
        key = key.strip()
        value = value.strip()
        # Remove quotes if present
        if value.startswith('"') and value.endswith('"'):
            value = value[1:-1]
        metadata[key] = value
    
    return metadata


def update_frontmatter(md_file, new_fields):
    """Update frontmatter in a markdown file with new fields.
    
    Adds or updates fields in the YAML frontmatter section.
    """
    with open(md_file, 'r', encoding='utf-8') as f:
        content = f.read()
    
    if not content.startswith('---\n'):
        return False
    
    # Find the closing delimiter
    end_match = re.search(r'\n---\n', content[4:])
    if not end_match:
        return False
    
    frontmatter_end = 4 + end_match.start() + 5  # +5 for '\n---\n'
    frontmatter_text = content[4:4 + end_match.start()]
    body = content[frontmatter_end:]
    
    # Parse existing frontmatter to preserve order
    lines = frontmatter_text.split('\n')
    
    # Find insertion point (after tokens_estimate or at end)
    insert_idx = len(lines)
    for i, line in enumerate(lines):
        if line.startswith('tokens_estimate:'):
            insert_idx = i + 1
            break
    
    # Build new lines for thread fields
    new_lines = []
    for key, value in new_fields.items():
        # Check if field already exists
        field_exists = False
        for i, line in enumerate(lines):
            if line.startswith(f'{key}:'):
                # Update existing field
                if isinstance(value, str):
                    lines[i] = f'{key}: "{value}"'
                else:
                    lines[i] = f'{key}: {value}'
                field_exists = True
                break
        
        if not field_exists:
            if isinstance(value, str):
                new_lines.append(f'{key}: "{value}"')
            else:
                new_lines.append(f'{key}: {value}')
    
    # Insert new lines at the insertion point
    if new_lines:
        lines = lines[:insert_idx] + new_lines + lines[insert_idx:]
    
    # Rebuild frontmatter
    new_frontmatter = '---\n' + '\n'.join(lines) + '\n---\n'
    new_content = new_frontmatter + body
    
    with open(md_file, 'w', encoding='utf-8') as f:
        f.write(new_content)
    
    return True


def build_thread_graph(emails):
    """Build a thread graph from email metadata.
    
    Args:
        emails: list of dicts with 'file', 'message_id', 'in_reply_to', 'date_sent'
    
    Returns:
        dict mapping thread_id (root message_id) to list of emails in thread order
    """
    # Build lookup maps
    by_message_id = {}
    for email in emails:
        msg_id = email.get('message_id', '').strip()
        if msg_id:
            by_message_id[msg_id] = email
    
    # Build parent-child relationships
    children = defaultdict(list)
    roots = []
    
    for email in emails:
        msg_id = email.get('message_id', '').strip()
        in_reply_to = email.get('in_reply_to', '').strip()
        
        if not msg_id:
            # No message_id, treat as standalone
            roots.append(email)
            continue
        
        if not in_reply_to or in_reply_to not in by_message_id:
            # Root message (no parent or parent not in dataset)
            roots.append(email)
        else:
            # Reply to another message
            children[in_reply_to].append(email)
    
    # Build threads by traversing from roots
    threads = {}
    
    def traverse(email, thread_list, position=0):
        """Recursively traverse thread tree."""
        email['thread_position'] = position
        thread_list.append(email)
        
        msg_id = email.get('message_id', '')
        if msg_id in children:
            # Sort children by date
            sorted_children = sorted(
                children[msg_id],
                key=lambda e: e.get('date_sent', '')
            )
            for child in sorted_children:
                traverse(child, thread_list, position + 1)
    
    for root in roots:
        thread_list = []
        traverse(root, thread_list)
        
        # Thread ID is the root message_id (or file path if no message_id)
        thread_id = root.get('message_id', '') or root['file']
        
        # Set thread_length for all emails in thread
        for email in thread_list:
            email['thread_length'] = len(thread_list)
            email['thread_id'] = thread_id
        
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
    lines = ['# Email Threads Index', '']
    lines.append(f'Generated: {datetime.now().strftime("%Y-%m-%d %H:%M:%S")}')
    lines.append(f'Total threads: {len(threads)}')
    lines.append('')
    
    # Sort threads by date of first message
    sorted_threads = sorted(
        threads.items(),
        key=lambda t: t[1][0].get('date_sent', '') if t[1] else '',
        reverse=True  # Most recent first
    )
    
    for thread_id, emails in sorted_threads:
        if not emails:
            continue
        
        root = emails[0]
        subject = root.get('subject', 'No Subject')
        thread_length = root.get('thread_length', len(emails))
        
        lines.append(f'## Thread: {subject} ({thread_length} messages)')
        lines.append(f'Thread ID: `{thread_id}`')
        lines.append('')
        
        for i, email in enumerate(emails, 1):
            file_path = Path(email['file']).name
            email_subject = email.get('subject', 'No Subject')
            from_addr = email.get('from', 'Unknown')
            date_sent = email.get('date_sent', 'Unknown')
            position = email.get('thread_position', i - 1)
            
            # Indent replies
            indent = '  ' * position
            lines.append(f'{indent}{i}. [{email_subject}]({file_path}) - {from_addr} - {date_sent}')
        
        lines.append('')
    
    with open(output_file, 'w', encoding='utf-8') as f:
        f.write('\n'.join(lines))
    
    return output_file


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
    
    # Find all .md files
    md_files = list(dir_path.glob('*.md'))
    if not md_files:
        print(f"WARNING: No .md files found in {directory}", file=sys.stderr)
        return {'threads': {}, 'updated_count': 0, 'index_file': None}
    
    # Parse frontmatter from all files
    emails = []
    for md_file in md_files:
        metadata = parse_frontmatter(md_file)
        if metadata:
            metadata['file'] = str(md_file)
            emails.append(metadata)
    
    if not emails:
        print(f"WARNING: No emails with frontmatter found in {directory}", file=sys.stderr)
        return {'threads': {}, 'updated_count': 0, 'index_file': None}
    
    # Build thread graph
    threads = build_thread_graph(emails)
    
    # Update frontmatter in all files
    updated_count = 0
    for thread_id, thread_emails in threads.items():
        for email in thread_emails:
            new_fields = {
                'thread_id': email['thread_id'],
                'thread_position': email['thread_position'],
                'thread_length': email['thread_length'],
            }
            if update_frontmatter(email['file'], new_fields):
                updated_count += 1
    
    # Generate thread index
    if output_index is None:
        output_index = dir_path / 'thread-index.md'
    
    index_file = generate_thread_index(threads, output_index)
    
    return {
        'threads': threads,
        'updated_count': updated_count,
        'index_file': str(index_file)
    }


def main():
    parser = argparse.ArgumentParser(
        description='Reconstruct email conversation threads from message-id chains'
    )
    parser.add_argument('directory', help='Directory containing .md email files')
    parser.add_argument('--output', '-o', help='Output thread index file (default: directory/thread-index.md)')
    
    args = parser.parse_args()
    
    result = reconstruct_threads(args.directory, args.output)
    
    print(f"Processed {result['updated_count']} emails")
    print(f"Found {len(result['threads'])} threads")
    if result['index_file']:
        print(f"Thread index: {result['index_file']}")


if __name__ == '__main__':
    main()
