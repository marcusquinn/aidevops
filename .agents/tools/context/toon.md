---
description: TOON format for token-efficient data serialization
mode: subagent
tools:
  read: true
  write: true
  edit: true
  bash: true
  glob: true
  grep: true
  webfetch: false
  task: true
---

# TOON Format Integration - AI DevOps Framework

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Purpose**: 20-60% token reduction vs JSON for LLM prompts
- **CLI**: `npx @toon-format/cli` (no install needed)
- **Commands**: `toon-helper.sh [encode|decode|compare|validate|batch|stdin-encode|stdin-decode] [input] [output]`
- **Format**: `users[2]{id,name,role}:` followed by `1,Alice,admin` rows
- **Delimiters**: comma (default), tab (`\t`), pipe (`|`)
- **Best for**: Tabular data (60%+ savings), config data, API responses
- **Config**: `configs/toon-config.json`
- **Resources**: https://toonformat.dev, https://github.com/toon-format/toon

<!-- AI-CONTEXT-END -->

**Token-Oriented Object Notation (TOON)** — compact, human-readable, schema-aware serialization for LLM prompts.

## Format Examples

### Simple Object

```toon
id: 1
name: Alice
active: true
```

### Tabular Data (most efficient)

```toon
users[2]{id,name,role}:
  1,Alice,admin
  2,Bob,user
```

### Nested Structures

```toon
project:
  name: AI DevOps
  metrics[2]{date,users}:
    2025-01-01,100
    2025-01-02,150
```

## Helper Script Commands

```bash
# File conversion
toon-helper.sh encode input.json output.toon
toon-helper.sh encode input.json output.toon '\t' true   # tab delimiter
toon-helper.sh decode input.toon output.json false        # lenient validation

# Batch processing
toon-helper.sh batch ./json-files ./toon-files json-to-toon
toon-helper.sh batch ./toon-files ./json-files toon-to-json '\t'

# Stream processing
cat data.json | toon-helper.sh stdin-encode
cat data.toon | toon-helper.sh stdin-decode

# Validation and comparison
toon-helper.sh validate data.toon
toon-helper.sh compare large-dataset.json
toon-helper.sh info
```

## Token Efficiency

| Data Type | JSON Tokens | TOON Tokens | Savings |
|-----------|-------------|-------------|---------|
| Employee Records | 126,860 | 49,831 | 60.7% |
| Time Series | 22,250 | 9,120 | 59.0% |
| GitHub Repos | 15,145 | 8,745 | 42.3% |
| E-commerce Orders | 108,806 | 72,771 | 33.1% |

## Use Cases

| Use Case | Command |
|----------|---------|
| Server config / inventory | `toon-helper.sh encode servers.json servers.toon '\t' true` |
| API response to LLM | `curl -s "https://api.example.com/data" \| toon-helper.sh stdin-encode` |
| Database export | `mysql -e "SELECT * FROM users" --json \| toon-helper.sh stdin-encode '\t'` |
| Log analysis | `toon-helper.sh batch ./logs/json ./logs/toon json-to-toon` |

## LLM Integration

**Sending TOON to LLMs** — include this preamble:

```
Data is in TOON format (2-space indent, arrays show length and fields):
```

**Generating TOON from LLMs:**

- Show expected header format: `users[N]{id,name,role}:`
- Rules: 2-space indent, no trailing spaces, `[N]` matches row count
- Request code block output only

## Configuration

```bash
cp configs/toon-config.json.txt configs/toon-config.json
```

Key options: `default_delimiter` (`,`/`\t`/`|`), `key_folding` (path compression), `batch_processing` (concurrency), `ai_prompts` (LLM optimisation).

## Best Practices

- Validate input before processing; use strict mode in production
- Keep JSON backups when converting; verify round-trip accuracy
- Monitor actual token savings — tabular data benefits most
