---
description: Store a memory entry for cross-session recall
agent: Build+
mode: subagent
---

Store knowledge, patterns, or learnings for future sessions.

Content to remember: $ARGUMENTS

## Memory Types

| Type | Use For | Example |
|------|---------|---------|
| `WORKING_SOLUTION` | Fixes that worked | "Fixed CORS by adding headers to nginx" |
| `FAILED_APPROACH` | What didn't work (avoid repeating) | "Don't use sync fs in Lambda" |
| `CODEBASE_PATTERN` | Project conventions | "All API routes use /api/v1 prefix" |
| `USER_PREFERENCE` | Developer preferences | "Prefers tabs over spaces" |
| `TOOL_CONFIG` | Tool setup notes | "SonarCloud needs SONAR_TOKEN in CI" |
| `DECISION` | Architecture decisions | "Chose SQLite over Postgres for simplicity" |
| `CONTEXT` | Background info | "Legacy API deprecated in Q3" |

## Workflow

### Step 1: Analyze Content

From the conversation or $ARGUMENTS, extract:
- **Content**: What to remember (concise, actionable)
- **Type**: Best matching type from above
- **Tags**: Relevant keywords (comma-separated)
- **Project**: Current project name (optional)

### Step 2: Confirm with User

```text
Storing memory:

Type: {type}
Content: "{content}"
Tags: {tags}
Project: {project or "global"}

1. Confirm
2. Change type
3. Edit content
4. Cancel
```

### Step 3: Store Memory

After confirmation, run:

```bash
~/.aidevops/agents/scripts/memory-helper.sh store --type "{type}" --content "{content}" --tags "{tags}" --project "{project}"
```

### Step 4: Confirm Storage

```text
Remembered: "{content}" ({type})
Tags: {tags}

Recall anytime with: /recall {keyword}
```

## Examples

**Storing a working solution:**

```text
User: /remember The CORS fix was adding Access-Control-Allow-Origin to nginx.conf
AI: Storing memory:
    Type: WORKING_SOLUTION
    Content: "Fixed CORS by adding Access-Control-Allow-Origin header to nginx.conf location block"
    Tags: cors,nginx,headers
    Project: api-gateway
    
    1. Confirm  2. Change type  3. Edit  4. Cancel
User: 1
AI: Remembered: "Fixed CORS by adding..." (WORKING_SOLUTION)
    Recall anytime with: /recall cors
```

**Storing a failed approach:**

```text
User: /remember Don't use moment.js - it's huge and deprecated
AI: Storing memory:
    Type: FAILED_APPROACH
    Content: "Avoid moment.js - large bundle size (300KB+) and deprecated. Use date-fns or dayjs instead"
    Tags: javascript,dates,bundle-size
    Project: global
    
    1. Confirm  2. Change type  3. Edit  4. Cancel
User: 1
AI: Remembered: "Avoid moment.js..." (FAILED_APPROACH)
```

**Storing a user preference:**

```text
User: /remember I prefer conventional commits
AI: Storing memory:
    Type: USER_PREFERENCE
    Content: "Use conventional commit format: type(scope): description"
    Tags: git,commits,style
    Project: global
    
    1. Confirm  2. Change type  3. Edit  4. Cancel
```

## Auto-Remember Triggers

AI assistants should proactively suggest `/remember` when:

1. A solution is found after debugging
2. User explicitly states a preference
3. A workaround is discovered for a tool limitation
4. An architecture decision is made
5. A failed approach is identified

```text
AI: That fixed it! Want me to remember this solution for future sessions?
    /remember {suggested content}
```

## Storage Location

Memories are stored in SQLite with FTS5 for fast search:
`~/.aidevops/.agent-workspace/memory/memory.db`

View stats: `~/.aidevops/agents/scripts/memory-helper.sh stats`
