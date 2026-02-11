import { execSync } from "child_process";
import {
  readFileSync,
  readdirSync,
  existsSync,
  statSync,
  appendFileSync,
  mkdirSync,
} from "fs";
import { join, relative, basename } from "path";
import { homedir } from "os";

const HOME = homedir();
const AGENTS_DIR = join(HOME, ".aidevops", "agents");
const SCRIPTS_DIR = join(AGENTS_DIR, "scripts");
const WORKSPACE_DIR = join(HOME, ".aidevops", ".agent-workspace");
const LOGS_DIR = join(HOME, ".aidevops", "logs");
const QUALITY_LOG = join(LOGS_DIR, "quality-hooks.log");

// ---------------------------------------------------------------------------
// Utility helpers
// ---------------------------------------------------------------------------

/**
 * Run a shell command and return stdout, or empty string on failure.
 * @param {string} cmd
 * @param {number} [timeout=5000]
 * @returns {string}
 */
function run(cmd, timeout = 5000) {
  try {
    return execSync(cmd, {
      encoding: "utf-8",
      timeout,
      stdio: ["pipe", "pipe", "pipe"],
    }).trim();
  } catch {
    return "";
  }
}

/**
 * Read a file if it exists, or return empty string.
 * @param {string} filepath
 * @returns {string}
 */
function readIfExists(filepath) {
  try {
    if (existsSync(filepath)) {
      return readFileSync(filepath, "utf-8").trim();
    }
  } catch {
    // ignore
  }
  return "";
}

/**
 * Parse YAML frontmatter from a markdown file.
 * Lightweight parser — no dependencies. Handles the common cases.
 * @param {string} content
 * @returns {{ data: Record<string, any>, body: string }}
 */
function parseFrontmatter(content) {
  const match = content.match(/^---\r?\n([\s\S]*?)\r?\n---\r?\n?([\s\S]*)$/);
  if (!match) return { data: {}, body: content };

  const yaml = match[1];
  const body = match[2];
  const data = {};

  for (const line of yaml.split("\n")) {
    const trimmed = line.trim();
    if (!trimmed || trimmed.startsWith("#")) continue;

    const colonIdx = trimmed.indexOf(":");
    if (colonIdx === -1) continue;

    const key = trimmed.slice(0, colonIdx).trim();
    let value = trimmed.slice(colonIdx + 1).trim();

    // Handle booleans and numbers
    if (value === "true") value = true;
    else if (value === "false") value = false;
    else if (/^\d+(\.\d+)?$/.test(value)) value = Number(value);

    data[key] = value;
  }

  return { data, body };
}

// ---------------------------------------------------------------------------
// Phase 1: Agent Loader
// ---------------------------------------------------------------------------

/**
 * Load agent definitions from ~/.aidevops/agents/ by reading markdown files
 * and parsing their YAML frontmatter.
 * @returns {Array<{name: string, description: string, mode: string, relPath: string}>}
 */
function loadAgentDefinitions() {
  if (!existsSync(AGENTS_DIR)) return [];

  const agents = [];

  // Load primary agents (root *.md files)
  try {
    const rootFiles = readdirSync(AGENTS_DIR).filter(
      (f) =>
        f.endsWith(".md") &&
        !f.startsWith("AGENTS") &&
        !f.startsWith("SKILL") &&
        !f.startsWith("README"),
    );

    for (const file of rootFiles) {
      const filepath = join(AGENTS_DIR, file);
      if (!statSync(filepath).isFile()) continue;

      const content = readIfExists(filepath);
      if (!content) continue;

      const { data } = parseFrontmatter(content);
      agents.push({
        name: basename(file, ".md"),
        description: data.description || "",
        mode: data.mode || "primary",
        relPath: file,
      });
    }
  } catch {
    // ignore read errors
  }

  // Load subagents from known subdirectories
  const subdirs = [
    "aidevops",
    "content",
    "seo",
    "tools",
    "services",
    "workflows",
    "memory",
    "custom",
    "draft",
  ];

  for (const subdir of subdirs) {
    const dirPath = join(AGENTS_DIR, subdir);
    if (!existsSync(dirPath)) continue;

    try {
      loadAgentsRecursive(dirPath, subdir, agents);
    } catch {
      // ignore
    }
  }

  return agents;
}

/**
 * Recursively load agent markdown files from a directory.
 * @param {string} dirPath
 * @param {string} relBase
 * @param {Array} agents
 */
function loadAgentsRecursive(dirPath, relBase, agents) {
  let entries;
  try {
    entries = readdirSync(dirPath, { withFileTypes: true });
  } catch {
    return;
  }

  for (const entry of entries) {
    const fullPath = join(dirPath, entry.name);

    if (entry.isDirectory()) {
      // Skip references/ and node_modules/
      if (entry.name === "references" || entry.name === "node_modules") {
        continue;
      }
      loadAgentsRecursive(fullPath, join(relBase, entry.name), agents);
    } else if (
      entry.isFile() &&
      entry.name.endsWith(".md") &&
      !entry.name.startsWith("README") &&
      !entry.name.endsWith("-skill.md")
    ) {
      const content = readIfExists(fullPath);
      if (!content) continue;

      const { data } = parseFrontmatter(content);
      agents.push({
        name: basename(entry.name, ".md"),
        description: data.description || "",
        mode: data.mode || "subagent",
        relPath: join(relBase, entry.name),
      });
    }
  }
}

// ---------------------------------------------------------------------------
// Phase 2: Config Hook — inject agents and MCPs into OpenCode config
// ---------------------------------------------------------------------------

/**
 * Modify OpenCode config to register aidevops agents dynamically.
 * This complements generate-opencode-agents.sh by ensuring agents are
 * always up-to-date even without re-running setup.sh.
 * @param {object} config - OpenCode Config object (mutable)
 */
async function configHook(config) {
  // Ensure agent section exists
  if (!config.agent) config.agent = {};

  // Load agent definitions and register any that aren't already configured
  const agents = loadAgentDefinitions();
  let injected = 0;

  for (const agent of agents) {
    // Skip if already configured (generate-opencode-agents.sh takes precedence)
    if (config.agent[agent.name]) continue;

    // Only auto-register subagents — primary agents need explicit config
    if (agent.mode !== "subagent") continue;

    config.agent[agent.name] = {
      description: agent.description || `aidevops subagent: ${agent.relPath}`,
      mode: "subagent",
    };
    injected++;
  }

  if (injected > 0) {
    // Log for debugging (visible in OpenCode logs)
    console.error(
      `[aidevops] Config hook: injected ${injected} subagent definitions`,
    );
  }
}

// ---------------------------------------------------------------------------
// Phase 3: Quality Hooks (t008.3)
// ---------------------------------------------------------------------------

/**
 * Log a quality event to the quality hooks log file.
 * @param {string} level - "INFO" | "WARN" | "ERROR"
 * @param {string} message
 */
function qualityLog(level, message) {
  try {
    mkdirSync(LOGS_DIR, { recursive: true });
    const timestamp = new Date().toISOString();
    appendFileSync(QUALITY_LOG, `[${timestamp}] [${level}] ${message}\n`);
  } catch {
    // Logging should never break the hook
  }
}

/**
 * Validate shell script return statements.
 * Checks that functions have explicit return statements (aidevops convention).
 * @param {string} filePath
 * @returns {{ violations: number, details: string[] }}
 */
function validateReturnStatements(filePath) {
  const details = [];
  let violations = 0;

  try {
    const content = readFileSync(filePath, "utf-8");
    const lines = content.split("\n");

    // Find function definitions and check for return statements
    let inFunction = false;
    let functionName = "";
    let functionStart = 0;
    let braceDepth = 0;
    let hasReturn = false;

    for (let i = 0; i < lines.length; i++) {
      const line = lines[i];
      const trimmed = line.trim();

      // Detect function definition: name() { or function name {
      const funcMatch = trimmed.match(
        /^([a-zA-Z_][a-zA-Z0-9_]*)\s*\(\)\s*\{/,
      );
      const funcMatch2 = trimmed.match(/^function\s+([a-zA-Z_][a-zA-Z0-9_]*)/);

      if (funcMatch || funcMatch2) {
        if (inFunction && !hasReturn) {
          details.push(
            `  Line ${functionStart}: function '${functionName}' missing explicit return`,
          );
          violations++;
        }
        inFunction = true;
        functionName = funcMatch ? funcMatch[1] : funcMatch2[1];
        functionStart = i + 1;
        braceDepth = trimmed.includes("{") ? 1 : 0;
        hasReturn = false;
        continue;
      }

      if (inFunction) {
        // Track brace depth
        for (const ch of trimmed) {
          if (ch === "{") braceDepth++;
          else if (ch === "}") braceDepth--;
        }

        // Check for return statement
        if (/\breturn\s+[0-9]/.test(trimmed) || /\breturn\s*$/.test(trimmed)) {
          hasReturn = true;
        }

        // Function ended
        if (braceDepth <= 0) {
          if (!hasReturn) {
            details.push(
              `  Line ${functionStart}: function '${functionName}' missing explicit return`,
            );
            violations++;
          }
          inFunction = false;
        }
      }
    }

    // Handle last function if file ends inside it
    if (inFunction && !hasReturn) {
      details.push(
        `  Line ${functionStart}: function '${functionName}' missing explicit return`,
      );
      violations++;
    }
  } catch {
    // File read error — skip validation
  }

  return { violations, details };
}

/**
 * Validate positional parameter usage in shell scripts.
 * Checks that $1, $2, etc. are assigned to local variables (aidevops convention).
 * @param {string} filePath
 * @returns {{ violations: number, details: string[] }}
 */
function validatePositionalParams(filePath) {
  const details = [];
  let violations = 0;

  try {
    const content = readFileSync(filePath, "utf-8");
    const lines = content.split("\n");

    for (let i = 0; i < lines.length; i++) {
      const line = lines[i];
      const trimmed = line.trim();

      // Skip comments
      if (trimmed.startsWith("#")) continue;

      // Check for direct $1-$9 usage not in a local assignment
      if (/\$[1-9]/.test(trimmed) && !/local\s+\w+=.*\$[1-9]/.test(trimmed)) {
        // Allow shift, case "$1", and getopts patterns
        if (
          /^\s*shift/.test(trimmed) ||
          /case\s+.*\$[1-9]/.test(trimmed) ||
          /getopts/.test(trimmed) ||
          /"\$@"/.test(trimmed) ||
          /"\$\*"/.test(trimmed)
        ) {
          continue;
        }
        details.push(`  Line ${i + 1}: direct positional parameter: ${trimmed.substring(0, 80)}`);
        violations++;
      }
    }
  } catch {
    // File read error — skip validation
  }

  return { violations, details };
}

/**
 * Scan file content for potential secrets.
 * Lightweight check — not a replacement for secretlint, but catches common patterns.
 * @param {string} filePath
 * @param {string} [content] - Optional content to scan (for Write operations)
 * @returns {{ violations: number, details: string[] }}
 */
function scanForSecrets(filePath, content) {
  const details = [];
  let violations = 0;

  const secretPatterns = [
    { pattern: /(?:api[_-]?key|apikey)\s*[:=]\s*['"][A-Za-z0-9+/=]{20,}['"]/i, label: "API key" },
    { pattern: /(?:secret|password|passwd|pwd)\s*[:=]\s*['"][^'"]{8,}['"]/i, label: "Secret/password" },
    { pattern: /(?:AKIA|ASIA)[A-Z0-9]{16}/, label: "AWS access key" },
    { pattern: /ghp_[A-Za-z0-9]{36}/, label: "GitHub personal access token" },
    { pattern: /gho_[A-Za-z0-9]{36}/, label: "GitHub OAuth token" },
    { pattern: /sk-[A-Za-z0-9]{20,}/, label: "OpenAI/Stripe secret key" },
    { pattern: /-----BEGIN (?:RSA |EC |DSA )?PRIVATE KEY-----/, label: "Private key" },
  ];

  try {
    const text = content || readFileSync(filePath, "utf-8");
    const lines = text.split("\n");

    for (let i = 0; i < lines.length; i++) {
      const line = lines[i];
      // Skip comments and example/placeholder lines
      if (line.trim().startsWith("#") || /example|placeholder|YOUR_/i.test(line)) {
        continue;
      }
      for (const { pattern, label } of secretPatterns) {
        if (pattern.test(line)) {
          details.push(`  Line ${i + 1}: potential ${label} detected`);
          violations++;
          break;
        }
      }
    }
  } catch {
    // File read error — skip
  }

  return { violations, details };
}

/**
 * Run the full pre-commit quality pipeline on a shell script.
 * Mirrors the checks in pre-commit-hook.sh but runs inline.
 * @param {string} filePath
 * @returns {{ totalViolations: number, report: string }}
 */
function runShellQualityPipeline(filePath) {
  const sections = [];
  let totalViolations = 0;

  // 1. ShellCheck
  const shellcheckResult = run(
    `shellcheck -x -S warning "${filePath}" 2>&1`,
    10000,
  );
  if (shellcheckResult) {
    const count = (shellcheckResult.match(/^In /gm) || []).length || 1;
    totalViolations += count;
    sections.push(`ShellCheck (${count} issue${count !== 1 ? "s" : ""}):\n${shellcheckResult}`);
  }

  // 2. Return statements
  const returnResult = validateReturnStatements(filePath);
  if (returnResult.violations > 0) {
    totalViolations += returnResult.violations;
    sections.push(
      `Return statements (${returnResult.violations} missing):\n${returnResult.details.join("\n")}`,
    );
  }

  // 3. Positional parameters
  const paramResult = validatePositionalParams(filePath);
  if (paramResult.violations > 0) {
    totalViolations += paramResult.violations;
    sections.push(
      `Positional params (${paramResult.violations} direct usage):\n${paramResult.details.join("\n")}`,
    );
  }

  // 4. Secrets scan
  const secretResult = scanForSecrets(filePath);
  if (secretResult.violations > 0) {
    totalViolations += secretResult.violations;
    sections.push(
      `Secrets scan (${secretResult.violations} potential):\n${secretResult.details.join("\n")}`,
    );
  }

  const report = sections.length > 0
    ? sections.join("\n\n")
    : "All quality checks passed.";

  return { totalViolations, report };
}

/**
 * Run markdown quality checks on a file.
 * Checks for common issues: trailing whitespace, missing blank lines around
 * code blocks (MD031), consecutive blank lines, broken links.
 * @param {string} filePath
 * @returns {{ totalViolations: number, report: string }}
 */
function runMarkdownQualityPipeline(filePath) {
  const sections = [];
  let totalViolations = 0;

  try {
    const content = readFileSync(filePath, "utf-8");
    const lines = content.split("\n");

    // MD031: Fenced code blocks should be surrounded by blank lines
    let inCodeBlock = false;
    for (let i = 0; i < lines.length; i++) {
      const line = lines[i];
      if (/^```/.test(line.trim())) {
        if (!inCodeBlock) {
          // Opening fence — check line before
          if (i > 0 && lines[i - 1].trim() !== "") {
            sections.push(`  Line ${i + 1}: MD031 — missing blank line before code fence`);
            totalViolations++;
          }
        } else {
          // Closing fence — check line after
          if (i < lines.length - 1 && lines[i + 1] !== undefined && lines[i + 1].trim() !== "") {
            sections.push(`  Line ${i + 1}: MD031 — missing blank line after code fence`);
            totalViolations++;
          }
        }
        inCodeBlock = !inCodeBlock;
      }
    }

    // Check for trailing whitespace (common quality issue)
    let trailingCount = 0;
    for (let i = 0; i < lines.length; i++) {
      if (/\s+$/.test(lines[i]) && !inCodeBlock) {
        trailingCount++;
      }
    }
    if (trailingCount > 0) {
      sections.push(`  Trailing whitespace on ${trailingCount} line${trailingCount !== 1 ? "s" : ""}`);
      totalViolations += trailingCount;
    }
  } catch {
    // File read error — skip
  }

  const report = sections.length > 0
    ? `Markdown quality:\n${sections.join("\n")}`
    : "Markdown checks passed.";

  return { totalViolations, report };
}

/**
 * Pre-tool-use hook: Comprehensive quality gate for Write/Edit operations.
 * Runs the full quality pipeline matching pre-commit-hook.sh checks:
 * - Shell scripts (.sh): ShellCheck, return statements, positional params, secrets
 * - Markdown (.md): MD031 (blank lines around code blocks), trailing whitespace
 * - All files: secrets scanning
 * @param {object} input - { tool, sessionID, callID }
 * @param {object} output - { args } (mutable)
 */
async function toolExecuteBefore(input, output) {
  const { tool } = input;

  // Only intercept Write and Edit tools
  if (
    tool !== "Write" &&
    tool !== "Edit" &&
    tool !== "write" &&
    tool !== "edit"
  ) {
    return;
  }

  const filePath = output.args?.filePath || output.args?.file_path || "";
  if (!filePath) return;

  // Shell script quality pipeline
  if (filePath.endsWith(".sh")) {
    const { totalViolations, report } = runShellQualityPipeline(filePath);
    if (totalViolations > 0) {
      console.error(
        `[aidevops] Quality gate: ${totalViolations} issue${totalViolations !== 1 ? "s" : ""} in ${filePath}:\n${report}`,
      );
      qualityLog(
        "WARN",
        `Shell quality: ${totalViolations} violations in ${filePath}`,
      );
    } else {
      qualityLog("INFO", `Shell quality: PASS for ${filePath}`);
    }
    return;
  }

  // Markdown quality pipeline
  if (filePath.endsWith(".md")) {
    const { totalViolations, report } = runMarkdownQualityPipeline(filePath);
    if (totalViolations > 0) {
      console.error(
        `[aidevops] Markdown quality: ${totalViolations} issue${totalViolations !== 1 ? "s" : ""} in ${filePath}:\n${report}`,
      );
      qualityLog(
        "WARN",
        `Markdown quality: ${totalViolations} violations in ${filePath}`,
      );
    }
    return;
  }

  // Secrets scan for all other file types
  const writeContent = output.args?.content || output.args?.newString || "";
  if (writeContent) {
    const secretResult = scanForSecrets(filePath, writeContent);
    if (secretResult.violations > 0) {
      console.error(
        `[aidevops] SECURITY: ${secretResult.violations} potential secret${secretResult.violations !== 1 ? "s" : ""} in ${filePath}:\n${secretResult.details.join("\n")}`,
      );
      qualityLog(
        "ERROR",
        `Secrets detected: ${secretResult.violations} in ${filePath}`,
      );
    }
  }
}

/**
 * Post-tool-use hook: Quality metrics tracking and pattern recording.
 * Logs tool execution for debugging and feeds data to pattern-tracker-helper.sh.
 * @param {object} input - { tool, sessionID, callID }
 * @param {object} output - { title, output, metadata } (mutable)
 */
async function toolExecuteAfter(input, output) {
  const toolName = input.tool || "";
  const title = output.title || "";
  const outputText = output.output || "";

  // Track git operations for pattern recording
  if (toolName === "Bash" || toolName === "bash") {
    if (title.includes("git commit") || title.includes("git push")) {
      console.error(`[aidevops] Git operation detected: ${title}`);
      qualityLog("INFO", `Git operation: ${title}`);

      // Record pattern if pattern-tracker-helper.sh is available
      const patternTracker = join(SCRIPTS_DIR, "pattern-tracker-helper.sh");
      if (existsSync(patternTracker)) {
        const success = !outputText.includes("error") && !outputText.includes("fatal");
        const patternType = success ? "SUCCESS_PATTERN" : "FAILURE_PATTERN";
        run(
          `bash "${patternTracker}" record "${patternType}" "git operation: ${title.substring(0, 100)}" --tag "quality-hook" 2>/dev/null`,
          5000,
        );
      }
    }

    // Track ShellCheck/lint runs in Bash commands
    if (
      title.includes("shellcheck") ||
      title.includes("linters-local")
    ) {
      const passed = !outputText.includes("error") && !outputText.includes("violation");
      qualityLog(
        passed ? "INFO" : "WARN",
        `Lint run: ${title} — ${passed ? "PASS" : "issues found"}`,
      );
    }
  }

  // Track Write/Edit operations for quality metrics
  if (
    toolName === "Write" ||
    toolName === "Edit" ||
    toolName === "write" ||
    toolName === "edit"
  ) {
    const filePath = output.metadata?.filePath || "";
    if (filePath) {
      qualityLog("INFO", `File modified: ${filePath} via ${toolName}`);
    }
  }
}

// ---------------------------------------------------------------------------
// Phase 4: Shell Environment
// ---------------------------------------------------------------------------

/**
 * Inject aidevops environment variables into shell sessions.
 * @param {object} _input - { cwd }
 * @param {object} output - { env } (mutable)
 */
async function shellEnvHook(_input, output) {
  // Ensure aidevops scripts are on PATH
  if (existsSync(SCRIPTS_DIR)) {
    const currentPath = output.env.PATH || process.env.PATH || "";
    if (!currentPath.includes(SCRIPTS_DIR)) {
      output.env.PATH = `${SCRIPTS_DIR}:${currentPath}`;
    }
  }

  // Set aidevops workspace directory
  output.env.AIDEVOPS_AGENTS_DIR = AGENTS_DIR;
  output.env.AIDEVOPS_WORKSPACE_DIR = WORKSPACE_DIR;

  // Set aidevops version if available
  const version = readIfExists(join(AGENTS_DIR, "..", "version"));
  if (version) {
    output.env.AIDEVOPS_VERSION = version;
  }
}

// ---------------------------------------------------------------------------
// Compaction Context (existing feature, improved)
// ---------------------------------------------------------------------------

/**
 * Get current agent state from the mailbox registry.
 * @returns {string}
 */
function getAgentState() {
  const registryPath = join(WORKSPACE_DIR, "mail", "registry.toon");
  const content = readIfExists(registryPath);
  if (!content) return "";

  return [
    "## Active Agent State",
    "The following agents are currently registered in the multi-agent orchestration system:",
    content,
  ].join("\n");
}

/**
 * Get loop guardrails from active loop state.
 * @param {string} directory - Current working directory
 * @returns {string}
 */
function getLoopGuardrails(directory) {
  const loopStateDir = join(directory, ".agent", "loop-state");
  if (!existsSync(loopStateDir)) return "";

  const stateFile = join(loopStateDir, "current.json");
  const content = readIfExists(stateFile);
  if (!content) return "";

  try {
    const state = JSON.parse(content);
    const lines = ["## Loop Guardrails"];

    if (state.task) lines.push(`Task: ${state.task}`);
    if (state.iteration)
      lines.push(
        `Iteration: ${state.iteration}/${state.maxIterations || "\u221e"}`,
      );
    if (state.objective) lines.push(`Objective: ${state.objective}`);
    if (state.constraints && state.constraints.length > 0) {
      lines.push("Constraints:");
      for (const c of state.constraints) {
        lines.push(`- ${c}`);
      }
    }
    if (state.completionCriteria)
      lines.push(`Completion: ${state.completionCriteria}`);

    return lines.join("\n");
  } catch {
    return "";
  }
}

/**
 * Recall relevant memories for the current session context.
 * @param {string} directory - Current working directory
 * @returns {string}
 */
function getRelevantMemories(directory) {
  const memoryHelper = join(SCRIPTS_DIR, "memory-helper.sh");
  if (!existsSync(memoryHelper)) return "";

  const projectName = directory.split("/").pop() || "";
  const memories = run(
    `bash "${memoryHelper}" recall "${projectName}" --limit 5 2>/dev/null`,
  );
  if (!memories) return "";

  return [
    "## Relevant Memories",
    "Previous session learnings relevant to this project:",
    memories,
  ].join("\n");
}

/**
 * Get the current git branch and recent commit context.
 * @param {string} directory
 * @returns {string}
 */
function getGitContext(directory) {
  const branch = run(`git -C "${directory}" branch --show-current 2>/dev/null`);
  if (!branch) return "";

  const recentCommits = run(
    `git -C "${directory}" log --oneline -5 2>/dev/null`,
  );

  const lines = ["## Git Context"];
  lines.push(`Branch: ${branch}`);
  if (recentCommits) {
    lines.push("Recent commits:");
    lines.push(recentCommits);
  }

  return lines.join("\n");
}

/**
 * Get session checkpoint state if it exists.
 * @returns {string}
 */
function getCheckpointState() {
  const checkpointFile = join(
    WORKSPACE_DIR,
    "tmp",
    "session-checkpoint.md",
  );
  const content = readIfExists(checkpointFile);
  if (!content) return "";

  return [
    "## Session Checkpoint",
    "Restore this operational state from the previous session:",
    content,
  ].join("\n");
}

/**
 * Get pending mailbox messages for context continuity.
 * @returns {string}
 */
function getMailboxState() {
  const mailHelper = join(SCRIPTS_DIR, "mail-helper.sh");
  if (!existsSync(mailHelper)) return "";

  const rawOutput = run(`bash "${mailHelper}" check 2>/dev/null`);
  const pending = parseInt(rawOutput, 10);
  if (isNaN(pending) || pending <= 0) return "";

  return [
    "## Pending Messages",
    `There are ${pending} unread messages in the agent mailbox.`,
    "Check inbox after resuming to handle inter-agent communications.",
  ].join("\n");
}

/**
 * Compaction hook — inject aidevops context into compaction summary.
 * @param {object} _input - { sessionID }
 * @param {object} output - { context: string[], prompt?: string }
 * @param {string} directory - Working directory
 */
async function compactingHook(_input, output, directory) {
  const sections = [
    getAgentState(),
    getLoopGuardrails(directory),
    getCheckpointState(),
    getRelevantMemories(directory),
    getGitContext(directory),
    getMailboxState(),
  ].filter(Boolean);

  if (sections.length === 0) return;

  output.context.push(
    [
      "# aidevops Framework Context",
      "Include the following state in your compaction summary so the next session can continue seamlessly:",
      "",
      ...sections,
      "",
      "## Critical Rules to Preserve",
      "- File discovery: use `git ls-files` not Glob",
      "- Git workflow: run pre-edit-check.sh before any file modifications",
      "- Security: never expose credentials in output/logs",
      "- Working directory: ~/.aidevops/.agent-workspace/work/[project]/",
      "- Quality: ShellCheck zero violations, SonarCloud A-grade",
      "- ALWAYS Read before Edit/Write — these tools fail without a prior Read",
    ].join("\n"),
  );
}

// ---------------------------------------------------------------------------
// Tool Definitions
// ---------------------------------------------------------------------------

/**
 * Create tool definitions for the plugin.
 *
 * NOTE: opencode 1.1.56+ uses Zod v4 to validate tool args schemas.
 * Plain `{ type: "string" }` objects are NOT valid Zod schemas and cause:
 *   TypeError: undefined is not an object (evaluating 'schema._zod.def')
 * Fix: omit `args` entirely and document parameters in `description`.
 * The LLM passes args as a plain object; we extract fields defensively.
 *
 * @returns {Record<string, object>}
 */
function createTools() {
  return {
    aidevops: {
      description:
        'Run aidevops CLI commands (status, repos, features, secret, etc.). Pass command as string e.g. "status", "repos", "features"',
      async execute(args) {
        const cmd = `aidevops ${args.command || args}`;
        const result = run(cmd, 15000);
        return result || `Command completed: ${cmd}`;
      },
    },

    aidevops_memory_recall: {
      description:
        'Recall memories from the aidevops cross-session memory system. Args: query (string), limit (string, default "5")',
      async execute(args) {
        const memoryHelper = join(SCRIPTS_DIR, "memory-helper.sh");
        if (!existsSync(memoryHelper)) {
          return "Memory system not available (memory-helper.sh not found)";
        }
        const limit = args.limit || "5";
        const result = run(
          `bash "${memoryHelper}" recall "${args.query}" --limit ${limit} 2>/dev/null`,
          10000,
        );
        return result || "No memories found for this query.";
      },
    },

    aidevops_memory_store: {
      description:
        'Store a new memory in the aidevops cross-session memory. Args: content (string), confidence (string: low/medium/high, default "medium")',
      async execute(args) {
        const memoryHelper = join(SCRIPTS_DIR, "memory-helper.sh");
        if (!existsSync(memoryHelper)) {
          return "Memory system not available (memory-helper.sh not found)";
        }
        const confidence = args.confidence || "medium";
        const result = run(
          `bash "${memoryHelper}" store "${args.content}" --confidence ${confidence} 2>/dev/null`,
          10000,
        );
        return result || "Memory stored successfully.";
      },
    },

    aidevops_pre_edit_check: {
      description:
        'Run the pre-edit git safety check before modifying files. Returns exit code and guidance. Args: task (optional string for loop mode)',
      async execute(args) {
        const script = join(SCRIPTS_DIR, "pre-edit-check.sh");
        if (!existsSync(script)) {
          return "pre-edit-check.sh not found — cannot verify git safety";
        }
        const taskFlag = args.task
          ? ` --loop-mode --task "${args.task}"`
          : "";
        try {
          const result = execSync(`bash "${script}"${taskFlag}`, {
            encoding: "utf-8",
            timeout: 10000,
            stdio: ["pipe", "pipe", "pipe"],
          });
          return `Pre-edit check PASSED (exit 0):\n${result.trim()}`;
        } catch (err) {
          const code = err.status || 1;
          const cmdOutput = (err.stdout || "") + (err.stderr || "");
          const guidance = {
            1: "STOP — you are on main/master branch. Create a worktree first.",
            2: "Create a worktree before proceeding with edits.",
            3: "WARNING — proceed with caution.",
          };
          return `Pre-edit check exit ${code}: ${guidance[code] || "Unknown"}\n${cmdOutput.trim()}`;
        }
      },
    },

    aidevops_quality_check: {
      description:
        'Run quality checks on a file or the full pre-commit pipeline. Args: file (string, path to check) OR command "pre-commit" to run full pipeline on staged files',
      async execute(args) {
        const file = args.file || args.command || args;

        // Full pre-commit pipeline
        if (file === "pre-commit" || file === "staged") {
          const hookScript = join(SCRIPTS_DIR, "pre-commit-hook.sh");
          if (!existsSync(hookScript)) {
            return "pre-commit-hook.sh not found — run aidevops update";
          }
          try {
            const result = execSync(`bash "${hookScript}"`, {
              encoding: "utf-8",
              timeout: 30000,
              stdio: ["pipe", "pipe", "pipe"],
            });
            return `Pre-commit quality checks PASSED:\n${result.trim()}`;
          } catch (err) {
            const cmdOutput = (err.stdout || "") + (err.stderr || "");
            return `Pre-commit quality checks FAILED:\n${cmdOutput.trim()}`;
          }
        }

        // Single file check
        if (typeof file === "string" && file.endsWith(".sh")) {
          const { totalViolations, report } = runShellQualityPipeline(file);
          return totalViolations > 0
            ? `Quality check: ${totalViolations} issue(s) found:\n${report}`
            : "Quality check: all checks passed.";
        }

        if (typeof file === "string" && file.endsWith(".md")) {
          const { totalViolations, report } = runMarkdownQualityPipeline(file);
          return totalViolations > 0
            ? `Markdown check: ${totalViolations} issue(s) found:\n${report}`
            : "Markdown check: all checks passed.";
        }

        // Generic secrets scan
        if (typeof file === "string" && existsSync(file)) {
          const secretResult = scanForSecrets(file);
          return secretResult.violations > 0
            ? `Secrets scan: ${secretResult.violations} potential issue(s):\n${secretResult.details.join("\n")}`
            : "Secrets scan: no issues found.";
        }

        return `Usage: pass a file path (.sh or .md) or "pre-commit" for full pipeline`;
      },
    },

    aidevops_install_hooks: {
      description:
        'Install or manage git pre-commit quality hooks. Args: action (string: "install", "uninstall", "status", "test")',
      async execute(args) {
        const action = args.action || args || "install";
        const helperScript = join(SCRIPTS_DIR, "install-hooks-helper.sh");

        // Try install-hooks-helper.sh first (Claude Code hooks)
        if (existsSync(helperScript)) {
          try {
            const result = execSync(
              `bash "${helperScript}" ${action}`,
              {
                encoding: "utf-8",
                timeout: 15000,
                stdio: ["pipe", "pipe", "pipe"],
              },
            );
            return result.trim();
          } catch (err) {
            const cmdOutput = (err.stdout || "") + (err.stderr || "");
            return `Hook ${action} failed:\n${cmdOutput.trim()}`;
          }
        }

        // Fallback: install git pre-commit hook directly
        if (action === "install") {
          const preCommitHook = join(SCRIPTS_DIR, "pre-commit-hook.sh");
          if (!existsSync(preCommitHook)) {
            return "pre-commit-hook.sh not found — run aidevops update";
          }
          const gitHookDir = run("git rev-parse --git-dir 2>/dev/null");
          if (!gitHookDir) {
            return "Not in a git repository — cannot install pre-commit hook";
          }
          const hookDest = join(gitHookDir, "hooks", "pre-commit");
          try {
            execSync(`cp "${preCommitHook}" "${hookDest}" && chmod +x "${hookDest}"`, {
              encoding: "utf-8",
              timeout: 5000,
            });
            return `Git pre-commit hook installed at ${hookDest}`;
          } catch (err) {
            return `Failed to install hook: ${err.message}`;
          }
        }

        return `install-hooks-helper.sh not found. Available actions: install, uninstall, status, test`;
      },
    },
  };
}

// ---------------------------------------------------------------------------
// Main Plugin Export
// ---------------------------------------------------------------------------

/**
 * aidevops OpenCode Plugin
 *
 * Provides:
 * 1. Config hook — dynamic agent loading from ~/.aidevops/agents/
 * 2. Custom tools — aidevops CLI, memory, pre-edit check, quality check, hook installer
 * 3. Quality hooks — full pre-commit pipeline (ShellCheck, return statements,
 *    positional params, secrets scan, markdown lint) on Write/Edit operations
 * 4. Shell environment — aidevops paths and variables
 * 5. Compaction context — preserves operational state across context resets
 *
 * @type {import('@opencode-ai/plugin').Plugin}
 */
export async function AidevopsPlugin({ directory }) {
  return {
    // Phase 1+2: Dynamic agent and config injection
    config: async (config) => configHook(config),

    // Phase 1: Custom tools
    tool: createTools(),

    // Phase 3: Quality hooks
    "tool.execute.before": toolExecuteBefore,
    "tool.execute.after": toolExecuteAfter,

    // Phase 4: Shell environment
    "shell.env": shellEnvHook,

    // Compaction context (existing + improved)
    "experimental.session.compacting": async (input, output) =>
      compactingHook(input, output, directory),
  };
}
