---
description: RapidFuzz - fast fuzzy string matching library for Python and C++
mode: subagent
tools:
  read: true
  write: false
  edit: false
  bash: true
  glob: true
  grep: true
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# RapidFuzz - Fuzzy String Matching

## Quick Reference

- **Purpose**: Fast fuzzy string matching (Levenshtein, Jaro-Winkler, token-based)
- **Use when**: Deduplication, typo-tolerant search, record linkage, autocomplete, entity matching
- **Performance**: 10-100x faster than `fuzzywuzzy` (C++ backend)
- **Install**: `pip install rapidfuzz`
- **Docs**: https://rapidfuzz.github.io/RapidFuzz/

## Core Functions

```python
from rapidfuzz import fuzz

fuzz.ratio("fuzzy wuzzy", "fuzzy wuzzy")                  # 100.0 — character-level
fuzz.partial_ratio("fuzzy wuzzy", "wuzzy")                # 100.0 — substring match
fuzz.token_sort_ratio("New York Mets", "Mets New York")   # 100.0 — order-independent
fuzz.token_set_ratio("fuzzy wuzzy was a bear", "fuzzy fuzzy was a bear")  # handles duplicates
```

## Process Module (batch matching)

```python
from rapidfuzz import process

choices = ["Atlanta Falcons", "New York Jets", "New York Giants", "Dallas Cowboys"]
process.extractOne("new york jets", choices)              # ('New York Jets', 100.0, 1)
process.extract("new york jets", choices, limit=2)        # top 2 matches
process.extract("new york jets", choices, score_cutoff=80)  # filtered by threshold
```

## Distance Functions

```python
from rapidfuzz.distance import Levenshtein, Jaro, JaroWinkler

Levenshtein.distance("kitten", "sitting")                # 3
Levenshtein.normalized_similarity("kitten", "sitting")   # ~0.571
Jaro.similarity("martha", "marhta")                      # ~0.944
JaroWinkler.similarity("martha", "marhta")               # ~0.961
```

## Performance Tips

- `score_cutoff` — skip low-scoring comparisons early
- `process.cdist()` — pairwise distance matrices (NumPy integration)
- `rapidfuzz.utils.default_process` — normalize strings (lowercase, strip) before matching
- `workers=-1` — parallel processing for large datasets (>10k items)

## Common Patterns in aidevops

```python
# Fuzzy-match user input to known commands
from rapidfuzz import process
commands = ["deploy", "status", "update", "rollback", "logs"]
match, score, idx = process.extractOne(user_input, commands)
if score > 80:
    execute(match)

# Deduplicate similar entries
from rapidfuzz import fuzz
def deduplicate(items, threshold=85):
    unique = []
    for item in items:
        if not any(fuzz.ratio(item, u) > threshold for u in unique):
            unique.append(item)
    return unique
```

## Related

- `tools/context/mcp-discovery.md` — uses fuzzy matching for tool search
- `memory-helper.sh` — candidate for RapidFuzz-based memory deduplication
