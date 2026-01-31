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

## Auto-Remember Triggers (MANDATORY)

AI assistants **MUST** proactively suggest `/remember` when detecting these patterns:

### Conversation Pattern Detection

| User Says | Trigger Type | Memory Type |
|-----------|--------------|-------------|
| "that fixed it", "it works now", "solved" | Solution found | `WORKING_SOLUTION` |
| "I prefer", "I like", "always use", "never use" | Preference stated | `USER_PREFERENCE` |
| "don't do X", "X doesn't work", "avoid X" | Failed approach | `FAILED_APPROACH` |
| "let's go with", "decided to", "we'll use" | Decision made | `DECISION` |
| "the trick is", "workaround", "hack" | Workaround found | `WORKING_SOLUTION` |
| "configure X as", "set X to", "X needs Y" | Tool config | `TOOL_CONFIG` |

### Required Response Format

When a trigger is detected, immediately offer:

```text
That worked! Want me to remember this for future sessions?

/remember {concise, actionable description}

(Reply 'y' to confirm, or edit the description)
```

### Examples

**After fixing a bug:**
```text
User: Adding --legacy-peer-deps fixed the npm install
AI: That worked! Want me to remember this for future sessions?
    
    /remember Use --legacy-peer-deps flag when npm install fails with peer dependency conflicts
    
    (Reply 'y' to confirm, or edit the description)
```

**When user states preference:**
```text
User: I always use pnpm instead of npm
AI: Got it! Want me to remember this preference?
    
    /remember User prefers pnpm over npm for package management
    
    (Reply 'y' to confirm)
```

**After failed approach:**
```text
User: That approach with setTimeout didn't work at all
AI: Noted. Want me to remember to avoid this approach?
    
    /remember Avoid using setTimeout for async coordination - use proper async/await or Promises instead
    
    (Reply 'y' to confirm)
```

### Do NOT Wait

- Do NOT wait for user to explicitly ask to remember
- Do NOT skip the suggestion if the learning seems minor
- DO suggest immediately when pattern is detected
- DO make the suggestion concise and actionable

## Storage Location

Memories are stored in SQLite with FTS5 for fast search:
`~/.aidevops/.agent-workspace/memory/memory.db`

View stats: `~/.aidevops/agents/scripts/memory-helper.sh stats`
