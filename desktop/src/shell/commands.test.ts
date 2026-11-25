import { describe, expect, it } from 'vitest';
import { DESTINATIONS } from './destinations';
import { filterCommands, PALETTE_COMMANDS } from './commands';

describe('command palette routes', () => {
  it('offers only registered destinations and valid world jumps', () => {
    const paths = new Set(DESTINATIONS.map((destination) => destination.path));
    expect(paths).toEqual(new Set(['/focus', '/world', '/providers', '/terminal']));

    for (const command of PALETTE_COMMANDS) {
      switch (command.action.type) {
        case 'navigate':
          expect(paths.has(command.action.path), command.id).toBe(true);
          break;
        case 'world-jump':
          expect(['world-memory', 'world-projects', 'world-terminal', 'world-attention']).toContain(
            command.action.target,
          );
          break;
        case 'world-project':
          break;
        case 'session':
          if (command.action.intent === 'new-terminal') expect(paths.has('/terminal'), command.id).toBe(true);
          break;
        case 'theme':
        case 'help':
          break;
      }
    }
  });

  it('keeps the real Focus, World, Providers, and Terminal routes searchable', () => {
    for (const path of ['/focus', '/world', '/providers', '/terminal']) {
      expect(
        PALETTE_COMMANDS.some((command) => command.action.type === 'navigate' && command.action.path === path),
      ).toBe(true);
    }
  });

  it('keeps semantic world places and terminal actions', () => {
    const ids = PALETTE_COMMANDS.map((command) => command.id);
    expect(ids).toEqual(
      expect.arrayContaining([
        'go:world-memory',
        'go:world-projects',
        'go:world-terminal',
        'go:world-attention',
        'session:new-terminal',
      ]),
    );
    expect(filterCommands(PALETTE_COMMANDS, 'pty').map((command) => command.id)).toContain('session:new-terminal');
  });

  it('removes palette rows that target unregistered product views', () => {
    const ids = PALETTE_COMMANDS.map((command) => command.id);
    expect(ids).not.toEqual(
      expect.arrayContaining([
        'go:world-knowledge',
        'people:create',
        'people:import-munder',
        'library:review-installation',
        'go:switch-workspace',
        'session:start-job',
        'session:run-loop',
        'session:start-swarm',
        'session:next-needs-me',
      ]),
    );
  });

  it('filters commands by title and keywords', () => {
    expect(filterCommands(PALETTE_COMMANDS, 'providers').map((command) => command.id)).toContain('go:/providers');
    expect(filterCommands(PALETTE_COMMANDS, 'workstation').map((command) => command.id)).toContain(
      'session:new-terminal',
    );
  });
});
