/**
 * Cursor Tool Handlers (t1553)
 *
 * Registers tool handlers for Cursor models via OpenCode's plugin `tool` hook.
 * When a Cursor model returns tool_calls, OpenCode calls these handlers to
 * execute the tools locally, then sends results back to the model.
 *
 * Architecture (from Nomadcxx/opencode-cursor analysis):
 *   1. Model returns tool_calls in response
 *   2. OpenCode calls the plugin's registered tool handlers
 *   3. Handlers execute locally (fs, child_process)
 *   4. OpenCode sends a new request with tool results
 *   5. Cycle repeats until model returns text
 *
 * Tool handlers: bash, read, write, edit, grep, ls, glob
 *
 * These are intentionally simple implementations — the model drives the
 * tool loop, not the proxy. The proxy just translates the protocol.
 *
 * @module cursor-tools
 */

import { execSync, spawn } from "child_process";
import {
  readFileSync,
  writeFileSync,
  readdirSync,
  existsSync,
  mkdirSync,
  statSync,
} from "fs";
import { dirname, resolve } from "path";

// ---------------------------------------------------------------------------
// Tool name alias resolution (subset of Nomadcxx's 50+ aliases)
// Maps common model-generated tool names to our canonical names.
// Cursor models sometimes emit camelCase or suffixed names.
// ---------------------------------------------------------------------------

const TOOL_ALIASES = new Map([
  // bash
  ["runcommand", "cursor_bash"],
  ["executecommand", "cursor_bash"],
  ["runterminalcommand", "cursor_bash"],
  ["shellcommand", "cursor_bash"],
  ["shell", "cursor_bash"],
  ["terminal", "cursor_bash"],
  ["bash", "cursor_bash"],
  // read
  ["readfile", "cursor_read"],
  ["read", "cursor_read"],
  // write
  ["writefile", "cursor_write"],
  ["createfile", "cursor_write"],
  ["write", "cursor_write"],
  // edit
  ["editfile", "cursor_edit"],
  ["edit", "cursor_edit"],
  // grep
  ["searchfiles", "cursor_grep"],
  ["grep", "cursor_grep"],
  // ls
  ["listdirectory", "cursor_ls"],
  ["listfiles", "cursor_ls"],
  ["listdir", "cursor_ls"],
  ["ls", "cursor_ls"],
  // glob
  ["findfiles", "cursor_glob"],
  ["glob", "cursor_glob"],
]);

/**
 * Resolve a tool name to its canonical cursor_* name.
 * Handles aliases, camelCase normalization, and ToolCall suffixes.
 * @param {string} name - Raw tool name from the model
 * @returns {string|null} Canonical tool name or null if not a cursor tool
 */
export function resolveToolName(name) {
  if (!name) return null;

  // Already canonical
  if (name.startsWith("cursor_")) return name;

  // Normalize: strip ToolCall suffix, lowercase, remove non-alphanumeric
  let normalized = name;
  if (normalized.endsWith("ToolCall")) {
    normalized = normalized.slice(0, -"ToolCall".length);
  }
  normalized = normalized.toLowerCase().replace(/[^a-z0-9]/g, "");

  return TOOL_ALIASES.get(normalized) || null;
}

// ---------------------------------------------------------------------------
// Tool handler implementations
// ---------------------------------------------------------------------------

/**
 * Execute a shell command.
 * @param {object} args - { command: string, timeout?: number, cwd?: string }
 * @returns {Promise<string>}
 */
async function executeBash(args) {
  const command = args.command || args.cmd || args.script || args.input;
  if (!command) {
    return "Error: missing required argument 'command'";
  }

  const timeoutMs = resolveTimeoutMs(args.timeout);
  const cwd = args.cwd || args.workdir || undefined;

  return new Promise((res) => {
    const proc = spawn(command, {
      shell: process.env.SHELL || "/bin/bash",
      cwd,
    });

    const stdoutChunks = [];
    const stderrChunks = [];
    let timedOut = false;

    const timer = setTimeout(() => {
      timedOut = true;
      proc.kill("SIGTERM");
    }, timeoutMs);

    proc.stdout.on("data", (chunk) => stdoutChunks.push(chunk));
    proc.stderr.on("data", (chunk) => stderrChunks.push(chunk));

    proc.on("close", (code) => {
      clearTimeout(timer);
      const stdout = Buffer.concat(stdoutChunks).toString("utf8");
      const stderr = Buffer.concat(stderrChunks).toString("utf8");
      const output = stdout || stderr || "Command executed successfully";
      if (timedOut) {
        res(`Command timed out after ${timeoutMs / 1000}s\n${output}`);
      } else if (code !== 0) {
        res(`${output}\n[Exit code: ${code}]`);
      } else {
        res(output);
      }
    });

    proc.on("error", (err) => {
      clearTimeout(timer);
      res(`Error: ${err.message}`);
    });
  });
}

/**
 * Read file contents.
 * @param {object} args - { path: string, offset?: number, limit?: number }
 * @returns {Promise<string>}
 */
async function executeRead(args) {
  const filePath = args.path || args.filePath || args.file;
  if (!filePath) {
    return "Error: missing required argument 'path'";
  }

  try {
    let content = readFileSync(filePath, "utf-8");

    if (args.offset !== undefined || args.limit !== undefined) {
      const lines = content.split("\n");
      const start = args.offset || 0;
      const end = args.limit ? start + args.limit : lines.length;
      content = lines.slice(start, end).join("\n");
    }

    return content;
  } catch (err) {
    return `Error reading ${filePath}: ${err.message}`;
  }
}

/**
 * Write content to a file.
 * @param {object} args - { path: string, content: string }
 * @returns {Promise<string>}
 */
async function executeWrite(args) {
  const filePath = args.path || args.filePath || args.file;
  const content = args.content;

  if (!filePath) {
    return "Error: missing required argument 'path'";
  }
  if (content === undefined || content === null) {
    return "Error: missing required argument 'content'";
  }

  try {
    const dir = dirname(filePath);
    if (!existsSync(dir)) {
      mkdirSync(dir, { recursive: true });
    }
    writeFileSync(filePath, content, "utf-8");
    return `File written successfully: ${filePath}`;
  } catch (err) {
    return `Error writing ${filePath}: ${err.message}`;
  }
}

/**
 * Edit a file by replacing old text with new text.
 * @param {object} args - { path: string, old_string: string, new_string: string }
 * @returns {Promise<string>}
 */
async function executeEdit(args) {
  const filePath = args.path || args.filePath || args.file;
  const oldString = args.old_string || args.oldString || args.search;
  const newString = args.new_string || args.newString || args.replace;

  if (!filePath) {
    return "Error: missing required argument 'path'";
  }

  try {
    if (!existsSync(filePath)) {
      // File doesn't exist — create with new content
      if (newString !== undefined) {
        const dir = dirname(filePath);
        if (!existsSync(dir)) {
          mkdirSync(dir, { recursive: true });
        }
        writeFileSync(filePath, newString, "utf-8");
        return `File did not exist. Created: ${filePath}`;
      }
      return `Error: file not found: ${filePath}`;
    }

    let content = readFileSync(filePath, "utf-8");

    if (!oldString) {
      // Empty old_string = overwrite entire file
      writeFileSync(filePath, newString || "", "utf-8");
      return `File edited successfully: ${filePath}`;
    }

    if (!content.includes(oldString)) {
      return `Error: could not find the text to replace in ${filePath}`;
    }

    content = content.replace(oldString, newString || "");
    writeFileSync(filePath, content, "utf-8");
    return `File edited successfully: ${filePath}`;
  } catch (err) {
    return `Error editing ${filePath}: ${err.message}`;
  }
}

/**
 * Search for a pattern in files using grep.
 * @param {object} args - { pattern: string, path: string, include?: string }
 * @returns {Promise<string>}
 */
async function executeGrep(args) {
  const pattern = args.pattern;
  const searchPath = args.path || args.directory || ".";
  const include = args.include;

  if (!pattern) {
    return "Error: missing required argument 'pattern'";
  }

  const grepArgs = ["-r", "-n"];
  if (include) {
    grepArgs.push(`--include=${include}`);
  }
  grepArgs.push(pattern, searchPath);

  try {
    const result = execSync(`grep ${grepArgs.map(shellEscape).join(" ")}`, {
      encoding: "utf-8",
      timeout: 30000,
      stdio: ["pipe", "pipe", "pipe"],
    });
    return result || "No matches found";
  } catch (err) {
    // grep exits with code 1 when no matches found
    if (err.status === 1) {
      return "No matches found";
    }
    // Try with extended regex on syntax errors
    if (err.status === 2) {
      try {
        const result = execSync(`grep -E ${grepArgs.map(shellEscape).join(" ")}`, {
          encoding: "utf-8",
          timeout: 30000,
          stdio: ["pipe", "pipe", "pipe"],
        });
        return result || "No matches found";
      } catch (extErr) {
        if (extErr.status === 1) return "No matches found";
        return `Error: ${extErr.message}`;
      }
    }
    return `Error: ${err.message}`;
  }
}

/**
 * List directory contents.
 * @param {object} args - { path: string }
 * @returns {Promise<string>}
 */
async function executeLs(args) {
  const dirPath = args.path || args.directory || ".";

  try {
    const entries = readdirSync(dirPath, { withFileTypes: true });
    const result = entries.map((entry) => {
      const type = entry.isDirectory() ? "d"
        : entry.isSymbolicLink() ? "l"
        : entry.isFile() ? "f" : "?";
      return `[${type}] ${entry.name}`;
    });
    return result.join("\n") || "Empty directory";
  } catch (err) {
    return `Error listing ${dirPath}: ${err.message}`;
  }
}

/**
 * Find files matching a glob pattern using find.
 * @param {object} args - { pattern: string, path?: string }
 * @returns {Promise<string>}
 */
async function executeGlob(args) {
  const pattern = args.pattern || args.globPattern;
  const searchPath = args.path || args.directory || ".";

  if (!pattern) {
    return "Error: missing required argument 'pattern'";
  }

  const normalizedPattern = pattern.replace(/\\/g, "/");
  const isPathPattern = normalizedPattern.includes("/");
  const findArgs = [searchPath, "-type", "f"];

  if (isPathPattern) {
    findArgs.push("-path", normalizedPattern);
  } else {
    findArgs.push("-name", normalizedPattern);
  }

  try {
    const result = execSync(`find ${findArgs.map(shellEscape).join(" ")}`, {
      encoding: "utf-8",
      timeout: 30000,
      stdio: ["pipe", "pipe", "pipe"],
    });
    const lines = (result || "").split("\n").filter(Boolean);
    return lines.slice(0, 50).join("\n") || "No files found";
  } catch (err) {
    const stdout = err.stdout || "";
    const lines = stdout.split("\n").filter(Boolean);
    return lines.slice(0, 50).join("\n") || "No files found";
  }
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

/**
 * Shell-escape a string for safe interpolation.
 * @param {string} str
 * @returns {string}
 */
function shellEscape(str) {
  return "'" + String(str).replace(/'/g, "'\\''") + "'";
}

/**
 * Resolve timeout value to milliseconds.
 * Values <= 600 are treated as seconds.
 * @param {unknown} value
 * @returns {number}
 */
function resolveTimeoutMs(value) {
  if (typeof value === "number" && Number.isFinite(value) && value > 0) {
    return value <= 600 ? value * 1000 : value;
  }
  if (typeof value === "string") {
    const parsed = Number(value.trim());
    if (Number.isFinite(parsed) && parsed > 0) {
      return parsed <= 600 ? parsed * 1000 : parsed;
    }
  }
  return 30000; // 30s default
}

// ---------------------------------------------------------------------------
// Tool registry for OpenCode plugin `tool` hook
// ---------------------------------------------------------------------------

/**
 * Handler map: canonical tool name → execute function.
 * @type {Map<string, (args: object) => Promise<string>>}
 */
const TOOL_HANDLERS = new Map([
  ["cursor_bash", executeBash],
  ["cursor_read", executeRead],
  ["cursor_write", executeWrite],
  ["cursor_edit", executeEdit],
  ["cursor_grep", executeGrep],
  ["cursor_ls", executeLs],
  ["cursor_glob", executeGlob],
]);

/**
 * Create tool definitions for the OpenCode plugin `tool` hook.
 *
 * These tools are registered under cursor_* names so they don't conflict
 * with OpenCode's built-in tools or other plugin tools. The proxy maps
 * Cursor model tool names to these canonical names.
 *
 * NOTE: OpenCode 1.1.56+ uses Zod v4 for tool arg validation.
 * Plain `{ type: "string" }` objects are NOT valid Zod schemas.
 * We omit `args` and document parameters in `description` instead.
 *
 * @returns {Record<string, { description: string, execute: (args: object) => Promise<string> }>}
 */
export function createCursorTools() {
  return {
    cursor_bash: {
      description:
        "Execute a shell command for Cursor models. Args: command (string, required), timeout (number, seconds), cwd (string)",
      async execute(args) {
        return executeBash(args);
      },
    },

    cursor_read: {
      description:
        "Read file contents for Cursor models. Args: path (string, required), offset (number), limit (number)",
      async execute(args) {
        return executeRead(args);
      },
    },

    cursor_write: {
      description:
        "Write content to a file for Cursor models. Args: path (string, required), content (string, required)",
      async execute(args) {
        return executeWrite(args);
      },
    },

    cursor_edit: {
      description:
        "Edit a file by replacing text for Cursor models. Args: path (string, required), old_string (string), new_string (string)",
      async execute(args) {
        return executeEdit(args);
      },
    },

    cursor_grep: {
      description:
        "Search for a pattern in files for Cursor models. Args: pattern (string, required), path (string), include (string)",
      async execute(args) {
        return executeGrep(args);
      },
    },

    cursor_ls: {
      description:
        "List directory contents for Cursor models. Args: path (string, required)",
      async execute(args) {
        return executeLs(args);
      },
    },

    cursor_glob: {
      description:
        "Find files matching a glob pattern for Cursor models. Args: pattern (string, required), path (string)",
      async execute(args) {
        return executeGlob(args);
      },
    },
  };
}

/**
 * Get the handler function for a tool name (with alias resolution).
 * @param {string} toolName - Raw or canonical tool name
 * @returns {((args: object) => Promise<string>) | null}
 */
export function getToolHandler(toolName) {
  // Direct canonical lookup
  const direct = TOOL_HANDLERS.get(toolName);
  if (direct) return direct;

  // Alias resolution
  const resolved = resolveToolName(toolName);
  if (resolved) return TOOL_HANDLERS.get(resolved) || null;

  return null;
}

/**
 * Get all canonical tool names.
 * @returns {string[]}
 */
export function getCursorToolNames() {
  return Array.from(TOOL_HANDLERS.keys());
}

/**
 * Build OpenAI-compatible tool definitions for sending to the Cursor model.
 * These tell the model what tools are available.
 * @returns {Array<{ type: "function", function: { name: string, description: string, parameters: object } }>}
 */
export function buildToolDefinitions() {
  return [
    {
      type: "function",
      function: {
        name: "bash",
        description: "Execute a shell command. Use this to run programs, tests, or system commands.",
        parameters: {
          type: "object",
          properties: {
            command: { type: "string", description: "The shell command to execute" },
            timeout: { type: "number", description: "Timeout in seconds (default: 30)" },
            cwd: { type: "string", description: "Working directory for the command" },
          },
          required: ["command"],
        },
      },
    },
    {
      type: "function",
      function: {
        name: "read",
        description: "Read the contents of a file.",
        parameters: {
          type: "object",
          properties: {
            path: { type: "string", description: "Absolute path to the file to read" },
            offset: { type: "number", description: "Line number to start reading from" },
            limit: { type: "number", description: "Maximum number of lines to read" },
          },
          required: ["path"],
        },
      },
    },
    {
      type: "function",
      function: {
        name: "write",
        description: "Write content to a file (creates or overwrites).",
        parameters: {
          type: "object",
          properties: {
            path: { type: "string", description: "Absolute path to the file to write" },
            content: { type: "string", description: "Content to write to the file" },
          },
          required: ["path", "content"],
        },
      },
    },
    {
      type: "function",
      function: {
        name: "edit",
        description: "Edit a file by replacing old text with new text.",
        parameters: {
          type: "object",
          properties: {
            path: { type: "string", description: "Absolute path to the file to edit" },
            old_string: { type: "string", description: "The text to replace" },
            new_string: { type: "string", description: "The replacement text" },
          },
          required: ["path", "old_string", "new_string"],
        },
      },
    },
    {
      type: "function",
      function: {
        name: "grep",
        description: "Search for a pattern in files.",
        parameters: {
          type: "object",
          properties: {
            pattern: { type: "string", description: "The search pattern (regex supported)" },
            path: { type: "string", description: "Directory or file to search in" },
            include: { type: "string", description: "File pattern to include (e.g., '*.ts')" },
          },
          required: ["pattern", "path"],
        },
      },
    },
    {
      type: "function",
      function: {
        name: "ls",
        description: "List directory contents.",
        parameters: {
          type: "object",
          properties: {
            path: { type: "string", description: "Absolute path to the directory" },
          },
          required: ["path"],
        },
      },
    },
    {
      type: "function",
      function: {
        name: "glob",
        description: "Find files matching a glob pattern.",
        parameters: {
          type: "object",
          properties: {
            pattern: { type: "string", description: "Glob pattern (e.g., '**/*.ts')" },
            path: { type: "string", description: "Directory to search in" },
          },
          required: ["pattern"],
        },
      },
    },
  ];
}
