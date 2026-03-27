---
description: Tailwind CSS utility-first styling - positioning, layouts, responsive design
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

# Tailwind CSS - Utility-First Styling

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Docs**: Use Context7 MCP (`resolve-library-id` → `query-docs`) for current documentation
- **Config**: `tailwind.config.ts` or `tailwind.config.js`

**Common Hazards**:

| Hazard | Problem | Fix |
|--------|---------|-----|
| Fixed vs Absolute | Button inside collapsing element disappears | Use `fixed` for elements that must stay visible when parent collapses |
| `w-0` + `overflow-hidden` | Hides absolutely positioned children | Position element outside collapsing parent, or use `fixed` |
| Transition during resize | Laggy drag-to-resize | Conditionally disable: `!isResizing && "transition-all"` |
| Z-index stacking | Elements hidden behind others | Use consistent scale: `z-40` (overlay), `z-50` (modal) |
| Global `overscroll-behavior: none` | Blocks scroll chaining from sidebar/panels | Override on container AND descendants: `overscroll-auto [&_*]:overscroll-auto` |
| `overflow-auto` on non-scrollable content | Creates scroll trap when content fits | Check if content actually overflows before adding overflow classes |
| Absolute rail overlapping scrollbar | Can't grab scrollbar | Reduce rail width and offset: `w-2 -right-3` instead of `w-4 -right-4` |

**Positioning Mental Model**:

```text
fixed    → relative to viewport (stays put when scrolling/resizing)
absolute → relative to nearest positioned ancestor
relative → normal flow, enables absolute children
sticky   → hybrid (normal until scroll threshold)
```

**Layout Patterns**:

```tsx
// 3-column flex layout with collapsible sidebar
<div className="flex">
  <aside className="w-64 shrink-0">Left</aside>
  <main className="flex-1 min-w-0">Content</main>
  <aside className={cn("w-80 shrink-0 transition-all", open ? "w-80" : "w-0 overflow-hidden")}>Right</aside>
</div>

// Button that stays visible when sidebar collapses — use fixed, not absolute inside collapsing element
<button className="fixed top-4 right-4 z-50">X</button>
<aside className={open ? "w-80" : "w-0 overflow-hidden"}>{/* content */}</aside>
```

**CSS Variables with Tailwind**:

```tsx
// Validate numeric values before injecting into CSS
const sanitizedWidth = Number.isFinite(width) && width > 0 ? width : 384;
<style>{`:root { --sidebar-width: ${sanitizedWidth}px; }`}</style>
<aside className="w-[var(--sidebar-width)]">
```

**Responsive Breakpoints**: `sm:` 640px · `md:` 768px · `lg:` 1024px · `xl:` 1280px · `2xl:` 1536px (mobile-first, no prefix = 0px)

**Glow Effects**:

```tsx
className={cn(
  "shadow-[0_0_20px_4px] shadow-primary/10",
  "hover:shadow-[0_0_25px_6px] hover:shadow-primary/30",
  "focus-within:shadow-[0_0_30px_6px] focus-within:shadow-primary/20"
)}
```

<!-- AI-CONTEXT-END -->

## Patterns

**Resizable sidebar** — disable transition while dragging:

```tsx
<aside className={cn("w-[var(--sidebar-width)]", !isResizing && "transition-all duration-300")}>
  <div onMouseDown={() => setIsResizing(true)}
    className="absolute left-0 top-0 h-full w-1 cursor-col-resize hover:bg-primary/20
               before:absolute before:inset-y-0 before:-left-1 before:w-3" />
</aside>
{/* Requires mousemove/mouseup handlers on window — see react-context.md */}
```

**Bottom-aligned content** (chat interfaces):

```tsx
<ScrollArea className="flex-1">
  <div className="flex min-h-full flex-col justify-end gap-4">
    {messages.map(msg => <Message key={msg.id} {...msg} />)}
  </div>
</ScrollArea>
```

**Scroll trap fix** — global `* { overscroll-behavior: none }` traps wheel events even on non-overflowing containers. Debug order: (1) check global styles, (2) check if content actually overflows, (3) only then consider JS handlers.

```tsx
// RIGHT: Override on container AND descendants
<div className="overflow-auto overscroll-auto [&_*]:overscroll-auto">
  {/* sidebar content */}
</div>
// WRONG: JS wheel handler forwarding — complex and fragile
```

Keep `overscroll-behavior: none` for: chat areas with independent scroll, modals, infinite scroll lists.

**Dark mode**: Use semantic tokens — `bg-background text-foreground`, `text-muted-foreground`, `bg-primary text-primary-foreground`.

**Common mistakes**:

| Mistake | Fix |
|---------|-----|
| Missing `min-w-0` on flex children | Flex children don't shrink below content width — add `min-w-0` for text truncation |
| `h-screen` on mobile | Use `h-dvh` (dynamic viewport height) — accounts for browser chrome |
| Transition on rapidly-changing values | Conditionally disable during resize/drag |

## Related

- `tools/ui/shadcn.md` — Component library using Tailwind
- `tools/ui/frontend-debugging.md` — Debugging layout issues
