#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# =============================================================================
# Site Crawler Helper -- Fallback Python Crawler Generator
# =============================================================================
# Functions that emit a lightweight async Python crawler as a heredoc.
# Used when Crawl4AI is not available.
#
# Usage: source "${SCRIPT_DIR}/site-crawler-helper-fallback.sh"
#
# Dependencies:
#   - (none at source time -- the generated Python script has its own deps)
#
# Part of aidevops framework: https://aidevops.sh

# Apply strict mode only when executed directly (not when sourced)
[[ "${BASH_SOURCE[0]}" == "${0}" ]] && set -euo pipefail

# Include guard
[[ -n "${_SITE_CRAWLER_FALLBACK_LIB_LOADED:-}" ]] && return 0
_SITE_CRAWLER_FALLBACK_LIB_LOADED=1

# Defensive SCRIPT_DIR fallback
if [[ -z "${SCRIPT_DIR:-}" ]]; then
	# Pure-bash dirname replacement -- avoids external binary dependency
	_lib_path="${BASH_SOURCE[0]%/*}"
	[[ "$_lib_path" == "${BASH_SOURCE[0]}" ]] && _lib_path="."
	SCRIPT_DIR="$(cd "$_lib_path" && pwd)"
	unset _lib_path
fi

# --- Functions ---

# Emit Python crawler imports and dataclass definition
_fallback_crawler_header() {
	cat <<'PYHEADER'
#!/usr/bin/env python3
"""
Lightweight SEO Site Crawler
Fallback when Crawl4AI is not available
"""

import asyncio
import aiohttp
import csv
import json
import hashlib
import sys
from datetime import datetime
from pathlib import Path
from urllib.parse import urljoin, urlparse
from collections import defaultdict
from dataclasses import dataclass, asdict
from bs4 import BeautifulSoup

try:
    import openpyxl
    from openpyxl.styles import Font, PatternFill, Alignment
    HAS_XLSX = True
except ImportError:
    HAS_XLSX = False


@dataclass
class PageData:
    url: str
    status_code: int = 0
    status: str = ""
    title: str = ""
    title_length: int = 0
    meta_description: str = ""
    description_length: int = 0
    h1: str = ""
    h1_count: int = 0
    canonical: str = ""
    meta_robots: str = ""
    word_count: int = 0
    response_time_ms: float = 0.0
    crawl_depth: int = 0
    internal_links: int = 0
    external_links: int = 0
    images: int = 0
    images_missing_alt: int = 0
PYHEADER
	return 0
}

# Emit SiteCrawler class definition (__init__, is_internal, normalize_url)
_fallback_crawler_class_init() {
	cat <<'PYINIT'


class SiteCrawler:
    def __init__(self, base_url: str, max_urls: int = 100, max_depth: int = 3, delay_ms: int = 100):
        self.base_url = base_url.rstrip('/')
        self.base_domain = urlparse(base_url).netloc
        self.max_urls = max_urls
        self.max_depth = max_depth
        self.delay = delay_ms / 1000.0
        
        self.visited = set()
        self.queue = [(self.base_url, 0)]
        self.pages = []
        self.broken_links = []
        self.redirects = []

    def is_internal(self, url: str) -> bool:
        parsed = urlparse(url)
        return parsed.netloc == self.base_domain or parsed.netloc == ""

    def normalize_url(self, url: str, base: str) -> str:
        url = urljoin(base, url)
        parsed = urlparse(url)
        normalized = f"{parsed.scheme}://{parsed.netloc}{parsed.path}"
        if parsed.query:
            normalized += f"?{parsed.query}"
        return normalized.rstrip('/')
PYINIT
	return 0
}

# Emit SiteCrawler._parse_html_meta() helper method
_fallback_crawler_class_parse_meta() {
	cat <<'PYPARSEMETA'

    def _parse_html_meta(self, soup, page):
        """Extract title, meta description, robots, canonical, H1, word count, images."""
        if soup.title:
            page.title = soup.title.get_text(strip=True)[:200]
            page.title_length = len(page.title)

        meta_desc = soup.find('meta', attrs={'name': 'description'})
        if meta_desc:
            page.meta_description = meta_desc.get('content', '')[:300]
            page.description_length = len(page.meta_description)

        meta_robots = soup.find('meta', attrs={'name': 'robots'})
        if meta_robots:
            page.meta_robots = meta_robots.get('content', '')

        canonical = soup.find('link', attrs={'rel': 'canonical'})
        if canonical:
            page.canonical = canonical.get('href', '')

        h1_tags = soup.find_all('h1')
        page.h1_count = len(h1_tags)
        if h1_tags:
            page.h1 = h1_tags[0].get_text(strip=True)[:200]

        text = soup.get_text(separator=' ', strip=True)
        page.word_count = len(text.split())

        images = soup.find_all('img')
        page.images = len(images)
        page.images_missing_alt = sum(1 for img in images if not img.get('alt'))
PYPARSEMETA
	return 0
}

# Emit SiteCrawler._parse_html_links() helper method
_fallback_crawler_class_parse_links() {
	cat <<'PYPARSELINKS'

    def _parse_html_links(self, soup, url: str, depth: int):
        """Count internal/external links and enqueue unvisited internal URLs."""
        internal_count = 0
        external_count = 0

        for link in soup.find_all('a', href=True):
            href = link.get('href', '')
            if not href or href.startswith(('#', 'javascript:', 'mailto:', 'tel:')):
                continue

            target_url = self.normalize_url(href, url)

            if self.is_internal(target_url):
                internal_count += 1
                if target_url not in self.visited and depth < self.max_depth:
                    self.queue.append((target_url, depth + 1))
            else:
                external_count += 1

        return internal_count, external_count
PYPARSELINKS
	return 0
}

# Emit SiteCrawler.fetch_page() method
_fallback_crawler_class_fetch() {
	cat <<'PYFETCH'

    async def fetch_page(self, session: aiohttp.ClientSession, url: str, depth: int) -> PageData:
        page = PageData(url=url, crawl_depth=depth)

        try:
            start = datetime.now()
            async with session.get(url, allow_redirects=True, timeout=aiohttp.ClientTimeout(total=15)) as response:
                page.status_code = response.status
                page.response_time_ms = (datetime.now() - start).total_seconds() * 1000

                if response.history:
                    for r in response.history:
                        self.redirects.append({
                            'original_url': str(r.url),
                            'status_code': r.status,
                            'redirect_url': str(response.url)
                        })

                page.status = "OK" if response.status < 300 else ("Redirect" if response.status < 400 else "Error")

                if response.status >= 400:
                    self.broken_links.append({'url': url, 'status_code': response.status, 'source': 'direct'})
                    return page

                content_type = response.headers.get('Content-Type', '')
                if 'text/html' not in content_type:
                    return page

                html = await response.text()
                soup = BeautifulSoup(html, 'html.parser')

                self._parse_html_meta(soup, page)
                page.internal_links, page.external_links = self._parse_html_links(soup, url, depth)

        except asyncio.TimeoutError:
            page.status = "Timeout"
        except Exception as e:
            page.status = f"Error: {str(e)[:50]}"

        return page
PYFETCH
	return 0
}

# Emit SiteCrawler.crawl() method
_fallback_crawler_class_crawl() {
	cat <<'PYCRAWL'

    async def crawl(self):
        connector = aiohttp.TCPConnector(limit=5)
        headers = {'User-Agent': 'AIDevOps-SiteCrawler/2.0'}
        
        async with aiohttp.ClientSession(connector=connector, headers=headers) as session:
            while self.queue and len(self.visited) < self.max_urls:
                url, depth = self.queue.pop(0)
                
                if url in self.visited:
                    continue
                
                self.visited.add(url)
                page = await self.fetch_page(session, url, depth)
                self.pages.append(page)
                
                print(f"[{len(self.pages)}/{self.max_urls}] {page.status_code or 'ERR'} {url[:70]}")
                
                await asyncio.sleep(self.delay)
        
        return self.pages
PYCRAWL
	return 0
}

# Emit SiteCrawler.export() method (CSV/XLSX section)
_fallback_crawler_class_export() {
	cat <<'PYEXPORT'

    def export(self, output_dir: Path, domain: str, fmt: str = "xlsx"):
        output_dir = Path(output_dir)
        
        # CSV export
        csv_file = output_dir / "crawl-data.csv"
        fieldnames = list(PageData.__dataclass_fields__.keys())
        
        with open(csv_file, 'w', newline='', encoding='utf-8') as f:
            writer = csv.DictWriter(f, fieldnames=fieldnames)
            writer.writeheader()
            for page in self.pages:
                writer.writerow(asdict(page))
        print(f"Exported: {csv_file}")
        
        # XLSX export
        if fmt in ("xlsx", "all") and HAS_XLSX:
            xlsx_file = output_dir / "crawl-data.xlsx"
            wb = openpyxl.Workbook()
            ws = wb.active
            ws.title = "Crawl Data"
            
            # Headers
            for col, field in enumerate(fieldnames, 1):
                cell = ws.cell(row=1, column=col, value=field.replace('_', ' ').title())
                cell.font = Font(bold=True)
            
            # Data
            for row, page in enumerate(self.pages, 2):
                for col, field in enumerate(fieldnames, 1):
                    ws.cell(row=row, column=col, value=getattr(page, field))
            
            wb.save(xlsx_file)
            print(f"Exported: {xlsx_file}")
        
        # Broken links
        if self.broken_links:
            broken_file = output_dir / "broken-links.csv"
            with open(broken_file, 'w', newline='', encoding='utf-8') as f:
                writer = csv.DictWriter(f, fieldnames=['url', 'status_code', 'source'])
                writer.writeheader()
                writer.writerows(self.broken_links)
            print(f"Exported: {broken_file}")
        
        # Redirects
        if self.redirects:
            redirects_file = output_dir / "redirects.csv"
            with open(redirects_file, 'w', newline='', encoding='utf-8') as f:
                writer = csv.DictWriter(f, fieldnames=['original_url', 'status_code', 'redirect_url'])
                writer.writeheader()
                writer.writerows(self.redirects)
            print(f"Exported: {redirects_file}")
        
        return self._export_issues_and_summary(output_dir)
PYEXPORT
	return 0
}

# Emit SiteCrawler._export_issues_and_summary() method
_fallback_crawler_class_issues_summary() {
	cat <<'PYISSUES'

    def _export_issues_and_summary(self, output_dir: Path):
        # Meta issues
        meta_issues = []
        for page in self.pages:
            issues = []
            if not page.title:
                issues.append("Missing title")
            elif page.title_length > 60:
                issues.append("Title too long")
            if not page.meta_description:
                issues.append("Missing description")
            elif page.description_length > 160:
                issues.append("Description too long")
            if page.h1_count == 0:
                issues.append("Missing H1")
            elif page.h1_count > 1:
                issues.append("Multiple H1s")
            
            if issues:
                meta_issues.append({
                    'url': page.url,
                    'title': page.title[:50],
                    'h1': page.h1[:50],
                    'issues': '; '.join(issues)
                })
        
        if meta_issues:
            issues_file = output_dir / "meta-issues.csv"
            with open(issues_file, 'w', newline='', encoding='utf-8') as f:
                writer = csv.DictWriter(f, fieldnames=['url', 'title', 'h1', 'issues'])
                writer.writeheader()
                writer.writerows(meta_issues)
            print(f"Exported: {issues_file}")
        
        # Summary
        summary = {
            'crawl_date': datetime.now().isoformat(),
            'base_url': self.base_url,
            'pages_crawled': len(self.pages),
            'broken_links': len(self.broken_links),
            'redirects': len(self.redirects),
            'meta_issues': len(meta_issues),
            'status_codes': {}
        }
        
        for page in self.pages:
            code = str(page.status_code)
            summary['status_codes'][code] = summary['status_codes'].get(code, 0) + 1
        
        with open(output_dir / "summary.json", 'w') as f:
            json.dump(summary, f, indent=2)
        print(f"Exported: {output_dir / 'summary.json'}")
        
        return summary
PYISSUES
	return 0
}

# Emit Python main() entry point
_fallback_crawler_main() {
	cat <<'PYMAIN'


async def main():
    if len(sys.argv) < 4:
        print("Usage: crawler.py <url> <output_dir> <max_urls> [depth] [format]")
        sys.exit(1)
    
    url = sys.argv[1]
    output_dir = sys.argv[2]
    max_urls = int(sys.argv[3])
    depth = int(sys.argv[4]) if len(sys.argv) > 4 else 3
    fmt = sys.argv[5] if len(sys.argv) > 5 else "xlsx"
    
    domain = urlparse(url).netloc
    
    print(f"Starting crawl: {url}")
    print(f"Max URLs: {max_urls}, Max depth: {depth}")
    print()
    
    crawler = SiteCrawler(url, max_urls=max_urls, max_depth=depth)
    await crawler.crawl()
    
    summary = crawler.export(Path(output_dir), domain, fmt)
    
    print()
    print("=== Crawl Summary ===")
    print(f"Pages crawled: {summary['pages_crawled']}")
    print(f"Broken links: {summary['broken_links']}")
    print(f"Redirects: {summary['redirects']}")
    print(f"Meta issues: {summary['meta_issues']}")


if __name__ == "__main__":
    asyncio.run(main())
PYMAIN
	return 0
}

# Lightweight Python crawler (fallback) - assembles Python script from sections
generate_fallback_crawler() {
	_fallback_crawler_header
	_fallback_crawler_class_init
	_fallback_crawler_class_parse_meta
	_fallback_crawler_class_parse_links
	_fallback_crawler_class_fetch
	_fallback_crawler_class_crawl
	_fallback_crawler_class_export
	_fallback_crawler_class_issues_summary
	_fallback_crawler_main
	return 0
}
