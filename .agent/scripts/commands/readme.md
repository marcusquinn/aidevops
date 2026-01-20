---
description: Create or update README.md for the current project
agent: Build+
mode: subagent
---

Create or update a comprehensive README.md file for the current project.

**Arguments**: Optional flags like `--sections "installation,usage"` for partial updates. Without arguments, generates/updates the full README.

## Workflow

### Step 1: Parse Arguments

Check for `--sections` flag:

```bash
# Full README (default)
/readme

# Partial update
/readme --sections "installation,usage"
/readme --sections "troubleshooting"
```

**When to use `--sections`**:
- After adding a feature → `--sections "usage"`
- After changing install process → `--sections "installation"`
- After discovering common issue → `--sections "troubleshooting"`
- When full regeneration would lose custom content

**When to use full `/readme`**:
- New project without README
- README is significantly outdated
- Major restructuring needed
- User explicitly requests full regeneration

### Step 2: Load Workflow

Read the full workflow guidance:

```text
Read: workflows/readme-create-update.md
```

### Step 3: Explore Codebase

Before writing anything:

1. **Detect project type** (package.json, Cargo.toml, go.mod, etc.)
2. **Detect deployment platform** (Dockerfile, fly.toml, vercel.json, etc.)
3. **Read existing README** (if updating)
4. **Gather key info** (scripts, entry points, config files)

### Step 4: Generate/Update README

**For new README**: Follow recommended section order from workflow.

**For updates with `--sections`**:
1. Read entire existing README
2. Preserve structure and custom content
3. Update only specified sections
4. Maintain consistent style

### Step 5: Confirm

Present the changes and ask for confirmation before writing:

```text
README changes:
- [Section]: [Brief description of change]
- [Section]: [Brief description of change]

1. Apply changes
2. Show full diff first
3. Modify before applying
```

## Section Mapping

| Argument | Sections Updated |
|----------|------------------|
| `installation` | Installation, Prerequisites, Quick Start |
| `usage` | Usage, Commands, Examples, API |
| `config` | Configuration, Environment Variables |
| `architecture` | Architecture, Project Structure |
| `troubleshooting` | Troubleshooting |
| `deployment` | Deployment, Production Setup |
| `badges` | Badge section only |
| `all` | Full regeneration (same as no flag) |

Multiple sections: `--sections "installation,usage,config"`

## Examples

```bash
# New project - create full README
/readme

# Added new CLI commands
/readme --sections "usage"

# Changed environment variables
/readme --sections "config"

# Added Docker support
/readme --sections "installation,deployment"

# Fixed common user issue
/readme --sections "troubleshooting"

# Major update needed
/readme --sections "all"
```

## Related

- `workflows/readme-create-update.md` - Full workflow guidance
- `workflows/changelog.md` - Changelog updates
- `workflows/wiki-update.md` - Wiki documentation
