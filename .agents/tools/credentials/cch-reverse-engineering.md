---
description: Reverse-engineer Claude CLI request signing and detect API protocol changes
mode: subagent
tools:
  read: true
  bash: true
  edit: true
  write: true
---

# CCH Reverse Engineering Agent

Analyses the Claude CLI binary/source to extract request signing constants and
detect protocol changes. Replicates the techniques from the a10k.co research
(February 2026) in an automated, repeatable way.

## When to use

- After every Claude CLI update (`claude --version` changed)
- When OAuth pool requests start failing with unexpected errors
- When `cch-extract.sh --verify` reports cache staleness
- When mitmproxy traffic capture shows new/changed headers or body fields
- Periodically as a proactive check (weekly via pulse)

## Quick Reference

```bash
# Extract constants from current CLI
cch-extract.sh --cache

# Verify cache matches installed version
cch-extract.sh --verify

# Capture and diff API traffic
cch-traffic-monitor.sh capture --duration 60
cch-traffic-monitor.sh diff <baseline.json> <current.json>

# Full analysis pipeline
cch-traffic-monitor.sh analyse
```

## Reverse Engineering Playbook

### Phase 1: Source Extraction

The Claude CLI ships in one of two forms:

| Form | Detection | Extraction |
|------|-----------|------------|
| **Node.js npm package** | `file $(which claude)` → "script text" | Source is directly readable (`cli.js`) |
| **Bun binary** | `file $(which claude)` → "Mach-O" / "ELF" | Extract embedded JS: `strings <binary> \| grep -A1000 'function.*cch'` |

For Node.js packages:
```bash
# Follow the symlink to the actual source
readlink -f $(which claude)
# → /opt/homebrew/lib/node_modules/@anthropic-ai/claude-code/cli.js

# The source is minified but readable
# Key functions to locate:
#   - GG8()  — builds the billing header string
#   - KA7()  — computes the version suffix (SHA-256)
#   - rlK()  — calls KA7 with the first user message
```

For Bun binaries:
```bash
# Extract embedded JavaScript
strings /path/to/claude | python3 -c "
import sys
content = sys.stdin.read()
# Bun embeds JS as a single blob; search for landmarks
start = content.find('function')
# ... extract the relevant section
"

# Alternatively, use Bun's built-in extraction if available
bun build --dump /path/to/claude
```

### Phase 2: Constant Identification

**Salt** (12-char hex, used for version suffix):
```bash
# Search for 12-char hex constants near sha256/createHash usage
rg -oP 'var\s+\w+="([0-9a-f]{12})"' cli.js
# v2.1.92: 59cf53e54c78
```

**Character indices** (array of integers):
```bash
# Search for [N,N,N].map( patterns
rg -oP '\[(\d+),(\d+),(\d+)\]\.map\(' cli.js
# v2.1.92: [4,7,20]
```

**Version** (semver in build config):
```bash
# Search for VERSION in the build config object (near PACKAGE_URL)
rg -oP 'PACKAGE_URL:"@anthropic-ai/claude-code"[^}]*?VERSION:"(\d+\.\d+\.\d+)"' cli.js
# v2.1.92: 2.1.92
```

**xxHash seed** (64-bit, in Bun binary only):
```bash
# Only present in Bun binaries — not in Node.js packages
# Search for the xxHash64 prime constants in the binary:
#   0x9E3779B185EBCA87 (PRIME1)
#   0xC2B2AE3D27D4EB4F (PRIME2)
# The seed is nearby in the .data section
# Use LLDB memory watchpoint technique from the article:
lldb -p $(pgrep -f claude) -o "watchpoint set expression -s 5 -- &cch_memory_addr"
```

### Phase 3: Algorithm Verification

After extracting constants, verify against known oracles:

```bash
# Generate a test billing header
python3 cch-sign.py header "Say hello" --cache

# Compare against real CLI output (via mitmproxy capture)
cch-traffic-monitor.sh capture --duration 30 &
claude -p "Say hello" --model claude-haiku-4-5 2>/dev/null
# Parse the captured request to extract the actual billing header
```

### Phase 4: Traffic Baseline & Drift Detection

Capture a "golden" request from the real Claude CLI, then compare future
versions against it to detect protocol changes.

```bash
# Capture baseline
cch-traffic-monitor.sh capture --output baseline-v2.1.92.json

# After CLI update, capture new traffic
cch-traffic-monitor.sh capture --output current-vX.Y.Z.json

# Diff the two
cch-traffic-monitor.sh diff baseline-v2.1.92.json current-vX.Y.Z.json
```

Changes to watch for:
- New headers (beyond the known set)
- Changed `anthropic-beta` values
- New fields in the billing header
- Different `cch` value format (length, charset)
- New body fields (`research_preview_*`, `context_management`, etc.)
- Changed JSON key ordering (affects body hash if xxHash is active)

## Known Signing Protocol (as of v2.1.92)

### Part 1: Version Suffix

```
cc_version = {version}.{suffix}
suffix = sha256(salt + picked_chars + version)[:3]
picked_chars = msg[4] + msg[7] + msg[20]  (or "0" if index > len)
```

- **Salt**: `59cf53e54c78` (12-char hex, in JS source)
- **Indices**: `[4, 7, 20]` (in JS source)
- **Hash**: SHA-256, first 3 hex characters

### Part 2: Body Hash

| Client | Mechanism | Value |
|--------|-----------|-------|
| Node.js (v2.1.92) | Placeholder sent as-is | `cch=00000` |
| Bun (v2.1.37) | xxHash64 in native fetch | `cch={hash & 0xFFFFF:05x}` |

Bun-era seed: `0x6E52736AC806831E`

### Required Headers

```
Authorization: Bearer {oauth_token}
anthropic-beta: claude-code-20250219,oauth-2025-04-20,...
anthropic-version: 2023-06-01
User-Agent: claude-cli/{version} (external, cli)
x-app: cli
```

### Required Body Structure

```json
{
  "system": [
    {"type": "text", "text": "x-anthropic-billing-header: cc_version=..."},
    {"type": "text", "text": "You are Claude Code, Anthropic's official CLI..."},
    {"type": "text", "text": "Your system prompt...", "cache_control": {"type": "ephemeral"}}
  ],
  "model": "claude-sonnet-4-6",
  "thinking": {"type": "adaptive"},
  "metadata": {"user_id": "..."},
  "messages": [...]
}
```

## Automation

The `cch-extract.sh` script automates Phase 1-3. Run after every CLI update:

```bash
# In the aidevops update flow:
cch-extract.sh --cache
```

The `cch-traffic-monitor.sh` script automates Phase 4 (traffic capture + diff).

## Files

| File | Purpose |
|------|---------|
| `scripts/cch-extract.sh` | Extract constants from installed CLI |
| `scripts/cch-sign.py` | Compute billing header |
| `scripts/cch-traffic-monitor.sh` | Capture and diff API traffic |
| `tools/credentials/cch-reverse-engineering.md` | This playbook |
| `~/.aidevops/cch-constants.json` | Cached constants (auto-generated) |

## References

- Original research: a10k.co/b/reverse-engineering-claude-code-cch.html
- Codey (Rust implementation): github.com/tcdent/code
- xxHash specification: github.com/Cyan4973/xxHash/blob/dev/doc/xxhash_spec.md
