module main

import json2
import net.http
import time

// Capability negotiation with an already-running backend. A backend started
// before caller authentication existed answers every route without a token, so
// any local process can drive it (approve edits, add MCP servers, ...).
// Clients must never attach to, or send the API token to, such a server.
// Design and recovery procedure: docs/security/backend-caller-auth.md.

enum BackendKind {
	absent // nothing answers on the port
	secure // advertises bearer auth and rejects an unauthenticated protected route
	legacy // reachable but not a verified authenticated backend (old, spoofed, unparseable)
}

struct LivenessProbe {
	healthy  bool
	auth     string
	protocol int
}

struct LegacyOperationStatus {
	status string
}

struct LegacyOperationRow {
	operation LegacyOperationStatus
}

struct LegacyOperationsPage {
	operations []LegacyOperationRow
}

const auth_protocol_version = 1

// Probes WITHOUT any credential: an unverified server must never receive the
// token. Reachable-but-unverifiable is `legacy` (fail closed), never `secure`.
fn probe_backend_kind(port int) BackendKind {
	health := http.fetch(
		url:           'http://127.0.0.1:${port}/v1/health'
		read_timeout:  500 * time.millisecond
		write_timeout: 500 * time.millisecond
		max_retries:   1
	) or { return .absent }
	if health.status_code != 200 {
		return .legacy
	}
	liveness := json2.decode[LivenessProbe](health.body) or { return .legacy }
	if !liveness.healthy || liveness.auth != 'bearer' || liveness.protocol < auth_protocol_version {
		return .legacy
	}
	// A server that merely claims bearer auth must still reject a protected route.
	protected := http.fetch(
		url:           'http://127.0.0.1:${port}/v1/capabilities'
		read_timeout:  500 * time.millisecond
		write_timeout: 500 * time.millisecond
		max_retries:   1
	) or { return .legacy }
	if protected.status_code != 401 {
		return .legacy
	}
	return .secure
}

// Read-only, unauthenticated GET against the legacy API: how many recent turns
// are in flight. none when it cannot be determined.
fn legacy_active_operations(port int) ?int {
	response := http.fetch(
		url:           'http://127.0.0.1:${port}/v1/operations'
		read_timeout:  1 * time.second
		write_timeout: 1 * time.second
		max_retries:   1
	) or { return none }
	if response.status_code != 200 {
		return none
	}
	page := json2.decode[LegacyOperationsPage](response.body) or { return none }
	mut active := 0
	for row in page.operations {
		if row.operation.status in ['running', 'queued'] {
			active++
		}
	}
	return active
}

fn legacy_backend_message(port int, active ?int) string {
	impact := if count := active {
		if count > 0 {
			'${count} turn(s) are running or queued on it and will be interrupted if you stop it.'
		} else {
			'No running or queued turns were reported (checked with a read-only request).'
		}
	} else {
		'It may be running turns; stopping it interrupts them.'
	}
	return 'a legacy Veasel backend without caller authentication is running on 127.0.0.1:${port} (or another server that cannot prove authentication holds that port). Any local process can control it, so Veasel will not attach to it or send it credentials. ${impact} Sessions are stored in SQLite and are kept; only in-flight turns are lost.
To recover, stop it yourself and run the command again (Veasel never stops a process it did not start):
  Linux:   ss -ltnp "sport = :${port}"    then   kill <pid>
  macOS:   lsof -nP -iTCP:${port} -sTCP:LISTEN   then   kill <pid>
  Windows: netstat -ano | findstr :${port}   then   taskkill /PID <pid>
Or start a new backend on another port with VEASEL_PORT=<port> and a SEPARATE VEASEL_DATA_DIR: two backends must never share one data directory, and a legacy process holds its directory without a lock, so Veasel cannot verify that for you.'
}
