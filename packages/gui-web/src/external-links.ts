import type { MouseEvent as ReactMouseEvent } from "react";

interface WebKitExternalLinkWindow extends Window {
  webkit?: {
    messageHandlers?: {
      externalLink?: {
        postMessage: (href: string) => void;
      };
    };
  };
}

export function openExternalLink(event: ReactMouseEvent<HTMLAnchorElement>, href: string): void {
  event.stopPropagation();
  if (shouldUseBrowserDefault(event)) {
    return;
  }

  event.preventDefault();
  openExternalDestination(href);
}

function shouldUseBrowserDefault(event: ReactMouseEvent<HTMLAnchorElement>): boolean {
  return [event.defaultPrevented, event.metaKey, event.ctrlKey, event.shiftKey, event.altKey].some(Boolean);
}

function openExternalDestination(href: string): void {
  if (document.documentElement.dataset.desktopShell === "macos") {
    if (postNativeExternalLink(href)) {
      return;
    }

    const opened = window.open(href, "_blank", "noopener,noreferrer");
    if (opened !== null) {
      opened.opener = null;
    }
    return;
  }

  const opened = window.open(href, "_blank", "noopener,noreferrer");
  if (opened === null) {
    window.location.assign(href);
  } else {
    opened.opener = null;
  }
}

function postNativeExternalLink(href: string): boolean {
  const handler = (window as WebKitExternalLinkWindow).webkit?.messageHandlers?.externalLink;
  if (handler === undefined) {
    return false;
  }

  try {
    handler.postMessage(href);
    return true;
  } catch {
    return false;
  }
}
