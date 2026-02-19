/**
 * AI Chat Sidebar — Configuration Constants
 *
 * Centralized constants for the chat sidebar feature.
 * Adjust these to change default behavior without modifying component logic.
 *
 * @see .agents/tools/ui/ai-chat-sidebar.md for architecture docs
 */

import type { ModelTier, SidebarPosition } from './types'

// ============================================
// Sidebar Panel
// ============================================

/** Default sidebar width in pixels */
export const DEFAULT_SIDEBAR_WIDTH = 420

/** Minimum sidebar width (resize clamp) */
export const MIN_SIDEBAR_WIDTH = 320

/** Maximum sidebar width (resize clamp) */
export const MAX_SIDEBAR_WIDTH = 640

/** Default sidebar position */
export const DEFAULT_SIDEBAR_POSITION: SidebarPosition = 'right'

/** Cookie name for sidebar open/close state */
export const SIDEBAR_STATE_COOKIE = 'ai_chat_sidebar_state'

/** Cookie name for sidebar width */
export const SIDEBAR_WIDTH_COOKIE = 'ai_chat_sidebar_width'

/** Cookie max age: 7 days (seconds) */
export const SIDEBAR_COOKIE_MAX_AGE = 60 * 60 * 24 * 7

// ============================================
// Chat
// ============================================

/** localStorage key for conversation data */
export const CONVERSATIONS_STORAGE_KEY = 'ai_chat_conversations'

/** Maximum conversations to keep in storage */
export const MAX_STORED_CONVERSATIONS = 50

/** Maximum messages per conversation before truncation */
export const MAX_MESSAGES_PER_CONVERSATION = 200

/** Default title for new conversations */
export const DEFAULT_CONVERSATION_TITLE = 'New conversation'

// ============================================
// Settings
// ============================================

/** Default model tier for new conversations */
export const DEFAULT_MODEL: ModelTier = 'sonnet'

/** Default max tokens for AI responses */
export const DEFAULT_MAX_TOKENS = 4096

/** Default temperature for AI responses */
export const DEFAULT_TEMPERATURE = 0.7

/** Cookie name for settings */
export const SETTINGS_COOKIE = 'ai_chat_settings'

/** Settings cookie max age: 30 days (seconds) */
export const SETTINGS_COOKIE_MAX_AGE = 60 * 60 * 24 * 30

// ============================================
// Input
// ============================================

/** Maximum lines before textarea stops growing */
export const INPUT_MAX_LINES = 6

/** Maximum character count for a single message */
export const INPUT_MAX_CHARS = 32_000

// ============================================
// Streaming
// ============================================

/** SSE reconnect delay in milliseconds */
export const SSE_RECONNECT_DELAY = 3000

/** SSE connection timeout in milliseconds */
export const SSE_TIMEOUT = 120_000

// ============================================
// API
// ============================================

/** Base path for chat API routes */
export const CHAT_API_BASE = '/api/chat'

/** Chat API endpoints */
export const CHAT_API = {
  send: `${CHAT_API_BASE}/send`,
  stream: `${CHAT_API_BASE}/stream`,
  conversations: `${CHAT_API_BASE}/conversations`,
  models: `${CHAT_API_BASE}/models`,
  context: `${CHAT_API_BASE}/context`,
} as const

// ============================================
// Keyboard Shortcuts
// ============================================

/** Toggle sidebar shortcut */
export const TOGGLE_SHORTCUT = {
  key: 'l',
  metaKey: true,
  shiftKey: true,
  label: '⌘⇧L',
} as const

/** Send message shortcut (Enter without Shift) */
export const SEND_SHORTCUT = {
  key: 'Enter',
  shiftKey: false,
  label: 'Enter',
} as const

/** New line shortcut (Shift+Enter) */
export const NEWLINE_SHORTCUT = {
  key: 'Enter',
  shiftKey: true,
  label: '⇧Enter',
} as const

// ============================================
// Accessibility
// ============================================

/** ARIA labels */
export const ARIA = {
  sidebar: 'AI chat sidebar',
  toggleButton: 'Open AI chat',
  closeButton: 'Close AI chat',
  sendButton: 'Send message',
  stopButton: 'Stop generating',
  messageList: 'Chat messages',
  input: 'Type a message',
  resizeHandle: 'Resize chat sidebar',
  newChat: 'Start new conversation',
} as const

// ============================================
// CSS Custom Properties
// ============================================

/** CSS variable names used by the sidebar */
export const CSS_VARS = {
  sidebarWidth: '--ai-sidebar-width',
  sidebarTransition: '--ai-sidebar-transition',
} as const

// ============================================
// Model Display Names
// ============================================

/** Human-readable names for model tiers */
export const MODEL_DISPLAY_NAMES: Record<ModelTier, string> = {
  haiku: 'Haiku (fast)',
  flash: 'Flash (balanced)',
  sonnet: 'Sonnet (default)',
  pro: 'Pro (advanced)',
  opus: 'Opus (best)',
}
