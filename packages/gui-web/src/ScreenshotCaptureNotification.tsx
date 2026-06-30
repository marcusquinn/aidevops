import type { ReactElement } from "react";

export interface ScreenshotCapturedDetail {
  path: string;
  url: string;
}

interface WebKitExternalLinkWindow extends Window {
  webkit?: {
    messageHandlers?: {
      externalLink?: {
        postMessage: (href: string) => void;
      };
    };
  };
}

export function ScreenshotCaptureNotification({ notification, onDismiss }: { notification: ScreenshotCapturedDetail; onDismiss: () => void }): ReactElement {
  const revealScreenshot = () => {
    const webkit = (window as WebKitExternalLinkWindow).webkit;
    webkit?.messageHandlers?.externalLink?.postMessage(notification.url);
  };

  return (
    <div className="screenshot-capture-notification" role="status">
      <div>
        <strong>Screenshot captured</strong>
        <span>Saved to <button onClick={revealScreenshot} type="button">{notification.path}</button>; path copied to clipboard.</span>
      </div>
      <button aria-label="Dismiss screenshot notification" onClick={onDismiss} type="button">×</button>
    </div>
  );
}
