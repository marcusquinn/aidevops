---
description: AI chat sidebar component architecture — design, state management, and integration patterns
mode: subagent
tools:
  read: true
  write: true
  edit: true
  bash: true
  glob: true
  grep: true
  task: true
---

# AI Chat Sidebar — Component Architecture

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Purpose**: Collapsible AI chat panel integrated into the aidevops dashboard
- **Stack**: React 19 + TypeScript + Tailwind CSS + Elysia (API)
- **State**: React Context with cookie persistence (matches existing sidebar patterns)
- **Streaming**: Server-Sent Events (SSE) from Elysia backend
- **Source**: `.opencode/ui/chat-sidebar/`

**Sibling tasks**:

| Task | Scope | Depends on |
|------|-------|------------|
| t005.1 | Architecture & types (this doc) | — |
| t005.2 | Collapsible panel, resize, toggle | t005.1 |
| t005.3 | Chat message UI, streaming, markdown | t005.1, t005.2 |
| t005.4 | AI backend integration, context, API routing | t005.1 |

<!-- AI-CONTEXT-END -->

## Architecture Overview

```text
┌─────────────────────────────────────────────────────────┐
│  Dashboard Layout (Elysia serves SPA)                   │
│  ┌──────────────────────┐  ┌──────────────────────────┐ │
│  │  Main Content Area   │  │  AI Chat Sidebar         │ │
│  │                      │  │  ┌────────────────────┐  │ │
│  │  (MCP Dashboard,     │  │  │ Header + Controls  │  │ │
│  │   Quality Metrics,   │  │  ├────────────────────┤  │ │
│  │   etc.)              │  │  │ Message List        │  │ │
│  │                      │  │  │  ├─ UserMessage     │  │ │
│  │                      │  │  │  ├─ AssistantMsg    │  │ │
│  │                      │  │  │  └─ StreamingMsg    │  │ │
│  │                      │  │  ├────────────────────┤  │ │
│  │                      │  │  │ Input Area         │  │ │
│  │                      │  │  │  ├─ TextArea       │  │ │
│  │                      │  │  │  └─ Send Button    │  │ │
│  │                      │  │  └────────────────────┘  │ │
│  └──────────────────────┘  └──────────────────────────┘ │
│  [Toggle Button - fixed position when sidebar closed]   │
└─────────────────────────────────────────────────────────┘
```

## Design Decisions

### 1. React for the sidebar, vanilla for existing dashboard

**Decision**: Introduce React only for the chat sidebar, not rewrite the existing dashboard.

**Rationale**: The existing MCP dashboard (`.opencode/server/mcp-dashboard.ts`) uses inline HTML with vanilla JS and works well for its purpose (status cards, start/stop buttons). The chat sidebar requires complex interactive state (streaming messages, resize handles, conversation history, markdown rendering) that vanilla JS handles poorly. React is scoped to the sidebar mount point only.

**Integration**: Elysia serves a new route (`/chat`) with a React SPA, or the sidebar is injected as a Web Component / iframe into the existing dashboard. The cleanest approach is a standalone React app served by Elysia at `/chat` that can also be embedded.

### 2. React Context for state (not Redux/Zustand)

**Decision**: Use React Context with the pattern from `tools/ui/react-context.md`.

**Rationale**: The sidebar has 3 concerns — panel state (open/width), conversation state (messages/streaming), and settings (model, context). These map cleanly to 3 split contexts (per the performance guidance in react-context.md). The app is small enough that Context avoids unnecessary dependencies. Cookie persistence for panel state matches the existing pattern.

### 3. SSE for streaming (not WebSocket)

**Decision**: Use Server-Sent Events for AI response streaming.

**Rationale**: The chat is unidirectional streaming (server → client for AI responses). SSE is simpler than WebSocket for this use case, works through proxies/CDNs, and auto-reconnects. User messages are sent via POST. The existing dashboard already uses WebSocket for real-time MCP status updates — SSE avoids conflating the two concerns.

### 4. Elysia API routes for backend

**Decision**: Add chat API routes to the existing Elysia server (or a new Elysia instance on a separate port).

**Rationale**: Elysia already handles the API gateway and MCP dashboard. Adding `/api/chat/*` routes keeps the backend unified. The chat backend proxies to the configured AI provider (Anthropic, OpenRouter, etc.) using the existing credential system.

## File Structure

```text
.opencode/ui/chat-sidebar/
├── types.ts              # Shared type definitions (t005.1)
├── constants.ts          # Configuration constants (t005.1)
├── context/
│   ├── sidebar-context.tsx    # Panel open/close/width state (t005.2)
│   ├── chat-context.tsx       # Conversation state + streaming (t005.3)
│   └── settings-context.tsx   # Model selection, context config (t005.4)
├── components/
│   ├── ChatSidebar.tsx        # Root sidebar component (t005.2)
│   ├── ChatHeader.tsx         # Title, model selector, close button (t005.2)
│   ├── MessageList.tsx        # Scrollable message container (t005.3)
│   ├── ChatMessage.tsx        # Individual message (user/assistant) (t005.3)
│   ├── StreamingMessage.tsx   # In-progress streaming response (t005.3)
│   ├── ChatInput.tsx          # Text input + send button (t005.3)
│   ├── ResizeHandle.tsx       # Drag-to-resize sidebar width (t005.2)
│   └── ToggleButton.tsx       # Floating button when sidebar closed (t005.2)
├── hooks/
│   ├── use-chat.ts            # Chat operations hook (t005.3/t005.4)
│   ├── use-streaming.ts       # SSE streaming hook (t005.3)
│   └── use-resize.ts          # Resize drag handler (t005.2)
├── lib/
│   ├── api-client.ts          # Chat API client (t005.4)
│   ├── markdown.ts            # Markdown rendering utilities (t005.3)
│   └── storage.ts             # Cookie/localStorage persistence (t005.2)
└── index.tsx                  # Entry point, provider composition (t005.2)

.opencode/server/
├── chat-api.ts                # Elysia chat API routes (t005.4)
└── (existing files unchanged)
```

## Type Definitions

See `.opencode/ui/chat-sidebar/types.ts` for the complete type system. Key types:

### Message Types

```typescript
type MessageRole = 'user' | 'assistant' | 'system'
type MessageStatus = 'pending' | 'streaming' | 'complete' | 'error'

interface ChatMessage {
  id: string
  role: MessageRole
  content: string
  status: MessageStatus
  timestamp: number
  model?: string           // Which model responded
  tokenCount?: number      // Response token count
  error?: string           // Error message if status === 'error'
}
```

### Conversation Types

```typescript
interface Conversation {
  id: string
  title: string
  messages: ChatMessage[]
  createdAt: number
  updatedAt: number
  model: string            // Default model for this conversation
  contextSources: ContextSource[]  // What context is injected
}

interface ContextSource {
  type: 'file' | 'directory' | 'memory' | 'agent' | 'custom'
  path: string
  label: string
  enabled: boolean
}
```

### Sidebar State Types

```typescript
interface SidebarState {
  open: boolean
  width: number            // Current width in pixels
  position: 'right' | 'left'
}

interface ChatState {
  conversations: Conversation[]
  activeConversationId: string | null
  isStreaming: boolean
  streamingContent: string  // Partial content during streaming
}

interface SettingsState {
  defaultModel: string     // e.g., 'sonnet', 'opus', 'haiku'
  contextSources: ContextSource[]
  maxTokens: number
  temperature: number
}
```

## State Management

### Three Split Contexts

Following the performance pattern from `tools/ui/react-context.md` — split by update frequency:

| Context | Update Frequency | Persistence | Scope |
|---------|-----------------|-------------|-------|
| `SidebarContext` | On user interaction (toggle/resize) | Cookie (7 days) | Panel open/close, width |
| `ChatContext` | On every message/stream chunk | localStorage (conversations) | Messages, streaming state |
| `SettingsContext` | Rarely (user preference changes) | Cookie (30 days) | Model, temperature, context |

### Provider Composition

```tsx
// index.tsx — provider nesting order (outer = least frequent updates)
<SettingsProvider defaultModel="sonnet">
  <SidebarProvider defaultOpen={false} defaultWidth={420}>
    <ChatProvider>
      <ChatSidebar />
    </ChatProvider>
  </SidebarProvider>
</SettingsProvider>
```

### SidebarContext Pattern

```tsx
// Follows react-context.md pattern exactly
const SIDEBAR_COOKIE = 'ai_chat_sidebar_state'
const WIDTH_COOKIE = 'ai_chat_sidebar_width'
const DEFAULT_WIDTH = 420
const MIN_WIDTH = 320
const MAX_WIDTH = 640

interface SidebarContextProps {
  open: boolean
  setOpen: (open: boolean) => void
  toggleSidebar: () => void
  width: number
  setWidth: (width: number) => void
}

// Hook with safe fallback for usage outside provider
function useSidebar(): SidebarContextProps {
  const context = useContext(SidebarContext)
  if (!context) {
    return {
      open: false,
      setOpen: () => {},
      toggleSidebar: () => {},
      width: DEFAULT_WIDTH,
      setWidth: () => {},
    }
  }
  return context
}
```

### ChatContext — Streaming Integration

```tsx
interface ChatContextProps {
  conversations: Conversation[]
  activeConversation: Conversation | null
  isStreaming: boolean
  streamingContent: string
  sendMessage: (content: string) => Promise<void>
  stopStreaming: () => void
  newConversation: () => void
  switchConversation: (id: string) => void
  deleteConversation: (id: string) => void
}
```

The `sendMessage` flow:

1. Add user message to active conversation (optimistic)
2. Create assistant message with `status: 'streaming'`
3. Open SSE connection to `/api/chat/stream`
4. Accumulate `streamingContent` on each SSE event
5. On stream end, finalize message with `status: 'complete'`
6. Persist conversation to localStorage

## API Design

### Elysia Chat Routes (`chat-api.ts`)

```text
POST /api/chat/send          — Send message, get full response (non-streaming)
POST /api/chat/stream        — Send message, get SSE stream
GET  /api/chat/conversations — List conversations (from server-side storage)
GET  /api/chat/models        — List available models + their status
POST /api/chat/context       — Resolve context sources to content
```

### SSE Stream Format

```text
event: start
data: {"conversationId": "abc", "model": "claude-sonnet-4-20250514"}

event: delta
data: {"content": "Here is"}

event: delta
data: {"content": " the answer"}

event: done
data: {"tokenCount": 150, "model": "claude-sonnet-4-20250514"}

event: error
data: {"message": "Rate limit exceeded", "code": "rate_limited"}
```

### Context Injection

The chat API resolves `ContextSource[]` before sending to the AI provider:

| Source Type | Resolution |
|-------------|-----------|
| `file` | Read file content (with line range support) |
| `directory` | List files + read key files |
| `memory` | Query memory-helper.sh for relevant memories |
| `agent` | Read agent markdown file |
| `custom` | User-provided text |

Context is prepended as a system message, keeping the conversation messages clean.

## Component Specifications

### ChatSidebar (root)

- Renders as a fixed-position panel on the right edge
- Uses CSS `transform: translateX()` for open/close animation (compositor-only per ui-skills.md)
- Width controlled by CSS variable `--ai-sidebar-width`
- Keyboard shortcut: `Cmd+Shift+L` to toggle (matches common IDE patterns)

### ResizeHandle

- Vertical drag handle on the left edge of the sidebar
- Uses `pointer-events` and `user-select: none` during drag
- Clamps width between `MIN_WIDTH` (320px) and `MAX_WIDTH` (640px)
- Persists final width to cookie on `pointerup`

### MessageList

- Virtualized scrolling for long conversations (use native `overflow-y: auto` initially, upgrade to virtual list if performance requires)
- Auto-scrolls to bottom on new messages
- Preserves scroll position when user scrolls up (reading history)
- Shows date separators between messages from different days

### ChatMessage

- User messages: right-aligned, accent background
- Assistant messages: left-aligned, neutral background
- Markdown rendering for assistant messages (code blocks with syntax highlighting)
- Copy button on code blocks
- Token count display (subtle, bottom-right)

### StreamingMessage

- Extends ChatMessage with a blinking cursor indicator
- Content updates on each SSE delta event
- "Stop generating" button appears during streaming

### ChatInput

- Auto-expanding textarea (grows with content, max 6 lines)
- Send on `Enter`, newline on `Shift+Enter`
- Disabled during streaming
- Character count indicator (subtle)
- File attachment button (future — not in initial scope)

### ToggleButton

- Fixed position, bottom-right corner
- Only visible when sidebar is closed
- Uses `useSidebarOptional()` — renders nothing if no provider (per react-context.md pattern)
- Accessible: `aria-label="Open AI chat"`

## Accessibility

Per `tools/ui/ui-skills.md` requirements:

- All interactive elements have `aria-label` or visible label
- Keyboard navigation: Tab through controls, Escape to close sidebar
- Focus trap when sidebar is open (optional — depends on whether it overlays content)
- `prefers-reduced-motion`: disable slide animation, use instant show/hide
- Screen reader announcements for new messages (`aria-live="polite"`)
- No `h-screen` — use `h-dvh` for mobile viewport

## Performance Considerations

- **Context splitting**: Three contexts prevent unnecessary re-renders (sidebar resize doesn't re-render messages)
- **Memoization**: `useCallback` for all setters, `useMemo` for derived state
- **Streaming**: SSE chunks update a single `streamingContent` string, not the full message array
- **Markdown**: Lazy-load markdown renderer (only when assistant messages exist)
- **No `will-change`** unless actively animating (per ui-skills.md)
- **No `useEffect` for render logic** (per ui-skills.md)

## Dependencies

New dependencies required (to be added to `package.json`):

| Package | Purpose | Size |
|---------|---------|------|
| `react` | UI framework | ~45KB gzipped |
| `react-dom` | DOM rendering | ~40KB gzipped |
| `@types/react` | TypeScript types | dev only |
| `@types/react-dom` | TypeScript types | dev only |

Optional (evaluate during implementation):

| Package | Purpose | Alternative |
|---------|---------|------------|
| `marked` or `markdown-it` | Markdown rendering | Custom minimal parser |
| `highlight.js` or `shiki` | Code syntax highlighting | CSS-only basic highlighting |

**No additional state management libraries needed** — React Context is sufficient.

## Integration with Existing Systems

### Credential Routing

The chat API uses the existing aidevops credential system:

```typescript
// chat-api.ts
const apiKey = await getCredential('ANTHROPIC_API_KEY')
// Falls back to: gopass → credentials.sh → environment variable
```

### Model Routing

Integrates with the existing model routing system:

```typescript
// Resolve model tier to concrete model
const model = await resolveModel(settings.defaultModel)
// 'sonnet' → 'claude-sonnet-4-20250514' (with fallback chain)
```

### Memory Integration

Chat can query cross-session memory for context:

```typescript
// Resolve memory context source
const memories = await execCommand('memory-helper.sh', ['recall', query, '--limit', '5'])
```

## Testing Strategy

| Layer | Tool | What to test |
|-------|------|-------------|
| Types | `tsc --noEmit` | Type correctness |
| Components | Bun test + React Testing Library | Render, interaction, accessibility |
| Hooks | Bun test | State transitions, streaming lifecycle |
| API | Bun test + Elysia test client | Route responses, SSE format, error handling |
| E2E | Playwright | Full sidebar flow (open, send, receive, close) |

## Migration Path

This architecture supports incremental delivery across t005.2-t005.4:

1. **t005.2**: SidebarContext + ChatSidebar + ResizeHandle + ToggleButton (panel works, no chat)
2. **t005.3**: ChatContext + MessageList + ChatMessage + StreamingMessage + ChatInput (chat works with mock data)
3. **t005.4**: SettingsContext + chat-api.ts + api-client.ts (real AI responses)

Each task produces a working increment that can be reviewed independently.
