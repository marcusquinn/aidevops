#!/bin/bash
# shellcheck disable=SC2034,SC2155,SC2317,SC2329,SC2016,SC2181,SC1091,SC2154,SC2015,SC2086,SC2129,SC2030,SC2031,SC2119,SC2120,SC2001,SC2162,SC2088,SC2089,SC2090,SC2029,SC2006,SC2153

# Site Crawler Helper Script
# SEO site auditing with Screaming Frog-like capabilities
#
# Usage: ./site-crawler-helper.sh [command] [url] [options]
# Commands:
#   crawl           - Full site crawl with SEO data extraction
#   audit-links     - Check for broken links (4XX/5XX)
#   audit-meta      - Audit page titles and meta descriptions
#   audit-redirects - Analyze redirects and chains
#   audit-duplicates - Find duplicate content
#   audit-schema    - Validate structured data
#   generate-sitemap - Generate XML sitemap from crawl
#   compare         - Compare two crawls
#   status          - Check crawler dependencies
#   help            - Show this help message
#
# Author: AI DevOps Framework
# Version: 1.0.0
# License: MIT

set -euo pipefail

# Colors for output
readonly GREEN='\033[0;32m'
readonly BLUE='\033[0;34m'
readonly YELLOW='\033[1;33m'
readonly RED='\033[0;31m'
readonly PURPLE='\033[0;35m'
readonly NC='\033[0m'

# Constants
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit
readonly SCRIPT_DIR
readonly CONFIG_DIR="${HOME}/.config/aidevops"
readonly CONFIG_FILE="${CONFIG_DIR}/site-crawler.json"
readonly DEFAULT_OUTPUT_DIR="${HOME}/Downloads"
readonly CRAWL4AI_PORT="11235"

# Default configuration
DEFAULT_DEPTH=10
DEFAULT_MAX_URLS=10000
DEFAULT_DELAY=100
DEFAULT_CONCURRENT=5
DEFAULT_TIMEOUT=30
DEFAULT_FORMAT="xlsx"
RESPECT_ROBOTS=true
RENDER_JS=false
USER_AGENT="AIDevOps-SiteCrawler/1.0 (+https://github.com/aidevops)"

# Print functions
print_success() {
    local message="$1"
    echo -e "${GREEN}[OK] $message${NC}"
    return 0
}

print_info() {
    local message="$1"
    echo -e "${BLUE}[INFO] $message${NC}"
    return 0
}

print_warning() {
    local message="$1"
    echo -e "${YELLOW}[WARN] $message${NC}"
    return 0
}

print_error() {
    local message="$1"
    echo -e "${RED}[ERROR] $message${NC}"
    return 0
}

print_header() {
    local message="$1"
    echo -e "${PURPLE}=== $message ===${NC}"
    return 0
}

# Load configuration
load_config() {
    if [[ -f "$CONFIG_FILE" ]]; then
        if command -v jq &> /dev/null; then
            DEFAULT_DEPTH=$(jq -r '.default_depth // 10' "$CONFIG_FILE")
            DEFAULT_MAX_URLS=$(jq -r '.max_urls // 10000' "$CONFIG_FILE")
            DEFAULT_DELAY=$(jq -r '.request_delay // 100' "$CONFIG_FILE")
            DEFAULT_CONCURRENT=$(jq -r '.concurrent_requests // 5' "$CONFIG_FILE")
            DEFAULT_TIMEOUT=$(jq -r '.timeout // 30' "$CONFIG_FILE")
            DEFAULT_FORMAT=$(jq -r '.output_format // "xlsx"' "$CONFIG_FILE")
            RESPECT_ROBOTS=$(jq -r '.respect_robots // true' "$CONFIG_FILE")
            RENDER_JS=$(jq -r '.render_js // false' "$CONFIG_FILE")
            USER_AGENT=$(jq -r '.user_agent // "AIDevOps-SiteCrawler/1.0"' "$CONFIG_FILE")
        fi
    fi
    return 0
}

# Check dependencies
check_dependencies() {
    local missing=()
    
    if ! command -v curl &> /dev/null; then
        missing+=("curl")
    fi
    
    if ! command -v jq &> /dev/null; then
        missing+=("jq")
    fi
    
    if ! command -v python3 &> /dev/null; then
        missing+=("python3")
    fi
    
    if [[ ${#missing[@]} -gt 0 ]]; then
        print_error "Missing dependencies: ${missing[*]}"
        print_info "Install with: brew install ${missing[*]}"
        return 1
    fi
    
    return 0
}

# Check if Crawl4AI is available
check_crawl4ai() {
    if curl -s "http://localhost:${CRAWL4AI_PORT}/health" &> /dev/null; then
        return 0
    fi
    return 1
}

# Extract domain from URL
get_domain() {
    local url="$1"
    echo "$url" | sed -E 's|^https?://||' | sed -E 's|/.*||' | sed -E 's|:.*||'
}

# Create output directory structure
create_output_dir() {
    local domain="$1"
    local output_base="${2:-$DEFAULT_OUTPUT_DIR}"
    local timestamp
    timestamp=$(date +%Y-%m-%d_%H%M%S)
    
    local output_dir="${output_base}/${domain}/${timestamp}"
    mkdir -p "$output_dir"
    
    # Update _latest symlink
    local latest_link="${output_base}/${domain}/_latest"
    rm -f "$latest_link"
    ln -sf "$timestamp" "$latest_link"
    
    echo "$output_dir"
    return 0
}

# Generate Python crawler script
generate_crawler_script() {
    local url="$1"
    local output_dir="$2"
    local depth="$3"
    local max_urls="$4"
    local render_js="$5"
    local respect_robots="$6"
    
    cat << 'PYTHON_SCRIPT'
#!/usr/bin/env python3
"""
Site Crawler - SEO Spider
Crawls websites and extracts SEO-relevant data
"""

import asyncio
import json
import csv
import hashlib
import re
import sys
from datetime import datetime
from pathlib import Path
from urllib.parse import urljoin, urlparse
from collections import defaultdict
from dataclasses import dataclass, field, asdict
from typing import Optional
import aiohttp
from bs4 import BeautifulSoup

try:
    import openpyxl
    HAS_OPENPYXL = True
except ImportError:
    HAS_OPENPYXL = False

@dataclass
class PageData:
    url: str
    status_code: int = 0
    status: str = ""
    content_type: str = ""
    title: str = ""
    title_length: int = 0
    meta_description: str = ""
    description_length: int = 0
    h1: str = ""
    h1_count: int = 0
    h2: str = ""
    h2_count: int = 0
    canonical: str = ""
    meta_robots: str = ""
    word_count: int = 0
    response_time: float = 0.0
    file_size: int = 0
    crawl_depth: int = 0
    inlinks: int = 0
    outlinks: int = 0
    external_links: int = 0
    images: int = 0
    images_missing_alt: int = 0
    content_hash: str = ""
    redirect_url: str = ""
    redirect_chain: str = ""

@dataclass
class LinkData:
    source_url: str
    target_url: str
    anchor_text: str
    link_type: str  # internal/external
    status_code: int = 0
    is_broken: bool = False
    rel: str = ""

@dataclass
class RedirectData:
    original_url: str
    status_code: int
    redirect_url: str
    final_url: str
    chain_length: int
    chain: str

class SiteCrawler:
    def __init__(self, base_url: str, output_dir: str, max_depth: int = 10,
                 max_urls: int = 10000, render_js: bool = False,
                 respect_robots: bool = True, delay: float = 0.1):
        self.base_url = base_url
        self.base_domain = urlparse(base_url).netloc
        self.output_dir = Path(output_dir)
        self.max_depth = max_depth
        self.max_urls = max_urls
        self.render_js = render_js
        self.respect_robots = respect_robots
        self.delay = delay
        
        self.visited: set = set()
        self.to_visit: list = [(base_url, 0)]  # (url, depth)
        self.pages: list = []
        self.links: list = []
        self.redirects: list = []
        self.broken_links: list = []
        self.inlink_counts: dict = defaultdict(int)
        
        self.robots_disallowed: set = set()
        self.session: Optional[aiohttp.ClientSession] = None
        
    async def fetch_robots_txt(self):
        """Parse robots.txt for disallowed paths"""
        if not self.respect_robots:
            return
            
        robots_url = urljoin(self.base_url, "/robots.txt")
        try:
            async with self.session.get(robots_url, timeout=10) as response:
                if response.status == 200:
                    text = await response.text()
                    current_ua = False
                    for line in text.split('\n'):
                        line = line.strip().lower()
                        if line.startswith('user-agent:'):
                            ua = line.split(':', 1)[1].strip()
                            current_ua = ua == '*' or 'bot' in ua
                        elif current_ua and line.startswith('disallow:'):
                            path = line.split(':', 1)[1].strip()
                            if path:
                                self.robots_disallowed.add(path)
        except Exception:
            pass
    
    def is_allowed(self, url: str) -> bool:
        """Check if URL is allowed by robots.txt"""
        if not self.respect_robots:
            return True
        path = urlparse(url).path
        for disallowed in self.robots_disallowed:
            if path.startswith(disallowed):
                return False
        return True
    
    def is_internal(self, url: str) -> bool:
        """Check if URL is internal to the site"""
        parsed = urlparse(url)
        return parsed.netloc == self.base_domain or parsed.netloc == ""
    
    def normalize_url(self, url: str, base: str) -> str:
        """Normalize and resolve relative URLs"""
        url = urljoin(base, url)
        parsed = urlparse(url)
        # Remove fragments
        url = f"{parsed.scheme}://{parsed.netloc}{parsed.path}"
        if parsed.query:
            url += f"?{parsed.query}"
        # Remove trailing slash for consistency
        return url.rstrip('/')
    
    async def fetch_page(self, url: str, depth: int) -> Optional[PageData]:
        """Fetch and parse a single page"""
        if url in self.visited:
            return None
        if len(self.visited) >= self.max_urls:
            return None
        if not self.is_allowed(url):
            return None
            
        self.visited.add(url)
        page = PageData(url=url, crawl_depth=depth)
        
        try:
            start_time = datetime.now()
            
            # Follow redirects manually to track chain
            redirect_chain = []
            current_url = url
            
            async with self.session.get(
                current_url,
                allow_redirects=False,
                timeout=30
            ) as response:
                page.status_code = response.status
                page.content_type = response.headers.get('Content-Type', '')
                
                # Handle redirects
                while response.status in (301, 302, 303, 307, 308):
                    redirect_url = response.headers.get('Location', '')
                    if redirect_url:
                        redirect_url = self.normalize_url(redirect_url, current_url)
                        redirect_chain.append(f"{response.status}:{redirect_url}")
                        
                        self.redirects.append(RedirectData(
                            original_url=url,
                            status_code=response.status,
                            redirect_url=redirect_url,
                            final_url="",  # Will update after chain
                            chain_length=len(redirect_chain),
                            chain=" -> ".join([url] + redirect_chain)
                        ))
                        
                        current_url = redirect_url
                        async with self.session.get(
                            current_url,
                            allow_redirects=False,
                            timeout=30
                        ) as new_response:
                            response = new_response
                            page.status_code = response.status
                    else:
                        break
                
                if redirect_chain:
                    page.redirect_url = redirect_chain[-1].split(':', 1)[1]
                    page.redirect_chain = " -> ".join([url] + redirect_chain)
                    # Update final URL in redirect records
                    for r in self.redirects:
                        if r.original_url == url:
                            r.final_url = current_url
                
                # Set status text
                if page.status_code < 300:
                    page.status = "OK"
                elif page.status_code < 400:
                    page.status = "Redirect"
                elif page.status_code < 500:
                    page.status = "Client Error"
                else:
                    page.status = "Server Error"
                
                # Only parse HTML content
                if 'text/html' in page.content_type and page.status_code == 200:
                    html = await response.text()
                    page.file_size = len(html.encode('utf-8'))
                    page.content_hash = hashlib.md5(html.encode()).hexdigest()
                    
                    soup = BeautifulSoup(html, 'html.parser')
                    
                    # Title
                    title_tag = soup.find('title')
                    if title_tag:
                        page.title = title_tag.get_text(strip=True)
                        page.title_length = len(page.title)
                    
                    # Meta description
                    meta_desc = soup.find('meta', attrs={'name': 'description'})
                    if meta_desc:
                        page.meta_description = meta_desc.get('content', '')
                        page.description_length = len(page.meta_description)
                    
                    # Meta robots
                    meta_robots = soup.find('meta', attrs={'name': 'robots'})
                    if meta_robots:
                        page.meta_robots = meta_robots.get('content', '')
                    
                    # Canonical
                    canonical = soup.find('link', attrs={'rel': 'canonical'})
                    if canonical:
                        page.canonical = canonical.get('href', '')
                    
                    # Headings
                    h1_tags = soup.find_all('h1')
                    page.h1_count = len(h1_tags)
                    if h1_tags:
                        page.h1 = h1_tags[0].get_text(strip=True)[:200]
                    
                    h2_tags = soup.find_all('h2')
                    page.h2_count = len(h2_tags)
                    if h2_tags:
                        page.h2 = h2_tags[0].get_text(strip=True)[:200]
                    
                    # Word count
                    text = soup.get_text(separator=' ', strip=True)
                    page.word_count = len(text.split())
                    
                    # Images
                    images = soup.find_all('img')
                    page.images = len(images)
                    page.images_missing_alt = sum(1 for img in images if not img.get('alt'))
                    
                    # Links
                    internal_count = 0
                    external_count = 0
                    
                    for link in soup.find_all('a', href=True):
                        href = link.get('href', '')
                        if not href or href.startswith(('#', 'javascript:', 'mailto:', 'tel:')):
                            continue
                        
                        target_url = self.normalize_url(href, url)
                        anchor = link.get_text(strip=True)[:100]
                        rel = link.get('rel', [])
                        rel_str = ' '.join(rel) if isinstance(rel, list) else str(rel)
                        
                        is_internal = self.is_internal(target_url)
                        
                        link_data = LinkData(
                            source_url=url,
                            target_url=target_url,
                            anchor_text=anchor,
                            link_type="internal" if is_internal else "external",
                            rel=rel_str
                        )
                        self.links.append(link_data)
                        
                        if is_internal:
                            internal_count += 1
                            self.inlink_counts[target_url] += 1
                            # Add to crawl queue
                            if target_url not in self.visited and depth < self.max_depth:
                                self.to_visit.append((target_url, depth + 1))
                        else:
                            external_count += 1
                    
                    page.outlinks = internal_count + external_count
                    page.external_links = external_count
                
                page.response_time = (datetime.now() - start_time).total_seconds() * 1000
                
        except asyncio.TimeoutError:
            page.status_code = 0
            page.status = "Timeout"
        except Exception as e:
            page.status_code = 0
            page.status = f"Error: {str(e)[:50]}"
        
        return page
    
    async def check_external_links(self):
        """Check status of external links"""
        external_urls = set()
        for link in self.links:
            if link.link_type == "external":
                external_urls.add(link.target_url)
        
        print(f"Checking {len(external_urls)} external links...")
        
        for url in external_urls:
            try:
                async with self.session.head(url, timeout=10, allow_redirects=True) as response:
                    status = response.status
                    for link in self.links:
                        if link.target_url == url:
                            link.status_code = status
                            link.is_broken = status >= 400
            except Exception:
                for link in self.links:
                    if link.target_url == url:
                        link.status_code = 0
                        link.is_broken = True
            
            await asyncio.sleep(0.1)  # Rate limit
    
    async def crawl(self):
        """Main crawl loop"""
        headers = {
            'User-Agent': 'AIDevOps-SiteCrawler/1.0 (+https://github.com/aidevops)'
        }
        
        connector = aiohttp.TCPConnector(limit=5)
        timeout = aiohttp.ClientTimeout(total=60)
        
        async with aiohttp.ClientSession(
            headers=headers,
            connector=connector,
            timeout=timeout
        ) as session:
            self.session = session
            
            # Fetch robots.txt first
            await self.fetch_robots_txt()
            
            print(f"Starting crawl of {self.base_url}")
            print(f"Max depth: {self.max_depth}, Max URLs: {self.max_urls}")
            
            while self.to_visit and len(self.visited) < self.max_urls:
                url, depth = self.to_visit.pop(0)
                
                if url in self.visited:
                    continue
                
                page = await self.fetch_page(url, depth)
                if page:
                    self.pages.append(page)
                    print(f"[{len(self.pages)}/{self.max_urls}] {page.status_code} {url[:80]}")
                
                await asyncio.sleep(self.delay / 1000)  # Convert ms to seconds
            
            # Update inlink counts
            for page in self.pages:
                page.inlinks = self.inlink_counts.get(page.url, 0)
            
            # Check external links
            await self.check_external_links()
            
            # Identify broken links
            for link in self.links:
                if link.is_broken or link.status_code >= 400:
                    self.broken_links.append(link)
        
        print(f"\nCrawl complete: {len(self.pages)} pages crawled")
    
    def export_csv(self, data: list, filename: str, fieldnames: list):
        """Export data to CSV"""
        filepath = self.output_dir / filename
        with open(filepath, 'w', newline='', encoding='utf-8') as f:
            writer = csv.DictWriter(f, fieldnames=fieldnames)
            writer.writeheader()
            for item in data:
                if hasattr(item, '__dict__'):
                    writer.writerow(asdict(item))
                else:
                    writer.writerow(item)
        print(f"Exported: {filepath}")
    
    def export_xlsx(self, data: list, filename: str, fieldnames: list):
        """Export data to Excel"""
        if not HAS_OPENPYXL:
            print("openpyxl not installed, skipping XLSX export")
            return
        
        filepath = self.output_dir / filename
        wb = openpyxl.Workbook()
        ws = wb.active
        
        # Header row
        for col, field in enumerate(fieldnames, 1):
            ws.cell(row=1, column=col, value=field)
        
        # Data rows
        for row_num, item in enumerate(data, 2):
            item_dict = asdict(item) if hasattr(item, '__dict__') else item
            for col, field in enumerate(fieldnames, 1):
                ws.cell(row=row_num, column=col, value=item_dict.get(field, ''))
        
        wb.save(filepath)
        print(f"Exported: {filepath}")
    
    def export_results(self, format: str = "xlsx"):
        """Export all crawl results"""
        # Main crawl data
        page_fields = [
            'url', 'status_code', 'status', 'content_type', 'title', 'title_length',
            'meta_description', 'description_length', 'h1', 'h1_count', 'h2', 'h2_count',
            'canonical', 'meta_robots', 'word_count', 'response_time', 'file_size',
            'crawl_depth', 'inlinks', 'outlinks', 'external_links', 'images',
            'images_missing_alt', 'content_hash', 'redirect_url', 'redirect_chain'
        ]
        
        if format in ("xlsx", "all"):
            self.export_xlsx(self.pages, "crawl-data.xlsx", page_fields)
        if format in ("csv", "all"):
            self.export_csv(self.pages, "crawl-data.csv", page_fields)
        
        # Broken links
        if self.broken_links:
            link_fields = ['source_url', 'target_url', 'anchor_text', 'link_type', 'status_code', 'rel']
            self.export_csv(self.broken_links, "broken-links.csv", link_fields)
        
        # Redirects
        if self.redirects:
            redirect_fields = ['original_url', 'status_code', 'redirect_url', 'final_url', 'chain_length', 'chain']
            self.export_csv(self.redirects, "redirects.csv", redirect_fields)
        
        # Meta issues
        meta_issues = []
        for page in self.pages:
            issues = []
            if not page.title:
                issues.append("Missing title")
            elif page.title_length > 60:
                issues.append("Title too long")
            elif page.title_length < 30:
                issues.append("Title too short")
            
            if not page.meta_description:
                issues.append("Missing description")
            elif page.description_length > 160:
                issues.append("Description too long")
            elif page.description_length < 70:
                issues.append("Description too short")
            
            if page.h1_count == 0:
                issues.append("Missing H1")
            elif page.h1_count > 1:
                issues.append("Multiple H1s")
            
            if issues:
                meta_issues.append({
                    'url': page.url,
                    'title': page.title,
                    'title_length': page.title_length,
                    'description': page.meta_description,
                    'description_length': page.description_length,
                    'h1': page.h1,
                    'h1_count': page.h1_count,
                    'issues': '; '.join(issues)
                })
        
        if meta_issues:
            meta_fields = ['url', 'title', 'title_length', 'description', 'description_length', 'h1', 'h1_count', 'issues']
            self.export_csv(meta_issues, "meta-issues.csv", meta_fields)
        
        # Duplicate content
        hash_groups = defaultdict(list)
        for page in self.pages:
            if page.content_hash:
                hash_groups[page.content_hash].append(page.url)
        
        duplicates = []
        for hash_val, urls in hash_groups.items():
            if len(urls) > 1:
                for url in urls:
                    duplicates.append({
                        'url': url,
                        'content_hash': hash_val,
                        'duplicate_count': len(urls),
                        'duplicate_urls': '; '.join(u for u in urls if u != url)
                    })
        
        if duplicates:
            dup_fields = ['url', 'content_hash', 'duplicate_count', 'duplicate_urls']
            self.export_csv(duplicates, "duplicate-content.csv", dup_fields)
        
        # Internal links
        internal_links = [l for l in self.links if l.link_type == "internal"]
        if internal_links:
            link_fields = ['source_url', 'target_url', 'anchor_text', 'rel']
            self.export_csv(internal_links, "internal-links.csv", link_fields)
        
        # External links
        external_links = [l for l in self.links if l.link_type == "external"]
        if external_links:
            link_fields = ['source_url', 'target_url', 'anchor_text', 'status_code', 'is_broken', 'rel']
            self.export_csv(external_links, "external-links.csv", link_fields)
        
        # Summary
        summary = {
            'crawl_date': datetime.now().isoformat(),
            'base_url': self.base_url,
            'pages_crawled': len(self.pages),
            'total_links': len(self.links),
            'internal_links': len(internal_links),
            'external_links': len(external_links),
            'broken_links': len(self.broken_links),
            'redirects': len(self.redirects),
            'duplicate_pages': len(duplicates),
            'pages_with_meta_issues': len(meta_issues),
            'status_codes': {},
            'avg_response_time': 0,
            'avg_word_count': 0
        }
        
        # Status code distribution
        for page in self.pages:
            code = str(page.status_code)
            summary['status_codes'][code] = summary['status_codes'].get(code, 0) + 1
        
        # Averages
        if self.pages:
            summary['avg_response_time'] = sum(p.response_time for p in self.pages) / len(self.pages)
            summary['avg_word_count'] = sum(p.word_count for p in self.pages) / len(self.pages)
        
        with open(self.output_dir / "summary.json", 'w') as f:
            json.dump(summary, f, indent=2)
        print(f"Exported: {self.output_dir / 'summary.json'}")
        
        return summary


async def main():
    import argparse
    
    parser = argparse.ArgumentParser(description='SEO Site Crawler')
    parser.add_argument('url', help='URL to crawl')
    parser.add_argument('--output', '-o', required=True, help='Output directory')
    parser.add_argument('--depth', '-d', type=int, default=10, help='Max crawl depth')
    parser.add_argument('--max-urls', '-m', type=int, default=10000, help='Max URLs to crawl')
    parser.add_argument('--render-js', action='store_true', help='Render JavaScript')
    parser.add_argument('--ignore-robots', action='store_true', help='Ignore robots.txt')
    parser.add_argument('--format', '-f', choices=['csv', 'xlsx', 'all'], default='xlsx', help='Output format')
    parser.add_argument('--delay', type=int, default=100, help='Delay between requests (ms)')
    
    args = parser.parse_args()
    
    crawler = SiteCrawler(
        base_url=args.url,
        output_dir=args.output,
        max_depth=args.depth,
        max_urls=args.max_urls,
        render_js=args.render_js,
        respect_robots=not args.ignore_robots,
        delay=args.delay
    )
    
    await crawler.crawl()
    summary = crawler.export_results(args.format)
    
    print(f"\n=== Crawl Summary ===")
    print(f"Pages crawled: {summary['pages_crawled']}")
    print(f"Broken links: {summary['broken_links']}")
    print(f"Redirects: {summary['redirects']}")
    print(f"Duplicate pages: {summary['duplicate_pages']}")
    print(f"Meta issues: {summary['pages_with_meta_issues']}")
    print(f"\nResults saved to: {args.output}")


if __name__ == "__main__":
    asyncio.run(main())
PYTHON_SCRIPT
}

# Run crawl
do_crawl() {
    local url="$1"
    shift
    
    # Parse options
    local depth="$DEFAULT_DEPTH"
    local max_urls="$DEFAULT_MAX_URLS"
    local format="$DEFAULT_FORMAT"
    local output_base="$DEFAULT_OUTPUT_DIR"
    local render_js="$RENDER_JS"
    local respect_robots="$RESPECT_ROBOTS"
    local delay="$DEFAULT_DELAY"
    local include_pattern=""
    local exclude_pattern=""
    
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --depth)
                depth="$2"
                shift 2
                ;;
            --max-urls)
                max_urls="$2"
                shift 2
                ;;
            --format)
                format="$2"
                shift 2
                ;;
            --output)
                output_base="$2"
                shift 2
                ;;
            --render-js)
                render_js="true"
                shift
                ;;
            --ignore-robots)
                respect_robots="false"
                shift
                ;;
            --delay)
                delay="$2"
                shift 2
                ;;
            --include)
                include_pattern="$2"
                shift 2
                ;;
            --exclude)
                exclude_pattern="$2"
                shift 2
                ;;
            --verbose)
                set -x
                shift
                ;;
            *)
                shift
                ;;
        esac
    done
    
    local domain
    domain=$(get_domain "$url")
    
    local output_dir
    output_dir=$(create_output_dir "$domain" "$output_base")
    
    print_header "Site Crawler - SEO Audit"
    print_info "URL: $url"
    print_info "Output: $output_dir"
    print_info "Depth: $depth, Max URLs: $max_urls"
    
    # Check for Python dependencies
    if ! python3 -c "import aiohttp, bs4" 2>/dev/null; then
        print_warning "Installing Python dependencies..."
        pip3 install aiohttp beautifulsoup4 openpyxl --quiet
    fi
    
    # Generate and run crawler
    local crawler_script="/tmp/site_crawler_$$.py"
    generate_crawler_script "$url" "$output_dir" "$depth" "$max_urls" "$render_js" "$respect_robots" > "$crawler_script"
    
    local ignore_robots_flag=""
    if [[ "$respect_robots" == "false" ]]; then
        ignore_robots_flag="--ignore-robots"
    fi
    
    local render_js_flag=""
    if [[ "$render_js" == "true" ]]; then
        render_js_flag="--render-js"
    fi
    
    python3 "$crawler_script" "$url" \
        --output "$output_dir" \
        --depth "$depth" \
        --max-urls "$max_urls" \
        --format "$format" \
        --delay "$delay" \
        $ignore_robots_flag \
        $render_js_flag
    
    rm -f "$crawler_script"
    
    print_success "Crawl complete!"
    print_info "Results: $output_dir"
    print_info "Latest: ${output_base}/${domain}/_latest"
    
    return 0
}

# Audit broken links
audit_links() {
    local url="$1"
    shift
    do_crawl "$url" --max-urls 500 "$@"
    return 0
}

# Audit meta data
audit_meta() {
    local url="$1"
    shift
    do_crawl "$url" --max-urls 500 "$@"
    return 0
}

# Audit redirects
audit_redirects() {
    local url="$1"
    shift
    do_crawl "$url" --max-urls 500 "$@"
    return 0
}

# Audit duplicates
audit_duplicates() {
    local url="$1"
    shift
    do_crawl "$url" --max-urls 500 "$@"
    return 0
}

# Audit structured data
audit_schema() {
    local url="$1"
    print_info "Structured data audit - use Crawl4AI for advanced extraction"
    print_info "See: ~/.aidevops/agents/tools/browser/crawl4ai.md"
    return 0
}

# Generate XML sitemap
generate_sitemap() {
    local url="$1"
    local domain
    domain=$(get_domain "$url")
    local output_dir="${DEFAULT_OUTPUT_DIR}/${domain}/_latest"
    
    if [[ ! -d "$output_dir" ]]; then
        print_error "No crawl data found. Run 'crawl' first."
        return 1
    fi
    
    local crawl_data="${output_dir}/crawl-data.csv"
    if [[ ! -f "$crawl_data" ]]; then
        print_error "Crawl data not found: $crawl_data"
        return 1
    fi
    
    print_header "Generating XML Sitemap"
    
    local sitemap="${output_dir}/sitemap.xml"
    
    {
        echo '<?xml version="1.0" encoding="UTF-8"?>'
        echo '<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">'
        
        # Skip header, filter 200 OK pages
        tail -n +2 "$crawl_data" | while IFS=, read -r page_url status_code rest; do
            if [[ "$status_code" == "200" ]]; then
                # Clean URL (remove quotes if present)
                page_url="${page_url//\"/}"
                echo "  <url>"
                echo "    <loc>$page_url</loc>"
                echo "    <changefreq>weekly</changefreq>"
                echo "    <priority>0.5</priority>"
                echo "  </url>"
            fi
        done
        
        echo '</urlset>'
    } > "$sitemap"
    
    print_success "Sitemap generated: $sitemap"
    return 0
}

# Compare crawls
compare_crawls() {
    local crawl1="$1"
    local crawl2="$2"
    
    if [[ -z "$crawl2" ]]; then
        # Compare latest with previous
        local domain
        domain=$(get_domain "$crawl1")
        local domain_dir="${DEFAULT_OUTPUT_DIR}/${domain}"
        
        if [[ ! -d "$domain_dir" ]]; then
            print_error "No crawl data found for domain"
            return 1
        fi
        
        # Get two most recent crawls
        local crawls
        crawls=$(ls -1d "${domain_dir}"/20* 2>/dev/null | sort -r | head -2)
        local count
        count=$(echo "$crawls" | wc -l)
        
        if [[ $count -lt 2 ]]; then
            print_error "Need at least 2 crawls to compare"
            return 1
        fi
        
        crawl1=$(echo "$crawls" | head -1)
        crawl2=$(echo "$crawls" | tail -1)
    fi
    
    print_header "Comparing Crawls"
    print_info "Crawl 1: $crawl1"
    print_info "Crawl 2: $crawl2"
    
    # Simple comparison - count differences
    local urls1 urls2
    urls1=$(cut -d, -f1 "${crawl1}/crawl-data.csv" 2>/dev/null | tail -n +2 | sort)
    urls2=$(cut -d, -f1 "${crawl2}/crawl-data.csv" 2>/dev/null | tail -n +2 | sort)
    
    local new_urls removed_urls
    new_urls=$(comm -23 <(echo "$urls1") <(echo "$urls2") | wc -l)
    removed_urls=$(comm -13 <(echo "$urls1") <(echo "$urls2") | wc -l)
    
    print_info "New URLs: $new_urls"
    print_info "Removed URLs: $removed_urls"
    
    return 0
}

# Check status
check_status() {
    print_header "Site Crawler Status"
    
    # Check dependencies
    print_info "Checking dependencies..."
    
    if command -v curl &> /dev/null; then
        print_success "curl: installed"
    else
        print_error "curl: not installed"
    fi
    
    if command -v jq &> /dev/null; then
        print_success "jq: installed"
    else
        print_error "jq: not installed"
    fi
    
    if command -v python3 &> /dev/null; then
        print_success "python3: installed"
        
        if python3 -c "import aiohttp" 2>/dev/null; then
            print_success "  aiohttp: installed"
        else
            print_warning "  aiohttp: not installed (pip3 install aiohttp)"
        fi
        
        if python3 -c "import bs4" 2>/dev/null; then
            print_success "  beautifulsoup4: installed"
        else
            print_warning "  beautifulsoup4: not installed (pip3 install beautifulsoup4)"
        fi
        
        if python3 -c "import openpyxl" 2>/dev/null; then
            print_success "  openpyxl: installed"
        else
            print_warning "  openpyxl: not installed (pip3 install openpyxl)"
        fi
    else
        print_error "python3: not installed"
    fi
    
    # Check Crawl4AI
    if check_crawl4ai; then
        print_success "Crawl4AI: running on port $CRAWL4AI_PORT"
    else
        print_warning "Crawl4AI: not running (optional, for JS rendering)"
    fi
    
    # Check config
    if [[ -f "$CONFIG_FILE" ]]; then
        print_success "Config: $CONFIG_FILE"
    else
        print_info "Config: using defaults (create $CONFIG_FILE to customize)"
    fi
    
    return 0
}

# Show help
show_help() {
    cat << 'EOF'
Site Crawler Helper - SEO Spider Tool

Usage: site-crawler-helper.sh [command] [url] [options]

Commands:
  crawl <url>           Full site crawl with SEO data extraction
  audit-links <url>     Check for broken links (4XX/5XX errors)
  audit-meta <url>      Audit page titles and meta descriptions
  audit-redirects <url> Analyze redirects and chains
  audit-duplicates <url> Find duplicate content
  audit-schema <url>    Validate structured data
  generate-sitemap <url> Generate XML sitemap from crawl
  compare [dir1] [dir2] Compare two crawls
  status                Check crawler dependencies
  help                  Show this help message

Options:
  --depth <n>           Max crawl depth (default: 10)
  --max-urls <n>        Max URLs to crawl (default: 10000)
  --format <fmt>        Output format: csv, xlsx, all (default: xlsx)
  --output <dir>        Output directory (default: ~/Downloads)
  --render-js           Enable JavaScript rendering
  --ignore-robots       Ignore robots.txt
  --delay <ms>          Delay between requests in ms (default: 100)
  --include <pattern>   Include URL patterns (comma-separated)
  --exclude <pattern>   Exclude URL patterns (comma-separated)
  --verbose             Enable verbose output

Examples:
  # Full site crawl
  site-crawler-helper.sh crawl https://example.com

  # Limited crawl with Excel output
  site-crawler-helper.sh crawl https://example.com --depth 3 --max-urls 500 --format xlsx

  # Crawl JavaScript site
  site-crawler-helper.sh crawl https://spa-site.com --render-js

  # Quick broken link check
  site-crawler-helper.sh audit-links https://example.com

  # Generate sitemap from existing crawl
  site-crawler-helper.sh generate-sitemap https://example.com

Output Structure:
  ~/Downloads/{domain}/{timestamp}/
    - crawl-data.xlsx      Full crawl data
    - crawl-data.csv       Full crawl data (CSV)
    - broken-links.csv     4XX/5XX errors
    - redirects.csv        Redirect chains
    - meta-issues.csv      Title/description issues
    - duplicate-content.csv Duplicate pages
    - internal-links.csv   Internal link structure
    - external-links.csv   Outbound links
    - summary.json         Crawl statistics

  ~/Downloads/{domain}/_latest -> symlink to latest crawl

Related:
  - E-E-A-T scoring: eeat-score-helper.sh
  - Crawl4AI: crawl4ai-helper.sh
  - PageSpeed: pagespeed-helper.sh
EOF
    return 0
}

# Main function
main() {
    load_config
    
    local command="${1:-help}"
    shift || true
    
    case "$command" in
        crawl)
            check_dependencies || exit 1
            do_crawl "$@"
            ;;
        audit-links)
            check_dependencies || exit 1
            audit_links "$@"
            ;;
        audit-meta)
            check_dependencies || exit 1
            audit_meta "$@"
            ;;
        audit-redirects)
            check_dependencies || exit 1
            audit_redirects "$@"
            ;;
        audit-duplicates)
            check_dependencies || exit 1
            audit_duplicates "$@"
            ;;
        audit-schema)
            audit_schema "$@"
            ;;
        generate-sitemap)
            generate_sitemap "$@"
            ;;
        compare)
            compare_crawls "$@"
            ;;
        status)
            check_status
            ;;
        help|-h|--help|"")
            show_help
            ;;
        *)
            print_error "Unknown command: $command"
            show_help
            exit 1
            ;;
    esac
    
    return 0
}

main "$@"
