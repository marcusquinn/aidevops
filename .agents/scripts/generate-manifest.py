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
from collections import OrderedDict
from datetime import datetime
from typing import Dict, List

from manifest_collectors import (
    collect_documents, collect_contacts, escape_toon_value, find_thread_root,
)


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
