import { describe, expect, it } from 'vitest';
import {
  authStatusLabel,
  mcpPath,
  providerAuthTone,
  setMcpServerEnabled,
  skillsPath,
  type ConfiguredMcpServer,
} from './workspace-capabilities';

describe('provider authentication labels', () => {
  it('only calls the native verified state signed in', () => {
    expect(authStatusLabel('verified')).toBe('Sign-in verified');
    expect(authStatusLabel('probe-present')).toBe('Probe available; sign-in not verified');
    expect(authStatusLabel('probe-missing')).toBe('No native sign-in probe');
    expect(authStatusLabel('unknown')).toBe('Sign-in unknown');
  });

  it('does not style an unknown or unverified probe as authenticated', () => {
    expect(providerAuthTone('verified')).toBe('ok');
    expect(providerAuthTone('probe-present')).toBe('warn');
    expect(providerAuthTone('unknown')).toBe('idle');
  });
});

describe('workspace capability routes', () => {
  it('encodes a workspace path without altering it', () => {
    const workspace = '/home/user/Project with spaces';
    expect(new URL(skillsPath(workspace), 'http://localhost').searchParams.get('directory')).toBe(workspace);
    expect(new URL(mcpPath(workspace), 'http://localhost').searchParams.get('directory')).toBe(workspace);
  });

  it('leaves global capability discovery unscoped', () => {
    expect(skillsPath('')).toBe('/v1/skills');
    expect(mcpPath('')).toBe('/v1/mcp-servers');
  });

  it('fails closed for read-only imported MCP entries', async () => {
    const imported: ConfiguredMcpServer = {
      name: 'project-tool',
      scope: 'project-import',
      enabled: true,
      transport: 'stdio',
    };
    await expect(setMcpServerEnabled(imported, '/tmp/project', false)).rejects.toThrow('read-only');
  });
});
