---
description: Opinionated constraints for building better interfaces with agents
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
---

# UI Skills

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Source**: https://www.ui-skills.com/llms.txt
- **Stack**: Tailwind CSS, `motion/react`, `tw-animate-css`, `cn` (`clsx` + `tailwind-merge`)
- **Apply when**: Building React/Next.js UIs, Tailwind components, animation, accessibility, or UI performance
- **Defaults**: Tailwind defaults first; accessible primitives; no animation unless requested; respect `prefers-reduced-motion`; never block paste

<!-- AI-CONTEXT-END -->

## Stack & Components

- MUST use Tailwind defaults (spacing, radius, shadows) before custom values
- MUST use `motion/react` (formerly `framer-motion`) for JavaScript animation
- SHOULD use `tw-animate-css` for Tailwind entrance and micro-animations
- MUST use `cn` (`clsx` + `tailwind-merge`) for class logic
- MUST use accessible component primitives for keyboard/focus behavior (`Base UI`, `React Aria`, `Radix`)
- MUST use the project's existing component primitives first; NEVER mix primitive systems on the same surface
- SHOULD prefer [`Base UI`](https://base-ui.com/react/components) for new primitives if compatible
- MUST add `aria-label` to icon-only buttons
- NEVER rebuild keyboard or focus behavior by hand unless explicitly requested

## Interaction

- MUST use `AlertDialog` for destructive or irreversible actions
- SHOULD use structural skeletons for loading states
- NEVER use `h-screen`; use `h-dvh`
- MUST respect `safe-area-inset` for fixed elements
- MUST show errors at the action point
- NEVER block paste in `input` or `textarea`

## Animation & Performance

- NEVER add animation unless explicitly requested
- MUST animate only compositor props (`transform`, `opacity`)
- NEVER animate layout properties (`width`, `height`, `top`, `left`, `margin`, `padding`)
- SHOULD avoid animating paint properties (`background`, `color`) except for small local UI
- SHOULD use `ease-out` for entrance; NEVER exceed `200ms` for interaction feedback
- MUST pause looping animations when off-screen
- MUST respect `prefers-reduced-motion`
- NEVER introduce custom easing curves unless explicitly requested
- SHOULD avoid animating large images or full-screen surfaces
- NEVER animate large `blur()` or `backdrop-filter` surfaces
- NEVER apply `will-change` outside an active animation
- NEVER use `useEffect` for anything expressible as render logic

## Typography

- MUST use `text-balance` for headings and `text-pretty` for body text
- MUST use `tabular-nums` for data
- SHOULD use `truncate` or `line-clamp` for dense UI
- NEVER modify `letter-spacing` (`tracking-`) unless explicitly requested

## Layout & Design

- MUST use a fixed `z-index` scale (`z-10`, `z-20`) — no arbitrary values (`z-[99]`)
- SHOULD use `size-*` for square elements instead of `w-*` + `h-*`
- NEVER use gradients unless explicitly requested; prefer subtle single-hue gradients when allowed
- NEVER use glow effects as primary affordances
- SHOULD use Tailwind default shadow scale unless explicitly requested
- MUST give empty states one clear next action
- SHOULD limit accent color to one per view
- SHOULD use existing theme or Tailwind color tokens before introducing new ones

## References

- [UI Skills](https://www.ui-skills.com/)
- [Base UI](https://base-ui.com/react/components)
- [React Aria](https://react-spectrum.adobe.com/react-aria/)
- [Radix Primitives](https://www.radix-ui.com/primitives)
- [motion/react](https://motion.dev/)
- [tw-animate-css](https://github.com/Wombosvideo/tw-animate-css)
- [shadcn/ui](https://ui.shadcn.com/) - See `tools/ui/shadcn.md`
