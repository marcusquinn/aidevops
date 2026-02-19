/**
 * AI Chat Sidebar — Entry Point
 *
 * Composes providers and renders the root sidebar component.
 * Provider nesting order: outer = least frequent updates.
 *
 * Usage:
 *   import { AIChatSidebar } from '.opencode/ui/chat-sidebar'
 *   <AIChatSidebar defaultOpen={false} defaultModel="sonnet" />
 *
 * @see .agents/tools/ui/ai-chat-sidebar.md for architecture docs
 */

'use client'

import type { ModelTier } from './types'
import { SettingsProvider } from './context/settings-context'
import { SidebarProvider } from './context/sidebar-context'
import { ChatProvider } from './context/chat-context'
import { DEFAULT_SIDEBAR_WIDTH } from './constants'

// ============================================
// Root Component
// ============================================

interface AIChatSidebarProps {
  /** Initial open state (can be read from cookie on server) */
  readonly defaultOpen?: boolean
  /** Initial sidebar width in pixels */
  readonly defaultWidth?: number
  /** Default model tier for new conversations */
  readonly defaultModel?: ModelTier
}

/**
 * Root AI Chat Sidebar component.
 * Wraps all providers and renders the sidebar UI.
 *
 * Implementation of ChatSidebar component is in t005.2.
 * This file provides the provider composition scaffold.
 */
export function AIChatSidebar({
  defaultOpen = false,
  defaultWidth = DEFAULT_SIDEBAR_WIDTH,
  defaultModel = 'sonnet',
}: AIChatSidebarProps) {
  return (
    <SettingsProvider defaultModel={defaultModel}>
      <SidebarProvider defaultOpen={defaultOpen} defaultWidth={defaultWidth}>
        <ChatProvider>
          {/* ChatSidebar component — implemented in t005.2 */}
          <div data-testid="ai-chat-sidebar-root">
            {/* Placeholder: replace with <ChatSidebar /> in t005.2 */}
          </div>
        </ChatProvider>
      </SidebarProvider>
    </SettingsProvider>
  )
}

// ============================================
// Re-exports for consumer convenience
// ============================================

export type { ModelTier, ChatMessage, Conversation, ContextSource } from './types'
export { useSidebar, useSidebarOptional } from './context/sidebar-context'
export { useChat } from './context/chat-context'
export { useSettings } from './context/settings-context'
