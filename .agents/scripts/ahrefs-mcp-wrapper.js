#!/usr/bin/env node
/**
 * Ahrefs MCP Server Wrapper
 * 
 * DEPRECATED: This wrapper is no longer needed for most use cases.
 * 
 * For OpenCode, use the bash wrapper pattern instead:
 * {
 *   "ahrefs": {
 *     "type": "local",
 *     "command": ["/bin/bash", "-c", "API_KEY=$AHREFS_API_KEY /opt/homebrew/bin/npx -y @ahrefs/mcp@latest"],
 *     "enabled": true
 *   }
 * }
 * 
 * Key facts:
 * - Use standard 40-char API key from https://ahrefs.com/api (JWT tokens don't work)
 * - The @ahrefs/mcp package expects API_KEY env var, not AHREFS_API_KEY
 * - OpenCode environment blocks don't expand shell variables
 * 
 * This wrapper was originally created to patch JSON Schema validation errors,
 * but the bash wrapper pattern is simpler and handles the env var issue.
 */

const { spawn } = require('child_process');

// Find npx command - try common locations
const findNpx = () => {
  const fs = require('fs');
  const paths = [
    '/opt/homebrew/bin/npx',
    '/usr/local/bin/npx',
    '/usr/bin/npx',
    process.env.HOME + '/.nvm/versions/node/v20/bin/npx',
    process.env.HOME + '/.nvm/versions/node/v18/bin/npx',
  ];
  for (const p of paths) {
    if (fs.existsSync(p)) return p;
  }
  return 'npx'; // fallback to PATH
};

const originalCmd = findNpx();
const originalArgs = ['-y', '@ahrefs/mcp@latest'];

console.error('[Wrapper] Starting Ahrefs MCP wrapper...');
console.error(`[Wrapper] Using npx: ${originalCmd}`);

const server = spawn(originalCmd, originalArgs, {
  stdio: ['pipe', 'pipe', 'inherit'],
  env: process.env
});

// Handle child process errors
server.on('error', (err) => {
  console.error(`[Wrapper] Failed to start child process: ${err.message}`);
  process.exit(1);
});

// Pipe stdin to the server (requests from client)
process.stdin.pipe(server.stdin);

/**
 * Deep recursive function to fix ALL schema issues for OpenAI compatibility
 * - Adds missing 'items' for array types
 * - Adds 'additionalProperties: false' for object types (required by OpenAI)
 * - Handles nested objects, arrays, allOf, anyOf, oneOf, etc.
 */
const fixSchemaForOpenAI = (obj, path = '', fixCount = { items: 0, additionalProps: 0 }) => {
  if (!obj || typeof obj !== 'object') return;
  
  // Handle arrays (JSON arrays, not schema arrays)
  if (Array.isArray(obj)) {
    obj.forEach((item, idx) => fixSchemaForOpenAI(item, `${path}[${idx}]`, fixCount));
    return;
  }
  
  // Fix 1: Array type missing items
  const typeIsArray = obj.type === 'array' || 
    (Array.isArray(obj.type) && obj.type.includes('array'));
  
  if (typeIsArray && !obj.items) {
    obj.items = { type: 'string' };
    fixCount.items++;
    console.error(`[Wrapper] Fixed: Added items to array at '${path}'`);
  }
  
  // Fix 2: Object type missing additionalProperties (OpenAI requirement)
  const typeIsObject = obj.type === 'object' || 
    (Array.isArray(obj.type) && obj.type.includes('object'));
  
  if (typeIsObject && obj.properties && !('additionalProperties' in obj)) {
    obj.additionalProperties = false;
    fixCount.additionalProps++;
    console.error(`[Wrapper] Fixed: Added additionalProperties:false at '${path}'`);
  }
  
  // Recurse into all object keys to catch any nested schemas
  for (const key of Object.keys(obj)) {
    if (obj[key] && typeof obj[key] === 'object') {
      fixSchemaForOpenAI(obj[key], path ? `${path}.${key}` : key, fixCount);
    }
  }
  
  return fixCount;
};

let buffer = '';

// Process stdout from the server (responses to client)
server.stdout.on('data', (data) => {
  buffer += data.toString();
  
  let newlineIndex;
  while ((newlineIndex = buffer.indexOf('\n')) !== -1) {
    const line = buffer.slice(0, newlineIndex);
    buffer = buffer.slice(newlineIndex + 1);
    
    if (!line.trim()) continue;
    
    try {
      const msg = JSON.parse(line);
      
      // Intercept tool list response to patch schema - handle various response formats
      let tools = null;
      if (msg.result && msg.result.tools) {
        tools = msg.result.tools;
      } else if (msg.result && Array.isArray(msg.result)) {
        // Some MCP servers return tools directly as array
        tools = msg.result;
      } else if (msg.tools) {
        // Direct tools property
        tools = msg.tools;
      }
      
      if (tools && Array.isArray(tools)) {
        console.error(`[Wrapper] Intercepted tools list with ${tools.length} tools, fixing schemas for OpenAI compatibility...`);
        let totalItemsFixes = 0;
        let totalAdditionalPropsFixes = 0;
        
        tools.forEach(tool => {
          // Check both inputSchema and parameters (different MCP versions)
          const schema = tool.inputSchema || tool.parameters;
          if (schema) {
            const fixes = fixSchemaForOpenAI(schema, tool.name || 'unknown');
            if (fixes) {
              totalItemsFixes += fixes.items || 0;
              totalAdditionalPropsFixes += fixes.additionalProps || 0;
            }
          }
        });
        
        console.error(`[Wrapper] Applied ${totalItemsFixes} array items fixes, ${totalAdditionalPropsFixes} additionalProperties fixes`);
      }
      
      console.log(JSON.stringify(msg));
    } catch (e) {
      // Pass through non-JSON or partial lines
      console.error(`[Wrapper] Parse warning: ${e.message}`);
      console.log(line);
    }
  }
});

server.on('close', (code) => {
  console.error(`[Wrapper] Child process exited with code ${code}`);
  process.exit(code || 0);
});
