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
- **Features**: Email/password, OAuth, magic links, passkeys, session management (DB-backed), Drizzle adapter, React hooks
- **Imports**: `@workspace/auth/server` (server), `@workspace/auth/client/react` (client) — never mix

**Server Setup**:

```tsx
// packages/auth/src/server.ts
import { betterAuth } from "better-auth";
import { drizzleAdapter } from "better-auth/adapters/drizzle";
import { db } from "@workspace/db";

const requiredEnvVars = ['GOOGLE_CLIENT_ID', 'GOOGLE_CLIENT_SECRET', 'BETTER_AUTH_SECRET'] as const;
for (const envVar of requiredEnvVars) {
  if (!process.env[envVar]) {
    throw new Error(`Missing required environment variable: ${envVar}`);
  }
}

// Server-side password validation — security boundary.
// Client-side Zod checks are UX only; this enforces on every signUp.email() call.
const validatePassword = (password: string) => {
  if (password.length < 8) return false;
  if (!/[A-Z]/.test(password)) return false;
  if (!/[a-z]/.test(password)) return false;
  if (!/[0-9]/.test(password)) return false;
  return true;
};

export const auth = betterAuth({
  database: drizzleAdapter(db, { provider: "pg" }),
  emailAndPassword: {
    enabled: true,
    password: { validate: validatePassword },
  },
  socialProviders: {
    google: {
      clientId: process.env.GOOGLE_CLIENT_ID,
      clientSecret: process.env.GOOGLE_CLIENT_SECRET,
    },
  },
});
```

**Client Setup**:

```tsx
// packages/auth/src/client/react.ts
import { createAuthClient } from "better-auth/react";

export const authClient = createAuthClient({
  baseURL: process.env.NEXT_PUBLIC_APP_URL,
});

export const { useSession, signIn, signOut, signUp } = authClient;
```

**API Route Handler**:

```tsx
// app/api/auth/[...all]/route.ts
import { auth } from "@workspace/auth/server";
import { toNextJsHandler } from "better-auth/next-js";

export const { GET, POST } = toNextJsHandler(auth);
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

## Usage Patterns

### Component Auth (Client)

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
  return <button onClick={() => signIn.email({ email, password })}>Sign In</button>;
}
```

### OAuth Sign In

```tsx
import { signIn } from "@workspace/auth/client/react";

// Google / GitHub OAuth
<button onClick={() => signIn.social({ provider: "google" })}>Sign in with Google</button>
<button onClick={() => signIn.social({ provider: "github" })}>Sign in with GitHub</button>
```

### Email/Password Sign Up

```tsx
import { signUp } from "@workspace/auth/client/react";
import { z } from "zod";

// Client-side validation — UX only, not a security boundary.
// Server enforces via emailAndPassword.password.validate (see server setup).
const passwordSchema = z.string()
  .min(8, "Password must be at least 8 characters")
  .regex(/[A-Z]/, "Must contain an uppercase letter")
  .regex(/[a-z]/, "Must contain a lowercase letter")
  .regex(/[0-9]/, "Must contain a number");

const handleSignUp = async (data: { email: string; password: string; name: string }) => {
  const passwordCheck = passwordSchema.safeParse(data.password);
  if (!passwordCheck.success) {
    console.error("Weak password:", passwordCheck.error.flatten().formErrors);
    return;
  }

  const result = await signUp.email({
    email: data.email,
    password: data.password,
    name: data.name,
  });

  if (result.error) {
    // Server-side validation failures, duplicate email, etc.
    console.error("Sign-up failed:", result.error.message);
    return;
  }
  router.push("/dashboard");
};
```

### Server-Side Session

```tsx
import { auth } from "@workspace/auth/server";
import { headers } from "next/headers";
import { redirect } from "next/navigation";

export async function getServerSession() {
  return auth.api.getSession({ headers: await headers() }); // headers() is async in Next.js 15+
}

export default async function DashboardPage() {
  const session = await getServerSession();
  if (!session) redirect("/login");
  return <div>Welcome, {session.user.name}</div>;
}
```

### Passkey Authentication

```tsx
// Server: add plugin
import { passkey } from "@better-auth/passkey";
export const auth = betterAuth({ plugins: [passkey()], /* ... */ });

// Client
import { signIn } from "@workspace/auth/client/react";
<button onClick={() => signIn.passkey()}>Sign in with Passkey</button>
```

### Custom Session Data

```tsx
export const auth = betterAuth({
  session: {
    expiresIn: 60 * 60 * 24 * 7, // 7 days
    updateAge: 60 * 60 * 24,      // refresh every 24h
    cookieCache: { enabled: true, maxAge: 60 * 5 }, // 5 min cache
  },
  user: {
    additionalFields: {
      role: { type: "string", defaultValue: "user" },
    },
  },
});
```

### Database Schema Generation

```bash
# Generate/update auth schema for Drizzle (creates packages/db/src/schema/auth.ts)
pnpm --filter auth db:generate
```

## Common Mistakes

1. **Missing env vars** — `BETTER_AUTH_SECRET` required; OAuth credentials per provider
2. **Schema not generated** — run `db:generate` after auth config changes; auth tables must exist
3. **Not awaiting `headers()`** — async in Next.js 15+; always `await headers()` before passing to auth
4. **Import confusion** — `@workspace/auth/server` on server, `@workspace/auth/client/react` on client

## Related

- `tools/api/drizzle.md` — Database adapter
- `tools/ui/nextjs-layouts.md` — Protected layouts
- Context7 MCP for Better Auth documentation
