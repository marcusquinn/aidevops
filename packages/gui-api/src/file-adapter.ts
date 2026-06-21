import { existsSync, readdirSync, readFileSync, statSync } from "node:fs";
import { dirname, extname, join, relative, resolve, sep } from "node:path";
import {
  assertNoSecretSentinels,
  createEnvelope,
  GUI_FILE_ROOTS,
  type GuiFileEntry,
  type GuiFileExplorerData,
  type GuiFilePreview,
  type GuiFileRootDefinition,
  type GuiResponseEnvelope,
} from "../../gui-shared/src";

const MAX_ENTRIES = 80;
const MAX_PREVIEW_CHARS = 48_000;

export function readFileExplorer(
  rootId: string,
  requestedPath = "",
  observedAt?: string,
): GuiResponseEnvelope<GuiFileExplorerData> {
  const root = GUI_FILE_ROOTS.find((entry) => entry.id === rootId);
  if (root === undefined) {
    return createFileEnvelope(unknownRoot(), "", [], null, ["unknown_file_root"], observedAt);
  }

  const rootPath = resolvePathRef(root.path_ref);
  const targetPath = resolve(rootPath, requestedPath);
  if (!isInsideRoot(rootPath, targetPath)) {
    return createFileEnvelope(root, "", [], blockedPreview(root, "Path is outside the allowed root."), ["path_outside_root"], observedAt);
  }

  if (!existsSync(rootPath)) {
    return createFileEnvelope(root, "", [], null, ["root_missing"], observedAt);
  }

  const targetExists = existsSync(targetPath);
  const targetStats = targetExists ? statSync(targetPath) : null;
  const browsePath = targetStats?.isFile() ? dirname(targetPath) : targetPath;
  const currentRelativePath = toRelativePath(rootPath, browsePath);
  const entries = targetExists && existsSync(browsePath) ? readEntries(root, rootPath, browsePath) : [];
  const preview = targetStats?.isFile()
    ? readPreview(root, rootPath, targetPath)
    : null;

  return createFileEnvelope(root, currentRelativePath, entries, preview, targetExists ? [] : ["path_missing"], observedAt);
}

function createFileEnvelope(
  root: GuiFileRootDefinition,
  currentRelativePath: string,
  entries: GuiFileEntry[],
  selectedPreview: GuiFilePreview | null,
  errors: string[],
  observedAt?: string,
): GuiResponseEnvelope<GuiFileExplorerData> {
  const data: GuiFileExplorerData = {
    root,
    current_path_ref: toPathRef(root.path_ref, currentRelativePath),
    current_relative_path: currentRelativePath,
    entries,
    selected_preview: selectedPreview,
    entry_limit: MAX_ENTRIES,
  };
  const envelope = createEnvelope({
    operation_id: "filesystem.read",
    source: {
      surface: "filesystem",
      authority: "local read-only allowlist",
      path_refs: [root.path_ref],
    },
    data,
    errors,
    observed_at: observedAt,
  });

  assertNoSecretSentinels(envelope);
  return envelope;
}

function readEntries(root: GuiFileRootDefinition, rootPath: string, browsePath: string): GuiFileEntry[] {
  return readdirSync(browsePath, { withFileTypes: true })
    .filter((entry) => !entry.name.startsWith("."))
    .sort((first, second) => sortEntry(first.isDirectory(), first.name, second.isDirectory(), second.name))
    .slice(0, MAX_ENTRIES)
    .map((entry) => {
      const entryPath = join(browsePath, entry.name);
      const relativePath = toRelativePath(rootPath, entryPath);
      const extension = entry.isDirectory() ? "" : extname(entry.name).toLowerCase();
      return {
        name: entry.name,
        kind: entry.isDirectory() ? "directory" : "file",
        path_ref: toPathRef(root.path_ref, relativePath),
        relative_path: relativePath,
        extension,
        preview_allowed: root.id === "agents" && entry.isFile(),
      };
    });
}

function readPreview(root: GuiFileRootDefinition, rootPath: string, targetPath: string): GuiFilePreview {
  const relativePath = toRelativePath(rootPath, targetPath);
  const pathRef = toPathRef(root.path_ref, relativePath);
  if (root.preview_policy !== "agents_markdown_and_code") {
    return {
      path_ref: pathRef,
      relative_path: relativePath,
      mode: "blocked",
      language: "",
      content: "",
      truncated: false,
      reason: "Content preview is disabled for this root until redaction and write-action policies land.",
    };
  }

  const content = readFileSync(targetPath, "utf8");
  const extension = extname(targetPath).toLowerCase();
  return {
    path_ref: pathRef,
    relative_path: relativePath,
    mode: extension === ".md" ? "markdown" : extension.length > 0 ? "code" : "text",
    language: extension.replace(/^\./, "") || "text",
    content: content.length > MAX_PREVIEW_CHARS ? content.slice(0, MAX_PREVIEW_CHARS) : content,
    truncated: content.length > MAX_PREVIEW_CHARS,
    reason: "",
  };
}

function blockedPreview(root: GuiFileRootDefinition, reason: string): GuiFilePreview {
  return {
    path_ref: root.path_ref,
    relative_path: "",
    mode: "blocked",
    language: "",
    content: "",
    truncated: false,
    reason,
  };
}

function unknownRoot(): GuiFileRootDefinition {
  return {
    id: "agents",
    label: "Unknown root",
    path_ref: "~",
    description: "The requested file root is not in the GUI allowlist.",
    preview_policy: "metadata_only",
  };
}

function resolvePathRef(pathRef: string): string {
  if (!pathRef.startsWith("~/")) {
    return resolve(pathRef);
  }

  return resolve(join(process.env.HOME ?? "", pathRef.slice(2)));
}

function isInsideRoot(rootPath: string, targetPath: string): boolean {
  return targetPath === rootPath || targetPath.startsWith(`${rootPath}${sep}`);
}

function toRelativePath(rootPath: string, targetPath: string): string {
  return relative(rootPath, targetPath).split(sep).filter(Boolean).join("/");
}

function toPathRef(rootPathRef: string, relativePath: string): string {
  return relativePath.length > 0 ? `${rootPathRef}/${relativePath}` : rootPathRef;
}

function sortEntry(firstIsDirectory: boolean, firstName: string, secondIsDirectory: boolean, secondName: string): number {
  if (firstIsDirectory !== secondIsDirectory) {
    return firstIsDirectory ? -1 : 1;
  }

  return firstName.localeCompare(secondName);
}
