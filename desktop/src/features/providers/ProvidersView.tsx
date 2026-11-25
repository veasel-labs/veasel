import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query';
import {
  Button,
  ConfirmAction,
  EmptyState,
  ErrorState,
  Grid,
  KeyValue,
  LoadingState,
  Mono,
  PageHeader,
  Panel,
  Stack,
  StatusBadge,
  Table,
} from '../../ui';
import { useSessionContext } from '../../shell/useSessionContext';
import {
  authStatusLabel,
  mcpPath,
  providerAuthTone,
  skillsPath,
  setMcpServerEnabled,
  veaselGet,
  type CliProviderStatus,
  type McpCatalog,
  type SkillCatalog,
} from '../../data/workspace-capabilities';
import styles from './providers.module.css';

export default function ProvidersView() {
  const { context } = useSessionContext();
  const queryClient = useQueryClient();
  const toggleMcp = useMutation({
    mutationFn: ({ server, enabled }: { server: McpCatalog['servers'][number]; enabled: boolean }) =>
      setMcpServerEnabled(server, context.workspace, enabled),
    onSuccess: () => queryClient.invalidateQueries({ queryKey: ['veasel', 'mcp-servers', context.workspace] }),
  });
  const providers = useQuery({
    queryKey: ['veasel', 'providers-cli'],
    queryFn: () => veaselGet<CliProviderStatus[]>('/v1/providers/cli'),
    retry: false,
  });
  const skills = useQuery({
    queryKey: ['veasel', 'skills', context.workspace],
    queryFn: () => veaselGet<SkillCatalog>(skillsPath(context.workspace)),
    retry: false,
  });
  const mcp = useQuery({
    queryKey: ['veasel', 'mcp-servers', context.workspace],
    queryFn: () => veaselGet<McpCatalog>(mcpPath(context.workspace)),
    retry: false,
  });
  const refresh = () => {
    void providers.refetch();
    void skills.refetch();
    void mcp.refetch();
  };

  return (
    <>
      <PageHeader
        eyebrow="Providers & integrations"
        title="What Veasel can use"
        lede="Local CLI sign-in is verified only when that provider exposes a safe native status check. Workspace skills and MCP settings are inspected without importing files or revealing secret values."
        actions={
          <Button size="sm" onClick={refresh}>
            Refresh status
          </Button>
        }
      />
      <Stack>
        <Panel title="Coding providers" meta="Detected on this machine through their supported CLI status contracts">
          {providers.isPending ? <LoadingState label="Checking installed provider CLIs" /> : null}
          {providers.isError ? (
            <ErrorState
              title="Provider status is unavailable"
              error={providers.error}
              onRetry={() => void providers.refetch()}
            />
          ) : null}
          {providers.data ? (
            providers.data.length === 0 ? (
              <EmptyState title="No provider adapters are registered." />
            ) : (
              <div className={styles.providerGrid}>
                {providers.data.map((provider) => (
                  <article className={styles.provider} key={provider.id}>
                    <header className={styles.providerHeader}>
                      <h3>{provider.name}</h3>
                      <StatusBadge
                        tone={provider.installed ? 'ok' : 'idle'}
                        label={provider.installed ? 'Installed' : 'Missing'}
                      />
                    </header>
                    <KeyValue
                      items={[
                        {
                          label: 'Version',
                          value:
                            provider.installed && provider.version
                              ? provider.version
                              : provider.installed
                                ? 'Unknown'
                                : '—',
                        },
                        {
                          label: 'Sign-in',
                          value: (
                            <StatusBadge
                              tone={providerAuthTone(provider.auth_state)}
                              label={provider.installed ? authStatusLabel(provider.auth_state) : 'Not applicable'}
                            />
                          ),
                        },
                        ...(provider.installed && provider.exec
                          ? [{ label: 'Executable', value: <Mono>{provider.exec}</Mono> }]
                          : []),
                        ...(provider.installed && provider.protocol
                          ? [{ label: 'Adapter', value: provider.protocol }]
                          : []),
                        ...(provider.installed && provider.auth_method
                          ? [{ label: 'Login method', value: provider.auth_method }]
                          : []),
                        ...(provider.installed && provider.account_mode
                          ? [{ label: 'Account mode', value: provider.account_mode }]
                          : []),
                        ...(provider.installed && provider.auth_error
                          ? [{ label: 'Status detail', value: provider.auth_error }]
                          : []),
                        ...(provider.installed
                          ? [{ label: 'Last successful probe', value: 'Timestamp not reported by backend' }]
                          : []),
                        ...(provider.installed
                          ? [{ label: 'Model selection', value: 'Not reported by status endpoint' }]
                          : []),
                        ...(provider.installed
                          ? [
                              {
                                label: 'Session resume',
                                value: provider.session_resume_verified ? 'Verified' : 'Not verified',
                              },
                            ]
                          : []),
                        ...(provider.installed
                          ? [
                              {
                                label: 'Permission modes',
                                value: provider.permission_modes.length
                                  ? provider.permission_modes.join(', ')
                                  : 'Not reported',
                              },
                            ]
                          : []),
                        ...(provider.installed
                          ? [{ label: 'Quota', value: 'Unknown; this status check does not query quota' }]
                          : []),
                        ...(provider.installed
                          ? [{ label: 'Usage reporting', value: provider.usage_reporting || 'Not reported' }]
                          : []),
                      ]}
                    />
                  </article>
                ))}
              </div>
            )
          ) : null}
        </Panel>

        <Grid>
          <Panel title="Workspace skills" meta={context.workspace || 'User-level skill roots'}>
            {skills.isPending ? <LoadingState label="Discovering skills" /> : null}
            {skills.isError ? (
              <ErrorState
                title="Skills could not be discovered"
                error={skills.error}
                onRetry={() => void skills.refetch()}
              />
            ) : null}
            {skills.data ? (
              <>
                {skills.data.roots.length ? (
                  <details className={styles.summary}>
                    <summary>Scanned {skills.data.roots.length} skill roots</summary>
                    <ul>
                      {skills.data.roots.map((root) => (
                        <li key={`${root.source}:${root.path}`}>
                          {root.label}: <Mono>{root.path}</Mono> ({root.scope}, {root.source})
                        </li>
                      ))}
                    </ul>
                    <p>Skills are discovered in place; this view does not copy or execute them.</p>
                  </details>
                ) : null}
                {skills.data.skills.length ? (
                  <Table caption="Discovered skill metadata">
                    <thead>
                      <tr>
                        <th scope="col">Skill</th>
                        <th scope="col">Source</th>
                        <th scope="col">Scope</th>
                        <th scope="col">Tool declaration</th>
                      </tr>
                    </thead>
                    <tbody>
                      {skills.data.skills.map((skill) => (
                        <tr key={skill.key}>
                          <th scope="row">
                            <span>{skill.name}</span>
                            <small className={styles.description}>{skill.description}</small>
                          </th>
                          <td>{skill.source}</td>
                          <td>{skill.scope}</td>
                          <td>
                            {skill.allowed_tools_declared
                              ? `Declared: ${skill.allowed_tools.join(', ') || 'empty list'}`
                              : 'No allowlist declared'}
                          </td>
                        </tr>
                      ))}
                    </tbody>
                  </Table>
                ) : (
                  <EmptyState title="No skills discovered for this workspace." />
                )}
                {skills.data.diagnostics.length > 0 ? (
                  <p className={styles.notice} role="status">
                    {skills.data.diagnostics.length} discovery diagnostics are available from the Veasel backend; some
                    entries may be unreadable or invalid.
                  </p>
                ) : null}
              </>
            ) : null}
          </Panel>

          <Panel title="MCP servers" meta="Configuration is shown without secret values or command arguments">
            {mcp.isPending ? <LoadingState label="Discovering MCP servers" /> : null}
            {mcp.isError ? (
              <ErrorState
                title="MCP configuration could not be discovered"
                error={mcp.error}
                onRetry={() => void mcp.refetch()}
              />
            ) : null}
            {mcp.data ? (
              mcp.data.servers.length ? (
                <Table caption="Discovered MCP server configuration">
                  <thead>
                    <tr>
                      <th scope="col">Server</th>
                      <th scope="col">Scope</th>
                      <th scope="col">Transport</th>
                      <th scope="col">State</th>
                      <th scope="col">Declared access</th>
                    </tr>
                  </thead>
                  <tbody>
                    {mcp.data.servers.map((server) => (
                      <tr key={`${server.scope}:${server.name}`}>
                        <th scope="row">{server.name}</th>
                        <td>{server.scope}</td>
                        <td>{server.transport}</td>
                        <td>
                          <StatusBadge
                            tone={server.enabled ? 'ok' : 'idle'}
                            label={server.enabled ? 'Enabled in config' : 'Disabled'}
                          />
                          {server.scope !== 'project-import' ? (
                            <div className={styles.serverAction}>
                              <ConfirmAction
                                label={server.enabled ? 'Disable' : 'Enable'}
                                triggerVariant="ghost"
                                size="sm"
                                variant={server.enabled ? 'danger' : 'primary'}
                                title={`${server.enabled ? 'Disable' : 'Enable'} ${server.name}?`}
                                description={
                                  server.enabled
                                    ? 'This keeps the configuration but prevents this server from being offered to future sessions. Existing session permissions are unchanged.'
                                    : 'This makes the configured server available to future sessions. It does not approve or trust the server for any session.'
                                }
                                confirmLabel={server.enabled ? 'Disable server' : 'Enable server'}
                                busy={
                                  toggleMcp.isPending &&
                                  toggleMcp.variables?.server.name === server.name &&
                                  toggleMcp.variables.server.scope === server.scope
                                }
                                onConfirm={() => toggleMcp.mutate({ server, enabled: !server.enabled })}
                              />
                            </div>
                          ) : null}
                        </td>
                        <td>
                          {server.transport === 'streamable-http'
                            ? (server.url_origin ?? 'Origin not reported')
                            : (server.command?.split(/[\\/]/).at(-1) ?? 'Command not reported')}
                          {server.credential ? (
                            <small className={styles.description}>Credential reference: {server.credential}</small>
                          ) : null}
                          {server.env_keys?.length ? (
                            <small className={styles.description}>
                              Environment names: {server.env_keys.join(', ')}
                            </small>
                          ) : null}
                          {server.header_names?.length ? (
                            <small className={styles.description}>Header names: {server.header_names.join(', ')}</small>
                          ) : null}
                          {server.scope === 'project-import' ? (
                            <small className={styles.description}>
                              Read-only import from {server.config_file ?? 'a supported project config'}
                            </small>
                          ) : null}
                        </td>
                      </tr>
                    ))}
                  </tbody>
                </Table>
              ) : (
                <EmptyState title="No MCP servers were discovered." />
              )
            ) : null}
            {mcp.data?.import_paths?.length ? (
              <p className={styles.summary}>Read-only project sources: {mcp.data.import_paths.join(', ')}</p>
            ) : null}
          </Panel>
        </Grid>
        {toggleMcp.isError ? (
          <p className={styles.notice} role="alert">
            {toggleMcp.error.message}
          </p>
        ) : null}
        <p className={styles.footnote}>
          An enabled MCP configuration is available to new sessions; it does not mean the server is running or trusted
          by an active session. Imported project files remain read-only.
        </p>
        <p className={styles.footnote}>
          A verified CLI sign-in does not establish quota, model availability, or permission for API billing. No test
          prompts were sent.
        </p>
      </Stack>
    </>
  );
}
