/**
 * AI Chat Sidebar — Shared Type Definitions
 *
 * Central type system for the chat sidebar feature.
 * Used by contexts, components, hooks, and the API layer.
 *
 * @see .agents/tools/ui/ai-chat-sidebar.md for architecture docs
 */

// ============================================
// Message Types
// ============================================

export type MessageRole = 'user' | 'assistant' | 'system'

export type MessageStatus = 'pending' | 'streaming' | 'complete' | 'error'

export interface ChatMessage {
  /** Unique message identifier (nanoid or crypto.randomUUID) */
  id: string
  /** Who sent this message */
  role: MessageRole
  /** Message content (plain text for user, markdown for assistant) */
  content: string
  /** Current lifecycle status */
  status: MessageStatus
  /** Unix timestamp (ms) when message was created */
  timestamp: number
  /** Model that generated this response (assistant messages only) */
  model?: string
  /** Token count for the response (assistant messages only) */
  tokenCount?: number
  /** Error details if status === 'error' */
  error?: string
}

// ============================================
// Conversation Types
// ============================================

export interface Conversation {
  /** Unique conversation identifier */
  id: string
  /** Display title (auto-generated from first message or user-set) */
  title: string
  /** Ordered list of messages in this conversation */
  messages: ChatMessage[]
  /** Unix timestamp (ms) when conversation was created */
  createdAt: number
  /** Unix timestamp (ms) of last activity */
  updatedAt: number
  /** Default model tier for this conversation */
  model: string
  /** Context sources injected into this conversation */
  contextSources: ContextSource[]
}

export interface ContextSource {
  /** Type of context to resolve */
  type: 'file' | 'directory' | 'memory' | 'agent' | 'custom'
  /** Path or identifier for the source */
  path: string
  /** Human-readable label for display */
  label: string
  /** Whether this source is currently active */
  enabled: boolean
}

// ============================================
// Sidebar State Types
// ============================================

export type SidebarPosition = 'right' | 'left'

export interface SidebarState {
  /** Whether the sidebar panel is open */
  open: boolean
  /** Current width in pixels */
  width: number
  /** Which side of the viewport */
  position: SidebarPosition
}

// ============================================
// Chat State Types
// ============================================

export interface ChatState {
  /** All conversations */
  conversations: Conversation[]
  /** Currently active conversation ID */
  activeConversationId: string | null
  /** Whether a response is currently streaming */
  isStreaming: boolean
  /** Partial content accumulated during streaming */
  streamingContent: string
}

// ============================================
// Settings Types
// ============================================

/** Model tier identifiers matching aidevops model routing */
export type ModelTier = 'haiku' | 'flash' | 'sonnet' | 'pro' | 'opus'

export interface SettingsState {
  /** Default model tier for new conversations */
  defaultModel: ModelTier
  /** Default context sources for new conversations */
  contextSources: ContextSource[]
  /** Maximum tokens for AI responses */
  maxTokens: number
  /** Temperature for AI responses (0-1) */
  temperature: number
}

// ============================================
// API Types
// ============================================

/** Request body for POST /api/chat/send and /api/chat/stream */
export interface ChatRequest {
  /** Conversation ID (creates new if not found) */
  conversationId: string
  /** The user's message content */
  message: string
  /** Model tier to use for this request */
  model: ModelTier
  /** Context sources to resolve and inject */
  contextSources: ContextSource[]
  /** Max tokens for the response */
  maxTokens: number
  /** Temperature (0-1) */
  temperature: number
}

/** Response body for POST /api/chat/send (non-streaming) */
export interface ChatResponse {
  /** The assistant's response content */
  content: string
  /** Concrete model used (e.g., 'claude-sonnet-4-20250514') */
  model: string
  /** Token count for the response */
  tokenCount: number
  /** Conversation ID */
  conversationId: string
}

/** SSE event types for POST /api/chat/stream */
export type StreamEventType = 'start' | 'delta' | 'done' | 'error'

export interface StreamStartEvent {
  type: 'start'
  conversationId: string
  model: string
}

export interface StreamDeltaEvent {
  type: 'delta'
  content: string
}

export interface StreamDoneEvent {
  type: 'done'
  tokenCount: number
  model: string
}

export interface StreamErrorEvent {
  type: 'error'
  message: string
  code: string
}

export type StreamEvent =
  | StreamStartEvent
  | StreamDeltaEvent
  | StreamDoneEvent
  | StreamErrorEvent

/** Response for GET /api/chat/models */
export interface ModelInfo {
  /** Model tier identifier */
  tier: ModelTier
  /** Human-readable name */
  name: string
  /** Whether this model is currently available */
  available: boolean
  /** Concrete model ID if resolved */
  modelId?: string
}

/** Response for POST /api/chat/context */
export interface ResolvedContext {
  /** The source that was resolved */
  source: ContextSource
  /** Resolved content (truncated if too large) */
  content: string
  /** Token estimate for this content */
  tokenEstimate: number
  /** Whether content was truncated */
  truncated: boolean
}

// ============================================
// Hook Return Types
// ============================================

export interface UseChatReturn {
  /** All conversations */
  conversations: Conversation[]
  /** Currently active conversation (derived) */
  activeConversation: Conversation | null
  /** Whether a response is currently streaming */
  isStreaming: boolean
  /** Partial content during streaming */
  streamingContent: string
  /** Send a message in the active conversation */
  sendMessage: (content: string) => Promise<void>
  /** Abort the current streaming response */
  stopStreaming: () => void
  /** Create a new empty conversation */
  newConversation: () => void
  /** Switch to a different conversation */
  switchConversation: (id: string) => void
  /** Delete a conversation */
  deleteConversation: (id: string) => void
}

export interface UseStreamingReturn {
  /** Whether currently streaming */
  isStreaming: boolean
  /** Accumulated content from the stream */
  content: string
  /** Start a new stream */
  startStream: (request: ChatRequest) => void
  /** Abort the current stream */
  stopStream: () => void
  /** Error from the stream (if any) */
  error: string | null
  /** Model info from the stream start event */
  model: string | null
  /** Token count from the stream done event */
  tokenCount: number | null
}

export interface UseResizeReturn {
  /** Current width */
  width: number
  /** Whether currently dragging */
  isDragging: boolean
  /** Props to spread on the resize handle element */
  handleProps: {
    onPointerDown: (e: PointerEvent) => void
    style: Record<string, string>
  }
}
