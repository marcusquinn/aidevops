import { existsSync } from "node:fs";
import type { GuiAppActionId, GuiManagedAppSummary } from "../../gui-shared/src";
import { collapseHome, expandHome, firstExistingPathRef, readBinaryVersion, resolveBinary } from "./status-adapter-utils";

type ManagedAppActionCommands = Partial<Record<GuiAppActionId, string>>;

interface ManagedAppDefinition {
  id: string;
  name: string;
  description: string;
  category: string;
  binary: string | null;
  version_args: string[];
  install_path_refs: string[];
  origin_website_url: string;
  origin_repo_url: string;
  aidevops_install: boolean;
  aidevops_update: boolean;
  latest_version_source: "aidevops" | "binary" | "unknown";
  action_commands: ManagedAppActionCommands;
}

type BinaryAppInput = Omit<ManagedAppDefinition, "action_commands" | "aidevops_install" | "aidevops_update" | "latest_version_source"> & {
  binary: string;
  aidevops_install?: boolean;
  aidevops_update?: boolean;
};

const TOOL_ACTIONS: ManagedAppActionCommands = {
  install: "./setup.sh --non-interactive",
  update: "aidevops update-tools --update",
};

const MANAGED_APP_DEFINITIONS: ManagedAppDefinition[] = [
  {
    id: "aidevops",
    name: "aidevops",
    description: "Framework CLI, agents, workflows, scripts, and local GUI assets.",
    category: "core",
    binary: "aidevops",
    version_args: ["--version"],
    install_path_refs: ["~/.aidevops/agents", "/opt/homebrew/bin/aidevops", "/usr/local/bin/aidevops"],
    origin_website_url: "https://aidevops.sh",
    origin_repo_url: "https://github.com/marcusquinn/aidevops.git",
    aidevops_install: true,
    aidevops_update: true,
    latest_version_source: "aidevops",
    action_commands: {
      install: "./setup.sh --non-interactive",
      update: "aidevops update",
      reinstall: "./setup.sh --non-interactive",
    },
  },
  {
    id: "agents",
    name: "Deployed agents",
    description: "Canonical aidevops agents, commands, workflows, scripts, and reference files.",
    category: "core",
    binary: null,
    version_args: [],
    install_path_refs: ["~/.aidevops/agents/VERSION"],
    origin_website_url: "https://aidevops.sh",
    origin_repo_url: "https://github.com/marcusquinn/aidevops.git",
    aidevops_install: true,
    aidevops_update: true,
    latest_version_source: "aidevops",
    action_commands: setupScopeActions("agents"),
  },
  {
    id: "gui-desktop",
    name: "aidevops.app",
    description: "Native macOS desktop launcher for the local GUI.",
    category: "desktop",
    binary: null,
    version_args: [],
    install_path_refs: ["~/Applications/aidevops.app", "/Applications/aidevops.app"],
    origin_website_url: "https://aidevops.sh",
    origin_repo_url: "https://github.com/marcusquinn/aidevops.git",
    aidevops_install: true,
    aidevops_update: true,
    latest_version_source: "aidevops",
    action_commands: setupScopeActions("gui-desktop"),
  },
  {
    id: "opencode",
    name: "OpenCode Beta",
    description: "Native OpenCode beta desktop app configured by aidevops.",
    category: "desktop",
    binary: null,
    version_args: [],
    install_path_refs: ["~/Applications/OpenCode AIDevOps.app", "~/Applications/OpenCode.app", "/Applications/OpenCode.app", "~/.config/opencode/opencode.json"],
    origin_website_url: "https://opencode.ai",
    origin_repo_url: "",
    aidevops_install: true,
    aidevops_update: true,
    latest_version_source: "binary",
    action_commands: setupScopeActions("opencode"),
  },
  binaryApp({ id: "opencode-cli", name: "OpenCode CLI", description: "Command-line runtime installed with OpenCode and configured by aidevops.", category: "cli", binary: "opencode", version_args: ["--version"], install_path_refs: ["/opt/homebrew/bin/opencode", "/usr/local/bin/opencode", "~/.bun/bin/opencode", "~/.config/opencode/opencode.json"], origin_website_url: "https://opencode.ai", origin_repo_url: "", aidevops_install: true, aidevops_update: true }),
  {
    id: "hooks",
    name: "Safety hooks",
    description: "Git, prompt, privacy, complexity, task-id, and canonical-install guards.",
    category: "safety",
    binary: null,
    version_args: [],
    install_path_refs: ["~/.aidevops/hooks", "~/.config/aidevops"],
    origin_website_url: "https://aidevops.sh",
    origin_repo_url: "https://github.com/marcusquinn/aidevops.git",
    aidevops_install: true,
    aidevops_update: true,
    latest_version_source: "aidevops",
    action_commands: setupScopeActions("hooks"),
  },
  {
    id: "pulse",
    name: "Pulse scheduler",
    description: "Launchd/cron supervisor for autonomous aidevops maintenance and dispatch routines.",
    category: "automation",
    binary: null,
    version_args: [],
    install_path_refs: ["~/Library/LaunchAgents/sh.aidevops.pulse.plist", "~/.aidevops/.agent-workspace/pulse"],
    origin_website_url: "https://aidevops.sh",
    origin_repo_url: "https://github.com/marcusquinn/aidevops.git",
    aidevops_install: true,
    aidevops_update: true,
    latest_version_source: "aidevops",
    action_commands: setupScopeActions("pulse"),
  },
  binaryApp({ id: "tabby", name: "Tabby terminal profiles", description: "Terminal profile sync for aidevops-managed shells.", category: "terminal", binary: "tabby", version_args: ["--version"], install_path_refs: ["~/Library/Application Support/tabby", "/Applications/Tabby.app"], origin_website_url: "https://github.com/Eugeny/tabby/releases/latest", origin_repo_url: "https://github.com/Eugeny/tabby/releases/latest" }),
  binaryApp({ id: "gh", name: "GitHub CLI", description: "GitHub issues, PRs, checks, releases, and API automation.", category: "git", binary: "gh", version_args: ["--version"], install_path_refs: ["/opt/homebrew/bin/gh", "/usr/local/bin/gh", "/usr/bin/gh"], origin_website_url: "", origin_repo_url: "" }),
  binaryApp({ id: "glab", name: "GitLab CLI", description: "GitLab repository, issue, merge request, and CI automation.", category: "git", binary: "glab", version_args: ["--version"], install_path_refs: ["/opt/homebrew/bin/glab", "/usr/local/bin/glab", "/usr/bin/glab"], origin_website_url: "", origin_repo_url: "" }),
  binaryApp({ id: "fd", name: "fd", description: "Fast file discovery for agents and developer workflows.", category: "search", binary: "fd", version_args: ["--version"], install_path_refs: ["/opt/homebrew/bin/fd", "/usr/local/bin/fd", "/usr/bin/fd"], origin_website_url: "", origin_repo_url: "" }),
  binaryApp({ id: "ripgrep", name: "ripgrep", description: "Fast code and text search used by agents and local diagnostics.", category: "search", binary: "rg", version_args: ["--version"], install_path_refs: ["/opt/homebrew/bin/rg", "/usr/local/bin/rg", "/usr/bin/rg"], origin_website_url: "", origin_repo_url: "" }),
  binaryApp({ id: "ripgrep-all", name: "ripgrep-all", description: "Document/archive-aware search companion for ripgrep.", category: "search", binary: "rga", version_args: ["--version"], install_path_refs: ["/opt/homebrew/bin/rga", "/usr/local/bin/rga", "/usr/bin/rga"], origin_website_url: "", origin_repo_url: "" }),
  binaryApp({ id: "shellcheck", name: "ShellCheck", description: "Shell script static analysis gate.", category: "quality", binary: "shellcheck", version_args: ["--version"], install_path_refs: ["/opt/homebrew/bin/shellcheck", "/usr/local/bin/shellcheck", "/usr/bin/shellcheck"], origin_website_url: "", origin_repo_url: "" }),
  binaryApp({ id: "shfmt", name: "shfmt", description: "Shell formatter used by local quality workflows.", category: "quality", binary: "shfmt", version_args: ["--version"], install_path_refs: ["/opt/homebrew/bin/shfmt", "/usr/local/bin/shfmt", "/usr/bin/shfmt"], origin_website_url: "", origin_repo_url: "" }),
  binaryApp({ id: "bun", name: "Bun", description: "JavaScript runtime used for the GUI and toolchain helpers.", category: "runtime", binary: "bun", version_args: ["--version"], install_path_refs: ["~/.bun/bin/bun", "/opt/homebrew/bin/bun", "/usr/local/bin/bun"], origin_website_url: "https://bun.sh/install", origin_repo_url: "" }),
  binaryApp({ id: "node", name: "Node.js", description: "JavaScript runtime required by npm-hosted helpers and frontend tooling.", category: "runtime", binary: "node", version_args: ["--version"], install_path_refs: ["/opt/homebrew/bin/node", "/usr/local/bin/node", "/usr/bin/node"], origin_website_url: "https://nodejs.org/", origin_repo_url: "" }),
  binaryApp({ id: "homebrew", name: "Homebrew", description: "macOS package manager used by setup/update when available.", category: "package manager", binary: "brew", version_args: ["--version"], install_path_refs: ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"], origin_website_url: "https://brew.sh", origin_repo_url: "https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh" }),
  binaryApp({ id: "qlty", name: "Qlty CLI", description: "Optional code quality aggregator installed by setup when selected.", category: "quality", binary: "qlty", version_args: ["--version"], install_path_refs: ["/opt/homebrew/bin/qlty", "/usr/local/bin/qlty", "~/.qlty/bin/qlty"], origin_website_url: "https://qlty.sh", origin_repo_url: "" }),
  binaryApp({ id: "rtk", name: "rtk", description: "Token-optimized GitHub/API helper used by interactive discovery.", category: "developer tooling", binary: "rtk", version_args: ["--version"], install_path_refs: ["~/.local/bin/rtk", "/opt/homebrew/bin/rtk", "/usr/local/bin/rtk"], origin_website_url: "https://github.com/rtk-ai/rtk#installation", origin_repo_url: "https://github.com/rtk-ai/rtk" }),
  binaryApp({ id: "cursor", name: "Cursor CLI", description: "Cursor command-line integration and config targets.", category: "cli", binary: "cursor", version_args: ["--version"], install_path_refs: ["~/.cursor/bin/cursor", "/Applications/Cursor.app"], origin_website_url: "https://cursor.com/install", origin_repo_url: "" }),
  binaryApp({ id: "zed", name: "Zed", description: "Optional editor installed by setup when selected.", category: "editor", binary: "zed", version_args: ["--version"], install_path_refs: ["/Applications/Zed.app", "/opt/homebrew/bin/zed", "/usr/local/bin/zed"], origin_website_url: "https://zed.dev/download", origin_repo_url: "", aidevops_install: false, aidevops_update: false }),
  binaryApp({ id: "orbstack", name: "OrbStack", description: "Optional local container/VM runtime for macOS development.", category: "runtime", binary: "orb", version_args: ["version"], install_path_refs: ["/Applications/OrbStack.app", "/opt/homebrew/bin/orb"], origin_website_url: "https://orbstack.dev/", origin_repo_url: "", aidevops_install: false, aidevops_update: false }),
  binaryApp({ id: "ollama", name: "Ollama", description: "Optional local model runtime for local AI workflows.", category: "ai runtime", binary: "ollama", version_args: ["--version"], install_path_refs: ["/Applications/Ollama.app", "/opt/homebrew/bin/ollama", "/usr/local/bin/ollama"], origin_website_url: "https://ollama.com", origin_repo_url: "" }),
];

export function readManagedApps(latestVersion: string, installedVersion: string): GuiManagedAppSummary[] {
  return MANAGED_APP_DEFINITIONS.map((definition) => managedAppSummary(definition, latestVersion, installedVersion));
}

function binaryApp(input: BinaryAppInput): ManagedAppDefinition {
  const aidevopsInstall = input.aidevops_install ?? true;
  const aidevopsUpdate = input.aidevops_update ?? true;

  return {
    id: input.id,
    name: input.name,
    description: input.description,
    category: input.category,
    binary: input.binary,
    version_args: input.version_args,
    install_path_refs: input.install_path_refs,
    origin_website_url: input.origin_website_url,
    origin_repo_url: input.origin_repo_url,
    aidevops_install: aidevopsInstall,
    aidevops_update: aidevopsUpdate,
    latest_version_source: "binary",
    action_commands: aidevopsUpdate ? TOOL_ACTIONS : { install: "./setup.sh --non-interactive" },
  };
}

function setupScopeActions(scope: string): ManagedAppActionCommands {
  return {
    install: `aidevops setup --scope ${scope}`,
    update: `aidevops setup --scope ${scope}`,
    reinstall: `aidevops setup --scope ${scope}`,
  };
}

function managedAppSummary(definition: ManagedAppDefinition, latestVersion: string, installedVersion: string): GuiManagedAppSummary {
  const binaryPath = definition.binary === null ? null : resolveBinary(definition.binary);
  const installPathRef = firstExistingPathRef(definition.install_path_refs) ?? definition.install_path_refs[0] ?? "not found";
  const installedVersionText = readManagedAppVersion(definition, binaryPath, installedVersion);
  const latestVersionText = definition.latest_version_source === "aidevops"
    ? latestVersion
    : definition.latest_version_source === "binary"
      ? installedVersionText
      : "unknown";

  return {
    id: definition.id,
    name: definition.name,
    description: definition.description,
    category: definition.category,
    origin_website_url: definition.origin_website_url,
    origin_repo_url: definition.origin_repo_url,
    aidevops_install: definition.aidevops_install,
    aidevops_update: definition.aidevops_update,
    installed_version: installedVersionText,
    latest_version: latestVersionText,
    install_path_ref: binaryPath === null ? installPathRef : collapseHome(binaryPath),
    status: binaryPath !== null || definition.install_path_refs.some((pathRef) => existsSync(expandHome(pathRef))) ? "found" : "missing",
    actions: (["install", "update", "reinstall", "remove"] as const).map((action) => managedAppAction(definition.action_commands, action)),
  };
}

function managedAppAction(actionCommands: ManagedAppActionCommands, action: GuiAppActionId): GuiManagedAppSummary["actions"][number] {
  return {
    id: action,
    label: action[0].toUpperCase() + action.slice(1),
    enabled: actionCommands[action] !== undefined,
    command_preview: actionCommands[action] ?? "No allowlisted command yet",
    confirmation: action === "remove" ? "required" : action === "reinstall" ? "recommended" : "none",
  };
}

function readManagedAppVersion(definition: ManagedAppDefinition, binaryPath: string | null, installedVersion: string): string {
  if (definition.latest_version_source === "aidevops") {
    return firstExistingPathRef(definition.install_path_refs) === null ? "not installed" : installedVersion;
  }

  if (binaryPath === null) {
    const existingPathRef = firstExistingPathRef(definition.install_path_refs);

    if (existingPathRef === null) {
      return "not installed";
    }

    return readAppBundleVersion(existingPathRef) ?? "installed";
  }

  return readBinaryVersion(binaryPath, definition.version_args);
}

function readAppBundleVersion(pathRef: string): string | null {
  if (!pathRef.endsWith(".app")) {
    return null;
  }

  return readBinaryVersion("/usr/libexec/PlistBuddy", ["-c", "Print :CFBundleShortVersionString", `${expandHome(pathRef)}/Contents/Info.plist`]);
}
