import { fireEvent, render, screen } from '@testing-library/react';
import { createElement, useState } from 'react';
import { describe, expect, it, vi } from 'vitest';
import type { FocusPermissionMode } from '../../types/focus';
import { usePermissionModeGuard } from './PermissionModeGuard';

function Harness({ onApply }: { onApply: (mode: FocusPermissionMode) => void }) {
  const [mode, setMode] = useState<FocusPermissionMode>('ask');
  const guard = usePermissionModeGuard(mode, 'Claude Code', '/ws/demo', 'thread-1', (next) => {
    setMode(next);
    onApply(next);
  });
  return createElement(
    'div',
    null,
    createElement(
      'select',
      {
        'aria-label': 'Permissions',
        value: mode,
        onChange: (event: { target: { value: string } }) =>
          guard.choose(event.target.value as FocusPermissionMode),
      },
      createElement('option', { value: 'ask' }, 'Ask'),
      createElement('option', { value: 'bypass' }, 'Bypass'),
    ),
    guard.dialog,
  );
}

describe('usePermissionModeGuard', () => {
  it('applies non-bypass modes immediately', () => {
    const onApply = vi.fn();
    render(createElement(Harness, { onApply }));
    fireEvent.change(screen.getByLabelText('Permissions'), { target: { value: 'ask' } });
    expect(onApply).toHaveBeenCalledWith('ask');
  });

  it('requires confirmation before bypass and keeps the current mode until confirmed', () => {
    const onApply = vi.fn();
    render(createElement(Harness, { onApply }));
    fireEvent.change(screen.getByLabelText('Permissions'), { target: { value: 'bypass' } });
    expect(onApply).not.toHaveBeenCalled();
    expect(screen.getByText('Enable unrestricted access?')).toBeTruthy();
    fireEvent.click(screen.getByText('Keep current permissions'));
    expect(onApply).not.toHaveBeenCalled();
    fireEvent.change(screen.getByLabelText('Permissions'), { target: { value: 'bypass' } });
    fireEvent.click(screen.getByText('Enable without asking'));
    expect(onApply).toHaveBeenCalledWith('bypass');
  });
});
