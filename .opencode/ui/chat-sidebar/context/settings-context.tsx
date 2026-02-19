/**
 * Settings Context — Model selection and AI configuration
 *
 * Manages user preferences for AI interactions.
 * Persists to cookies (long-lived, rarely changes).
 *
 * Implementation task: t005.4
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
  ContextSource,
  ModelTier,
  SettingsState,
} from '../types'
import {
  DEFAULT_MAX_TOKENS,
  DEFAULT_MODEL,
  DEFAULT_TEMPERATURE,
  SETTINGS_COOKIE,
  SETTINGS_COOKIE_MAX_AGE,
} from '../constants'

// ============================================
// Context Interface
// ============================================

interface SettingsContextProps {
  settings: SettingsState
  setDefaultModel: (model: ModelTier) => void
  setMaxTokens: (tokens: number) => void
  setTemperature: (temp: number) => void
  addContextSource: (source: ContextSource) => void
  removeContextSource: (path: string) => void
  toggleContextSource: (path: string) => void
}

// ============================================
// Context
// ============================================

const SettingsContext = createContext<SettingsContextProps | null>(null)

// ============================================
// Hooks
// ============================================

/**
 * Access settings state and operations.
 * Returns safe defaults when used outside provider.
 */
export function useSettings(): SettingsContextProps {
  const context = useContext(SettingsContext)
  if (!context) {
    return {
      settings: {
        defaultModel: DEFAULT_MODEL,
        contextSources: [],
        maxTokens: DEFAULT_MAX_TOKENS,
        temperature: DEFAULT_TEMPERATURE,
      },
      setDefaultModel: () => {},
      setMaxTokens: () => {},
      setTemperature: () => {},
      addContextSource: () => {},
      removeContextSource: () => {},
      toggleContextSource: () => {},
    }
  }
  return context
}

// ============================================
// Cookie Helpers
// ============================================

function persistSettings(settings: SettingsState): void {
  try {
    const value = encodeURIComponent(JSON.stringify(settings))
    document.cookie = `${SETTINGS_COOKIE}=${value}; path=/; max-age=${SETTINGS_COOKIE_MAX_AGE}`
  } catch {
    // Cookie may be too large — fail silently
  }
}

function loadSettings(): SettingsState | null {
  try {
    const match = document.cookie.match(
      new RegExp(`(?:^|; )${SETTINGS_COOKIE}=([^;]*)`),
    )
    if (!match) return null
    return JSON.parse(decodeURIComponent(match[1])) as SettingsState
  } catch {
    return null
  }
}

// ============================================
// Provider
// ============================================

interface SettingsProviderProps {
  readonly children: ReactNode
  readonly defaultModel?: ModelTier
}

export function SettingsProvider({
  children,
  defaultModel = DEFAULT_MODEL,
}: SettingsProviderProps) {
  const [settings, setSettings] = useState<SettingsState>(() => {
    const stored = loadSettings()
    return stored ?? {
      defaultModel,
      contextSources: [],
      maxTokens: DEFAULT_MAX_TOKENS,
      temperature: DEFAULT_TEMPERATURE,
    }
  })

  const updateSettings = useCallback((updater: (prev: SettingsState) => SettingsState) => {
    setSettings((prev) => {
      const next = updater(prev)
      persistSettings(next)
      return next
    })
  }, [])

  const setDefaultModel = useCallback(
    (model: ModelTier) => updateSettings((s) => ({ ...s, defaultModel: model })),
    [updateSettings],
  )

  const setMaxTokens = useCallback(
    (tokens: number) => updateSettings((s) => ({ ...s, maxTokens: tokens })),
    [updateSettings],
  )

  const setTemperature = useCallback(
    (temp: number) => updateSettings((s) => ({ ...s, temperature: Math.min(1, Math.max(0, temp)) })),
    [updateSettings],
  )

  const addContextSource = useCallback(
    (source: ContextSource) =>
      updateSettings((s) => ({
        ...s,
        contextSources: [...s.contextSources, source],
      })),
    [updateSettings],
  )

  const removeContextSource = useCallback(
    (path: string) =>
      updateSettings((s) => ({
        ...s,
        contextSources: s.contextSources.filter((cs) => cs.path !== path),
      })),
    [updateSettings],
  )

  const toggleContextSource = useCallback(
    (path: string) =>
      updateSettings((s) => ({
        ...s,
        contextSources: s.contextSources.map((cs) =>
          cs.path === path ? { ...cs, enabled: !cs.enabled } : cs,
        ),
      })),
    [updateSettings],
  )

  const contextValue = useMemo<SettingsContextProps>(
    () => ({
      settings,
      setDefaultModel,
      setMaxTokens,
      setTemperature,
      addContextSource,
      removeContextSource,
      toggleContextSource,
    }),
    [
      settings,
      setDefaultModel,
      setMaxTokens,
      setTemperature,
      addContextSource,
      removeContextSource,
      toggleContextSource,
    ],
  )

  return (
    <SettingsContext.Provider value={contextValue}>
      {children}
    </SettingsContext.Provider>
  )
}
