---
description: Screaming Frog SEO Spider CLI integration for site auditing and crawling
mode: subagent
tools:
  read: true
  write: false
  edit: false
  bash: true
  glob: true
  grep: true
---

# Screaming Frog SEO Spider Integration

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Purpose**: Advanced site crawling and SEO auditing via CLI
- **License**: Paid license required for CLI automation ($259/yr); free tier = GUI only, 500 URL cap
- **Command**: `screamingfrogseospider` (requires alias/path setup)
- **Output**: Headless mode supports CSV, PDF, and Google Sheets exports

## Setup

1. Download from [screamingfrog.co.uk](https://www.screamingfrog.co.uk/seo-spider/)
2. Enter license key in GUI (`Help > Enter License`)
3. **macOS**: Add alias to `~/.zshrc` or `~/.bashrc`:

```bash
alias screamingfrogseospider="/Applications/Screaming\ Frog\ SEO\ Spider.app/Contents/MacOS/ScreamingFrogSEOSpiderLauncher"
```

4. **Linux**: Standard package install. **Windows**: Add install dir to PATH.
5. Verify: `screamingfrogseospider --help`

## Usage

### Basic Crawl

```bash
screamingfrogseospider --crawl https://example.com --headless --output-folder ./reports
```

### Configuration

- **Save Config**: Configure in GUI, save as `profile.seospiderconfig`
- **Load Config**: Use `--config profile.seospiderconfig`

### Export Options

- `--export-tabs "Internal:All,Response Codes:All"`
- `--save-crawl` (saves .seospider file)
- `--bulk-export "All Inlinks"`

## Integration with AI DevOps

- **Audit**: Use for deep technical audits when `site-crawler` is insufficient
- **Validation**: Verify fixes by re-crawling specific paths
- **Reporting**: Generate CSVs for analysis by other agents

<!-- AI-CONTEXT-END -->
