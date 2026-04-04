---
description: Next.js App Router layouts - nested layouts, providers, route groups
mode: subagent
tools:
  read: true
  write: true
  edit: true
  bash: false
  glob: true
  grep: true
  webfetch: true
  task: true
  context7_*: true
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Next.js Layouts - App Router Patterns

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Scope**: Nested layouts, route groups, providers in Next.js 14+ App Router
- **Docs**: Use Context7 MCP for current documentation

**Common Hazards**:

| Hazard | Problem | Solution |
|--------|---------|----------|
| Provider in wrong layout | Context not available in child routes | Place provider in parent layout wrapping all consumers |
| Server vs Client | Using hooks in server component | Add `"use client"` or move to client component |
| Layout re-renders | Entire layout re-renders on navigation | Layouts are cached; check if issue is in page component |
| Cookie reading | Can't read cookies in client component | Read in server layout, pass as prop to provider |

## Layout Hierarchy

```text
app/
├── layout.tsx              # Root layout (html, body, global providers)
├── [locale]/
│   ├── layout.tsx          # Locale layout (i18n provider)
│   ├── dashboard/
│   │   ├── layout.tsx      # Dashboard layout (sidebar, auth check)
│   │   ├── (user)/
│   │   │   ├── layout.tsx  # User dashboard layout
│   │   │   └── page.tsx
│   │   └── [organization]/
│   │       ├── layout.tsx  # Org dashboard layout
│   │       └── page.tsx
│   └── admin/
│       ├── layout.tsx      # Admin layout
│       └── page.tsx
```

## Server Layout with Cookie-Driven Providers

Read cookies server-side, pass initial state to client providers:

```tsx
// app/[locale]/dashboard/layout.tsx
import { cookies } from "next/headers";
import { SidebarProvider } from "@/components/sidebar/context";
import { AISidebarProvider } from "@/components/ai-sidebar/context";
import { Sidebar } from "@/components/sidebar";
import { AISidebar } from "@/components/ai-sidebar";

export default async function DashboardLayout({
  children,
}: {
  children: React.ReactNode;
}) {
  const cookieStore = await cookies();
  const sidebarOpen = cookieStore.get("sidebar_state")?.value === "true";
  const aiSidebarOpen = cookieStore.get("ai_sidebar_state")?.value !== "false";
  const aiSidebarWidth = parseInt(
    cookieStore.get("ai_sidebar_width")?.value || "384"
  );

  return (
    <SidebarProvider defaultOpen={sidebarOpen}>
      <AISidebarProvider defaultOpen={aiSidebarOpen} defaultWidth={aiSidebarWidth}>
        <div className="flex min-h-screen">
          <Sidebar />
          <main className="flex-1">{children}</main>
          <AISidebar />
        </div>
      </AISidebarProvider>
    </SidebarProvider>
  );
}
```

## Client Shell Component

Extract layout structure into a client component when you need hooks:

```tsx
// components/layout/dashboard-shell.tsx
"use client";

import { useSidebar } from "@/components/sidebar/context";
import { useAISidebar } from "@/components/ai-sidebar/context";

export function DashboardShell({ children }: { children: React.ReactNode }) {
  const { open: sidebarOpen } = useSidebar();
  const { open: aiSidebarOpen } = useAISidebar();

  return (
    <div className="flex min-h-screen">
      <Sidebar />
      <div className="flex flex-1 flex-col">
        <Header />
        <main className="flex-1">{children}</main>
      </div>
      <AISidebar />
    </div>
  );
}
```

<!-- AI-CONTEXT-END -->

## Route Groups

Parenthesized directories don't affect URLs. Use for applying different layouts to the same route prefix:

```text
dashboard/
├── (user)/               # /dashboard/* — user routes
│   ├── layout.tsx        # User-specific layout (has sidebar)
│   ├── page.tsx          # /dashboard
│   └── settings/
│       └── page.tsx      # /dashboard/settings
├── (fullscreen)/         # /dashboard/* — fullscreen variant
│   ├── layout.tsx        # No sidebar
│   └── focus/
│       └── page.tsx      # /dashboard/focus
└── [organization]/       # /dashboard/[org]/* — org routes
    ├── layout.tsx        # Org-specific layout
    └── page.tsx          # /dashboard/acme
```

## Parallel Routes

For modals or split views using `@slot` directories:

```text
app/[locale]/dashboard/
├── layout.tsx
├── page.tsx
├── @modal/
│   ├── default.tsx       # Empty when no modal
│   └── (.)settings/
│       └── page.tsx      # Intercepts /dashboard/settings as modal
└── settings/
    └── page.tsx          # Full page version
```

```tsx
// layout.tsx — receives parallel route slots as props
export default function Layout({
  children,
  modal,
}: {
  children: React.ReactNode;
  modal: React.ReactNode;
}) {
  return (
    <>
      {children}
      {modal}
    </>
  );
}
```

## Loading & Error States

```tsx
// app/[locale]/dashboard/loading.tsx
export default function Loading() {
  return (
    <div className="flex items-center justify-center h-full">
      <Spinner />
    </div>
  );
}
```

```tsx
// app/[locale]/dashboard/error.tsx
"use client";

export default function Error({
  error,
  reset,
}: {
  error: Error;
  reset: () => void;
}) {
  return (
    <div className="flex flex-col items-center justify-center h-full gap-4">
      <h2>Something went wrong!</h2>
      <button onClick={reset}>Try again</button>
    </div>
  );
}
```

## Common Mistakes

1. **Providers in page instead of layout** — context resets on navigation. Move to layout for persistence.
2. **Async in client component** — can't `await cookies()` in client. Read in server layout, pass as props.
3. **Missing `default.tsx` for parallel routes** — causes 404 when slot not matched. Return `null`.
4. **Layout vs Template** — layouts persist across navigations (cached); templates re-mount every navigation. Use layout for providers, template for animations.

## Related

- `tools/ui/react-context.md` — Context patterns for layouts
- `tools/ui/tailwind-css.md` — Layout styling
- Context7 MCP for Next.js documentation
