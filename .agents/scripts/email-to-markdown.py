#!/usr/bin/env python3
"""
email-to-markdown.py - Convert .eml/.msg files to markdown with attachment extraction
Part of aidevops framework: https://aidevops.sh

Usage: email-to-markdown.py <input-file> [--output <file>] [--attachments-dir <dir>]

Output format: YAML frontmatter with visible headers (from, to, cc, bcc, date_sent,
date_received, subject, size, message_id, in_reply_to, attachment_count, attachments),
markdown.new convention fields (title, description), and tokens_estimate for LLM context.
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


def email_to_markdown(input_file, output_file=None, attachments_dir=None,
                      extract_entities=False, entity_method='auto'):
    """Convert email file to markdown with YAML frontmatter and attachment extraction.

    Output includes:
    - YAML frontmatter with visible email headers (from, to, cc, bcc, date_sent,
      date_received, subject, size, message_id, in_reply_to, attachment_count,
      attachments list)
    - markdown.new convention fields (title = subject, description = first 160 chars)
    - tokens_estimate for LLM context budgeting
    - entities (when extract_entities=True): people, organisations, properties,
      locations, dates extracted via spaCy/Ollama/regex
    - Body as markdown content
    """
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

    # markdown.new convention fields
    description = make_description(body)

    # Token estimate for the full converted content (body + frontmatter)
    tokens_estimate = estimate_tokens(body)

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
        description='Convert .eml/.msg email files to markdown with attachment extraction'
    )
    parser.add_argument('input', help='Input email file (.eml or .msg)')
    parser.add_argument('--output', '-o', help='Output markdown file (default: input.md)')
    parser.add_argument('--attachments-dir', help='Directory for attachments (default: input_attachments/)')
    parser.add_argument('--extract-entities', action='store_true',
                        help='Extract named entities (people, orgs, locations, dates) into frontmatter')
    parser.add_argument('--entity-method', choices=['auto', 'spacy', 'ollama', 'regex'],
                        default='auto', help='Entity extraction method (default: auto)')
    
    args = parser.parse_args()
    
    result = email_to_markdown(
        args.input, args.output, args.attachments_dir,
        extract_entities=args.extract_entities,
        entity_method=args.entity_method
    )
    
    print(f"Created: {result['markdown']}")
    if result['attachments']:
        print(f"Extracted {len(result['attachments'])} attachment(s) to: {result['attachments_dir']}")
        for att in result['attachments']:
            print(f"  - {att['filename']} ({format_size(att['size'])})")


if __name__ == '__main__':
    main()
