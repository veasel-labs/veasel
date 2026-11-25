import { resolveVeaselBackendUrl } from './veasel-focus';

export interface CliProviderStatus {
  id: string;
  name: string;
  exec: string;
  protocol: string;
  installed: boolean;
  version: string;
  auth_probe_present: boolean;
  auth_state: 'verified' | 'signed-out' | 'probe-present' | 'probe-missing' | 'unknown';
  auth_method: string;
  account_mode: string;
  auth_error: string;
  permission_modes: string[];
  session_resume_verified: boolean;
  usage_reporting: string;
}

export interface DiscoveredSkill {
  key: string;
  name: string;
  description: string;
  source: string;
  scope: string;
  root: string;
  allowed_tools_declared: boolean;
  allowed_tools: string[];
}

export interface SkillRoot {
  path: string;
  source: string;
  scope: string;
  label: string;
}

export interface SkillCatalog {
  skills: DiscoveredSkill[];
  diagnostics: Array<{ code?: string; message?: string; severity?: string }>;
  roots: SkillRoot[];
}

export interface ConfiguredMcpServer {
  name: string;
  scope: 'user' | 'project' | 'project-import';
  config_file?: string;
  enabled: boolean;
  transport: 'stdio' | 'streamable-http';
  command?: string;
  args?: string[];
  cwd?: string;
  env_keys?: string[];
  url_origin?: string;
  header_names?: string[];
  credential?: string;
}

export interface McpCatalog {
  scope: 'user' | 'mixed';
  path?: string;
  project_path?: string;
  import_paths?: string[];
  servers: ConfiguredMcpServer[];
}

export async function veaselGet<T>(path: string, fetcher: typeof fetch = fetch): Promise<T> {
  const base = await resolveVeaselBackendUrl();
  if (!base) throw new Error('Veasel backend is not connected.');
  const response = await fetcher(`${base.replace(/\/$/, '')}${path}`, {
    headers: { Accept: 'application/json' },
  });
  const body = (await response.json().catch(() => null)) as { error?: unknown } | null;
  if (!response.ok) {
    const detail = typeof body?.error === 'string' ? body.error : `HTTP ${response.status}`;
    throw new Error(`Veasel API request failed: ${detail}`);
  }
  return body as T;
}

export async function setMcpServerEnabled(
  server: ConfiguredMcpServer,
  workspace: string,
  enabled: boolean,
  fetcher: typeof fetch = fetch,
): Promise<ConfiguredMcpServer> {
  if (server.scope === 'project-import') throw new Error('Imported MCP configuration is read-only.');
  if (server.scope === 'project' && !workspace)
    throw new Error('Select a workspace before changing project MCP settings.');
  const query = new URLSearchParams({ scope: server.scope });
  if (server.scope === 'project') query.set('directory', workspace);
  const base = await resolveVeaselBackendUrl();
  if (!base) throw new Error('Veasel backend is not connected.');
  const response = await fetcher(
    `${base.replace(/\/$/, '')}/v1/mcp-servers/${encodeURIComponent(server.name)}?${query.toString()}`,
    {
      method: 'PATCH',
      headers: { Accept: 'application/json', 'Content-Type': 'application/json' },
      body: JSON.stringify({ enabled }),
    },
  );
  const body = (await response.json().catch(() => null)) as { error?: unknown } | null;
  if (!response.ok) {
    const detail = body && typeof body.error === 'string' ? body.error : `HTTP ${response.status}`;
    throw new Error(`MCP setting was not changed: ${detail}`);
  }
  return body as ConfiguredMcpServer;
}

export function authStatusLabel(state: CliProviderStatus['auth_state']): string {
  switch (state) {
    case 'verified':
      return 'Sign-in verified';
    case 'signed-out':
      return 'Signed out';
    case 'probe-present':
      return 'Probe available; sign-in not verified';
    case 'probe-missing':
      return 'No native sign-in probe';
    default:
      return 'Sign-in unknown';
  }
}

export function providerAuthTone(state: CliProviderStatus['auth_state']): 'ok' | 'warn' | 'err' | 'idle' {
  if (state === 'verified') return 'ok';
  if (state === 'signed-out') return 'warn';
  if (state === 'probe-present') return 'warn';
  if (state === 'probe-missing') return 'idle';
  return 'idle';
}

export function skillsPath(path: string): string {
  const query = new URLSearchParams();
  if (path) query.set('directory', path);
  return `/v1/skills${query.size > 0 ? `?${query.toString()}` : ''}`;
}

export function mcpPath(path: string): string {
  const query = new URLSearchParams();
  if (path) query.set('directory', path);
  return `/v1/mcp-servers${query.size > 0 ? `?${query.toString()}` : ''}`;
}
