/**
 * Sidebar Context — Panel open/close and width state
 *
 * Manages the physical sidebar panel state with cookie persistence.
 * Follows the pattern from .agents/tools/ui/react-context.md exactly.
 *
 * Implementation task: t005.2
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
import type { SidebarState } from '../types'
import {
  DEFAULT_SIDEBAR_WIDTH,
  MAX_SIDEBAR_WIDTH,
  MIN_SIDEBAR_WIDTH,
  SIDEBAR_COOKIE_MAX_AGE,
  SIDEBAR_STATE_COOKIE,
  SIDEBAR_WIDTH_COOKIE,
  CSS_VARS,
} from '../constants'

// ============================================
// Context Interface
// ============================================

interface SidebarContextProps {
  open: boolean
  setOpen: (open: boolean) => void
  toggleSidebar: () => void
  width: number
  setWidth: (width: number) => void
}

// ============================================
// Context
// ============================================

const SidebarContext = createContext<SidebarContextProps | null>(null)

// ============================================
// Hooks
// ============================================

/**
 * Access sidebar state. Returns safe defaults when used outside provider.
 */
export function useSidebar(): SidebarContextProps {
  const context = useContext(SidebarContext)
  if (!context) {
    return {
      open: false,
      setOpen: () => {},
      toggleSidebar: () => {},
      width: DEFAULT_SIDEBAR_WIDTH,
      setWidth: () => {},
    }
  }
  return context
}

/**
 * Access sidebar state, returning null when outside provider.
 * Use for conditional rendering (e.g., ToggleButton that hides when no provider).
 */
export function useSidebarOptional(): SidebarContextProps | null {
  return useContext(SidebarContext)
}

// ============================================
// Cookie Helpers
// ============================================

function setCookie(name: string, value: string, maxAge: number): void {
  document.cookie = `${name}=${value}; path=/; max-age=${maxAge}`
}

function getCookie(name: string): string | null {
  const match = document.cookie.match(new RegExp(`(?:^|; )${name}=([^;]*)`))
  return match ? decodeURIComponent(match[1]) : null
}

// ============================================
// Provider
// ============================================

interface SidebarProviderProps {
  readonly children: ReactNode
  readonly defaultOpen?: boolean
  readonly defaultWidth?: number
}

export function SidebarProvider({
  children,
  defaultOpen = false,
  defaultWidth = DEFAULT_SIDEBAR_WIDTH,
}: SidebarProviderProps) {
  const [open, setOpenState] = useState(defaultOpen)
  const [width, setWidthState] = useState(defaultWidth)

  const setOpen = useCallback((value: boolean) => {
    setOpenState(value)
    setCookie(SIDEBAR_STATE_COOKIE, String(value), SIDEBAR_COOKIE_MAX_AGE)
  }, [])

  const toggleSidebar = useCallback(() => {
    setOpenState((prev) => {
      const newValue = !prev
      setCookie(SIDEBAR_STATE_COOKIE, String(newValue), SIDEBAR_COOKIE_MAX_AGE)
      return newValue
    })
  }, [])

  const setWidth = useCallback((value: number) => {
    const clamped = Math.min(Math.max(value, MIN_SIDEBAR_WIDTH), MAX_SIDEBAR_WIDTH)
    setWidthState(clamped)
    setCookie(SIDEBAR_WIDTH_COOKIE, String(clamped), SIDEBAR_COOKIE_MAX_AGE)
  }, [])

  const contextValue = useMemo(
    () => ({ open, setOpen, toggleSidebar, width, setWidth }),
    [open, setOpen, toggleSidebar, width, setWidth],
  )

  return (
    <SidebarContext.Provider value={contextValue}>
      <style>{`:root { ${CSS_VARS.sidebarWidth}: ${width}px; }`}</style>
      {children}
    </SidebarContext.Provider>
  )
}
