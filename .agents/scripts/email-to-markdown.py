#!/usr/bin/env python3
"""
email-to-markdown.py - Convert .eml/.msg files to markdown with attachment extraction
Part of aidevops framework: https://aidevops.sh

Usage:
  Single file:  email-to-markdown.py <input-file> [--output <file>] [--attachments-dir <dir>]
                [--summarize [auto|ollama|heuristic]]
  Batch mode:   email-to-markdown.py <directory> --batch [--threads-index]

Output format: YAML frontmatter with visible headers (from, to, cc, bcc, date_sent,
date_received, subject, size, message_id, in_reply_to, attachment_count, attachments),
thread reconstruction fields (thread_id, thread_position, thread_length),
markdown.new convention fields (title, description), and tokens_estimate for LLM context.

Auto-summary (t1053.7): With --summarize (or --auto-summary), the description field uses
intelligent summarisation — heuristic extraction for short emails, LLM via Ollama for long
ones. When --summarize is used, the description field contains an auto-generated 1-2 sentence
summary instead of a simple truncation. Short emails (<100 words) use a heuristic
summariser; long emails use LLM summarisation via Ollama (with heuristic fallback).

Thread reconstruction:
- Parses message_id and in_reply_to headers to build conversation threads
- thread_id: message-id of the root message (first in thread)
- thread_position: 1-based position in thread (1 = root)
- thread_length: total number of messages in thread
- --threads-index: generates JSON index files per thread in threads/ directory
"""

import sys
import os
import email
import email.policy
from email import message_from_binary_file
from email.utils import parsedate_to_datetime
import html2text
import argparse
from pathlib import Path
import mimetypes
import re
import json
from typing import Dict, List, Optional, Tuple
from collections import defaultdict


def parse_eml(file_path):
    """Parse .eml file using Python's email library."""
    with open(file_path, 'rb') as f:
        msg = message_from_binary_file(f, policy=email.policy.default)
    return msg


def parse_msg(file_path):
    """Parse .msg file using extract_msg library."""
    try:
        import extract_msg
    except ImportError:
        print("ERROR: extract_msg library required for .msg files", file=sys.stderr)
        print("Install: pip install extract-msg", file=sys.stderr)
        sys.exit(1)
    
    msg = extract_msg.Message(file_path)
    return msg


def get_email_body(msg, prefer_html=True):
    """Extract email body, preferring HTML if available."""
    body_text = ""
    body_html = ""
    
    if hasattr(msg, 'body'):  # extract_msg Message object
        body_text = msg.body or ""
        body_html = msg.htmlBody or ""
    else:  # email.message.Message object
        if msg.is_multipart():
            for part in msg.walk():
                content_type = part.get_content_type()
                if content_type == 'text/plain' and not body_text:
                    body_text = part.get_content()
                elif content_type == 'text/html' and not body_html:
                    body_html = part.get_content()
        else:
            content_type = msg.get_content_type()
            if content_type == 'text/plain':
                body_text = msg.get_content()
            elif content_type == 'text/html':
                body_html = msg.get_content()
    
    # Convert HTML to markdown if available and preferred
    if body_html and prefer_html:
        h = html2text.HTML2Text()
        h.ignore_links = False
        h.ignore_images = False
        h.ignore_emphasis = False
        h.body_width = 0  # Don't wrap lines
        return h.handle(body_html)
    
    return body_text


def extract_attachments(msg, output_dir):
    """Extract attachments from email message."""
    attachments = []
    output_path = Path(output_dir)
    output_path.mkdir(parents=True, exist_ok=True)
    
    if hasattr(msg, 'attachments'):  # extract_msg Message object
        for attachment in msg.attachments:
            filename = attachment.longFilename or attachment.shortFilename or "attachment"
            filepath = output_path / filename
            with open(filepath, 'wb') as f:
                f.write(attachment.data)
            attachments.append({
                'filename': filename,
                'path': str(filepath),
                'size': len(attachment.data)
            })
    else:  # email.message.Message object
        for part in msg.walk():
            if part.get_content_maintype() == 'multipart':
                continue
            if part.get('Content-Disposition') is None:
                continue
            
            filename = part.get_filename()
            if filename:
                filepath = output_path / filename
                with open(filepath, 'wb') as f:
                    f.write(part.get_payload(decode=True))
                attachments.append({
                    'filename': filename,
                    'path': str(filepath),
                    'size': len(part.get_payload(decode=True))
                })
    
    return attachments


def format_size(size_bytes):
    """Format file size in human-readable format."""
    for unit in ['B', 'KB', 'MB', 'GB']:
        if size_bytes < 1024.0:
            return f"{size_bytes:.1f} {unit}"
        size_bytes /= 1024.0
    return f"{size_bytes:.1f} TB"


def estimate_tokens(text):
    """Estimate token count using word-based heuristic (words * 1.3).

    This approximates GPT/Claude tokenization without requiring tiktoken.
    The 1.3 multiplier accounts for subword tokenization of punctuation,
    numbers, and multi-syllable words.
    """
    if not text:
        return 0
    words = len(text.split())
    return int(words * 1.3)


def yaml_escape(value):
    """Escape a string value for safe YAML output.

    Wraps in double quotes if the value contains characters that could
    break YAML parsing (colons, quotes, newlines, leading special chars).
    """
    if value is None:
        return '""'
    value = str(value)
    if not value:
        return '""'
    # Quote if contains YAML-special characters or starts with special chars
    needs_quoting = any(c in value for c in [':', '#', '{', '}', '[', ']', ',', '&', '*', '?', '|', '-', '<', '>', '=', '!', '%', '@', '`', '\n', '\r', '"', "'"])
    needs_quoting = needs_quoting or value.startswith((' ', '\t'))
    if needs_quoting:
        # Escape backslashes and double quotes for YAML double-quoted strings
        value = value.replace('\\', '\\\\').replace('"', '\\"')
        # Replace newlines with spaces
        value = value.replace('\n', ' ').replace('\r', '')
        return f'"{value}"'
    return value


def build_thread_map(emails_dir: Path) -> Dict[str, Dict]:
    """Build a map of all emails by message-id for thread reconstruction.
    
    Returns a dict mapping message_id -> {file_path, in_reply_to, date_sent, subject}
    """
    thread_map = {}
    
    # Find all .eml and .msg files
    for ext in ['.eml', '.msg']:
        for email_file in emails_dir.glob(f'**/*{ext}'):
            try:
                # Parse just the headers we need
                if ext == '.eml':
                    msg = parse_eml(email_file)
                else:
                    msg = parse_msg(email_file)
                
                message_id = extract_header_safe(msg, 'Message-ID')
                in_reply_to = extract_header_safe(msg, 'In-Reply-To')
                date_sent_raw = extract_header_safe(msg, 'Date')
                subject = extract_header_safe(msg, 'Subject', 'No Subject')
                
                if message_id:
                    thread_map[message_id] = {
                        'file_path': str(email_file),
                        'in_reply_to': in_reply_to,
                        'date_sent': parse_date_safe(date_sent_raw),
                        'subject': subject
                    }
            except Exception as e:
                print(f"Warning: Failed to parse {email_file}: {e}", file=sys.stderr)
                continue
    
    return thread_map


def reconstruct_thread(message_id: str, thread_map: Dict[str, Dict]) -> Tuple[str, int, int]:
    """Reconstruct thread information for a given message.
    
    Returns: (thread_id, thread_position, thread_length)
    - thread_id: message-id of the root message (first in thread)
    - thread_position: 1-based position in thread (1 = root)
    - thread_length: total number of messages in thread
    """
    if not message_id or message_id not in thread_map:
        return ('', 0, 0)
    
    # Walk backwards to find root
    current_id = message_id
    chain = [current_id]
    visited = {current_id}
    
    while True:
        current_info = thread_map.get(current_id)
        if not current_info:
            break
        
        in_reply_to = current_info.get('in_reply_to', '')
        if not in_reply_to or in_reply_to not in thread_map:
            break
        
        # Prevent infinite loops
        if in_reply_to in visited:
            break
        
        chain.insert(0, in_reply_to)
        visited.add(in_reply_to)
        current_id = in_reply_to
    
    # Root is first in chain
    thread_id = chain[0]
    
    # Position is where our message appears in the chain
    thread_position = chain.index(message_id) + 1
    
    # Walk forwards from root to find all descendants
    def count_descendants(msg_id: str, visited_desc: set) -> int:
        if msg_id in visited_desc:
            return 0
        visited_desc.add(msg_id)
        
        count = 1
        # Find all messages that reply to this one
        for mid, info in thread_map.items():
            if info.get('in_reply_to') == msg_id and mid not in visited_desc:
                count += count_descendants(mid, visited_desc)
        return count
    
    thread_length = count_descendants(thread_id, set())
    
    return (thread_id, thread_position, thread_length)


def generate_thread_index(thread_map: Dict[str, Dict], output_dir: Path) -> Dict[str, List[Dict]]:
    """Generate thread index files grouped by thread_id.
    
    Returns a dict mapping thread_id -> list of email metadata in chronological order.
    Writes one index file per thread to output_dir/threads/
    """
    # Group emails by thread
    threads = defaultdict(list)
    
    for message_id, info in thread_map.items():
        thread_id, position, length = reconstruct_thread(message_id, thread_map)
        if thread_id:
            threads[thread_id].append({
                'message_id': message_id,
                'file_path': info['file_path'],
                'subject': info['subject'],
                'date_sent': info['date_sent'],
                'thread_position': position,
                'thread_length': length
            })
    
    # Sort each thread by date
    for thread_id in threads:
        threads[thread_id].sort(key=lambda x: x['date_sent'] or '')
    
    # Write thread index files
    threads_dir = output_dir / 'threads'
    threads_dir.mkdir(parents=True, exist_ok=True)
    
    for thread_id, emails in threads.items():
        # Sanitize thread_id for filename (remove angle brackets, slashes)
        safe_thread_id = re.sub(r'[<>:/\\|?*]', '_', thread_id)
        index_file = threads_dir / f'{safe_thread_id}.json'
        
        with open(index_file, 'w', encoding='utf-8') as f:
            json.dump({
                'thread_id': thread_id,
                'thread_length': len(emails),
                'emails': emails
            }, f, indent=2, ensure_ascii=False)
    
    return dict(threads)


def make_description(body, max_len=160):
    """Extract first max_len chars of body as description (markdown.new convention).

    Strips markdown formatting, collapses whitespace, and truncates with
    ellipsis if the text exceeds max_len.
    """
    if not body:
        return ""
    # Strip markdown links, images, emphasis
    text = re.sub(r'!\[([^\]]*)\]\([^)]*\)', r'\1', body)  # images
    text = re.sub(r'\[([^\]]*)\]\([^)]*\)', r'\1', text)    # links
    text = re.sub(r'[*_]{1,3}', '', text)                    # emphasis
    text = re.sub(r'^#{1,6}\s+', '', text, flags=re.MULTILINE)  # headings
    text = re.sub(r'\n+', ' ', text)                          # newlines
    text = re.sub(r'\s+', ' ', text).strip()                  # whitespace
    if len(text) > max_len:
        # Truncate at word boundary
        text = text[:max_len].rsplit(' ', 1)[0] + '...'
    return text


def get_file_size(file_path):
    """Get file size in bytes."""
    try:
        return os.path.getsize(file_path)
    except OSError:
        return 0


def extract_header_safe(msg, header, default=''):
    """Safely extract an email header, handling both eml and msg formats."""
    if hasattr(msg, 'sender'):  # extract_msg object
        header_map = {
            'From': getattr(msg, 'sender', default),
            'To': getattr(msg, 'to', default),
            'Cc': getattr(msg, 'cc', default),
            'Bcc': getattr(msg, 'bcc', default),
            'Subject': getattr(msg, 'subject', default),
            'Date': getattr(msg, 'date', default),
            'Message-ID': getattr(msg, 'messageId', default),
            'In-Reply-To': getattr(msg, 'inReplyTo', default),
        }
        return header_map.get(header, default) or default
    else:  # email.message.EmailMessage
        return msg.get(header, default) or default


def parse_date_safe(date_str):
    """Parse a date string to ISO format, returning original on failure."""
    if not date_str or date_str == 'Unknown':
        return ''
    try:
        dt = parsedate_to_datetime(date_str)
        return dt.strftime('%Y-%m-%dT%H:%M:%S%z')
    except Exception:
        return str(date_str)


def build_frontmatter(metadata):
    """Build YAML frontmatter string from metadata dict.

    Handles scalar values, lists of dicts (attachments), nested dicts
    of lists (entities), and proper YAML escaping for all string values.
    """
    lines = ['---']
    for key, value in metadata.items():
        if key == 'attachments' and isinstance(value, list):
            if not value:
                lines.append(f'{key}: []')
            else:
                lines.append(f'{key}:')
                for att in value:
                    lines.append(f'  - filename: {yaml_escape(att["filename"])}')
                    lines.append(f'    size: {yaml_escape(att["size"])}')
        elif key == 'entities' and isinstance(value, dict):
            if not value:
                lines.append(f'{key}: {{}}')
            else:
                lines.append(f'{key}:')
                for entity_type, entity_list in value.items():
                    if entity_list:
                        lines.append(f'  {entity_type}:')
                        for entity in entity_list:
                            lines.append(f'    - {yaml_escape(entity)}')
        elif isinstance(value, (int, float)):
            lines.append(f'{key}: {value}')
        else:
            lines.append(f'{key}: {yaml_escape(value)}')
    lines.append('---')
    return '\n'.join(lines)


def run_entity_extraction(body, method='auto'):
    """Run entity extraction on email body text.

    Imports entity-extraction.py from the same directory and runs extraction.
    Returns dict of entities grouped by type, or empty dict on failure.
    """
    if not body or not body.strip():
        return {}

    try:
        script_dir = Path(__file__).parent
        # Import entity-extraction module dynamically (filename has hyphens)
        import importlib.util
        spec = importlib.util.spec_from_file_location(
            "entity_extraction",
            script_dir / "entity-extraction.py"
        )
        if spec is None or spec.loader is None:
            return {}
        mod = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(mod)
        return mod.extract_entities(body, method=method)
    except Exception as e:
        print(f"WARNING: Entity extraction failed: {e}", file=sys.stderr)
        return {}


def run_auto_summary(body, method='auto'):
    """Run auto-summary generation on email body text (t1053.7).

    Imports email-summary.py from the same directory and runs summarisation.
    Returns a 1-2 sentence summary string, or empty string on failure.
    Falls back to make_description() if the summary module is unavailable.
    """
    if not body or not body.strip():
        return ""

    try:
        script_dir = Path(__file__).parent
        import importlib.util
        spec = importlib.util.spec_from_file_location(
            "email_summary",
            script_dir / "email-summary.py"
        )
        if spec is None or spec.loader is None:
            return make_description(body)
        mod = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(mod)
        summary = mod.generate_summary(body, method=method)
        return summary if summary else make_description(body)
    except Exception as e:
        print(f"WARNING: Auto-summary failed: {e}", file=sys.stderr)
        return make_description(body)


def email_to_markdown(input_file, output_file=None, attachments_dir=None,
                      extract_entities=False, entity_method='auto',
                      auto_summary=False, summary_method='auto',
                      summarize=False, thread_map=None):
    """Convert email file to markdown with YAML frontmatter and attachment extraction.

    Output includes:
    - YAML frontmatter with visible email headers (from, to, cc, bcc, date_sent,
      date_received, subject, size, message_id, in_reply_to, attachment_count,
      attachments list)
    - Thread reconstruction fields (thread_id, thread_position, thread_length)
    - markdown.new convention fields (title = subject, description)
    - description: auto-summary (1-2 sentences) when auto_summary=True or
      summarize=True, otherwise first 160 chars of body
    - tokens_estimate for LLM context budgeting
    - entities (when extract_entities=True): people, organisations, properties,
      locations, dates extracted via spaCy/Ollama/regex
    - Body as markdown content
    
    Args:
        input_file: Path to .eml or .msg file
        output_file: Optional output path for markdown file
        attachments_dir: Optional directory for extracted attachments
        auto_summary: Enable auto-summary (legacy flag name)
        summarize: Enable auto-summary (new flag name, same effect)
        summary_method: Summary method ('auto', 'heuristic', 'ollama')
        thread_map: Optional pre-built thread map for thread reconstruction.
                   If None, thread fields will be empty.
    """
    # Support both flag names
    use_summary = auto_summary or summarize

    input_path = Path(input_file)

    # Determine file type
    ext = input_path.suffix.lower()
    if ext == '.eml':
        msg = parse_eml(input_file)
    elif ext == '.msg':
        msg = parse_msg(input_file)
    else:
        print(f"ERROR: Unsupported file type: {ext}", file=sys.stderr)
        print("Supported: .eml, .msg", file=sys.stderr)
        sys.exit(1)

    # Set default output paths
    if output_file is None:
        output_file = input_path.with_suffix('.md')

    if attachments_dir is None:
        attachments_dir = input_path.parent / f"{input_path.stem}_attachments"

    # Extract all visible headers
    from_addr = extract_header_safe(msg, 'From', 'Unknown')
    to_addr = extract_header_safe(msg, 'To', 'Unknown')
    cc_addr = extract_header_safe(msg, 'Cc')
    bcc_addr = extract_header_safe(msg, 'Bcc')
    subject = extract_header_safe(msg, 'Subject', 'No Subject')
    message_id = extract_header_safe(msg, 'Message-ID')
    in_reply_to = extract_header_safe(msg, 'In-Reply-To')

    # Parse dates
    date_sent_raw = extract_header_safe(msg, 'Date')
    date_received_raw = extract_header_safe(msg, 'Received')
    # The Received header contains routing info; extract the date portion
    if date_received_raw and ';' in date_received_raw:
        date_received_raw = date_received_raw.rsplit(';', 1)[-1].strip()
    date_sent = parse_date_safe(date_sent_raw)
    date_received = parse_date_safe(date_received_raw)

    # Get file size
    file_size = get_file_size(input_file)

    # Extract body
    body = get_email_body(msg)

    # Extract attachments
    attachments = extract_attachments(msg, attachments_dir)

    # Build attachment metadata for frontmatter
    attachment_meta = []
    for att in attachments:
        attachment_meta.append({
            'filename': att['filename'],
            'size': format_size(att['size']),
        })

    # markdown.new convention fields — auto-summary (t1053.7) or truncation
    if use_summary:
        description = run_auto_summary(body, method=summary_method)
    else:
        description = make_description(body)

    # Token estimate for the full converted content (body + frontmatter)
    tokens_estimate = estimate_tokens(body)

    # Thread reconstruction
    thread_id = ''
    thread_position = 0
    thread_length = 0
    if thread_map and message_id:
        thread_id, thread_position, thread_length = reconstruct_thread(message_id, thread_map)

    # Build ordered metadata for frontmatter
    from collections import OrderedDict
    metadata = OrderedDict()
    # markdown.new convention
    metadata['title'] = subject
    metadata['description'] = description
    # Email headers
    metadata['from'] = from_addr
    metadata['to'] = to_addr
    if cc_addr:
        metadata['cc'] = cc_addr
    if bcc_addr:
        metadata['bcc'] = bcc_addr
    metadata['date_sent'] = date_sent
    if date_received:
        metadata['date_received'] = date_received
    metadata['subject'] = subject
    metadata['size'] = format_size(file_size)
    metadata['message_id'] = message_id
    if in_reply_to:
        metadata['in_reply_to'] = in_reply_to
    # Thread reconstruction fields
    if thread_id:
        metadata['thread_id'] = thread_id
        metadata['thread_position'] = thread_position
        metadata['thread_length'] = thread_length
    metadata['attachment_count'] = len(attachments)
    metadata['attachments'] = attachment_meta
    metadata['tokens_estimate'] = tokens_estimate

    # Entity extraction (t1044.6)
    if extract_entities:
        entities = run_entity_extraction(body, method=entity_method)
        if entities:
            metadata['entities'] = entities

    # Build markdown with YAML frontmatter
    frontmatter = build_frontmatter(metadata)
    md_content = f"{frontmatter}\n\n{body}"

    # Write markdown file
    with open(output_file, 'w', encoding='utf-8') as f:
        f.write(md_content)

    return {
        'markdown': str(output_file),
        'attachments': attachments,
        'attachments_dir': str(attachments_dir) if attachments else None
    }


def main():
    parser = argparse.ArgumentParser(
        description='Convert .eml/.msg email files to markdown with attachment extraction and thread reconstruction'
    )
    parser.add_argument('input', help='Input email file (.eml or .msg) or directory for batch processing')
    parser.add_argument('--output', '-o', help='Output markdown file (default: input.md)')
    parser.add_argument('--attachments-dir', help='Directory for attachments (default: input_attachments/)')
    parser.add_argument('--extract-entities', action='store_true',
                        help='Extract named entities (people, orgs, locations, dates) into frontmatter')
    parser.add_argument('--entity-method', choices=['auto', 'spacy', 'ollama', 'regex'],
                        default='auto', help='Entity extraction method (default: auto)')
    parser.add_argument('--auto-summary', action='store_true',
                        help='Generate intelligent summary for description field '
                             '(heuristic for short emails, LLM for long ones)')
    parser.add_argument('--summarize', action='store_true',
                        help='Generate auto-summary for description field (t1053.7) '
                             '(alias for --auto-summary)')
    parser.add_argument('--summary-method', choices=['auto', 'heuristic', 'ollama'],
                        default='auto', help='Summary method (default: auto — word-count decides)')
    parser.add_argument('--batch', action='store_true', 
                       help='Process all .eml/.msg files in input directory with thread reconstruction')
    parser.add_argument('--threads-index', action='store_true',
                       help='Generate thread index files (requires --batch)')
    
    args = parser.parse_args()
    
    input_path = Path(args.input)

    # Support both --auto-summary and --summarize flags
    use_summary = args.auto_summary or args.summarize
    
    # Batch processing mode
    if args.batch or input_path.is_dir():
        if not input_path.is_dir():
            print("ERROR: --batch requires input to be a directory", file=sys.stderr)
            sys.exit(1)
        
        # Build thread map for all emails
        print("Building thread map...")
        thread_map = build_thread_map(input_path)
        print(f"Found {len(thread_map)} emails")
        
        # Process each email
        processed = 0
        for message_id, info in thread_map.items():
            email_file = Path(info['file_path'])
            try:
                result = email_to_markdown(
                    email_file,
                    output_file=email_file.with_suffix('.md'),
                    extract_entities=args.extract_entities,
                    entity_method=args.entity_method,
                    auto_summary=use_summary,
                    summary_method=args.summary_method,
                    thread_map=thread_map
                )
                processed += 1
                print(f"Processed: {email_file.name} -> {result['markdown']}")
            except Exception as e:
                print(f"ERROR processing {email_file}: {e}", file=sys.stderr)
        
        print(f"\nProcessed {processed}/{len(thread_map)} emails")
        
        # Generate thread index if requested
        if args.threads_index:
            print("\nGenerating thread index files...")
            threads = generate_thread_index(thread_map, input_path)
            print(f"Created {len(threads)} thread index files in {input_path}/threads/")
    
    # Single file mode
    else:
        if not input_path.is_file():
            print(f"ERROR: Input file not found: {input_path}", file=sys.stderr)
            sys.exit(1)
        
        # For single file, optionally build thread map if parent dir has other emails
        thread_map = None
        if input_path.parent.exists():
            try:
                thread_map = build_thread_map(input_path.parent)
                if thread_map:
                    print(f"Found {len(thread_map)} emails in directory for thread reconstruction")
            except Exception:
                pass  # Thread reconstruction is optional
        
        result = email_to_markdown(
            args.input, args.output, args.attachments_dir,
            extract_entities=args.extract_entities,
            entity_method=args.entity_method,
            auto_summary=use_summary,
            summary_method=args.summary_method,
            thread_map=thread_map
        )
        
        print(f"Created: {result['markdown']}")
        if result['attachments']:
            print(f"Extracted {len(result['attachments'])} attachment(s) to: {result['attachments_dir']}")
            for att in result['attachments']:
                print(f"  - {att['filename']} ({format_size(att['size'])})")


if __name__ == '__main__':
    main()
