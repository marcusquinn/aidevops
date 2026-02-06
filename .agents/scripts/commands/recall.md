---
description: Search and retrieve memories from previous sessions
agent: Build+
mode: subagent
---

Search stored memories for relevant knowledge.

Search query: $ARGUMENTS

## Workflow

### Step 1: Search Memories

Run the search:

```bash
~/.aidevops/agents/scripts/memory-helper.sh recall "{query}"
```

### Step 2: Present Results

If results found:

```text
Found {count} memories for "{query}":

1. [{type}] {content}
   Tags: {tags} | Project: {project} | {age}
   
2. [{type}] {content}
   Tags: {tags} | Project: {project} | {age}

---
Actions:
- Use memory #1 in current context
- Search with different terms
- Show more results
```

If no results:

```text
No memories found for "{query}"

Try:
- Different keywords
- Broader search terms
- /recall --recent (show latest memories)
```

### Step 3: Apply Memory

When user selects a memory, incorporate it into the current context:

```text
Applying memory: "{content}"

This suggests: {interpretation for current task}
```

## Search Options

| Command | Purpose |
|---------|---------|
| `/recall {query}` | Search by keywords |
| `/recall --type WORKING_SOLUTION` | Filter by type |
| `/recall --project myapp` | Filter by project |
| `/recall --recent` | Show 10 most recent |
| `/recall --stats` | Show memory statistics |

## Examples

**Basic search:**

```text
User: /recall cors
AI: Found 2 memories for "cors":

    1. [WORKING_SOLUTION] Fixed CORS by adding Access-Control-Allow-Origin header to nginx.conf
       Tags: cors,nginx,headers | Project: api-gateway | 3 days ago
       
    2. [FAILED_APPROACH] Setting CORS in Express middleware didn't work with nginx proxy
       Tags: cors,express,nginx | Project: api-gateway | 3 days ago

    Which memory is relevant to your current task?
```

**Type-filtered search:**

```text
User: /recall --type USER_PREFERENCE
AI: Found 5 user preferences:

    1. [USER_PREFERENCE] Use conventional commit format
       Tags: git,commits | Global | 1 week ago
       
    2. [USER_PREFERENCE] Prefer tabs over spaces (width: 2)
       Tags: formatting,style | Global | 2 weeks ago
    ...
```

**Project-specific search:**

```text
User: /recall --project wordpress-plugin
AI: Found 8 memories for project "wordpress-plugin":

    1. [CODEBASE_PATTERN] All hooks use prefix 'myplugin_'
    2. [DECISION] Using SCF instead of ACF for custom fields
    3. [WORKING_SOLUTION] Fixed activation hook by checking PHP version first
    ...
```

**Recent memories:**

```text
User: /recall --recent
AI: 10 most recent memories:

    1. [WORKING_SOLUTION] Memory system uses SQLite FTS5 (today)
    2. [DECISION] Chose SQLite over Postgres for zero dependencies (today)
    3. [TOOL_CONFIG] ShellCheck requires local var pattern (yesterday)
    ...
```

## Memory Statistics

```text
User: /recall --stats
AI: Memory Statistics:
    
    Total entries: 47
    By type:
      WORKING_SOLUTION: 15
      CODEBASE_PATTERN: 12
      USER_PREFERENCE: 8
      FAILED_APPROACH: 6
      DECISION: 4
      TOOL_CONFIG: 2
    
    By project:
      global: 20
      api-gateway: 12
      wordpress-plugin: 8
      aidevops: 7
    
    Oldest: 45 days ago
    Most accessed: "conventional commits" (12 accesses)
```

## Proactive Recall

AI assistants should proactively search memories when:

1. Starting work on a project (check project-specific memories)
2. Encountering an error (search for similar issues)
3. Making architecture decisions (check past decisions)
4. Setting up tools (check TOOL_CONFIG memories)

```text
AI: Before we start, let me check for relevant memories...
    [Searches: /recall --project {current-project}]
    
    Found 3 relevant memories:
    - This project uses conventional commits
    - API routes follow /api/v1/{resource} pattern
    - Tests require DATABASE_URL env var
```

## Memory Maintenance

Memories track access patterns. Stale memories (>90 days, never accessed) can be pruned:

```bash
# Validate memory health
~/.aidevops/agents/scripts/memory-helper.sh validate

# Prune stale entries (dry-run first)
~/.aidevops/agents/scripts/memory-helper.sh prune --dry-run
~/.aidevops/agents/scripts/memory-helper.sh prune
```
