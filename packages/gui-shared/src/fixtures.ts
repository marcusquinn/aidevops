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
