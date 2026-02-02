---
description: Sentry error monitoring and debugging via MCP
mode: subagent
tools:
  read: true
  write: false
  edit: false
  bash: true
  glob: false
  grep: false
  webfetch: true
  task: false
mcp:
  - sentry
---

# Sentry MCP

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Purpose**: Error monitoring, debugging, and issue tracking via Sentry
- **MCP**: Local stdio mode with `@sentry/mcp-server`
- **Auth**: Personal Auth Token (created after org exists)
- **Credentials**: `~/.config/aidevops/mcp-env.sh` → `SENTRY_YOURNAME`

**When to use**:

- Debugging production errors
- Analyzing error trends and patterns
- Investigating specific issues or stack traces
- Checking release health and performance

**OpenCode Config** (`~/.config/opencode/opencode.json`):

```json
"sentry": {
  "type": "local",
  "command": ["npx", "@sentry/mcp-server@latest", "--access-token", "YOUR_TOKEN"],
  "enabled": false
}
```

<!-- AI-CONTEXT-END -->

## MCP Setup

### 1. Create Sentry Account & Organization

1. Sign up at [sentry.io](https://sentry.io)
2. **Create an organization first** (Settings → Organizations → Create)
3. Create a project within the organization

### 2. Generate Personal Auth Token

**Important**: Create the token AFTER creating the organization.

1. Go to Settings → Account → Personal Tokens (or Auth Tokens)
2. Click "Create New Token"
3. Select permissions:
   - `alerts:read`, `alerts:write`
   - `event:admin`, `event:read`, `event:write`
   - `member:read`, `org:read`
   - `project:read`, `project:releases`
   - `team:read`

4. Save token:

```bash
echo 'export SENTRY_YOURNAME="sntryu_..."' >> ~/.config/aidevops/mcp-env.sh
chmod 600 ~/.config/aidevops/mcp-env.sh
```

### 3. Configure OpenCode MCP

```bash
source ~/.config/aidevops/mcp-env.sh
jq --arg token "$SENTRY_YOURNAME" \
  '.mcp.sentry = {"type": "local", "command": ["npx", "@sentry/mcp-server@latest", "--access-token", $token], "enabled": false}' \
  ~/.config/opencode/opencode.json > /tmp/oc.json && mv /tmp/oc.json ~/.config/opencode/opencode.json
```

## Available MCP Tools

| Tool | Description |
|------|-------------|
| `list_projects` | List all Sentry projects |
| `get_issue` | Get details of a specific issue |
| `list_issues` | List issues for a project |
| `get_event` | Get details of a specific event |
| `resolve_issue` | Mark an issue as resolved |
| `assign_issue` | Assign issue to a team member |

## Usage Examples

```text
@sentry list my projects
@sentry show recent issues in javascript-nextjs
@sentry get details for issue PROJ-123
@sentry what's the error rate for the latest release?
```

---

## Next.js SDK Integration

### Quick Setup (Recommended)

```bash
npx @sentry/wizard@latest -i nextjs
```

This creates all required files automatically.

### Manual Setup (Next.js 15+ with App Router)

**File structure:**

```text
project-root/
├── instrumentation-client.ts    # Client-side SDK init
├── instrumentation.ts           # Server/Edge registration
├── sentry.server.config.ts      # Server-side SDK init
├── sentry.edge.config.ts        # Edge runtime SDK init
├── next.config.ts               # withSentryConfig wrapper
├── app/
│   └── global-error.tsx         # React error boundary
└── .env.local                   # Environment variables
```

### Configuration Files

**instrumentation-client.ts**:

```typescript
import * as Sentry from "@sentry/nextjs";

Sentry.init({
  dsn: process.env.NEXT_PUBLIC_SENTRY_DSN,
  sendDefaultPii: true,
  tracesSampleRate: process.env.NODE_ENV === "development" ? 1.0 : 0.1,
  replaysSessionSampleRate: 0.1,
  replaysOnErrorSampleRate: 1.0,
  integrations: [Sentry.replayIntegration()],
});

export const onRouterTransitionStart = Sentry.captureRouterTransitionStart;
```

**sentry.server.config.ts**:

```typescript
import * as Sentry from "@sentry/nextjs";

Sentry.init({
  dsn: process.env.SENTRY_DSN,
  sendDefaultPii: true,
  tracesSampleRate: process.env.NODE_ENV === "development" ? 1.0 : 0.1,
});
```

**sentry.edge.config.ts**:

```typescript
import * as Sentry from "@sentry/nextjs";

Sentry.init({
  dsn: process.env.SENTRY_DSN,
  tracesSampleRate: process.env.NODE_ENV === "development" ? 1.0 : 0.1,
});
```

**instrumentation.ts**:

```typescript
import * as Sentry from "@sentry/nextjs";

export async function register() {
  if (process.env.NEXT_RUNTIME === "nodejs") {
    await import("./sentry.server.config");
  }
  if (process.env.NEXT_RUNTIME === "edge") {
    await import("./sentry.edge.config");
  }
}

// Next.js 15+ only
export const onRequestError = Sentry.captureRequestError;
```

**next.config.ts**:

```typescript
import type { NextConfig } from "next";
import { withSentryConfig } from "@sentry/nextjs";

const nextConfig: NextConfig = {
  // Your existing config
};

export default withSentryConfig(nextConfig, {
  org: "your-org-slug",
  project: "your-project-slug",
  authToken: process.env.SENTRY_AUTH_TOKEN,
  tunnelRoute: "/monitoring",  // Avoids ad-blockers
  widenClientFileUpload: true,
  silent: !process.env.CI,
});
```

**app/global-error.tsx**:

```tsx
"use client";

import * as Sentry from "@sentry/nextjs";
import NextError from "next/error";
import { useEffect } from "react";

export default function GlobalError({ error }: { error: Error & { digest?: string } }) {
  useEffect(() => {
    Sentry.captureException(error);
  }, [error]);

  return (
    <html>
      <body>
        <NextError statusCode={0} />
      </body>
    </html>
  );
}
```

### Environment Variables

| Variable | Purpose | File |
|----------|---------|------|
| `NEXT_PUBLIC_SENTRY_DSN` | Client-side DSN | `.env.local` |
| `SENTRY_DSN` | Server-side DSN | `.env.local` |
| `SENTRY_AUTH_TOKEN` | Source map uploads | `.env.local` or CI |
| `SENTRY_ORG` | Organization slug | `next.config.ts` |
| `SENTRY_PROJECT` | Project slug | `next.config.ts` |

**.env.local**:

```bash
NEXT_PUBLIC_SENTRY_DSN=https://xxx@xxx.ingest.sentry.io/xxx
SENTRY_DSN=https://xxx@xxx.ingest.sentry.io/xxx
SENTRY_AUTH_TOKEN=sntrys_eyJ...
```

### Server Actions

```typescript
"use server";
import * as Sentry from "@sentry/nextjs";

export async function submitForm(formData: FormData) {
  return Sentry.withServerActionInstrumentation("submitForm", async () => {
    // Your server action logic
    return { success: true };
  });
}
```

## Troubleshooting

### Token returns empty organizations

Create a new Personal Auth Token **after** the organization exists. Tokens created before the org don't inherit access.

### "Not authenticated"

1. Verify token in `~/.config/aidevops/mcp-env.sh`
2. Test with: `curl -H "Authorization: Bearer $TOKEN" https://sentry.io/api/0/`
3. Restart OpenCode after config changes

### Ad-blockers blocking Sentry

Use `tunnelRoute: "/monitoring"` in `next.config.ts` to proxy requests.

### Source maps not uploading

1. Verify `SENTRY_AUTH_TOKEN` is set
2. Check org/project slugs match exactly
3. Run build with `DEBUG=sentry* npm run build`

## Related

- [Sentry Next.js Docs](https://docs.sentry.io/platforms/javascript/guides/nextjs/)
- [Sentry MCP](https://mcp.sentry.dev/)
- [@sentry/nextjs on npm](https://www.npmjs.com/package/@sentry/nextjs)
