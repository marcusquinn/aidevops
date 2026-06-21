import { GUI_FILE_ROOTS, type GuiFileExplorerData, type GuiStatusData } from "./contracts";

export const statusFixture: GuiStatusData = {
  aidevops_version: "unknown",
  update: {
    running_version: "unknown",
    installed_version: "unknown",
    restart_required: false,
    message: "The GUI app is using the latest installed aidevops version.",
  },
  runtime: {
    host: "local",
    api: "hono",
    read_only: true,
  },
  paths: [
    {
      label: "deployed agents",
      path_ref: "~/.aidevops/agents",
      health: "unchecked",
    },
    {
      label: "settings",
      path_ref: "~/.config/aidevops/settings.json",
      health: "unchecked",
    },
  ],
  helper_availability: [
    {
      name: "aidevops status",
      status: "unchecked",
    },
  ],
  navigation: [
    {
      id: "overview",
      label: "Overview",
      description: "Local setup, update, and API health.",
    },
    {
      id: "agents",
      label: "Agents",
      description: "Read-only file explorer for deployed agent files.",
    },
    {
      id: "config",
      label: "Config",
      description: "Read-only file explorer for aidevops config.",
    },
    {
      id: "git",
      label: "Git",
      description: "Read-only local git workspace browser.",
    },
    {
      id: "security",
      label: "Security",
      description: "Secret-reference-only trust boundary.",
    },
  ],
  settings: {
    path_ref: "~/.config/aidevops/settings.json",
    health: "unchecked",
    key_count: 0,
    keys: [],
    value_policy: "keys_only_no_values",
  },
  repos: {
    path_ref: "~/.config/aidevops/repos.json",
    health: "unchecked",
    total: 0,
    repos: [],
  },
  capabilities: [
    {
      id: "setup-status",
      label: "Setup/status",
      status: "available",
      doc_ref: "docs/gui/helper-api-contract.md:98",
    },
    {
      id: "repos",
      label: "Repository registry",
      status: "placeholder",
      doc_ref: "docs/gui/helper-api-contract.md:103",
    },
    {
      id: "settings",
      label: "Effective settings",
      status: "placeholder",
      doc_ref: "docs/gui/helper-api-contract.md:101",
    },
  ],
  secrets: [
    {
      name: "GITHUB_TOKEN",
      status: "unchecked",
    },
  ],
  placeholders: [
    "Settings, repos, routines, OpenCode sessions, and capabilities will be added as read-only adapters.",
  ],
};

export const fileExplorerFixture: GuiFileExplorerData = {
  root: GUI_FILE_ROOTS[0],
  current_path_ref: "~/.aidevops/agents",
  current_relative_path: "",
  entry_limit: 80,
  entries: [
    {
      name: "workflows",
      kind: "directory",
      path_ref: "~/.aidevops/agents/workflows",
      relative_path: "workflows",
      extension: "",
      preview_allowed: false,
    },
    {
      name: "AGENTS.md",
      kind: "file",
      path_ref: "~/.aidevops/agents/AGENTS.md",
      relative_path: "AGENTS.md",
      extension: ".md",
      preview_allowed: true,
    },
  ],
  selected_preview: {
    path_ref: "~/.aidevops/agents/AGENTS.md",
    relative_path: "AGENTS.md",
    mode: "markdown",
    language: "md",
    content: "# AI DevOps Framework\n\nRead-only local preview.",
    truncated: false,
    reason: "",
  },
};

export const unsafeSecretFixture = {
  secret_name: "GUI_TEST_SECRET",
  secret_value: "SECRET_SENTINEL_DO_NOT_RENDER",
  private_key: "-----BEGIN PRIVATE KEY-----\nfake\n-----END PRIVATE KEY-----",
  bearer: "Bearer fake-token-value",
  cookie: "sessionid=fake-cookie-value",
  credential_path: "/tmp/fake/credentials.json",
};
