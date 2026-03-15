import { existsSync } from "fs";
import { join } from "path";

/**
 * Built-in TTSR rules — enforced by default.
 * Each rule has:
 *   - id: unique identifier
 *   - description: human-readable explanation
 *   - pattern: regex string to detect violations in assistant output
 *   - correction: message injected when violation is detected
 *   - severity: "error" | "warn" | "info"
 *   - systemPrompt: instruction injected into system prompt (preventative)
 *
 * @type {Array<{id: string, description: string, pattern: string, correction: string, severity: string, systemPrompt: string}>}
 */
const BUILTIN_TTSR_RULES = [
  {
    id: "no-glob-for-discovery",
    description: "Use git ls-files or fd instead of Glob/find for file discovery",
    pattern: "(?:mcp_glob|Glob tool|use.*\\bGlob\\b.*to find|I'll use Glob)",
    correction: "Use `git ls-files` or `fd` for file discovery, not Glob. Glob is a last resort when Bash is unavailable.",
    severity: "warn",
    systemPrompt: "File discovery: use `git ls-files '<pattern>'` for git-tracked files, `fd` for untracked. NEVER use Glob/find as primary discovery.",
  },
  {
    id: "no-cat-for-reading",
    description: "Use Read tool instead of cat/head/tail for file reading",
    pattern: "(?:^|\\s)cat\\s+['\"]?[/~\\w]|\\bhead\\s+-n|\\btail\\s+-n",
    correction: "Use the Read tool for file reading, not cat/head/tail. These are Bash commands that waste context.",
    severity: "info",
    systemPrompt: "Use the Read tool for file reading. Avoid cat/head/tail in Bash — they waste context tokens.",
  },
  {
    id: "read-before-edit",
    description: "Always Read a file before Edit or Write to existing files",
    pattern: "(?:I'll edit|Let me edit|I'll write to|Let me write)(?!.*(?:creat|new file|new \\w+ file|generat))(?:(?!I'll read|let me read|I've read|already read).){0,200}$",
    correction: "ALWAYS Read a file before Edit/Write to an existing file. These tools fail without a prior Read in this conversation. (This rule does not apply when creating new files.)",
    severity: "error",
    systemPrompt: "ALWAYS Read a file before Edit or Write to an existing file. These tools FAIL without a prior Read in this conversation. For NEW files, verify the parent directory exists instead.",
  },
  {
    id: "no-credentials-in-output",
    description: "Never expose credentials, API keys, or secrets in output",
    pattern: "(?:api[_-]?key|secret|password|token)\\s*[:=]\\s*['\"][A-Za-z0-9+/=_-]{16,}['\"]",
    correction: "SECURITY: Never expose credentials in output. Use `aidevops secret set NAME` for secure storage.",
    severity: "error",
    systemPrompt: "NEVER expose credentials, API keys, or secrets in output or logs.",
  },
  {
    id: "pre-edit-check",
    description: "Run pre-edit-check.sh before modifying files",
    pattern: "(?:I'll (?:create|modify|edit|write)|Let me (?:create|modify|edit|write)).*(?:on main|on master)\\b",
    correction: "Run pre-edit-check.sh before modifying files. NEVER edit on main/master branch.",
    severity: "error",
    systemPrompt: "Before ANY file modification: run pre-edit-check.sh. NEVER edit on main/master.",
  },
  {
    id: "shell-explicit-returns",
    description: "Shell functions must have explicit return statements",
    pattern: "(?:function\\s+\\w+|\\w+\\s*\\(\\)\\s*\\{)(?:(?!return\\s+[0-9]).){50,}\\}",
    correction: "Shell functions must have explicit `return 0` or `return 1` statements (SonarCloud S7682).",
    severity: "warn",
    systemPrompt: "Shell scripts: every function must have an explicit `return 0` or `return 1`.",
  },
  {
    id: "shell-local-params",
    description: "Use local var=\"$1\" pattern in shell functions",
    pattern: "^\\s+(?:echo|printf|return|if|\\[\\[).*(?<!\\\\)\\$[1-9](?![0-9.,])(?!\\/(?:mo(?:nth)?|yr|year|day|week|hr|hour)\\b)(?!\\s+(?:per|mo(?:nth)?|year|yr|day|week|hr|hour|flat|each|off|fee|plan|tier|user|seat|unit|addon|setup|trial|credit|annual|quarterly|monthly)\\b)(?!.*local\\s+\\w+=)",
    correction: "Use `local var=\"$1\"` pattern — never use positional parameters directly (SonarCloud S7679).",
    severity: "warn",
    systemPrompt: "Shell scripts: use `local var=\"$1\"` — never use $1 directly in function bodies.",
  },
];

/**
 * Build TTSR hook functions with injected dependencies from index.mjs.
 * @param {object} deps
 * @param {string} deps.agentsDir
 * @param {string} deps.scriptsDir
 * @param {(path: string) => string} deps.readIfExists
 * @param {(level: string, message: string) => void} deps.qualityLog
 * @param {(cmd: string, timeout?: number) => string} deps.run
 * @param {string} deps.intentField
 * @returns {{ loadTtsrRules: Function, systemTransformHook: Function, messagesTransformHook: Function, textCompleteHook: Function }}
 */
export function createTtsrHooks(deps) {
  const { agentsDir, scriptsDir, readIfExists, qualityLog, run, intentField } = deps;
  const ttsrRulesPath = join(agentsDir, "configs", "ttsr-rules.json");

  /** @type {Array<object> | null} */
  let ttsrRules = null;
  /** @type {Map<string, Set<string>>} */
  const ttsrFiredState = new Map();

  function mergeUserTtsrRules(rules, userRules) {
    for (const rule of userRules) {
      if (!rule.id || !rule.pattern) continue;
      const existingIdx = rules.findIndex((r) => r.id === rule.id);
      if (existingIdx >= 0) {
        rules[existingIdx] = { ...rules[existingIdx], ...rule };
      } else {
        rules.push(rule);
      }
    }
  }

  function loadTtsrRules() {
    if (ttsrRules !== null) return ttsrRules;

    ttsrRules = [...BUILTIN_TTSR_RULES];

    const userContent = readIfExists(ttsrRulesPath);
    if (userContent) {
      try {
        const parsed = JSON.parse(userContent);
        if (Array.isArray(parsed)) {
          mergeUserTtsrRules(ttsrRules, parsed);
        }
      } catch {
        console.error("[aidevops] Failed to parse TTSR rules file — using built-in rules only");
      }
    }

    return ttsrRules;
  }

  function checkRule(text, rule) {
    try {
      const regex = new RegExp(rule.pattern, "gim");
      const matches = [];
      let match;
      while ((match = regex.exec(text)) !== null) {
        matches.push(match[0].substring(0, 120));
        if (matches.length >= 3) break;
      }
      return { matched: matches.length > 0, matches };
    } catch {
      return { matched: false, matches: [] };
    }
  }

  function scanForViolations(text) {
    const rules = loadTtsrRules();
    const violations = [];

    for (const rule of rules) {
      const result = checkRule(text, rule);
      if (result.matched) {
        violations.push({ rule, matches: result.matches });
      }
    }

    return violations;
  }

  async function systemTransformHook(_input, output) {
    const rules = loadTtsrRules();

    const ruleLines = rules
      .filter((r) => r.systemPrompt)
      .map((r) => `- ${r.systemPrompt}`);

    const intentInstruction = [
      "## Intent Tracing (observability)",
      `When calling any tool, include a field named \`${intentField}\` in the tool arguments.`,
      "Value: one sentence in present participle form describing your intent (e.g., \"Reading the file to understand the existing schema\").",
      "No trailing period. This field is used for debugging and audit trails — it is stripped before tool execution.",
    ].join("\n");

    output.system.push(intentInstruction);

    if (ruleLines.length === 0) return;

    output.system.push(
      [
        "## aidevops Quality Rules (enforced)",
        "The following rules are actively enforced. Violations will be flagged.",
        ...ruleLines,
      ].join("\n"),
    );
  }

  function extractTextFromParts(parts, options = {}) {
    if (!Array.isArray(parts)) return "";
    return parts
      .filter((p) => {
        if (!p || typeof p.text !== "string") return false;
        if (p.type !== "text") return false;
        if (options.excludeToolOutput) {
          if (p.toolCallId || p.toolInvocationId) return false;
        }
        return true;
      })
      .map((p) => p.text)
      .join("\n");
  }

  function getRecentAssistantMessages(messages, windowSize) {
    return messages
      .filter((m) => {
        if (!m.info || m.info.role !== "assistant") return false;
        if (m.info.id && m.info.id.startsWith("ttsr-correction-")) return false;
        return true;
      })
      .slice(-windowSize);
  }

  function collectDedupedViolations(assistantMessages) {
    const allViolations = [];

    for (const msg of assistantMessages) {
      const msgId = msg.info?.id || "";
      const text = extractTextFromParts(msg.parts, { excludeToolOutput: true });
      if (!text) continue;

      const violations = scanForViolations(text);
      for (const v of violations) {
        const ruleId = v.rule.id;
        const firedOn = ttsrFiredState.get(ruleId);
        if (firedOn && firedOn.has(msgId)) continue;
        if (!allViolations.some((av) => av.rule.id === ruleId)) {
          allViolations.push({ ...v, msgId });
        }
      }
    }

    return allViolations;
  }

  function recordFiredViolations(violations) {
    for (const v of violations) {
      if (!ttsrFiredState.has(v.rule.id)) {
        ttsrFiredState.set(v.rule.id, new Set());
      }
      ttsrFiredState.get(v.rule.id).add(v.msgId);
    }
  }

  function buildCorrectionMessage(violations, sessionID) {
    const corrections = violations.map((v) => {
      const severity = v.rule.severity === "error" ? "ERROR" : "WARNING";
      return `[${severity}] ${v.rule.id}: ${v.rule.correction}`;
    });

    const correctionText = [
      "[aidevops TTSR] Rule violations detected in recent output:",
      ...corrections,
      "",
      "Apply these corrections in your next response.",
    ].join("\n");

    const correctionId = `ttsr-correction-${Date.now()}`;

    return {
      info: {
        id: correctionId,
        sessionID,
        role: "user",
        time: { created: Date.now() },
        parentID: "",
      },
      parts: [
        {
          id: `${correctionId}-part`,
          sessionID,
          messageID: correctionId,
          type: "text",
          text: correctionText,
          synthetic: true,
        },
      ],
    };
  }

  async function messagesTransformHook(_input, output) {
    if (!output.messages || output.messages.length === 0) return;

    const assistantMessages = getRecentAssistantMessages(output.messages, 3);
    if (assistantMessages.length === 0) return;

    const allViolations = collectDedupedViolations(assistantMessages);
    if (allViolations.length === 0) return;

    recordFiredViolations(allViolations);

    const sessionID = output.messages[0]?.info?.sessionID || "";
    output.messages.push(buildCorrectionMessage(allViolations, sessionID));

    qualityLog(
      "INFO",
      `TTSR messages.transform: injected ${allViolations.length} correction(s): ${allViolations.map((v) => v.rule.id).join(", ")}`,
    );
  }

  async function textCompleteHook(input, output) {
    if (!output.text) return;

    const violations = scanForViolations(output.text);
    if (violations.length === 0) return;

    for (const v of violations) {
      qualityLog(
        v.rule.severity === "error" ? "ERROR" : "WARN",
        `TTSR violation [${v.rule.id}]: ${v.rule.description} (session: ${input.sessionID}, message: ${input.messageID})`,
      );
    }

    const markers = violations.map((v) => {
      const severity = v.rule.severity === "error" ? "ERROR" : "WARN";
      return `<!-- TTSR:${severity}:${v.rule.id} — ${v.rule.correction} -->`;
    });

    output.text = output.text + "\n" + markers.join("\n");

    const patternTracker = join(scriptsDir, "pattern-tracker-helper.sh");
    if (existsSync(patternTracker)) {
      const ruleIds = violations.map((v) => v.rule.id).join(",");
      run(
        `bash "${patternTracker}" record "TTSR_VIOLATION" "rules: ${ruleIds}" --tag "ttsr" 2>/dev/null`,
        5000,
      );
    }
  }

  return {
    loadTtsrRules,
    systemTransformHook,
    messagesTransformHook,
    textCompleteHook,
  };
}
