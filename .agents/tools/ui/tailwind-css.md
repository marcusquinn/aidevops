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

- **Docs**: Context7 MCP (`"Tailwind CSS flexbox utilities"`, `"Tailwind CSS positioning"`, `"Tailwind CSS responsive design"`)
- **Config**: `tailwind.config.ts` or `tailwind.config.js`

**Common Hazards** (from real sessions):

| Hazard | Problem | Solution |
|--------|---------|----------|
| Fixed vs Absolute | Element inside collapsing parent disappears | Use `fixed` for elements that must stay visible when parent collapses |
| `w-0` + `overflow-hidden` | Hides absolutely positioned children | Position element outside collapsing parent, or use `fixed` |
| Transition during resize | Laggy drag-to-resize | Conditionally disable: `!isResizing && "transition-all"` |
| Z-index stacking | Elements hidden behind others | Consistent scale: `z-40` (overlay), `z-50` (modal) |
| Global `overscroll-behavior: none` | Blocks scroll chaining from sidebar/panels | Override container AND descendants: `overscroll-auto [&_*]:overscroll-auto` |
| `overflow-auto` on non-scrollable | Creates scroll trap even when content fits | Only add overflow classes when content actually overflows |
| Absolute rail overlapping scrollbar | Can't grab scrollbar | Reduce rail width/offset: `w-2 -right-3` |
| `min-w-0` missing on flex children | Text won't truncate — flex children don't shrink below content width | Add `min-w-0` |
| `h-screen` on mobile | Doesn't account for browser chrome | Use `h-dvh` (dynamic viewport height) |

**Positioning**: `fixed` → viewport; `absolute` → nearest positioned ancestor; `relative` → normal flow + enables absolute children; `sticky` → hybrid.

**Responsive Breakpoints**: `sm:` 640px · `md:` 768px · `lg:` 1024px · `xl:` 1280px · `2xl:` 1536px (mobile-first, no prefix = 0px base).

<!-- AI-CONTEXT-END -->

## Patterns

### Collapsible Sidebar Layout

```tsx
// 3-column flex with collapsible sidebar
// cn = clsx + tailwind-merge
<div className="flex">
  <aside className="w-64 shrink-0">Left</aside>
  <main className="flex-1 min-w-0">Content</main>
  <aside className={cn("w-80 shrink-0 transition-all", open ? "w-80" : "w-0 overflow-hidden")}>
    Right
  </aside>
</div>

// WRONG: Button inside collapsing element disappears
<aside className={open ? "w-80" : "w-0 overflow-hidden"}>
  <button className="absolute top-4 right-4">X</button>
</aside>

// CORRECT: Fixed position outside collapsing parent
<button className="fixed top-4 right-4 z-50">X</button>
<aside className={open ? "w-80" : "w-0 overflow-hidden"}>{/* content */}</aside>
```

### Resizable Elements

```tsx
// Disable transition while dragging for smooth resize
<aside className={cn("w-[var(--sidebar-width)]", !isResizing && "transition-all duration-300")}>
  {/* Resize handle — attach mousemove/mouseup to window; see react-context.md */}
  <div
    onMouseDown={() => setIsResizing(true)}
    className={cn(
      "absolute left-0 top-0 h-full w-1 cursor-col-resize",
      "hover:bg-primary/20 active:bg-primary/30",
      "before:absolute before:inset-y-0 before:-left-1 before:w-3" // wider hit area
    )}
  />
</aside>
```

**CSS variable pattern** — validate before injecting:

```tsx
const sanitizedWidth = Number.isFinite(width) && width > 0 ? width : 384;
<style>{`:root { --sidebar-width: ${sanitizedWidth}px; }`}</style>
<aside className="w-[var(--sidebar-width)]" />
```

### Bottom-Aligned Content (Chat)

```tsx
// flex-col + justify-end
<div className="flex flex-1 flex-col justify-end gap-4 p-4">
  {messages.map(msg => <Message key={msg.id} {...msg} />)}
</div>

// With ScrollArea (shadcn/ui)
<ScrollArea className="flex-1">
  <div className="flex min-h-full flex-col justify-end gap-4">
    {messages.map(msg => <Message key={msg.id} {...msg} />)}
  </div>
</ScrollArea>
```

### Scroll Behavior & overscroll-behavior

Global `* { overscroll-behavior: none; }` traps wheel events on `overflow-auto` containers even when content doesn't overflow. Debug order: (1) check global styles for `overscroll-behavior: none`, (2) verify content actually overflows, (3) only then check JS handlers.

```tsx
// Override global overscroll-behavior on container AND descendants
<div className="overflow-auto overscroll-auto [&_*]:overscroll-auto">
  {/* content */}
</div>
```

`[&_*]:overscroll-auto` needed because global `*` rule applies to every descendant — hovering a link makes it the wheel event target, blocking scroll chaining. Keep `overscroll-behavior: none` for: chat areas, modals, infinite scroll.

### Glow Effects

```tsx
className={cn(
  "shadow-[0_0_20px_4px] shadow-primary/10",
  "hover:shadow-[0_0_25px_6px] hover:shadow-primary/30",
  "focus-within:shadow-[0_0_30px_6px] focus-within:shadow-primary/20"
)}
```

### Dark Mode (shadcn/ui Semantic Colors)

```tsx
<div className="bg-background text-foreground">
  <p className="text-muted-foreground">Secondary</p>
  <div className="bg-primary text-primary-foreground">Primary</div>
</div>
```

## Related

- `tools/ui/shadcn.md` — Component library using Tailwind
- `tools/ui/frontend-debugging.md` — Debugging layout issues
