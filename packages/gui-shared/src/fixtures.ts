import type { GuiStatusData } from "./contracts";

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
      id: "repos",
      label: "Repos",
      description: "Read-only repository registry summary.",
    },
    {
      id: "settings",
      label: "Settings",
      description: "Settings file health and keys only.",
    },
    {
      id: "capabilities",
      label: "Capabilities",
      description: "Available and planned dashboard surfaces.",
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

export const unsafeSecretFixture = {
  secret_name: "GUI_TEST_SECRET",
  secret_value: "SECRET_SENTINEL_DO_NOT_RENDER",
  private_key: "-----BEGIN PRIVATE KEY-----\nfake\n-----END PRIVATE KEY-----",
  bearer: "Bearer fake-token-value",
  cookie: "sessionid=fake-cookie-value",
  credential_path: "/tmp/fake/credentials.json",
};
