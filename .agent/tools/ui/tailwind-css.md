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

- **Purpose**: Utility-first CSS framework for rapid UI development
- **Docs**: Use Context7 MCP for current documentation
- **Config**: `tailwind.config.ts` or `tailwind.config.js`

**Common Hazards** (from real sessions):

| Hazard | Problem | Solution |
|--------|---------|----------|
| Fixed vs Absolute | Button inside collapsing element disappears | Use `fixed` for elements that must stay visible when parent collapses |
| `w-0` + `overflow-hidden` | Hides absolutely positioned children | Position element outside collapsing parent, or use `fixed` |
| Transition during resize | Laggy drag-to-resize | Conditionally disable: `!isResizing && "transition-all"` |
| Z-index stacking | Elements hidden behind others | Use consistent z-index scale: `z-40` (overlay), `z-50` (modal) |
| Global `overscroll-behavior: none` | Blocks scroll chaining from sidebar/panels to page | Override on container AND descendants: `overscroll-auto [&_*]:overscroll-auto` |
| `overflow-auto` on non-scrollable content | Creates scroll trap even when content fits | Check if content actually overflows before adding overflow classes |
| Absolute-positioned rail overlapping scrollbar | Can't grab scrollbar, clicks trigger rail action | Reduce rail width and offset: `w-2 -right-3` instead of `w-4 -right-4` |

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
  <aside className={cn(
    "w-80 shrink-0 transition-all",
    open ? "w-80" : "w-0 overflow-hidden"
  )}>Right</aside>
</div>

// Button that stays visible when sidebar collapses
// WRONG: Inside collapsing element
<aside className={open ? "w-80" : "w-0 overflow-hidden"}>
  <button className="absolute top-4 right-4">X</button> {/* Disappears! */}
</aside>

// CORRECT: Fixed position outside
<button className="fixed top-4 right-4 z-50">X</button>
<aside className={open ? "w-80" : "w-0 overflow-hidden"}>
  {/* content */}
</aside>
```

**CSS Variables with Tailwind**:

```tsx
// Define in context/provider
<style>{`:root { --sidebar-width: ${width}px; }`}</style>

// Use in className
<aside className="w-[var(--sidebar-width)]">
```

**Responsive Breakpoints**:

| Prefix | Min Width | Use Case |
|--------|-----------|----------|
| (none) | 0px | Mobile-first base |
| `sm:` | 640px | Large phones |
| `md:` | 768px | Tablets |
| `lg:` | 1024px | Laptops |
| `xl:` | 1280px | Desktops |
| `2xl:` | 1536px | Large screens |

**Glow Effects** (theme-colored):

```tsx
// Subtle glow
className="shadow-[0_0_20px_4px] shadow-primary/10"

// Enhanced on hover/focus
className={cn(
  "shadow-[0_0_20px_4px] shadow-primary/10",
  "hover:shadow-[0_0_25px_6px] hover:shadow-primary/30",
  "focus-within:shadow-[0_0_30px_6px] focus-within:shadow-primary/20"
)}
```

<!-- AI-CONTEXT-END -->

## Detailed Patterns

### Resizable Elements

Implementing drag-to-resize with Tailwind:

```tsx
const [width, setWidth] = useState(384);
const [isResizing, setIsResizing] = useState(false);

// Disable transition while dragging for smooth resize
<aside className={cn(
  "w-[var(--sidebar-width)]",
  !isResizing && "transition-all duration-300"
)}>
  {/* Resize handle */}
  <div
    onMouseDown={() => setIsResizing(true)}
    className={cn(
      "absolute left-0 top-0 h-full w-1 cursor-col-resize",
      "hover:bg-primary/20 active:bg-primary/30",
      // Wider hit area for easier grabbing
      "before:absolute before:inset-y-0 before:-left-1 before:w-3"
    )}
  />
</aside>
```

### Bottom-Aligned Content

For chat interfaces where content should align to bottom:

```tsx
// Container with flex-col and justify-end
<div className="flex flex-1 flex-col justify-end gap-4 p-4">
  {messages.map(msg => <Message key={msg.id} {...msg} />)}
</div>

// Or with min-height for scroll behavior
<ScrollArea className="flex-1">
  <div className="flex min-h-full flex-col justify-end gap-4">
    {messages.map(msg => <Message key={msg.id} {...msg} />)}
  </div>
</ScrollArea>
```

### Scroll Behavior & overscroll-behavior

**Critical**: Global `* { overscroll-behavior: none; }` prevents scroll chaining. When a user hovers over a sidebar or panel that has `overflow-auto`, wheel events get trapped even if the content doesn't overflow.

**Debugging approach** (check CSS first, not JS):

1. Check global styles for `overscroll-behavior: none` on `*` or `html`/`body`
2. Check if the scroll container actually has overflowing content
3. Only then consider JS wheel event handlers

```tsx
// WRONG: Complex JS wheel handler to forward scroll events
React.useEffect(() => {
  const handleWheel = (e: WheelEvent) => {
    window.scrollBy({ top: e.deltaY });
    e.preventDefault();
  };
  el.addEventListener("wheel", handleWheel, { passive: false });
}, []);

// RIGHT: Override the global overscroll-behavior on the container
<div className="overflow-auto overscroll-auto [&_*]:overscroll-auto">
  {/* Sidebar content */}
</div>
```

**Why `[&_*]:overscroll-auto` is needed**: The global `* { overscroll-behavior: none }` applies to every element including links and buttons inside the sidebar. When the cursor hovers a link, the wheel event target is the link (which has `overscroll-behavior: none`), blocking scroll chaining even if the parent allows it.

**When to keep `overscroll-behavior: none`**:
- Chat/messaging areas with independent scroll
- Modal/dialog content that shouldn't scroll the page behind
- Infinite scroll lists where boundary scroll would be confusing

### Dark Mode

```tsx
// Using next-themes or similar
<div className="bg-background text-foreground">
  <p className="text-muted-foreground">Secondary text</p>
  <div className="bg-muted">Muted background</div>
  <div className="bg-primary text-primary-foreground">Primary</div>
</div>
```

### Common Mistakes

1. **Forgetting `min-w-0` on flex children**
   - Flex children don't shrink below content width by default
   - Add `min-w-0` to allow text truncation

2. **Using `h-screen` instead of `h-dvh`**
   - `h-screen` doesn't account for mobile browser chrome
   - Use `h-dvh` (dynamic viewport height) for full-height layouts

3. **Transition on frequently-changing values**
   - Causes performance issues
   - Conditionally disable during rapid changes (resize, drag)

## Context7 Integration

For current Tailwind documentation:

```text
Use Context7 MCP to query:
- "Tailwind CSS flexbox utilities"
- "Tailwind CSS positioning"
- "Tailwind CSS responsive design"
```

## Related

- `tools/ui/shadcn.md` - Component library using Tailwind
- `tools/ui/frontend-debugging.md` - Debugging layout issues
