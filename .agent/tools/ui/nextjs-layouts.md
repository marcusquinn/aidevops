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

# Next.js Layouts - App Router Patterns

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Purpose**: Nested layouts, route groups, and provider patterns in Next.js App Router
- **Version**: Next.js 14+ with App Router
- **Docs**: Use Context7 MCP for current documentation

**Common Hazards** (from real sessions):

| Hazard | Problem | Solution |
|--------|---------|----------|
| Provider in wrong layout | Context not available in child routes | Place provider in parent layout that wraps all consumers |
| Server vs Client | Using hooks in server component | Add `"use client"` or move to client component |
| Layout re-renders | Entire layout re-renders on navigation | Layouts are cached; check if issue is in page component |
| Cookie reading | Can't read cookies in client component | Read in server layout, pass as prop to provider |

**Layout Hierarchy**:

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

**Provider Placement**:

```tsx
// app/[locale]/dashboard/layout.tsx
// Place providers here if ALL dashboard routes need them

import { SidebarProvider } from "@/components/sidebar/context";
import { AISidebarProvider } from "@/components/ai-sidebar/context";

import { cookies } from "next/headers";
// Import your sidebar components
import { Sidebar } from "@/components/sidebar";
import { AISidebar } from "@/components/ai-sidebar";

export default async function DashboardLayout({ children }) {
  const cookieStore = await cookies();
  const sidebarOpen = cookieStore.get("sidebar_state")?.value === "true";
  const aiSidebarOpen = cookieStore.get("ai_sidebar_state")?.value !== "false";

  return (
    <SidebarProvider defaultOpen={sidebarOpen}>
      <AISidebarProvider defaultOpen={aiSidebarOpen}>
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

**Route Groups** (parentheses don't affect URL):

```text
dashboard/
├── (user)/           # /dashboard/* - user routes
│   ├── layout.tsx    # User-specific layout
│   ├── page.tsx      # /dashboard
│   └── settings/
│       └── page.tsx  # /dashboard/settings
└── [organization]/   # /dashboard/[org]/* - org routes
    ├── layout.tsx    # Org-specific layout
    └── page.tsx      # /dashboard/acme
```

**3-Column Flex Layout**:

```tsx
// Dashboard with left sidebar, content, and right AI sidebar
<div className="flex min-h-screen">
  {/* Left sidebar - fixed width */}
  <aside className="w-64 shrink-0 border-r">
    <Sidebar />
  </aside>
  
  {/* Main content - flexible */}
  <main className="flex-1 min-w-0">
    {children}
  </main>
  
  {/* Right AI sidebar - collapsible */}
  <AISidebar />
</div>
```

<!-- AI-CONTEXT-END -->

## Detailed Patterns

### Reading Cookies in Server Layout

```tsx
// app/[locale]/dashboard/layout.tsx
import { cookies } from "next/headers";

export default async function DashboardLayout({
  children,
}: {
  children: React.ReactNode;
}) {
  const cookieStore = await cookies();
  
  // Read initial state from cookies
  const sidebarOpen = cookieStore.get("sidebar_state")?.value === "true";
  const aiSidebarOpen = cookieStore.get("ai_sidebar_state")?.value !== "false";
  const aiSidebarWidth = parseInt(
    cookieStore.get("ai_sidebar_width")?.value || "384"
  );

  return (
    <SidebarProvider defaultOpen={sidebarOpen}>
      <AISidebarProvider 
        defaultOpen={aiSidebarOpen}
        defaultWidth={aiSidebarWidth}
      >
        <DashboardShell>{children}</DashboardShell>
      </AISidebarProvider>
    </SidebarProvider>
  );
}
```

### Shared Layout Components

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

### Multiple Layouts for Same Route

Use route groups to apply different layouts:

```text
app/[locale]/dashboard/
├── (with-sidebar)/
│   ├── layout.tsx      # Has sidebar
│   ├── page.tsx        # /dashboard
│   └── settings/
│       └── page.tsx    # /dashboard/settings
└── (fullscreen)/
    ├── layout.tsx      # No sidebar, fullscreen
    └── focus/
        └── page.tsx    # /dashboard/focus
```

### Parallel Routes

For modals or split views:

```text
app/[locale]/dashboard/
├── layout.tsx
├── page.tsx
├── @modal/
│   ├── default.tsx     # Empty when no modal
│   └── (.)settings/
│       └── page.tsx    # Intercepts /dashboard/settings as modal
└── settings/
    └── page.tsx        # Full page version
```

```tsx
// layout.tsx
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

### Loading States

```tsx
// app/[locale]/dashboard/loading.tsx
export default function Loading() {
  return (
    <div className="flex items-center justify-center h-full">
      <Spinner /> {/* Your loading spinner component */}
    </div>
  );
}
```

### Error Boundaries

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

1. **Providers in page instead of layout**
   - Context resets on navigation
   - Move providers to layout for persistence

2. **Async in client component**
   - Can't use `await cookies()` in client
   - Read in server layout, pass as props

3. **Missing default.tsx for parallel routes**
   - Causes 404 when parallel route not matched
   - Add `default.tsx` returning `null`

4. **Layout vs Template**
   - Layout: persists across navigations (cached)
   - Template: re-mounts on every navigation
   - Use layout for providers, template for animations

## Related

- `tools/ui/react-context.md` - Context patterns for layouts
- `tools/ui/tailwind-css.md` - Layout styling
- Context7 MCP for Next.js documentation
