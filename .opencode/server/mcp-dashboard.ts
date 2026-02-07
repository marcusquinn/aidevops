/**
 * MCP Dashboard Server with WebSocket Support
 * 
 * Real-time monitoring dashboard for all MCP server integrations.
 * Uses Elysia with WebSocket for live updates.
 * Includes authentication for control endpoints.
 * 
 * Usage: bun run .opencode/server/mcp-dashboard.ts
 * 
 * Environment Variables:
 *   DASHBOARD_TOKEN - Bearer token for authenticated endpoints (required for start/stop)
 *   MCP_DASHBOARD_PORT - Port to listen on (default: 3101)
 */

import { Elysia, t } from 'elysia'

// Types
interface McpServer {
  name: string
  command: string
  status: 'running' | 'stopped' | 'error' | 'unknown'
  lastCheck: number
  port?: number
  error?: string
}

// Configuration
const CONFIG = {
  port: Number(process.env.MCP_DASHBOARD_PORT) || 3101,
  authToken: process.env.DASHBOARD_TOKEN || '',
  requireAuth: !!process.env.DASHBOARD_TOKEN,
}

// MCP Server definitions
const MCP_SERVERS: Array<{ name: string; command: string; port?: number; healthCheck?: string }> = [
  { name: 'crawl4ai', command: 'npx crawl4ai-mcp-server@latest', port: 11235, healthCheck: 'http://localhost:11235/health' },
  { name: 'context7', command: 'npx @context7/mcp-server', port: 3007 },
  { name: 'repomix', command: 'npx repomix --mcp', port: 3008 },
  { name: 'augment', command: 'augment-mcp-server', port: 3009 },
  { name: 'github', command: 'gh mcp-server', port: 3010 },
  { name: 'filesystem', command: 'npx @anthropic/mcp-server-filesystem', port: 3011 },
  { name: 'memory', command: 'npx @anthropic/mcp-server-memory', port: 3012 },
]

// Authentication helper
function validateAuth(authHeader: string | null): boolean {
  if (!CONFIG.requireAuth) {
    return true
  }
  if (!authHeader) {
    return false
  }
  const token = authHeader.replace('Bearer ', '')
  return token === CONFIG.authToken
}

// Check if a server is running
async function checkServerHealth(server: typeof MCP_SERVERS[0]): Promise<McpServer> {
  const result: McpServer = {
    name: server.name,
    command: server.command,
    status: 'unknown',
    lastCheck: Date.now(),
    port: server.port,
  }

  try {
    if (server.healthCheck) {
      const response = await fetch(server.healthCheck, { 
        signal: AbortSignal.timeout(2000) 
      })
      result.status = response.ok ? 'running' : 'error'
    } else if (server.port) {
      // Try to connect to the port
      const response = await fetch(`http://localhost:${server.port}`, {
        signal: AbortSignal.timeout(1000)
      }).catch(() => null)
      result.status = response ? 'running' : 'stopped'
    } else {
      // Check if process is running using safe spawn
      const proc = Bun.spawn(['pgrep', '-f', server.command], {
        stdout: 'pipe',
        stderr: 'pipe',
      })
      const output = await new Response(proc.stdout).text()
      result.status = output.trim() ? 'running' : 'stopped'
    }
  } catch (error) {
    result.status = 'error'
    result.error = error instanceof Error ? error.message : 'Unknown error'
  }

  return result
}

// Server state
const serverState = new Map<string, McpServer>()

// Create the dashboard app
const app = new Elysia()
  // Serve dashboard HTML
  .get('/', () => {
    return new Response(DASHBOARD_HTML, {
      headers: { 'Content-Type': 'text/html' },
    })
  })

  // Get all server statuses (public)
  .get('/api/servers', async () => {
    // Refresh all server statuses
    const checks = await Promise.all(
      MCP_SERVERS.map(server => checkServerHealth(server))
    )

    checks.forEach(server => {
      serverState.set(server.name, server)
    })

    return {
      servers: Array.from(serverState.values()),
      timestamp: Date.now(),
    }
  })

  // Get single server status (public)
  .get('/api/servers/:name', async ({ params }) => {
    const serverDef = MCP_SERVERS.find(s => s.name === params.name)
    if (!serverDef) {
      return { error: 'Server not found' }
    }

    const status = await checkServerHealth(serverDef)
    serverState.set(status.name, status)
    return status
  })

  // Start a server (authenticated)
  .post('/api/servers/:name/start', async ({ params, headers, set }) => {
    // Check authentication
    const authHeader = headers.authorization || null
    if (!validateAuth(authHeader)) {
      set.status = 401
      return { 
        error: 'Unauthorized', 
        message: CONFIG.requireAuth 
          ? 'Set Authorization: Bearer <DASHBOARD_TOKEN> header' 
          : 'Authentication not configured'
      }
    }

    const serverDef = MCP_SERVERS.find(s => s.name === params.name)
    if (!serverDef) {
      set.status = 404
      return { error: 'Server not found' }
    }

    try {
      // Start the server in background using safe spawn with array args
      const [cmd, ...args] = serverDef.command.split(' ')
      Bun.spawn([cmd, ...args], {
        stdout: 'ignore',
        stderr: 'ignore',
      })

      return { 
        success: true, 
        message: `Started ${params.name}`,
        command: serverDef.command,
      }
    } catch (error) {
      set.status = 500
      return { 
        error: error instanceof Error ? error.message : 'Failed to start server' 
      }
    }
  })

  // Stop a server (authenticated)
  .post('/api/servers/:name/stop', async ({ params, headers, set }) => {
    // Check authentication
    const authHeader = headers.authorization || null
    if (!validateAuth(authHeader)) {
      set.status = 401
      return { 
        error: 'Unauthorized',
        message: CONFIG.requireAuth 
          ? 'Set Authorization: Bearer <DASHBOARD_TOKEN> header' 
          : 'Authentication not configured'
      }
    }

    const serverDef = MCP_SERVERS.find(s => s.name === params.name)
    if (!serverDef) {
      set.status = 404
      return { error: 'Server not found' }
    }

    try {
      // Use safe spawn with array args - escape the server name for pkill pattern
      const safeName = params.name.replace(/[^a-zA-Z0-9-_]/g, '')
      const proc = Bun.spawn(['pkill', '-f', safeName], {
        stdout: 'pipe',
        stderr: 'pipe',
      })
      await proc.exited
      return { success: true, message: `Stopped ${params.name}` }
    } catch {
      return { success: true, message: `${params.name} was not running` }
    }
  })

  // WebSocket for real-time updates
  .ws('/ws', {
    open(ws) {
      console.log('Client connected')
      // Send initial state
      ws.send(JSON.stringify({
        type: 'connected',
        servers: MCP_SERVERS.map(s => s.name),
        authRequired: CONFIG.requireAuth,
      }))
    },
    message(ws, message) {
      try {
        const data = JSON.parse(String(message))
        
        if (data.type === 'subscribe') {
          // Client wants updates
          ws.send(JSON.stringify({ type: 'subscribed' }))
        }
      } catch {
        ws.send(JSON.stringify({ type: 'error', message: 'Invalid message format' }))
      }
    },
    close() {
      console.log('Client disconnected')
    },
  })

  // Health check (public)
  .get('/health', () => ({
    status: 'healthy',
    service: 'mcp-dashboard',
    authRequired: CONFIG.requireAuth,
    timestamp: Date.now(),
  }))

  // Auth status (public - shows if auth is required, not the token)
  .get('/api/auth/status', () => ({
    required: CONFIG.requireAuth,
    configured: !!CONFIG.authToken,
  }))

  .listen(CONFIG.port)

console.log(`🎛️  MCP Dashboard running at http://localhost:${CONFIG.port}`)
console.log(`   WebSocket available at ws://localhost:${CONFIG.port}/ws`)
if (CONFIG.requireAuth) {
  console.log(`   🔐 Authentication ENABLED for control endpoints`)
} else {
  console.log(`   ⚠️  Authentication DISABLED - set DASHBOARD_TOKEN to enable`)
}

// Dashboard HTML with auth support
const DASHBOARD_HTML = `<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <title>MCP Server Dashboard</title>
  <style>
    * { box-sizing: border-box; margin: 0; padding: 0; }
    body { 
      font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif;
      background: #0d1117; color: #c9d1d9; padding: 20px;
    }
    h1 { margin-bottom: 20px; color: #58a6ff; }
    .auth-bar {
      background: #161b22; border: 1px solid #30363d; border-radius: 8px;
      padding: 12px 16px; margin-bottom: 16px; display: flex; align-items: center; gap: 12px;
    }
    .auth-bar input {
      flex: 1; padding: 8px 12px; border-radius: 6px; border: 1px solid #30363d;
      background: #0d1117; color: #c9d1d9; font-size: 14px;
    }
    .auth-bar button {
      padding: 8px 16px; border-radius: 6px; border: none;
      background: #238636; color: #fff; cursor: pointer; font-size: 14px;
    }
    .auth-status { font-size: 12px; color: #8b949e; }
    .auth-status.authenticated { color: #3fb950; }
    .grid { display: grid; grid-template-columns: repeat(auto-fill, minmax(300px, 1fr)); gap: 16px; }
    .card {
      background: #161b22; border: 1px solid #30363d; border-radius: 8px;
      padding: 16px; transition: border-color 0.2s;
    }
    .card:hover { border-color: #58a6ff; }
    .card-header { display: flex; justify-content: space-between; align-items: center; margin-bottom: 12px; }
    .card-title { font-size: 18px; font-weight: 600; }
    .status { 
      padding: 4px 8px; border-radius: 12px; font-size: 12px; font-weight: 500;
    }
    .status.running { background: #238636; color: #fff; }
    .status.stopped { background: #6e7681; color: #fff; }
    .status.error { background: #da3633; color: #fff; }
    .status.unknown { background: #6e7681; color: #fff; }
    .card-body { font-size: 14px; color: #8b949e; }
    .card-body code { background: #0d1117; padding: 2px 6px; border-radius: 4px; font-size: 12px; }
    .actions { margin-top: 12px; display: flex; gap: 8px; }
    button {
      padding: 6px 12px; border-radius: 6px; border: 1px solid #30363d;
      background: #21262d; color: #c9d1d9; cursor: pointer; font-size: 12px;
    }
    button:hover { background: #30363d; }
    button.primary { background: #238636; border-color: #238636; }
    button.primary:hover { background: #2ea043; }
    button.danger { background: #da3633; border-color: #da3633; }
    button.danger:hover { background: #f85149; }
    button:disabled { opacity: 0.5; cursor: not-allowed; }
    .refresh { margin-bottom: 16px; }
    .last-update { font-size: 12px; color: #6e7681; margin-top: 20px; }
    .error-msg { color: #f85149; font-size: 12px; margin-top: 8px; }
  </style>
</head>
<body>
  <h1>🎛️ MCP Server Dashboard</h1>
  
  <div class="auth-bar">
    <input type="password" id="authToken" placeholder="Enter DASHBOARD_TOKEN for control access" onkeydown="if(event.key==='Enter')setToken()">
    <button onclick="setToken()">Set Token</button>
    <button id="clearTokenBtn" onclick="clearToken()" style="display:none;background:#da3633;border-color:#da3633;">Clear Token</button>
    <span class="auth-status" id="authStatus">Not authenticated</span>
  </div>
  
  <button class="refresh" onclick="refreshAll()">🔄 Refresh All</button>
  <div class="grid" id="servers"></div>
  <p class="last-update" id="lastUpdate"></p>
  <p class="error-msg" id="errorMsg"></p>

  <script>
    let ws;
    let authToken = sessionStorage.getItem('dashboardToken') || '';
    let authRequired = false;
    
    function setToken() {
      const input = document.getElementById('authToken');
      authToken = input.value;
      sessionStorage.setItem('dashboardToken', authToken);
      input.value = '';
      updateAuthStatus();
      refreshAll();
    }
    
    function clearToken() {
      authToken = '';
      sessionStorage.removeItem('dashboardToken');
      document.getElementById('authToken').value = '';
      updateAuthStatus();
      refreshAll();
    }
    
    function updateAuthStatus() {
      const status = document.getElementById('authStatus');
      const clearBtn = document.getElementById('clearTokenBtn');
      if (authToken) {
        status.textContent = 'Token set (session only)';
        status.className = 'auth-status authenticated';
        if (clearBtn) clearBtn.style.display = 'inline-block';
      } else {
        status.textContent = authRequired ? 'Token required' : 'No token set';
        status.className = 'auth-status';
        if (clearBtn) clearBtn.style.display = 'none';
      }
    }
    
    async function fetchServers() {
      try {
        const res = await fetch('/api/servers');
        const data = await res.json();
        renderServers(data.servers);
        document.getElementById('lastUpdate').textContent = 
          'Last updated: ' + new Date(data.timestamp).toLocaleTimeString();
        document.getElementById('errorMsg').textContent = '';
      } catch (e) {
        document.getElementById('errorMsg').textContent = 'Failed to fetch servers: ' + e.message;
      }
    }
    
    async function checkAuthRequired() {
      try {
        const res = await fetch('/api/auth/status');
        const data = await res.json();
        authRequired = data.required;
        updateAuthStatus();
      } catch (e) {
        console.error('Failed to check auth status:', e);
      }
    }

    function renderServers(servers) {
      const container = document.getElementById('servers');
      container.innerHTML = servers.map(s => \`
        <div class="card">
          <div class="card-header">
            <span class="card-title">\${s.name}</span>
            <span class="status \${s.status}">\${s.status}</span>
          </div>
          <div class="card-body">
            <p><code>\${s.command}</code></p>
            \${s.port ? '<p>Port: ' + s.port + '</p>' : ''}
            \${s.error ? '<p style="color:#f85149">Error: ' + s.error + '</p>' : ''}
          </div>
          <div class="actions">
            <button class="primary" onclick="startServer('\${s.name}')" \${!authToken && authRequired ? 'disabled title="Token required"' : ''}>▶ Start</button>
            <button class="danger" onclick="stopServer('\${s.name}')" \${!authToken && authRequired ? 'disabled title="Token required"' : ''}>⏹ Stop</button>
            <button onclick="checkServer('\${s.name}')">🔍 Check</button>
          </div>
        </div>
      \`).join('');
    }

    async function startServer(name) {
      try {
        const res = await fetch('/api/servers/' + name + '/start', { 
          method: 'POST',
          headers: authToken ? { 'Authorization': 'Bearer ' + authToken } : {}
        });
        const data = await res.json();
        if (data.error) {
          document.getElementById('errorMsg').textContent = data.error + ': ' + (data.message || '');
        } else {
          document.getElementById('errorMsg').textContent = '';
        }
        setTimeout(fetchServers, 1000);
      } catch (e) {
        document.getElementById('errorMsg').textContent = 'Failed to start: ' + e.message;
      }
    }

    async function stopServer(name) {
      try {
        const res = await fetch('/api/servers/' + name + '/stop', { 
          method: 'POST',
          headers: authToken ? { 'Authorization': 'Bearer ' + authToken } : {}
        });
        const data = await res.json();
        if (data.error) {
          document.getElementById('errorMsg').textContent = data.error + ': ' + (data.message || '');
        } else {
          document.getElementById('errorMsg').textContent = '';
        }
        setTimeout(fetchServers, 500);
      } catch (e) {
        document.getElementById('errorMsg').textContent = 'Failed to stop: ' + e.message;
      }
    }

    async function checkServer(name) {
      const res = await fetch('/api/servers/' + name);
      const data = await res.json();
      alert(name + ': ' + data.status);
      fetchServers();
    }

    function refreshAll() {
      fetchServers();
    }

    function connectWebSocket() {
      ws = new WebSocket('ws://localhost:${CONFIG.port}/ws');
      ws.onmessage = (e) => {
        const data = JSON.parse(e.data);
        if (data.type === 'update') {
          fetchServers();
        }
        if (data.authRequired !== undefined) {
          authRequired = data.authRequired;
          updateAuthStatus();
        }
      };
      ws.onclose = () => setTimeout(connectWebSocket, 3000);
    }

    // Initialize
    checkAuthRequired();
    fetchServers();
    connectWebSocket();
    setInterval(fetchServers, 30000);
    
    // Restore token display from sessionStorage
    if (authToken) {
      updateAuthStatus();
    }
  </script>
</body>
</html>`

export type App = typeof app
