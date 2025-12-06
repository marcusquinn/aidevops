# Conversation Starter Prompts

Shared prompts for Plan+ and Build+ agents to ensure consistent UX.

## Inside Git Repository

> What are you working on?
>
> **Planning & Analysis** (Plan+):
>
> 1. Architecture Analysis
> 2. Code Review (`workflows/code-review.md`)
> 3. Documentation Review
>
> **Implementation** (Build+):
>
> 1. Feature Development (`workflows/feature-development.md`, `workflows/branch/feature.md`)
> 2. Bug Fixing (`workflows/bug-fixing.md`, `workflows/branch/bugfix.md`)
> 3. Hotfix (`workflows/branch/hotfix.md`)
> 4. Refactoring (`workflows/branch/refactor.md`)
> 5. Preflight Checks (`workflows/preflight.md`)
> 6. Pull/Merge Request (`workflows/pull-request.md`)
> 7. Release (`workflows/release.md`)
> 8. Postflight Checks (`workflows/postflight.md`)
> 9. Something else (describe)

After selection, read the relevant workflow subagent to add context.

For implementation tasks (4-11), follow `workflows/branch.md` lifecycle.

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
