import { DESTINATIONS, type DestinationPath } from './destinations';

export type CommandGroup = 'Go' | 'Session' | 'Appearance' | 'Help';

export type PaletteAction =
  | { type: 'navigate'; path: DestinationPath }
  | {
      type: 'world-jump';
      target: 'world-memory' | 'world-projects' | 'world-terminal' | 'world-attention';
    }
  | { type: 'world-project'; projectName: string }
  | {
      type: 'session';
      intent: 'new-terminal' | 'restart-backend' | 'replay-onboarding';
    }
  | { type: 'theme'; theme: 'meadow' | 'dusk' | 'system' }
  | { type: 'help'; intent: 'shortcuts' };

export interface PaletteCommand {
  id: string;
  group: CommandGroup;
  title: string;
  hint?: string;
  keys?: readonly string[];
  keywords?: readonly string[];
  action: PaletteAction;
}

export const PALETTE_COMMANDS: readonly PaletteCommand[] = [
  ...DESTINATIONS.map<PaletteCommand>((destination) => ({
    id: `go:${destination.path}`,
    group: 'Go' as const,
    title: `Go to ${destination.label}`,
    hint: destination.question,
    keywords: [destination.label, destination.path.slice(1)],
    action: { type: 'navigate', path: destination.path },
  })),
  {
    id: 'go:world-memory',
    group: 'Go',
    title: 'Open memory archive',
    hint: 'Semantic place · card index on the world grounds',
    keywords: ['world', 'memory', 'archive', 'records'],
    action: { type: 'world-jump', target: 'world-memory' },
  },
  {
    id: 'go:world-projects',
    group: 'Go',
    title: 'Open project houses',
    hint: 'Semantic district · real project cottages on /world',
    keywords: ['world', 'project', 'house', 'grounds'],
    action: { type: 'world-jump', target: 'world-projects' },
  },
  {
    id: 'go:world-terminal',
    group: 'Go',
    title: 'Open terminal workstation',
    hint: 'Semantic object · focus Terminal on the world',
    keywords: ['world', 'terminal', 'pty'],
    action: { type: 'world-jump', target: 'world-terminal' },
  },
  {
    id: 'go:world-attention',
    group: 'Go',
    title: 'Open attention (Needs you)',
    hint: 'Attention board · open Needs you and current recovery items',
    keywords: ['world', 'office', 'attention', 'needs'],
    action: { type: 'world-jump', target: 'world-attention' },
  },
  {
    id: 'session:new-terminal',
    group: 'Session',
    title: 'New terminal session',
    hint: 'Open a PTY at this workstation',
    keywords: ['pty', 'shell', 'dock', 'workstation'],
    action: { type: 'session', intent: 'new-terminal' },
  },
  {
    id: 'session:restart-backend',
    group: 'Session',
    title: 'Restart backend',
    hint: 'Relaunch the supervised serve process',
    keywords: ['serve', 'crash'],
    action: { type: 'session', intent: 'restart-backend' },
  },
  {
    id: 'session:replay-onboarding',
    group: 'Session',
    title: 'Run first-run setup again',
    hint: 'Replay harness confirm, then enter the world',
    keywords: ['onboarding', 'setup', 'welcome'],
    action: { type: 'session', intent: 'replay-onboarding' },
  },
  {
    id: 'appearance:meadow',
    group: 'Appearance',
    title: 'Use Meadow theme',
    keywords: ['light', 'theme'],
    action: { type: 'theme', theme: 'meadow' },
  },
  {
    id: 'appearance:dusk',
    group: 'Appearance',
    title: 'Use Dusk theme',
    keywords: ['dark', 'theme'],
    action: { type: 'theme', theme: 'dusk' },
  },
  {
    id: 'appearance:system',
    group: 'Appearance',
    title: 'Use System theme',
    keywords: ['auto', 'theme'],
    action: { type: 'theme', theme: 'system' },
  },
  {
    id: 'help:shortcuts',
    group: 'Help',
    title: 'Keyboard shortcuts',
    keys: ['?'],
    keywords: ['bindings', 'hotkeys'],
    action: { type: 'help', intent: 'shortcuts' },
  },
];

export const SHORTCUTS: ReadonlyArray<{ keys: readonly string[]; action: string }> = [
  { keys: ['Ctrl', 'K'], action: 'Open the command palette' },
  { keys: ['Esc'], action: 'Close the innermost dialog' },
  { keys: ['?'], action: 'Show this shortcut map' },
];

export function filterCommands(commands: readonly PaletteCommand[], query: string): PaletteCommand[] {
  const terms = query.trim().toLowerCase().split(/\s+/).filter(Boolean);
  if (terms.length === 0) return [...commands];
  return commands.filter((command) => {
    const haystack = [command.title, command.hint ?? '', command.group, ...(command.keywords ?? [])]
      .join(' ')
      .toLowerCase();
    return terms.every((term) => haystack.includes(term));
  });
}
