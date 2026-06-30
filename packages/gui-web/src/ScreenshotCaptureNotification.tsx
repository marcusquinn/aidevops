import { type ReactElement, useEffect, useRef, useState } from "react";

export interface ScreenshotCapturedDetail {
  path: string;
  url: string;
}

interface ScreenshotCapturedNotification extends ScreenshotCapturedDetail {
  id: number;
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
        <span>Saved to <button className="screenshot-path-button" onClick={revealScreenshot} title={notification.path} type="button">{notification.path}</button>; path copied to clipboard.</span>
      </div>
      <button aria-label="Dismiss screenshot notification" className="screenshot-dismiss-button" onClick={onDismiss} type="button">×</button>
    </div>
  );
}

export function ScreenshotCaptureNotificationHost(): ReactElement | null {
  const nextNotificationId = useRef(0);
  const [screenshotNotifications, setScreenshotNotifications] = useState<ScreenshotCapturedNotification[]>([]);

  useEffect(() => {
    const showScreenshotNotification = (event: Event) => {
      const detail = (event as CustomEvent<Partial<ScreenshotCapturedDetail>>).detail;
      if (detail !== undefined && typeof detail.path === "string" && typeof detail.url === "string") {
        nextNotificationId.current += 1;
        setScreenshotNotifications((current) => [...current, { id: nextNotificationId.current, path: detail.path, url: detail.url }]);
      }
    };

    window.addEventListener("aidevops:screenshot-captured", showScreenshotNotification);
    return () => window.removeEventListener("aidevops:screenshot-captured", showScreenshotNotification);
  }, []);

  return screenshotNotifications.length > 0 ? (
    <div className="screenshot-capture-notification-stack">
      {screenshotNotifications.map((notification) => (
        <ScreenshotCaptureNotification
          key={notification.id}
          notification={notification}
          onDismiss={() => setScreenshotNotifications((current) => current.filter((item) => item.id !== notification.id))}
        />
      ))}
    </div>
  ) : null;
}
