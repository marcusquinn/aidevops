import { type ReactElement, useEffect, useState } from "react";

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

export function ScreenshotCaptureNotificationHost(): ReactElement | null {
  const [screenshotNotification, setScreenshotNotification] = useState<ScreenshotCapturedDetail | undefined>();

  useEffect(() => {
    const showScreenshotNotification = (event: Event) => {
      const detail = (event as CustomEvent<Partial<ScreenshotCapturedDetail>>).detail;
      if (detail !== undefined && typeof detail.path === "string" && typeof detail.url === "string") {
        setScreenshotNotification({ path: detail.path, url: detail.url });
      }
    };

    window.addEventListener("aidevops:screenshot-captured", showScreenshotNotification);
    return () => window.removeEventListener("aidevops:screenshot-captured", showScreenshotNotification);
  }, []);

  return screenshotNotification ? <ScreenshotCaptureNotification notification={screenshotNotification} onDismiss={() => setScreenshotNotification(undefined)} /> : null;
}
