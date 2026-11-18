/**
 * Focus session model (ADR-044). One canonical thread/turn/event vocabulary
 * shared by the Electron session runtime and the renderer. Provider adapters
 * normalise their native streams into these events; the journal on disk is
 * the only source of truth for history.
 *
 * Declaration-only module: it is imported by both the commonjs Electron
 * build (whose rootDir is electron/) and the renderer bundle.
 */

export type FocusProviderId = 'claude' | 'codex' | 'opencode' | 'muse';

/** Provider attached to an existing thread; canonical sessions may not record one. */
export type FocusThreadProviderId = FocusProviderId | 'unknown';

/** How much the agent may do without asking. Mapped per provider. */
export type FocusPermissionMode = 'ask' | 'accept-edits' | 'plan' | 'bypass';

export type FocusThreadStatus = 'idle' | 'running' | 'awaiting-approval' | 'awaiting-input' | 'interrupted' | 'error';

export interface FocusModelOption {
  id: string;
  label: string;
  description?: string;
}

export interface FocusProviderCapabilities {
  /** Structured Focus sessions are implemented for this provider. */
  sessions: boolean;
  approvals: boolean;
  interrupt: boolean;
  resume: boolean;
  modelSwitch: boolean;
  /** Whether a new message can be accepted during an active turn. Defaults to false. */
  sendWhileRunning?: boolean;
  /** Permission modes this adapter can actually apply for the provider. */
  permissionModes?: FocusPermissionMode[];
}

export interface FocusProviderStatus {
  id: FocusProviderId;
  label: string;
  installed: boolean;
  binary: string | null;
  version: string | null;
  /** `ready` only when the provider's own CLI reports a signed-in account. */
  auth: 'ready' | 'signed-out' | 'unknown';
  /** Human-readable, never contains account identifiers. */
  authDetail: string;
  /** Command the user can run to sign in, when signed out. */
  signInHint: string | null;
  models: FocusModelOption[];
  capabilities: FocusProviderCapabilities;
  checkedAt: string;
}

export interface FocusUsage {
  /** Fresh input tokens (including cache writes). */
  inputTokens: number;
  /** Input tokens served from the provider's prompt cache. */
  cachedInputTokens: number;
  outputTokens: number;
  /** Provider-reported API-equivalent cost; null when the provider reports none. */
  costUsd: number | null;
}

export interface FocusThread {
  id: string;
  title: string;
  workspace: string;
  projectName: string | null;
  cwd: string;
  provider: FocusThreadProviderId;
  /** The model the user picked; null means the provider's default. */
  model: string | null;
  /** The model the provider reported it is actually using. */
  resolvedModel: string | null;
  permissionMode: FocusPermissionMode;
  /** Provider-native session/thread id used for resume; null until the provider reports one. */
  providerSessionId: string | null;
  status: FocusThreadStatus;
  createdAt: string;
  updatedAt: string;
  turns: number;
  lastError: string | null;
  usage: FocusUsage;
}

export type FocusToolKind = 'command' | 'edit' | 'read' | 'search' | 'web' | 'agent' | 'other';

export type FocusApprovalDecision = 'allow' | 'allow-session' | 'deny';

export interface FocusUserInputOption {
  label: string;
  description: string;
}

export interface FocusUserInputQuestion {
  id: string;
  header: string;
  question: string;
  isOther: boolean;
  isSecret: boolean;
  options: FocusUserInputOption[];
}

export type FocusEventBody =
  | { type: 'user'; text: string }
  | { type: 'turn.started'; model: string | null }
  | { type: 'assistant'; itemId: string; text: string }
  | { type: 'reasoning'; itemId: string; text: string }
  | {
      type: 'tool.started';
      itemId: string;
      name: string;
      kind: FocusToolKind;
      title: string;
      input: unknown;
      /** Set when the call was made by a provider-native subagent. */
      parentItemId: string | null;
    }
  | { type: 'tool.finished'; itemId: string; ok: boolean; output: string; truncated: boolean }
  | {
      type: 'approval.requested';
      requestId: string;
      itemId: string | null;
      tool: string;
      kind: FocusToolKind;
      title: string;
      input: unknown;
      canAllowForSession: boolean;
    }
  | {
      type: 'approval.resolved';
      requestId: string;
      decision: FocusApprovalDecision;
      by: 'user' | 'interrupt' | 'shutdown';
    }
  | { type: 'userInput.requested'; requestId: string; questions: FocusUserInputQuestion[] }
  | { type: 'userInput.resolved'; requestId: string; by: 'user' | 'provider' | 'interrupt' | 'shutdown' }
  | {
      type: 'turn.finished';
      outcome: 'completed' | 'interrupted' | 'failed';
      /**
       * The server's finer, fact-derived outcome when it differs from the
       * three-way lifecycle above: a failed lifecycle that applied edits is
       * 'partial', a completed one with denied/expired approvals is
       * 'completed_with_denials'. Absent on older servers.
       */
      outcomeDetail?: 'completed_with_denials' | 'partial' | 'uncertain';
      detail: string | null;
      durationMs: number | null;
      usage: FocusUsage | null;
    }
  | { type: 'notice'; level: 'info' | 'warning' | 'error'; text: string };

export type FocusEvent = { seq: number; at: string; turn: number } & FocusEventBody;

export interface FocusThreadSnapshot {
  thread: FocusThread;
  events: FocusEvent[];
}

/** Pushed from main to the renderer. Deltas are live-only and never journaled. */
export type FocusLiveUpdate =
  | { kind: 'event'; threadId: string; event: FocusEvent }
  | { kind: 'delta'; threadId: string; itemId: string; channel: 'assistant' | 'reasoning'; text: string }
  | { kind: 'thread'; thread: FocusThread }
  /** The thread's lifecycle status changed (for example a turn started). */
  | { kind: 'status'; threadId: string; status: FocusThreadStatus }
  /** The backend stopped answering (or answered again) while a turn was being watched. */
  | { kind: 'connection'; threadId: string; online: boolean }
  | { kind: 'removed'; threadId: string }
  /** The server-side state changed (for example a new pending approval): re-read this thread. */
  | { kind: 'refresh'; threadId: string };

export interface FocusCreateThreadInput {
  cwd: string;
  projectName: string | null;
  provider: FocusProviderId;
  model: string | null;
  permissionMode: FocusPermissionMode;
  title?: string;
}

export interface FocusThreadPatch {
  title?: string;
  model?: string | null;
  permissionMode?: FocusPermissionMode;
}

export type FocusResult<T> = { ok: true; value: T } | { ok: false; error: string };

export interface FocusGitChange {
  path: string;
  /** Porcelain index (staged) column; ' ' when unchanged. */
  index: string;
  /** Porcelain working-tree column; ' ' when unchanged. */
  worktree: string;
  untracked: boolean;
}

export interface FocusGitChanges {
  branch: string;
  changes: FocusGitChange[];
  truncated: boolean;
}

export interface FocusGitDiff {
  path: string;
  staged: boolean;
  diff: string;
  truncated: boolean;
}

export interface FocusBridge {
  providers: (options?: { refresh?: boolean }) => Promise<FocusProviderStatus[]>;
  listThreads: () => Promise<FocusThread[]>;
  createThread: (input: FocusCreateThreadInput) => Promise<FocusResult<FocusThread>>;
  readThread: (id: string) => Promise<FocusThreadSnapshot | null>;
  updateThread: (id: string, patch: FocusThreadPatch) => Promise<FocusResult<FocusThread>>;
  deleteThread: (id: string) => Promise<FocusResult<true>>;
  send: (id: string, text: string) => Promise<FocusResult<true>>;
  respondApproval: (id: string, requestId: string, decision: FocusApprovalDecision) => Promise<FocusResult<true>>;
  respondUserInput: (id: string, requestId: string, answers: Record<string, string[]>) => Promise<FocusResult<true>>;
  interrupt: (id: string) => Promise<FocusResult<true>>;
  /** Read-only git working-tree view of the session's own directory. */
  gitChanges: (id: string) => Promise<FocusResult<FocusGitChanges>>;
  gitDiff: (id: string, path: string, staged: boolean) => Promise<FocusResult<FocusGitDiff>>;
  onUpdate: (listener: (update: FocusLiveUpdate) => void) => () => void;
}
