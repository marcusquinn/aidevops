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
- MUST use `cn` (`clsx` + `tailwind-merge`) for class logic
- MUST use `motion/react` (formerly `framer-motion`) for JS animation; SHOULD use `tw-animate-css` for entrance/micro-animations
- MUST use accessible component primitives (`Base UI`, `React Aria`, `Radix`) — NEVER rebuild keyboard/focus behavior by hand
- MUST use the project's existing component primitives first; NEVER mix primitive systems on the same surface
- SHOULD prefer [`Base UI`](https://base-ui.com/react/components) for new primitives if compatible
- MUST add `aria-label` to icon-only buttons

## Interaction

- MUST use `AlertDialog` for destructive or irreversible actions
- MUST show errors at the action point; NEVER block paste in `input` or `textarea`
- MUST respect `safe-area-inset` for fixed elements
- NEVER use `h-screen`; use `h-dvh`
- SHOULD use structural skeletons for loading states

## Animation & Performance

- NEVER add animation unless explicitly requested; MUST respect `prefers-reduced-motion`
- MUST animate only compositor props (`transform`, `opacity`); NEVER animate layout props (`width`, `height`, `top`, `left`, `margin`, `padding`)
- SHOULD avoid animating paint properties (`background`, `color`) except for small local UI
- SHOULD use `ease-out` for entrance; NEVER exceed `200ms` for interaction feedback
- NEVER introduce custom easing curves unless explicitly requested
- SHOULD avoid animating large images or full-screen surfaces; NEVER animate large `blur()`/`backdrop-filter` surfaces
- NEVER apply `will-change` outside an active animation
- MUST pause looping animations when off-screen
- NEVER use `useEffect` for anything expressible as render logic

## Typography

- MUST use `text-balance` for headings and `text-pretty` for body text
- MUST use `tabular-nums` for data; SHOULD use `truncate` or `line-clamp` for dense UI
- NEVER modify `letter-spacing` (`tracking-`) unless explicitly requested

## Layout & Design

- MUST use a fixed `z-index` scale (`z-10`, `z-20`) — no arbitrary values (`z-[99]`)
- SHOULD use `size-*` for square elements instead of `w-*` + `h-*`
- MUST give empty states one clear next action; SHOULD limit accent color to one per view
- SHOULD use existing theme or Tailwind color tokens before introducing new ones
- SHOULD use Tailwind default shadow scale unless explicitly requested
- NEVER use gradients unless explicitly requested; prefer subtle single-hue gradients when allowed
- NEVER use glow effects as primary affordances

## Relationship to DESIGN.md

These rules are **implementation constraints** that apply regardless of which DESIGN.md is active. DESIGN.md specifies _what_ the design looks like (colours, typography, components); UI Skills specifies _how_ to build it correctly (accessibility, performance, animation discipline). Both apply simultaneously -- DESIGN.md tokens feed into Tailwind/component props, while UI Skills rules govern the implementation quality.

- `tools/design/design-md.md` -- DESIGN.md format (what to build)
- `tools/design/library/` -- Design examples and style archetypes
- `tools/design/colour-palette.md` -- Palette generation for DESIGN.md

## References

- [UI Skills](https://www.ui-skills.com/) · [Base UI](https://base-ui.com/react/components) · [React Aria](https://react-spectrum.adobe.com/react-aria/) · [Radix Primitives](https://www.radix-ui.com/primitives)
- [motion/react](https://motion.dev/) · [tw-animate-css](https://github.com/Wombosvideo/tw-animate-css) · [shadcn/ui](https://ui.shadcn.com/) — see `tools/ui/shadcn.md`
