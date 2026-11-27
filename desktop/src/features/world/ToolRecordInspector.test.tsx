// eslint-disable-next-line import-x/named -- screen is re-exported by Testing Library React at runtime.
import { render, screen } from '@testing-library/react';
import { describe, expect, it } from 'vitest';
import { ToolRecordInspector } from './ToolRecordInspector';
import type { ToolRecord } from './model/types';

const fixture: ToolRecord = {
  id: 'claude',
  toolName: 'Claude Code',
  detected: true,
  configured: true,
  enabled: 'true',
  verified: true,
  version: '1.0.0',
  authStatus: 'ready',
  authDetail: 'Signed in',
  binary: '/usr/bin/claude',
};

describe('ToolRecordInspector', () => {
  it('shows installed provider and native authentication details', () => {
    render(<ToolRecordInspector toolId="claude" tool={fixture} onBack={() => undefined} />);

    expect(screen.getByRole('region', { name: /Coding agent claude/i })).toBeInTheDocument();
    expect(screen.getAllByText('claude').length).toBeGreaterThan(0);
    expect(screen.getByText('Native sign-in')).toBeInTheDocument();
    expect(screen.getByText('ready')).toBeInTheDocument();
    expect(screen.getByText('/usr/bin/claude')).toBeInTheDocument();
    expect(screen.getByText('1.0.0')).toBeInTheDocument();
    expect(screen.getByText('Signed in')).toBeInTheDocument();
    expect(screen.queryByText(/installation in Library/i)).not.toBeInTheDocument();
  });

  it('shows an unknown state when the provider is absent from the canonical probe', () => {
    render(<ToolRecordInspector toolId="claude" onBack={() => undefined} />);
    expect(screen.getByText('Agent not in provider list')).toBeInTheDocument();
  });

  it('shows native sign-in hint and launch blocker as guidance, not commands to execute', () => {
    render(
      <ToolRecordInspector
        toolId="claude"
        tool={{ ...fixture, authStatus: 'signed-out', signInHint: 'claude login', launchBlocker: 'Restart Veasel' }}
        onBack={() => undefined}
      />,
    );
    expect(screen.getByText('claude login')).toBeInTheDocument();
    expect(screen.getByText('Restart Veasel')).toBeInTheDocument();
    expect(screen.queryByRole('button', { name: /claude login/i })).not.toBeInTheDocument();
  });
});
