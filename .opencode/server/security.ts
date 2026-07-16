export const DEFAULT_LISTEN_HOST = '127.0.0.1'

export function getListenHost(configuredHost: string | undefined): string {
  return configuredHost?.trim() || DEFAULT_LISTEN_HOST
}

export function requireServerToken(environmentName: string, configuredToken: string | undefined): string {
  const token = configuredToken?.trim()
  if (!token) {
    throw new Error(`${environmentName} must be set to a non-empty bearer token before this server can start`)
  }
  if (!/^[A-Za-z0-9._~-]{32,}$/.test(token)) {
    throw new Error(`${environmentName} must contain at least 32 letters, digits, or URL-safe token characters`)
  }
  return token
}

export function hasValidBearerToken(authorization: string | null, expectedToken: string): boolean {
  if (!authorization) return false

  const match = authorization.match(/^Bearer ([^\s]+)$/i)
  return match?.[1] === expectedToken
}

export function parseAllowedOrigins(configuredOrigins: string | undefined): string[] {
  if (!configuredOrigins?.trim()) return []

  const origins = [...new Set(configuredOrigins.split(',').map(origin => origin.trim()).filter(Boolean))]
  if (origins.includes('*')) {
    throw new Error('CORS_ORIGINS cannot contain a wildcard; configure explicit trusted origins')
  }

  for (const origin of origins) {
    let parsed: URL
    try {
      parsed = new URL(origin)
    } catch {
      throw new Error(`CORS_ORIGINS contains an invalid origin: ${origin}`)
    }
    if (!['http:', 'https:'].includes(parsed.protocol) || parsed.origin !== origin) {
      throw new Error(`CORS_ORIGINS entries must be HTTP(S) origins without paths: ${origin}`)
    }
  }

  return origins
}
