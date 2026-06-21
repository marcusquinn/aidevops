import { useEffect, useState, type ReactElement } from "react";
import type { GuiFileEntry, GuiFileExplorerData, GuiFilePreview, GuiFileRootId, GuiResponseEnvelope } from "@aidevops/gui-shared";
import { text } from "./app-model";
import { PathActions } from "./PathActions";
import { fetchFileExplorer, mockedFileExplorer } from "./status-client";

export function FileExplorerSurface({ rootId }: { rootId: GuiFileRootId }): ReactElement {
  const [relativePath, setRelativePath] = useState("");
  const [explorer, setExplorer] = useState<GuiResponseEnvelope<GuiFileExplorerData>>(() => mockedFileExplorer(rootId));
  const [markdownFormatted, setMarkdownFormatted] = useState(true);

  useEffect(() => {
    let cancelled = false;
    fetchFileExplorer(rootId, relativePath)
      .then((response) => {
        if (!cancelled) {
          setExplorer(response);
        }
      })
      .catch(() => {
        if (!cancelled) {
          setExplorer(mockedFileExplorer(rootId));
        }
      });

    return () => {
      cancelled = true;
    };
  }, [rootId, relativePath]);

  const data = explorer.data;
  const intro = explorerIntro(rootId, data.root.description);

  return (
    <section className="surface-page" aria-label={data.root.label}>
      <section className="panel explorer-panel">
        <div className="section-heading split-heading">
          <div>
            <p className="eyebrow">{data.root.path_ref}</p>
            <h2>{data.root.label}</h2>
            <p>{intro}</p>
          </div>
          <PathActions pathRef={data.current_path_ref} />
        </div>
        <div className="file-workspace">
          <ul className="file-list" aria-label={`${data.root.label} file list`}>
            <li>
              <button className="file-entry parent-entry" disabled={data.current_relative_path.length === 0} onClick={() => setRelativePath(parentPath(data.current_relative_path))} type="button">
                <span>↰</span>
                <strong>{text.parentDirectory}</strong>
              </button>
            </li>
            {data.entries.map((entry) => (
              <FileEntryButton entry={entry} key={entry.path_ref} setRelativePath={setRelativePath} />
            ))}
          </ul>
          <FilePreviewPanel markdownFormatted={markdownFormatted} preview={data.selected_preview} setMarkdownFormatted={setMarkdownFormatted} />
        </div>
      </section>
    </section>
  );
}

function FileEntryButton({ entry, setRelativePath }: { entry: GuiFileEntry; setRelativePath: (path: string) => void }): ReactElement {
  return (
    <li className="file-entry-row">
      <button className="file-entry" onClick={() => setRelativePath(entry.relative_path)} type="button">
        <span>{entry.kind === "directory" ? "▸" : "•"}</span>
        <strong>{entry.name}</strong>
        <small>{entry.kind}</small>
      </button>
      <PathActions pathRef={entry.path_ref} />
    </li>
  );
}

function FilePreviewPanel({ markdownFormatted, preview, setMarkdownFormatted }: {
  markdownFormatted: boolean;
  preview: GuiFilePreview | null;
  setMarkdownFormatted: (value: boolean) => void;
}): ReactElement {
  if (preview === null) {
    return <aside className="file-preview empty-preview"><p>{text.noPreview}</p></aside>;
  }

  if (preview.mode === "blocked") {
    return <aside className="file-preview empty-preview"><p>{preview.reason}</p></aside>;
  }

  const isMarkdown = preview.mode === "markdown";
  return (
    <aside className="file-preview">
      <div className="preview-header">
        <div>
          <p className="eyebrow">{preview.language || text.codeView}</p>
          <strong>{preview.path_ref}</strong>
        </div>
        {isMarkdown ? (
          <label className="toggle-row">
            <input checked={markdownFormatted} onChange={(event) => setMarkdownFormatted(event.currentTarget.checked)} type="checkbox" />
            <span>{text.markdownFormatted}</span>
          </label>
        ) : null}
      </div>
      {preview.truncated ? <p className="notice compact-notice">{text.truncated}</p> : null}
      {isMarkdown && markdownFormatted ? <MarkdownPreview content={preview.content} /> : <pre className="code-preview"><code>{preview.content}</code></pre>}
    </aside>
  );
}

function MarkdownPreview({ content }: { content: string }): ReactElement {
  return (
    <div className="markdown-preview">
      {content.split("\n").slice(0, 240).map((line, index) => renderMarkdownLine(line, index))}
    </div>
  );
}

function renderMarkdownLine(line: string, index: number): ReactElement {
  if (line.startsWith("### ")) {
    return <h4 key={`${index}:${line}`}>{line.slice(4)}</h4>;
  }
  if (line.startsWith("## ")) {
    return <h3 key={`${index}:${line}`}>{line.slice(3)}</h3>;
  }
  if (line.startsWith("# ")) {
    return <h2 key={`${index}:${line}`}>{line.slice(2)}</h2>;
  }
  if (line.startsWith("- ")) {
    return <p className="markdown-bullet" key={`${index}:${line}`}>{line}</p>;
  }

  return <p key={`${index}:${line}`}>{line.length > 0 ? line : "\u00a0"}</p>;
}

function explorerIntro(rootId: GuiFileRootId, agentsDescription: string): string {
  if (rootId === "agents") {
    return agentsDescription;
  }
  if (rootId === "config") {
    return text.configIntro;
  }

  return rootId === "localSetup" ? text.localSetupIntro : text.gitIntro;
}

function parentPath(relativePath: string): string {
  const parts = relativePath.split("/").filter(Boolean);
  parts.pop();
  return parts.join("/");
}
