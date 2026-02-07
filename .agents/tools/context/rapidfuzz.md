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

# RapidFuzz - Fuzzy String Matching

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Purpose**: Fast fuzzy string matching (Levenshtein, Jaro-Winkler, token-based)
- **Install**: `pip install rapidfuzz` or `conda install -c conda-forge rapidfuzz`
- **Repo**: https://github.com/rapidfuzz/RapidFuzz (2.8k+ stars, MIT)
- **Docs**: https://rapidfuzz.github.io/RapidFuzz/

**When to use**: Deduplication, typo-tolerant search, record linkage, autocomplete, entity matching. 10-100x faster than `fuzzywuzzy` (C++ backend, no Python-only fallback).

<!-- AI-CONTEXT-END -->

## Core Functions

### Simple Ratio (character-level similarity)

```python
from rapidfuzz import fuzz

fuzz.ratio("fuzzy wuzzy", "fuzzy wuzzy")       # 100.0
fuzz.ratio("fuzzy wuzzy", "fzzy wzzy")         # ~84.2
```

### Partial Ratio (substring matching)

```python
fuzz.partial_ratio("fuzzy wuzzy", "wuzzy")     # 100.0
```

### Token Sort Ratio (order-independent)

```python
fuzz.token_sort_ratio("New York Mets", "Mets New York")  # 100.0
```

### Token Set Ratio (handles duplicates and extras)

```python
fuzz.token_set_ratio(
    "fuzzy wuzzy was a bear",
    "fuzzy fuzzy was a bear"
)  # High score despite differences
```

## Process Module (batch matching)

```python
from rapidfuzz import process

choices = ["Atlanta Falcons", "New York Jets", "New York Giants", "Dallas Cowboys"]

# Best match
process.extractOne("new york jets", choices)
# ('New York Jets', 100.0, 1)

# Top N matches
process.extract("new york jets", choices, limit=2)
# [('New York Jets', 100.0, 1), ('New York Giants', 78.57, 2)]

# Score cutoff
process.extract("new york jets", choices, score_cutoff=80)
```

## Distance Functions

```python
from rapidfuzz.distance import Levenshtein, Jaro, JaroWinkler

Levenshtein.distance("kitten", "sitting")       # 3
Levenshtein.normalized_similarity("kitten", "sitting")  # ~0.571

Jaro.similarity("martha", "marhta")             # ~0.944
JaroWinkler.similarity("martha", "marhta")      # ~0.961
```

## Performance Tips

- Use `score_cutoff` parameter to skip low-scoring comparisons early
- Use `process.cdist()` for pairwise distance matrices (NumPy integration)
- Pre-process strings with `rapidfuzz.utils.default_process` (lowercase, strip)
- For large datasets (>10k items), use `process.extract` with `workers=-1` for parallelism

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

- `tools/context/mcp-discovery.md` - Uses fuzzy matching for tool search
- `memory-helper.sh` - Could use RapidFuzz for similar memory deduplication
