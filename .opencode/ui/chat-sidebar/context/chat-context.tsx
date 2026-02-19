/**
 * Chat Context — Conversation state and streaming
 *
 * Manages conversations, messages, and streaming state.
 * Persists conversations to localStorage.
 *
 * Implementation task: t005.3
 * @see .agents/tools/ui/ai-chat-sidebar.md
 */

'use client'

import {
  createContext,
  useCallback,
  useContext,
  useMemo,
  useState,
} from 'react'
import type { ReactNode } from 'react'
import type {
  ChatState,
  Conversation,
  UseChatReturn,
} from '../types'
import {
  CONVERSATIONS_STORAGE_KEY,
  DEFAULT_CONVERSATION_TITLE,
  DEFAULT_MODEL,
  MAX_STORED_CONVERSATIONS,
} from '../constants'

// ============================================
// Context
// ============================================

const ChatContext = createContext<UseChatReturn | null>(null)

// ============================================
// Hooks
// ============================================

/**
 * Access chat state and operations.
 * Returns safe no-op defaults when used outside provider.
 */
export function useChat(): UseChatReturn {
  const context = useContext(ChatContext)
  if (!context) {
    return {
      conversations: [],
      activeConversation: null,
      isStreaming: false,
      streamingContent: '',
      sendMessage: async () => {},
      stopStreaming: () => {},
      newConversation: () => {},
      switchConversation: () => {},
      deleteConversation: () => {},
    }
  }
  return context
}

// ============================================
// Storage Helpers
// ============================================

function loadConversations(): Conversation[] {
  try {
    const stored = localStorage.getItem(CONVERSATIONS_STORAGE_KEY)
    if (!stored) return []
    return JSON.parse(stored) as Conversation[]
  } catch {
    return []
  }
}

function saveConversations(conversations: Conversation[]): void {
  try {
    // Keep only the most recent conversations
    const trimmed = conversations.slice(0, MAX_STORED_CONVERSATIONS)
    localStorage.setItem(CONVERSATIONS_STORAGE_KEY, JSON.stringify(trimmed))
  } catch {
    // localStorage may be full or unavailable — fail silently
  }
}

function generateId(): string {
  return crypto.randomUUID()
}

// ============================================
// Provider
// ============================================

interface ChatProviderProps {
  readonly children: ReactNode
}

export function ChatProvider({ children }: ChatProviderProps) {
  const [conversations, setConversations] = useState<Conversation[]>(loadConversations)
  const [activeConversationId, setActiveConversationId] = useState<string | null>(
    () => conversations[0]?.id ?? null,
  )
  const [isStreaming, setIsStreaming] = useState(false)
  const [streamingContent, setStreamingContent] = useState('')

  // Derived state
  const activeConversation = useMemo(
    () => conversations.find((c) => c.id === activeConversationId) ?? null,
    [conversations, activeConversationId],
  )

  const newConversation = useCallback(() => {
    const conversation: Conversation = {
      id: generateId(),
      title: DEFAULT_CONVERSATION_TITLE,
      messages: [],
      createdAt: Date.now(),
      updatedAt: Date.now(),
      model: DEFAULT_MODEL,
      contextSources: [],
    }
    setConversations((prev) => {
      const updated = [conversation, ...prev]
      saveConversations(updated)
      return updated
    })
    setActiveConversationId(conversation.id)
  }, [])

  const switchConversation = useCallback((id: string) => {
    setActiveConversationId(id)
  }, [])

  const deleteConversation = useCallback((id: string) => {
    setConversations((prev) => {
      const updated = prev.filter((c) => c.id !== id)
      saveConversations(updated)
      return updated
    })
    setActiveConversationId((prevId) => (prevId === id ? null : prevId))
  }, [])

  const sendMessage = useCallback(async (content: string) => {
    // Stub — full implementation in t005.3 with streaming hook
    // This will:
    // 1. Add user message to active conversation
    // 2. Create assistant message with status: 'streaming'
    // 3. Open SSE connection
    // 4. Accumulate streamingContent
    // 5. Finalize on stream end
    void content
  }, [])

  const stopStreaming = useCallback(() => {
    // Stub — full implementation in t005.3
    setIsStreaming(false)
    setStreamingContent('')
  }, [])

  const contextValue = useMemo<UseChatReturn>(
    () => ({
      conversations,
      activeConversation,
      isStreaming,
      streamingContent,
      sendMessage,
      stopStreaming,
      newConversation,
      switchConversation,
      deleteConversation,
    }),
    [
      conversations,
      activeConversation,
      isStreaming,
      streamingContent,
      sendMessage,
      stopStreaming,
      newConversation,
      switchConversation,
      deleteConversation,
    ],
  )

  return (
    <ChatContext.Provider value={contextValue}>
      {children}
    </ChatContext.Provider>
  )
}
