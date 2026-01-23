---
description: Better Auth - authentication library for Next.js, sessions, OAuth
mode: subagent
tools:
  read: true
  write: true
  edit: true
  bash: true
  glob: true
  grep: true
  webfetch: true
  task: true
  context7_*: true
---

# Better Auth - Authentication Library

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Purpose**: Full-featured authentication for Next.js applications
- **Packages**: `better-auth`, `@better-auth/expo`, `@better-auth/passkey`
- **Docs**: Use Context7 MCP for current documentation

**Key Features**:
- Email/password, OAuth, magic links, passkeys
- Session management with database storage
- Built-in Drizzle adapter
- React hooks for client-side auth

**Server Setup**:

```tsx
// packages/auth/src/server.ts
import { betterAuth } from "better-auth";
import { drizzleAdapter } from "better-auth/adapters/drizzle";
import { db } from "@workspace/db";

// Validate required environment variables
const requiredEnvVars = ['GOOGLE_CLIENT_ID', 'GOOGLE_CLIENT_SECRET', 'BETTER_AUTH_SECRET'] as const;
for (const envVar of requiredEnvVars) {
  if (!process.env[envVar]) {
    throw new Error(`Missing required environment variable: ${envVar}`);
  }
}

export const auth = betterAuth({
  database: drizzleAdapter(db, {
    provider: "pg",
  }),
  emailAndPassword: {
    enabled: true,
  },
  socialProviders: {
    google: {
      clientId: process.env.GOOGLE_CLIENT_ID,
      clientSecret: process.env.GOOGLE_CLIENT_SECRET,
    },
  },
});
```

**Client Hooks**:

```tsx
// packages/auth/src/client/react.ts
import { createAuthClient } from "better-auth/react";

export const authClient = createAuthClient({
  baseURL: process.env.NEXT_PUBLIC_APP_URL,
});

export const { useSession, signIn, signOut, signUp } = authClient;
```

**Usage in Components**:

```tsx
"use client";
import { useSession, signIn, signOut } from "@workspace/auth/client/react";

function AuthButton() {
  const { data: session, isPending } = useSession();

  if (isPending) return <div>Loading...</div>;

  if (session) {
    return (
      <div>
        <span>{session.user.email}</span>
        <button onClick={() => signOut()}>Sign Out</button>
      </div>
    );
  }

  return (
    // Get from form state
    const { email, password } = formData;
    <button onClick={() => signIn.email({ email, password })}>
      Sign In
    </button>
  );
}
```

**Protected Routes**:

```tsx
// middleware.ts
import { auth } from "@workspace/auth/server";

export default auth.middleware({
  publicRoutes: ["/", "/login", "/signup"],
  redirectTo: "/login",
});
```

<!-- AI-CONTEXT-END -->

## Detailed Patterns

### OAuth Sign In

```tsx
import { signIn } from "@workspace/auth/client/react";

// Google OAuth
<button onClick={() => signIn.social({ provider: "google" })}>
  Sign in with Google
</button>

// GitHub OAuth
<button onClick={() => signIn.social({ provider: "github" })}>
  Sign in with GitHub
</button>
```

### Email/Password Sign Up

```tsx
import { signUp } from "@workspace/auth/client/react";

const handleSignUp = async (data: { email: string; password: string; name: string }) => {
  const result = await signUp.email({
    email: data.email,
    password: data.password,
    name: data.name,
  });

  if (result.error) {
    console.error(result.error);
    return;
  }

  // User created and signed in
  router.push("/dashboard");
};
```

### Server-Side Session

```tsx
// In server component or API route
import { auth } from "@workspace/auth/server";
import { headers } from "next/headers";

export async function getServerSession() {
  const session = await auth.api.getSession({
    headers: await headers(),
  });
  return session;
}

// Usage in page
import { redirect } from "next/navigation";

export default async function DashboardPage() {
  const session = await getServerSession();
  
  if (!session) {
    redirect("/login");
  }

  return <div>Welcome, {session.user.name}</div>;
}
```

### Passkey Authentication

```tsx
// Server config
import { passkey } from "@better-auth/passkey";

export const auth = betterAuth({
  plugins: [passkey()],
  // ... other config
});

// Client usage
import { signIn } from "@workspace/auth/client/react";

<button onClick={() => signIn.passkey()}>
  Sign in with Passkey
</button>
```

### Custom Session Data

```tsx
// Extend session with custom fields
export const auth = betterAuth({
  session: {
    expiresIn: 60 * 60 * 24 * 7, // 7 days
    updateAge: 60 * 60 * 24, // Update session every 24 hours
    cookieCache: {
      enabled: true,
      maxAge: 60 * 5, // 5 minutes
    },
  },
  user: {
    additionalFields: {
      role: {
        type: "string",
        defaultValue: "user",
      },
    },
  },
});
```

### Database Schema Generation

```bash
# Generate auth schema for Drizzle
pnpm --filter auth db:generate

# This creates/updates packages/db/src/schema/auth.ts
```

### API Route Handler

```tsx
// app/api/auth/[...all]/route.ts
import { auth } from "@workspace/auth/server";
import { toNextJsHandler } from "better-auth/next-js";

export const { GET, POST } = toNextJsHandler(auth);
```

## Common Mistakes

1. **Missing environment variables**
   - `BETTER_AUTH_SECRET` required
   - OAuth credentials for each provider

2. **Not generating schema**
   - Run `db:generate` after auth config changes
   - Auth tables must exist in database

3. **Forgetting to await headers()**
   - `headers()` is async in Next.js 15+
   - Always `await headers()` before passing to auth

4. **Client/server import confusion**
   - Use `@workspace/auth/server` on server
   - Use `@workspace/auth/client/react` on client

## Related

- `tools/api/drizzle.md` - Database adapter
- `tools/ui/nextjs-layouts.md` - Protected layouts
- Context7 MCP for Better Auth documentation
