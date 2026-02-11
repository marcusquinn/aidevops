---
mode: subagent
---
# Conversation Starter Prompts

Shared prompts for Build+ agent to ensure consistent UX.

## Inside Git Repository

**First**: Check git context and recall recent lessons:

```bash
BRANCH=$(git branch --show-current)
if [[ "$BRANCH" == "main" ]]; then
    echo "Currently on main branch - will suggest work branch for coding tasks"
fi

# Surface recent lessons from memory (silent if no results)
~/.aidevops/agents/scripts/memory-helper.sh recall --recent --limit 3 2>/dev/null
```

If memory recall returns results, briefly note any relevant lessons (e.g.,
"Recent lesson: always read domain subagents before content generation tasks").
Do not dump raw memory output — summarize actionable items only.

If on `main` branch, include this note in the prompt:

> **Note**: You're on the `main` branch. For file changes, I'll check for existing branches and offer options before proceeding.

What are you working on?

**Planning & Analysis** (Build+ deliberation mode):
>
> 1. Architecture Analysis
> 2. Code Review (`workflows/code-audit-remote.md`)
> 3. Documentation Review
>
> **Implementation** (Build+):
>
> 1. Feature Development (`workflows/feature-development.md`, `workflows/branch/feature.md`)
> 2. Bug Fixing (`workflows/bug-fixing.md`, `workflows/branch/bugfix.md`)
> 3. Hotfix (`workflows/branch/hotfix.md`)
> 4. Refactoring (`workflows/branch/refactor.md`)
> 5. Preflight Checks (`workflows/preflight.md`)
> 6. Pull/Merge Request (`workflows/pr.md`)
> 7. Release (`workflows/release.md`)
> 8. Postflight Checks (`workflows/postflight.md`)
> 9. Work on Issue (paste GitHub/GitLab/Gitea issue URL)
> 10. Something else (describe)

**For implementation tasks (1-4, 9-10)**: Read `workflows/git-workflow.md` first for branch creation, issue URL handling, and fork detection.

After selection, read the relevant workflow subagent to add context.

## Outside Git Repository

> Where are you working?
>
> 1. Local project (provide path)
> 2. Remote services

If "Remote services", show available services:

> Which service do you need?
>
> 1. 101domains (`services/hosting/101domains.md`)
> 2. Closte (`services/hosting/closte.md`)
> 3. Cloudflare (`services/hosting/cloudflare.md`)
> 4. Cloudron (`services/hosting/cloudron.md`)
> 5. Hetzner (`services/hosting/hetzner.md`)
> 6. Hostinger (`services/hosting/hostinger.md`)
> 7. QuickFile (`services/accounting/quickfile.md`)
> 8. SES (`services/email/ses.md`)
> 9. Spaceship (`services/hosting/spaceship.md`)

After selection, read the relevant service subagent to add context.
