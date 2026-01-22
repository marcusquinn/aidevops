---
description: React Context API patterns - state management, providers, hooks
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

# React Context - State Management Patterns

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Purpose**: Share state across component tree without prop drilling
- **Use Case**: Theme, auth, sidebar state, user preferences
- **Docs**: Use Context7 MCP for current React documentation

**Common Hazards** (from real sessions):

| Hazard | Problem | Solution |
|--------|---------|----------|
| Adding state to existing context | Forgot to update interface, provider, and hook | Update ALL: interface, default value, provider state, hook return |
| Context outside provider | Hook returns undefined | Add fallback in hook or ensure provider wraps usage |
| Stale closures | Event handlers capture old state | Use `useCallback` with proper dependencies |
| Re-renders | Entire tree re-renders on any context change | Split contexts by update frequency |

**Context Pattern Template**:

```tsx
// 1. Define interface with ALL state
interface SidebarContextProps {
  open: boolean;
  setOpen: (open: boolean) => void;
  toggleSidebar: () => void;
  width: number;           // Don't forget new state!
  setWidth: (width: number) => void;
}

// 2. Create context with null (forces provider usage)
const SidebarContext = createContext<SidebarContextProps | null>(null);

// 3. Hook with fallback for optional usage
export function useSidebar() {
  const context = useContext(SidebarContext);
  if (!context) {
    // Return safe defaults when used outside provider
    return {
      open: false,
      setOpen: () => {},
      toggleSidebar: () => {},
      width: 384,
      setWidth: () => {},
    };
  }
  return context;
}

// 4. Optional hook that returns null (for conditional rendering)
export function useSidebarOptional() {
  return useContext(SidebarContext);
}
```

**Adding New State Checklist**:

1. [ ] Update interface with new property
2. [ ] Update default/fallback values in hook
3. [ ] Add state in provider (`useState`)
4. [ ] Add setter in provider (`useCallback`)
5. [ ] Add to provider value object
6. [ ] Update any CSS variables if needed

**Persisting to Cookies**:

```tsx
const COOKIE_NAME = "sidebar_state";
const COOKIE_MAX_AGE = 60 * 60 * 24 * 7; // 7 days

const setOpen = useCallback((value: boolean) => {
  setOpenState(value);
  document.cookie = `${COOKIE_NAME}=${value}; path=/; max-age=${COOKIE_MAX_AGE}`;
}, []);
```

**CSS Variables from Context**:

```tsx
// In provider
<SidebarContext.Provider value={contextValue}>
  <style>{`:root { --sidebar-width: ${width}px; }`}</style>
  {children}
</SidebarContext.Provider>

// In component
<aside className="w-[var(--sidebar-width)]">
```

<!-- AI-CONTEXT-END -->

## Detailed Patterns

### Full Provider Example

```tsx
"use client";

import { createContext, useCallback, useContext, useState } from "react";
import type { ReactNode } from "react";

// Constants
const COOKIE_NAME = "sidebar_state";
const WIDTH_COOKIE_NAME = "sidebar_width";
export const DEFAULT_WIDTH = 384;
export const MIN_WIDTH = 320;
export const MAX_WIDTH = 640;

// Interface
interface SidebarContextProps {
  open: boolean;
  setOpen: (open: boolean) => void;
  toggleSidebar: () => void;
  width: number;
  setWidth: (width: number) => void;
}

// Context
const SidebarContext = createContext<SidebarContextProps | null>(null);

// Hooks
export function useSidebar() {
  const context = useContext(SidebarContext);
  if (!context) {
    return {
      open: false,
      setOpen: () => {},
      toggleSidebar: () => {},
      width: DEFAULT_WIDTH,
      setWidth: () => {},
    };
  }
  return context;
}

export function useSidebarOptional() {
  return useContext(SidebarContext);
}

// Provider Props
interface SidebarProviderProps {
  readonly children: ReactNode;
  readonly defaultOpen?: boolean;
}

// Provider
export function SidebarProvider({
  children,
  defaultOpen = false,
}: SidebarProviderProps) {
  const [open, setOpenState] = useState(defaultOpen);
  const [width, setWidthState] = useState(DEFAULT_WIDTH);

  const setOpen = useCallback((value: boolean) => {
    setOpenState(value);
    document.cookie = `${COOKIE_NAME}=${value}; path=/; max-age=${60 * 60 * 24 * 7}`;
  }, []);

  const toggleSidebar = useCallback(() => {
    setOpenState((prev) => {
      const newValue = !prev;
      document.cookie = `${COOKIE_NAME}=${newValue}; path=/; max-age=${60 * 60 * 24 * 7}`;
      return newValue;
    });
  }, []);

  const setWidth = useCallback((value: number) => {
    const clamped = Math.min(Math.max(value, MIN_WIDTH), MAX_WIDTH);
    setWidthState(clamped);
    document.cookie = `${WIDTH_COOKIE_NAME}=${clamped}; path=/; max-age=${60 * 60 * 24 * 7}`;
  }, []);

  return (
    <SidebarContext.Provider
      value={{ open, setOpen, toggleSidebar, width, setWidth }}
    >
      <style>{`:root { --sidebar-width: ${width}px; }`}</style>
      {children}
    </SidebarContext.Provider>
  );
}
```

### Conditional Rendering Based on Context

```tsx
const AISidebarToggle = () => {
  const sidebar = useSidebarOptional();

  // Don't render if no provider (e.g., on pages without sidebar)
  if (!sidebar) return null;

  const { open, toggleSidebar } = sidebar;

  // Don't render when open (close button is in sidebar)
  if (open) return null;

  return (
    <Button onClick={toggleSidebar}>
      <Icons.Sparkles />
    </Button>
  );
};
```

### Reading Initial State from Cookies (Server Component)

```tsx
// In layout.tsx (server component)
import { cookies } from "next/headers";

export default async function Layout({ children }) {
  const cookieStore = await cookies();
  const defaultOpen = cookieStore.get("sidebar_state")?.value === "true";

  return (
    <SidebarProvider defaultOpen={defaultOpen}>
      {children}
    </SidebarProvider>
  );
}
```

### Performance: Split Contexts

```tsx
// BAD: One context for everything
const AppContext = createContext({
  user: null,
  theme: "light",
  sidebarOpen: false,
  notifications: [],
});

// GOOD: Split by update frequency
const UserContext = createContext(null);      // Rarely changes
const ThemeContext = createContext("light");  // Rarely changes
const SidebarContext = createContext(false);  // Changes on interaction
const NotificationContext = createContext([]); // Changes frequently
```

## Common Mistakes

1. **Forgetting "use client"**
   - Context requires client-side React
   - Add `"use client"` at top of context file

2. **Not memoizing setters**
   - Causes unnecessary re-renders
   - Wrap setters in `useCallback`

3. **Mutating state directly**
   - React won't detect changes
   - Always use setter functions

4. **Missing dependency arrays**
   - Stale closures in callbacks
   - Include all dependencies in `useCallback`

## Related

- `tools/ui/nextjs-layouts.md` - Layout patterns with providers
- `tools/ui/tailwind-css.md` - Styling with context-driven CSS variables
