#!/usr/bin/env python3
"""
add-related-docs.py - Add related_docs frontmatter and navigation links to markdown files
Part of aidevops framework: https://aidevops.sh

Usage: add-related-docs.py <markdown-file> [--directory <dir>] [--update-all]

Scans markdown files with YAML frontmatter and adds:
1. related_docs frontmatter field with:
   - attachments: Links to attachment files
   - thread_siblings: Links to emails in the same thread
   - entity_matches: Links to documents mentioning the same entities
2. Navigation links section at the bottom of the markdown file

Dependencies: PyYAML
"""

import sys
import os
import re
import yaml
from pathlib import Path
from typing import Dict, List, Optional, Set, Tuple
from collections import defaultdict
import argparse


def parse_frontmatter(content: str) -> Tuple[Optional[Dict], str]:
    """Extract YAML frontmatter and body from markdown content.
    
    Returns: (frontmatter_dict, body_content)
    """
    if not content.startswith('---\n'):
        return None, content
    
    # Find the closing ---
    parts = content.split('\n---\n', 1)
    if len(parts) != 2:
        return None, content
    
    try:
        frontmatter = yaml.safe_load(parts[0][4:])  # Skip opening ---\n
        body = parts[1]
        return frontmatter, body
    except yaml.YAMLError:
        return None, content


def build_frontmatter_yaml(metadata: Dict) -> str:
    """Build YAML frontmatter string from metadata dict."""
    yaml_str = yaml.dump(metadata, default_flow_style=False, allow_unicode=True, sort_keys=False)
    return f"---\n{yaml_str}---"


def find_attachments(md_file: Path, frontmatter: Dict) -> List[str]:
    """Find attachment files referenced in frontmatter.
    
    Returns list of relative paths to attachment files.
    """
    attachments = []
    
    # Check for attachments field in frontmatter
    if 'attachments' in frontmatter and isinstance(frontmatter['attachments'], list):
        # Assume attachments are in a subdirectory named <filename>_attachments/
        base_name = md_file.stem
        attachments_dir = md_file.parent / f"{base_name}_attachments"
        
        if attachments_dir.exists():
            for att_meta in frontmatter['attachments']:
                if isinstance(att_meta, dict) and 'filename' in att_meta:
                    att_file = attachments_dir / att_meta['filename']
                    if att_file.exists():
                        # Store relative path from md_file location
                        rel_path = os.path.relpath(att_file, md_file.parent)
                        attachments.append(rel_path)
    
    return attachments


def find_thread_siblings(md_file: Path, frontmatter: Dict, all_docs: Dict[Path, Dict]) -> Dict[str, Optional[str]]:
    """Find previous and next emails in the same thread.
    
    Returns: {'previous': path_or_none, 'next': path_or_none}
    """
    siblings: Dict[str, Optional[str]] = {'previous': None, 'next': None}
    
    thread_id = frontmatter.get('thread_id')
    thread_position = frontmatter.get('thread_position')
    
    if not thread_id or not thread_position:
        return siblings
    
    # Find all docs in the same thread
    thread_docs = []
    for doc_path, doc_meta in all_docs.items():
        if doc_meta.get('thread_id') == thread_id:
            thread_docs.append((doc_path, doc_meta.get('thread_position', 0)))
    
    # Sort by thread_position
    thread_docs.sort(key=lambda x: x[1])
    
    # Find current position in sorted list
    for i, (doc_path, pos) in enumerate(thread_docs):
        if doc_path == md_file:
            if i > 0:
                prev_path = thread_docs[i-1][0]
                siblings['previous'] = os.path.relpath(prev_path, md_file.parent)
            if i < len(thread_docs) - 1:
                next_path = thread_docs[i+1][0]
                siblings['next'] = os.path.relpath(next_path, md_file.parent)
            break
    
    return siblings


def find_entity_matches(md_file: Path, frontmatter: Dict, all_docs: Dict[Path, Dict], min_overlap: int = 1) -> List[Dict]:
    """Find documents that mention the same entities.
    
    Returns: List of {'path': rel_path, 'entities': [shared_entities], 'title': doc_title}
    """
    matches = []
    
    # Get entities from current document
    current_entities = frontmatter.get('entities', {})
    if not current_entities or not isinstance(current_entities, dict):
        return matches
    
    # Flatten current entities to a set
    current_entity_set = set()
    for entity_type, entity_list in current_entities.items():
        if isinstance(entity_list, list):
            current_entity_set.update(entity_list)
    
    if not current_entity_set:
        return matches
    
    # Compare with other documents
    for doc_path, doc_meta in all_docs.items():
        if doc_path == md_file:
            continue
        
        doc_entities = doc_meta.get('entities', {})
        if not doc_entities or not isinstance(doc_entities, dict):
            continue
        
        # Flatten doc entities
        doc_entity_set = set()
        for entity_type, entity_list in doc_entities.items():
            if isinstance(entity_list, list):
                doc_entity_set.update(entity_list)
        
        # Find overlap
        shared = current_entity_set & doc_entity_set
        if len(shared) >= min_overlap:
            rel_path = os.path.relpath(doc_path, md_file.parent)
            matches.append({
                'path': rel_path,
                'entities': sorted(list(shared)),
                'title': doc_meta.get('title', doc_path.stem)
            })
    
    # Sort by number of shared entities (descending)
    matches.sort(key=lambda x: len(x['entities']), reverse=True)
    
    return matches


def build_navigation_section(related_docs: Dict, frontmatter: Dict) -> str:
    """Build markdown navigation section from related_docs.
    
    Returns: Markdown string with navigation links.
    """
    sections = []
    
    # Attachments section
    if related_docs.get('attachments'):
        sections.append("### Attachments\n")
        for att_path in related_docs['attachments']:
            filename = Path(att_path).name
            sections.append(f"- [{filename}]({att_path})\n")
    
    # Thread navigation section
    thread_siblings = related_docs.get('thread_siblings', {})
    if thread_siblings.get('previous') or thread_siblings.get('next'):
        sections.append("\n### Thread Navigation\n")
        
        if thread_siblings.get('previous'):
            prev_path = thread_siblings['previous']
            sections.append(f"- ← Previous: [{Path(prev_path).stem}]({prev_path})\n")
        
        if thread_siblings.get('next'):
            next_path = thread_siblings['next']
            sections.append(f"- → Next: [{Path(next_path).stem}]({next_path})\n")
    
    # Entity matches section
    if related_docs.get('entity_matches'):
        sections.append("\n### Related by Entities\n")
        for match in related_docs['entity_matches'][:10]:  # Limit to top 10
            path = match['path']
            title = match['title']
            entities = ', '.join(match['entities'][:5])  # Show first 5 entities
            if len(match['entities']) > 5:
                entities += f" (+{len(match['entities']) - 5} more)"
            sections.append(f"- [{title}]({path}) ({entities})\n")
    
    if not sections:
        return ""
    
    return "\n---\n\n## Related Documents\n\n" + "".join(sections)


def scan_directory(directory: Path) -> Dict[Path, Dict]:
    """Scan directory for markdown files and extract their frontmatter.
    
    Returns: Dict mapping file paths to frontmatter dicts.
    """
    all_docs = {}
    
    for md_file in directory.rglob('*.md'):
        if not md_file.is_file():
            continue
        
        try:
            with open(md_file, 'r', encoding='utf-8') as f:
                content = f.read()
            
            frontmatter, _ = parse_frontmatter(content)
            if frontmatter:
                all_docs[md_file] = frontmatter
        except Exception as e:
            print(f"Warning: Failed to parse {md_file}: {e}", file=sys.stderr)
    
    return all_docs


def add_related_docs(md_file: Path, all_docs: Optional[Dict[Path, Dict]] = None, dry_run: bool = False) -> bool:
    """Add related_docs frontmatter and navigation links to a markdown file.
    
    Args:
        md_file: Path to markdown file
        all_docs: Optional pre-scanned dict of all documents (for batch processing)
        dry_run: If True, print changes without writing
    
    Returns: True if file was modified, False otherwise
    """
    # Read file
    try:
        with open(md_file, 'r', encoding='utf-8') as f:
            content = f.read()
    except Exception as e:
        print(f"Error reading {md_file}: {e}", file=sys.stderr)
        return False
    
    # Parse frontmatter
    frontmatter, body = parse_frontmatter(content)
    if not frontmatter:
        print(f"Skipping {md_file}: No frontmatter found", file=sys.stderr)
        return False
    
    # If all_docs not provided, scan the directory
    if all_docs is None:
        all_docs = scan_directory(md_file.parent)
    
    # Build related_docs
    related_docs = {}
    
    # Find attachments
    attachments = find_attachments(md_file, frontmatter)
    if attachments:
        related_docs['attachments'] = attachments
    
    # Find thread siblings
    thread_siblings = find_thread_siblings(md_file, frontmatter, all_docs)
    if thread_siblings['previous'] or thread_siblings['next']:
        related_docs['thread_siblings'] = thread_siblings
    
    # Find entity matches
    entity_matches = find_entity_matches(md_file, frontmatter, all_docs)
    if entity_matches:
        related_docs['entity_matches'] = entity_matches
    
    # If no related docs found, skip
    if not related_docs:
        print(f"No related documents found for {md_file}")
        return False
    
    # Add related_docs to frontmatter
    frontmatter['related_docs'] = related_docs
    
    # Remove existing navigation section if present
    body_clean = re.sub(r'\n---\n\n## Related Documents\n.*$', '', body, flags=re.DOTALL)
    
    # Build new content
    new_frontmatter = build_frontmatter_yaml(frontmatter)
    navigation = build_navigation_section(related_docs, frontmatter)
    new_content = f"{new_frontmatter}\n\n{body_clean.strip()}{navigation}\n"
    
    if dry_run:
        print(f"\n{'='*60}")
        print(f"File: {md_file}")
        print(f"{'='*60}")
        print("Related docs that would be added:")
        print(yaml.dump(related_docs, default_flow_style=False, allow_unicode=True))
        print("\nNavigation section:")
        print(navigation)
        return True
    
    # Write file
    try:
        with open(md_file, 'w', encoding='utf-8') as f:
            f.write(new_content)
        print(f"Updated: {md_file}")
        return True
    except Exception as e:
        print(f"Error writing {md_file}: {e}", file=sys.stderr)
        return False


def main():
    parser = argparse.ArgumentParser(
        description='Add related_docs frontmatter and navigation links to markdown files'
    )
    parser.add_argument('input', nargs='?', help='Input markdown file or directory')
    parser.add_argument('--directory', '-d', help='Process all markdown files in directory')
    parser.add_argument('--update-all', action='store_true', help='Update all markdown files in current directory')
    parser.add_argument('--dry-run', action='store_true', help='Show changes without writing files')
    
    args = parser.parse_args()
    
    # Determine target
    if args.update_all:
        target_dir = Path.cwd()
    elif args.directory:
        target_dir = Path(args.directory)
    elif args.input:
        input_path = Path(args.input)
        if input_path.is_dir():
            target_dir = input_path
        else:
            # Single file mode
            success = add_related_docs(input_path, dry_run=args.dry_run)
            sys.exit(0 if success else 1)
    else:
        parser.print_help()
        sys.exit(1)
    
    # Batch mode: process directory
    if not target_dir.exists():
        print(f"Error: Directory not found: {target_dir}", file=sys.stderr)
        sys.exit(1)
    
    print(f"Scanning directory: {target_dir}")
    all_docs = scan_directory(target_dir)
    print(f"Found {len(all_docs)} markdown files with frontmatter")
    
    updated_count = 0
    for md_file in all_docs.keys():
        if add_related_docs(md_file, all_docs, dry_run=args.dry_run):
            updated_count += 1
    
    print(f"\n{'Would update' if args.dry_run else 'Updated'} {updated_count} file(s)")


if __name__ == '__main__':
    main()
