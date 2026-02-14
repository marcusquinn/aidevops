#!/usr/bin/env python3
"""
email-to-markdown.py - Convert .eml/.msg files to markdown with attachment extraction
Part of aidevops framework: https://aidevops.sh

Usage: email-to-markdown.py <input-file> [--output <file>] [--attachments-dir <dir>]
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


def email_to_markdown(input_file, output_file=None, attachments_dir=None):
    """Convert email file to markdown with attachment extraction."""
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
    
    # Extract metadata
    if hasattr(msg, 'sender'):  # extract_msg
        from_addr = msg.sender
        to_addr = msg.to
        subject = msg.subject
        date = msg.date
    else:  # email.message
        from_addr = msg.get('From', 'Unknown')
        to_addr = msg.get('To', 'Unknown')
        subject = msg.get('Subject', 'No Subject')
        date_str = msg.get('Date', '')
        try:
            date = parsedate_to_datetime(date_str).strftime('%Y-%m-%d %H:%M:%S') if date_str else 'Unknown'
        except:
            date = date_str or 'Unknown'
    
    # Extract body
    body = get_email_body(msg)
    
    # Extract attachments
    attachments = extract_attachments(msg, attachments_dir)
    
    # Build markdown
    md_content = f"""# {subject}

**From:** {from_addr}  
**To:** {to_addr}  
**Date:** {date}

---

{body}
"""
    
    # Add attachments section if any
    if attachments:
        md_content += "\n\n---\n\n## Attachments\n\n"
        for att in attachments:
            md_content += f"- [{att['filename']}]({att['path']}) ({format_size(att['size'])})\n"
    
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
    
    args = parser.parse_args()
    
    result = email_to_markdown(args.input, args.output, args.attachments_dir)
    
    print(f"Created: {result['markdown']}")
    if result['attachments']:
        print(f"Extracted {len(result['attachments'])} attachment(s) to: {result['attachments_dir']}")
        for att in result['attachments']:
            print(f"  - {att['filename']} ({format_size(att['size'])})")


if __name__ == '__main__':
    main()
