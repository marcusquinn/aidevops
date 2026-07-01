import { createContext, type ReactElement, type ReactNode, useContext, useEffect, useMemo, useState } from "react";
import type { SurfaceId } from "./app-model";

export interface WorkspaceTourStep {
  body: string;
  target: string;
  title: string;
}

export type WorkspaceTourRegistry = Partial<Record<SurfaceId, WorkspaceTourStep[]>>;

interface WorkspaceTourContextValue {
  activeStep: WorkspaceTourStep | undefined;
  activeStepIndex: number;
  closeTour: () => void;
  hasTour: boolean;
  missingTarget: boolean;
  nextStep: () => void;
  startTour: () => void;
  stepCount: number;
  steps: WorkspaceTourStep[];
}

const WorkspaceTourContext = createContext<WorkspaceTourContextValue | undefined>(undefined);

export const workspaceTourRegistry = {
  aiSessions: [
    { body: "Choose a local repo/session context before the Turbostarter AI transport adapter is enabled.", target: '[data-tour="ai-session-list"]', title: "Session list" },
    { body: "Read the current AI transcript, attachments, tool status, and GenUI cards in one MessageScroller-compatible lane.", target: '[data-tour="ai-session-transcript"]', title: "AI transcript" },
    { body: "The prompt composer is disabled until audited write routes land, but its stable selector is ready for the session bridge.", target: '[data-tour="ai-composer"]', title: "Composer" },
  ],
  channels: [
    { body: "Channels use the shared conversation model and encrypted transport placeholder.", target: '[data-tour="comms-conversations"]', title: "Channel workspace" },
    { body: "Messages, system events, reactions, and Tambo DevOps cards render through the shared timeline.", target: '[data-tour="comms-message-timeline"]', title: "Channel timeline" },
  ],
  directMessages: [
    { body: "Direct and group DM threads share the same conversation shell as channels.", target: '[data-tour="comms-conversations"]', title: "DM workspace" },
    { body: "Protected payloads remain read-only until Vault policy and audited transport routes are connected.", target: '[data-tour="comms-message-timeline"]', title: "DM timeline" },
  ],
  workers: [
    { body: "Pulse worker health, systemic findings, and safe diagnostic actions collect on this operational dashboard.", target: '[data-tour="workers-surface"]', title: "Workers dashboard" },
  ],
  repos: [
    { body: "Repository context will connect local and remote repo adapters once audited read/write routes land.", target: '[data-tour="repos-surface"]', title: "Repos" },
  ],
  deployments: [
    { body: "Deployment activity, environments, releases, and rollout checks will appear here after deployment adapters land.", target: '[data-tour="deployments-surface"]', title: "Deployments" },
  ],
  settings: [
    { body: "Account, appearance, language, and notification preferences are grouped here while writes remain disabled.", target: '[data-tour="settings-surface"]', title: "Settings" },
  ],
} satisfies WorkspaceTourRegistry;

export function WorkspaceTourProvider({ activeSurface, children, registry = workspaceTourRegistry }: { activeSurface: SurfaceId; children: ReactNode; registry?: WorkspaceTourRegistry }): ReactElement {
  const steps = registry[activeSurface] ?? [];
  const [activeStepIndex, setActiveStepIndex] = useState(0);
  const [isOpen, setIsOpen] = useState(false);
  const [missingTarget, setMissingTarget] = useState(false);
  const activeStep = isOpen ? steps[activeStepIndex] : undefined;

  useEffect(() => {
    const nextSurface = activeSurface;
    if (!nextSurface) return;
    setIsOpen(false);
    setActiveStepIndex(0);
    setMissingTarget(false);
  }, [activeSurface]);

  useEffect(() => {
    if (!activeStep || typeof document === "undefined") {
      setMissingTarget(false);
      return;
    }

    const target = document.querySelector(activeStep.target);
    setMissingTarget(target === null);
    if (target instanceof HTMLElement) {
      target.scrollIntoView({ behavior: "smooth", block: "center" });
    }
  }, [activeStep]);

  const value = useMemo(() => ({
    activeStep,
    activeStepIndex,
    closeTour: () => setIsOpen(false),
    hasTour: steps.length > 0,
    missingTarget,
    nextStep: () => setActiveStepIndex((current) => current + 1 >= steps.length ? 0 : current + 1),
    startTour: () => {
      if (steps.length === 0) return;
      setActiveStepIndex(0);
      setIsOpen(true);
    },
    stepCount: steps.length,
    steps,
  }), [activeStep, activeStepIndex, missingTarget, steps]);

  return <WorkspaceTourContext.Provider value={value}>{children}</WorkspaceTourContext.Provider>;
}

export function useWorkspaceTour(): WorkspaceTourContextValue {
  const context = useContext(WorkspaceTourContext);
  if (!context) {
    throw new Error("useWorkspaceTour must be used inside WorkspaceTourProvider");
  }

  return context;
}
