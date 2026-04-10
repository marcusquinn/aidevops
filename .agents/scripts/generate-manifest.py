#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""
generate-manifest.py - Generate _index.toon collection manifest for email imports.

Part of aidevops document-creation-helper.sh (extracted for complexity reduction).

Scans .md files for YAML frontmatter, .toon contact files, and builds three
TOON indexes: documents, threads, contacts.

Usage: generate-manifest.py <output_dir> <index_file>
"""

import sys
import os
import re
import glob
from collections import OrderedDict
from datetime import datetime
from typing import Any, Dict, List


def _strip_quotes(value: str) -> str:
    """Strip surrounding single or double quotes from a YAML value."""
    if len(value) >= 2 and value[0] in ('"', "'") and value[-1] == value[0]:
        return value[1:-1]
    return value


def _parse_fm_line(line: str, fields: Dict[str, str]) -> None:
    """Parse a single frontmatter key: value line into fields."""
    colon_pos = line.find(':')
    if colon_pos > 0:
        key = line[:colon_pos].strip()
        value = _strip_quotes(line[colon_pos + 1:].strip())
        fields[key] = value


def _read_frontmatter_block(md_path: str) -> str:
    """Read and return the raw frontmatter block from a markdown file, or ''."""
    try:
        with open(md_path, 'r', encoding='utf-8', errors='replace') as f:
            content = f.read(8192)
    except (OSError, IOError):
        return ''
    if not content.startswith('---'):
        return ''
    end = content.find('\n---', 3)
    if end == -1:
        return ''
    return content[4:end]


def parse_frontmatter(md_path: str) -> Dict[str, str]:
    """Extract YAML frontmatter fields from a markdown file."""
    fields: Dict[str, str] = {}
    fm_block = _read_frontmatter_block(md_path)
    if not fm_block:
        return fields

    for raw_line in fm_block.split('\n'):
        if raw_line.startswith((' ', '\t')):
            continue
        line = raw_line.strip()
        if not line or line.startswith('#') or line.startswith('- '):
            continue
        _parse_fm_line(line, fields)

    return fields


def escape_toon_value(val: Any) -> str:
    """Escape a value for TOON format — quote if it contains commas or quotes."""
    val = str(val)
    if ',' in val or '"' in val or '\n' in val:
        return '"' + val.replace('"', '""') + '"'
    return val


def parse_contact_toon(toon_path: str) -> Dict[str, str]:
    """Parse a contact .toon file into a dict."""
    contact: Dict[str, str] = {}
    try:
        with open(toon_path, 'r', encoding='utf-8', errors='replace') as f:
            for line in f:
                line = line.strip()
                if line == 'contact' or not line:
                    continue
                parts = line.split('\t', 1)
                if len(parts) == 2:
                    contact[parts[0]] = parts[1]
    except (OSError, IOError):
        pass
    return contact


def find_thread_root(mid: str, reply_chains: Dict[str, str]) -> str:
    """Walk in_reply_to chain to find the root message_id."""
    visited = set()
    current = mid
    while current in reply_chains and current not in visited:
        visited.add(current)
        current = reply_chains[current]
    return current


def collect_documents(output_dir: str) -> tuple:
    """Collect and index documents from markdown files."""
    md_files = sorted(glob.glob(os.path.join(output_dir, '*.md')))
    documents: List[OrderedDict] = []
    msg_id_map: Dict[str, int] = {}
    thread_map: Dict[str, List[int]] = {}
    reply_chains: Dict[str, str] = {}

    for md_path in md_files:
        basename = os.path.basename(md_path)
        if basename.startswith('_'):
            continue  # Skip index files

        fm = parse_frontmatter(md_path)
        if not fm:
            continue

        doc: OrderedDict = OrderedDict()
        doc['file'] = basename
        doc['subject'] = fm.get('subject', fm.get('title', ''))
        doc['from'] = fm.get('from', '')
        doc['to'] = fm.get('to', '')
        doc['date_sent'] = fm.get('date_sent', '')
        doc['message_id'] = fm.get('message_id', '')
        doc['in_reply_to'] = fm.get('in_reply_to', '')
        doc['attachment_count'] = fm.get('attachment_count', '0')
        doc['tokens_estimate'] = fm.get('tokens_estimate', '0')
        doc['size'] = fm.get('size', '')
        doc['thread_id'] = fm.get('thread_id', '')
        doc['thread_position'] = fm.get('thread_position', '')

        idx = len(documents)
        documents.append(doc)

        # Index by message_id for thread reconstruction
        mid = doc['message_id']
        if mid:
            msg_id_map[mid] = idx

        irt = doc['in_reply_to']
        if irt and mid:
            reply_chains[mid] = irt

        # If thread_id exists, group by it
        tid = doc['thread_id']
        if tid:
            thread_map.setdefault(tid, []).append(idx)

    return documents, msg_id_map, thread_map, reply_chains


def discover_threads(
    documents: List[OrderedDict],
    msg_id_map: Dict[str, int],
    thread_map: Dict[str, List[int]],
    reply_chains: Dict[str, str],
) -> Dict[str, List[int]]:
    """Populate thread_map from reply chains when thread_id data is absent."""
    if thread_map:
        return thread_map

    root_groups: Dict[str, List[int]] = {}
    for mid, idx in msg_id_map.items():
        root = find_thread_root(mid, reply_chains)
        root_groups.setdefault(root, []).append(idx)

    result: Dict[str, List[int]] = {}
    for root_mid, indices in root_groups.items():
        if len(indices) > 1:
            result[root_mid] = sorted(
                indices,
                key=lambda i: documents[i].get('date_sent', ''),
            )
    return result


def collect_thread_participants(thread_docs: List[OrderedDict]) -> set:
    """Extract unique email addresses from from/to fields of thread documents."""
    participants: set = set()
    for d in thread_docs:
        for addr in (d.get('from', ''), d.get('to', '')):
            for part in addr.split(','):
                part = part.strip()
                if not part:
                    continue
                email_match = re.search(r'<([^>]+)>', part)
                if email_match:
                    participants.add(email_match.group(1).lower())
                elif '@' in part:
                    participants.add(part.lower())
    return participants


def assemble_thread_record(
    tid: str, indices: List[int], documents: List[OrderedDict]
) -> OrderedDict:
    """Build a single thread OrderedDict from its document indices."""
    thread_docs = [documents[i] for i in indices]
    participants = collect_thread_participants(thread_docs)
    thread: OrderedDict = OrderedDict()
    thread['thread_id'] = tid
    thread['subject'] = thread_docs[0].get('subject', '') if thread_docs else ''
    thread['message_count'] = str(len(indices))
    thread['participants'] = '; '.join(sorted(participants))
    thread['first_date'] = thread_docs[0].get('date_sent', '') if thread_docs else ''
    thread['last_date'] = thread_docs[-1].get('date_sent', '') if thread_docs else ''
    return thread


def build_threads(
    documents: List[OrderedDict],
    msg_id_map: Dict[str, int],
    thread_map: Dict[str, List[int]],
    reply_chains: Dict[str, str],
) -> List[OrderedDict]:
    """Build thread records from document index data."""
    resolved_map = discover_threads(documents, msg_id_map, thread_map, reply_chains)
    return [
        assemble_thread_record(tid, indices, documents)
        for tid, indices in sorted(resolved_map.items(), key=lambda x: x[0])
    ]


def collect_contacts(
    output_dir: str, documents: List[OrderedDict]
) -> List[OrderedDict]:
    """Collect contacts from .toon files and count email interactions."""
    contacts_dir = os.path.join(output_dir, 'contacts')
    contacts: List[OrderedDict] = []

    if not os.path.isdir(contacts_dir):
        return contacts

    toon_files = sorted(glob.glob(os.path.join(contacts_dir, '*.toon')))
    for toon_path in toon_files:
        c = parse_contact_toon(toon_path)
        if not c.get('email'):
            continue

        # Count emails from/to this contact in the documents
        email_addr = c['email'].lower()
        email_count = sum(
            1 for doc in documents
            if email_addr in doc.get('from', '').lower()
            or email_addr in doc.get('to', '').lower()
        )

        contact: OrderedDict = OrderedDict()
        contact['email'] = c.get('email', '')
        contact['name'] = c.get('name', '')
        contact['title'] = c.get('title', '')
        contact['company'] = c.get('company', '')
        contact['email_count'] = str(email_count)
        contact['first_seen'] = c.get('first_seen', '')
        contact['last_seen'] = c.get('last_seen', '')
        contact['confidence'] = c.get('confidence', 'low')
        contacts.append(contact)

    return contacts


def write_manifest(
    index_file: str,
    documents: List[OrderedDict],
    threads: List[OrderedDict],
    contacts: List[OrderedDict],
) -> None:
    """Write the _index.toon manifest file."""
    now = datetime.now().strftime('%Y-%m-%dT%H:%M:%S')

    with open(index_file, 'w', encoding='utf-8') as f:
        # Documents index
        doc_fields = (
            'file,subject,from,to,date_sent,message_id,'
            'in_reply_to,attachment_count,tokens_estimate,size'
        )
        f.write(f'documents[{len(documents)}]{{{doc_fields}}}:\n')
        for doc in documents:
            vals = [escape_toon_value(doc.get(k, '')) for k in doc_fields.split(',')]
            f.write(f'  {",".join(vals)}\n')

        # Threads index
        thread_fields = 'thread_id,subject,message_count,participants,first_date,last_date'
        f.write(f'threads[{len(threads)}]{{{thread_fields}}}:\n')
        for t in threads:
            vals = [escape_toon_value(t.get(k, '')) for k in thread_fields.split(',')]
            f.write(f'  {",".join(vals)}\n')

        # Contacts index
        contact_fields = (
            'email,name,title,company,email_count,first_seen,last_seen,confidence'
        )
        f.write(f'contacts[{len(contacts)}]{{{contact_fields}}}:\n')
        for c in contacts:
            vals = [escape_toon_value(c.get(k, '')) for k in contact_fields.split(',')]
            f.write(f'  {",".join(vals)}\n')

        # Summary metadata
        f.write('metadata:\n')
        f.write(f'  total_documents: {len(documents)}\n')
        f.write(f'  total_threads: {len(threads)}\n')
        f.write(f'  total_contacts: {len(contacts)}\n')
        f.write(f'  generated: "{now}"\n')
        f.write('  source: email-import\n')


def main() -> None:
    if len(sys.argv) < 3:
        print(
            "Usage: generate-manifest.py <output_dir> <index_file>",
            file=sys.stderr,
        )
        sys.exit(1)

    output_dir = sys.argv[1]
    index_file = sys.argv[2]

    documents, msg_id_map, thread_map, reply_chains = collect_documents(output_dir)
    threads = build_threads(documents, msg_id_map, thread_map, reply_chains)
    contacts = collect_contacts(output_dir, documents)
    write_manifest(index_file, documents, threads, contacts)

    print(f'MANIFEST_DOCS={len(documents)}')
    print(f'MANIFEST_THREADS={len(threads)}')
    print(f'MANIFEST_CONTACTS={len(contacts)}')


if __name__ == '__main__':
    main()
