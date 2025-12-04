/**
 * Main Server Entry Point
 * 
 * Starts all Elysia services for the AI DevOps Framework.
 * 
 * Usage: bun run .opencode/server/index.ts
 */

import { Elysia } from 'elysia'

// Read version from VERSION file
async function getVersion(): Promise<string> {
  try {
    const versionFile = Bun.file(new URL('../../VERSION', import.meta.url).pathname)
    if (await versionFile.exists()) {
      return (await versionFile.text()).trim()
    }
  } catch {
    // Fall back to package.json
    try {
      const pkgFile = Bun.file(new URL('../../package.json', import.meta.url).pathname)
      const pkg = await pkgFile.json()
      return pkg.version || 'unknown'
    } catch {
      return 'unknown'
    }
  }
  return 'unknown'
}

const PORT = Number(process.env.PORT) || 3100
const VERSION = await getVersion()

const app = new Elysia()
  .get('/', () => ({
    name: 'AI DevOps Framework',
    version: VERSION,
    services: {
      'api-gateway': 'http://localhost:3100',
      'mcp-dashboard': 'http://localhost:3101',
    },
    docs: 'https://github.com/marcusquinn/aidevops',
  }))

  .get('/health', () => ({
    status: 'healthy',
    version: VERSION,
    timestamp: Date.now(),
    uptime: process.uptime(),
  }))

  .listen(PORT)

console.log(`
🚀 AI DevOps Framework Server v${VERSION}
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

Main server:     http://localhost:${PORT}

To start individual services:
  bun run .opencode/server/api-gateway.ts    # API Gateway (port 3100)
  bun run .opencode/server/mcp-dashboard.ts  # MCP Dashboard (port 3101)

Available npm scripts:
  bun run dev        # Start API gateway
  bun run dashboard  # Start MCP dashboard
  bun run quality    # Run parallel quality checks
`)

export type App = typeof app
