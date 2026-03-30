---
description: React Context API patterns - state management, providers, hooks
mode: subagent
tools:
  read: true
  write: true
  edit: true
  glob: true
  grep: true
  webfetch: true
  task: true
  context7_*: true
---

# React Context - State Management Patterns

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Purpose**: Share state across component tree without prop drilling
- **Use Case**: Theme, auth, sidebar state, user preferences
- **Docs**: Use Context7 MCP for current React documentation

**Hazards** (from real sessions):

| Hazard | Solution |
|--------|----------|
| Adding state — forgot to update interface/provider/hook | Update ALL: interface, default value, provider state, hook return |
| Context outside provider — hook returns undefined | Add fallback in hook or ensure provider wraps usage |
| Stale closures / missing dependency arrays | Use `useCallback` with ALL dependencies |
| Re-renders on any context change | Split contexts by update frequency; memoize setters |
| Forgetting `"use client"` | Context requires client-side React — add at top of file |
| Mutating state directly | Always use setter functions — React won't detect direct mutation |

**Adding New State Checklist**: interface -> hook defaults -> `useState` in provider -> `useCallback` setter -> provider value object -> CSS variables if needed.

<!-- AI-CONTEXT-END -->

## Full Provider Example

```tsx
"use client";
import { createContext, useCallback, useContext, useState } from "react";
import type { ReactNode } from "react";

const COOKIE_NAME = "sidebar_state";
const WIDTH_COOKIE_NAME = "sidebar_width";
export const DEFAULT_WIDTH = 384;
export const MIN_WIDTH = 320;
export const MAX_WIDTH = 640;

interface SidebarContextProps {
  open: boolean;
  setOpen: (open: boolean) => void;
  toggleSidebar: () => void;
  width: number;
  setWidth: (width: number) => void;
}

const SidebarContext = createContext<SidebarContextProps | null>(null);

// Hook with safe defaults when used outside provider
export function useSidebar() {
  const context = useContext(SidebarContext);
  if (!context) {
    return { open: false, setOpen: () => {}, toggleSidebar: () => {}, width: DEFAULT_WIDTH, setWidth: () => {} };
  }
  return context;
}

// Optional hook — returns null (use for conditional rendering)
export function useSidebarOptional() {
  return useContext(SidebarContext);
}

interface SidebarProviderProps {
  readonly children: ReactNode;
  readonly defaultOpen?: boolean;
  readonly defaultWidth?: number;
}

export function SidebarProvider({ children, defaultOpen = false, defaultWidth = DEFAULT_WIDTH }: SidebarProviderProps) {
  const [open, setOpenState] = useState(defaultOpen);
  const [width, setWidthState] = useState(defaultWidth);
  const COOKIE_MAX_AGE = 60 * 60 * 24 * 7; // 7 days

  const setOpen = useCallback((value: boolean) => {
    setOpenState(value);
    document.cookie = `${COOKIE_NAME}=${value}; path=/; max-age=${COOKIE_MAX_AGE}; SameSite=Lax`;
  }, []);

  const toggleSidebar = useCallback(() => {
    setOpenState((prev) => {
      const newValue = !prev;
      document.cookie = `${COOKIE_NAME}=${newValue}; path=/; max-age=${COOKIE_MAX_AGE}; SameSite=Lax`;
      return newValue;
    });
  }, []);

  const setWidth = useCallback((value: number) => {
    const clamped = Math.min(Math.max(value, MIN_WIDTH), MAX_WIDTH);
    setWidthState(clamped);
    document.cookie = `${WIDTH_COOKIE_NAME}=${clamped}; path=/; max-age=${COOKIE_MAX_AGE}; SameSite=Lax`;
  }, []);

  return (
    <SidebarContext.Provider value={{ open, setOpen, toggleSidebar, width, setWidth }}>
      <style>{`:root { --sidebar-width: ${width}px; }`}</style>
      {children}
    </SidebarContext.Provider>
  );
}
```

## Usage Patterns

**Conditional rendering** — `useSidebarOptional()` skips rendering when no provider:

```tsx
const AISidebarToggle = () => {
  const sidebar = useSidebarOptional();
  if (!sidebar || sidebar.open) return null;
  return <Button onClick={sidebar.toggleSidebar}><Icons.Sparkles /></Button>;
};
```

**Server-side cookie hydration** — read initial state in server component:

```tsx
import { cookies } from "next/headers";
export default async function Layout({ children }) {
  const cookieStore = await cookies();
  const defaultOpen = cookieStore.get("sidebar_state")?.value === "true";
  return <SidebarProvider defaultOpen={defaultOpen}>{children}</SidebarProvider>;
}
```

**Split contexts by update frequency** to avoid unnecessary re-renders:

```tsx
// BAD: one context — any change re-renders all consumers
const AppContext = createContext({ user: null, theme: "light", sidebarOpen: false, notifications: [] });

// GOOD: split by update frequency
const UserContext = createContext(null);      // Rarely changes
const ThemeContext = createContext("light");  // Rarely changes
const SidebarContext = createContext(false);  // Changes on interaction
const NotificationContext = createContext([]); // Changes frequently
```

## Related

- `tools/ui/nextjs-layouts.md` - Layout patterns with providers
- `tools/ui/tailwind-css.md` - Styling with context-driven CSS variables
