import { Button, ErrorState, KeyValue, LoadingState, Mono, Panel, Stack, StatusBadge, type Tone } from '../../ui';
import type { ToolRecord } from './model/types';
import styles from './world.module.css';

function yesNo(value: boolean): { tone: Tone; label: string } {
  return value ? { tone: 'ok', label: 'yes' } : { tone: 'idle', label: 'no' };
}

export interface ToolRecordInspectorProps {
  toolId: string;
  /** Installed CLI provider from the canonical Veasel provider probe. */
  tool?: ToolRecord | null;
  isPending?: boolean;
  error?: Error | null;
  /** Visible Back control — returns to project interior or world. */
  onBack: () => void;
  backLabel?: string;
  onRetry?: () => void;
}

/** Cozy World inspector for one discovered native coding provider. */
export function ToolRecordInspector({
  toolId,
  tool,
  isPending,
  error,
  onBack,
  backLabel = 'Back',
  onRetry,
}: ToolRecordInspectorProps) {
  const auth = tool?.authStatus ?? 'unknown';
  const authTone: Tone = auth === 'ready' ? 'ok' : auth === 'signed-out' ? 'warn' : 'idle';

  return (
    <Panel
      tone="notice"
      title="Coding agent"
      meta={toolId}
      actions={
        <Button type="button" onClick={onBack} aria-label={backLabel}>
          Back
        </Button>
      }
    >
      <div className={styles.detailInspector} role="region" aria-label={`Coding agent ${toolId}`}>
        {isPending ? (
          <LoadingState label="Checking installed agents" />
        ) : error ? (
          <ErrorState title="Could not check installed agents" error={error} onRetry={onRetry} />
        ) : !tool ? (
          <ErrorState
            title="Agent not in provider list"
            error={new Error(`GET /v1/providers/cli has no row for ${toolId}`)}
            onRetry={onRetry}
          />
        ) : (
          <Stack>
            <KeyValue
              items={[
                { label: 'Id', value: <Mono>{tool.id}</Mono> },
                {
                  label: 'Installed',
                  value: <StatusBadge tone={yesNo(tool.detected).tone} label={yesNo(tool.detected).label} />,
                },
                { label: 'Native sign-in', value: <StatusBadge tone={authTone} label={auth} /> },
                { label: 'Executable', value: tool.binary ? <Mono>{tool.binary}</Mono> : 'unknown' },
                { label: 'Version', value: tool.version || 'unknown' },
              ]}
            />
            {tool.authDetail ? <p className={styles.detailEmpty}>{tool.authDetail}</p> : null}
            {tool.signInHint ? (
              <p className={styles.detailEmpty}>
                Sign in with <Mono>{tool.signInHint}</Mono>
              </p>
            ) : null}
            {tool.launchBlocker ? <p className={styles.detailEmpty}>{tool.launchBlocker}</p> : null}
          </Stack>
        )}
      </div>
    </Panel>
  );
}
