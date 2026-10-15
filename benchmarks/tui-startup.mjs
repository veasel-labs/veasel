#!/usr/bin/env node
/**
 * Honest local TUI baselines: CLI --version/--help wall + RSS, and PTY time to
 * the connected home screen against an isolated local backend.
 *
 * Does not measure interactive rendering quality, model latency, or coding-task
 * performance. Document the host, binary version, and sample counts with every claim.
 */
import { spawn, spawnSync } from "node:child_process"
import { mkdtempSync, rmSync, writeFileSync } from "node:fs"
import { performance } from "node:perf_hooks"
import process from "node:process"
import { join } from "node:path"
import { tmpdir } from "node:os"
import net from "node:net"
import http from "node:http"

const warmupCount = Number.parseInt(process.env.VEASEL_BENCH_WARMUPS ?? "2", 10)
const sampleCount = Number.parseInt(process.env.VEASEL_BENCH_SAMPLES ?? "15", 10)
const ptySamples = Number.parseInt(process.env.VEASEL_TUI_PTY_SAMPLES ?? "5", 10)
const measureRss = process.env.VEASEL_BENCH_RSS !== "0" && process.platform === "linux"
const tuiBin = process.env.VEASEL_TUI_BIN ?? "veasel-tui"
const serverBin = process.env.VEASEL_BIN ?? "veasel"
const timeoutMs = 15_000

function percentile(sorted, p) {
	if (sorted.length === 0) return null
	const rank = (p / 100) * (sorted.length - 1)
	const low = Math.floor(rank)
	const high = Math.ceil(rank)
	if (low === high) return sorted[low]
	return sorted[low] + (sorted[high] - sorted[low]) * (rank - low)
}

function summarize(samples) {
	const sorted = [...samples].sort((a, b) => a - b)
	const sum = sorted.reduce((acc, value) => acc + value, 0)
	return {
		count: sorted.length,
		minMs: sorted[0] ?? null,
		medianMs: percentile(sorted, 50),
		p95Ms: percentile(sorted, 95),
		maxMs: sorted[sorted.length - 1] ?? null,
		meanMs: sorted.length ? sum / sorted.length : null,
	}
}

function runCli(args) {
	const started = performance.now()
	const result = spawnSync(tuiBin, args, {
		encoding: "utf8",
		timeout: timeoutMs,
		windowsHide: true,
	})
	const elapsedMs = performance.now() - started
	if (result.error || result.status !== 0) {
		return { elapsedMs, error: result.error?.code ?? `exit ${result.status ?? "unknown"}` }
	}
	return { elapsedMs, error: null, stdout: (result.stdout ?? "").trim() }
}

function sampleRssKb(args) {
	const script = `
import json, resource, subprocess, sys
exe, *args = sys.argv[1:]
proc = subprocess.run([exe, *args], capture_output=True, text=True, timeout=${Math.floor(timeoutMs / 1000)})
rss = resource.getrusage(resource.RUSAGE_CHILDREN).ru_maxrss
print(json.dumps({"status": proc.returncode, "rss_kb": rss}))
`
	const result = spawnSync("python3", ["-c", script, tuiBin, ...args], {
		encoding: "utf8",
		timeout: timeoutMs + 5_000,
		windowsHide: true,
	})
	if (result.error || result.status !== 0) {
		return { error: result.error?.code ?? `exit ${result.status ?? "unknown"}` }
	}
	try {
		const parsed = JSON.parse((result.stdout ?? "").trim())
		if (parsed.status !== 0) return { error: `exit ${parsed.status}` }
		return { rssKb: Number(parsed.rss_kb) }
	} catch (error) {
		return { error: `parse ${error}` }
	}
}

function freePort() {
	return new Promise((resolve, reject) => {
		const server = net.createServer()
		server.listen(0, "127.0.0.1", () => {
			const address = server.address()
			const port = typeof address === "object" && address ? address.port : 0
			server.close((error) => (error ? reject(error) : resolve(port)))
		})
		server.on("error", reject)
	})
}

function waitHealth(port, deadlineMs) {
	const deadline = Date.now() + deadlineMs
	return new Promise((resolve, reject) => {
		const attempt = () => {
			const req = http.get(`http://127.0.0.1:${port}/v1/health`, (res) => {
				res.resume()
				if (res.statusCode === 200) resolve()
				else if (Date.now() > deadline) reject(new Error(`health ${res.statusCode}`))
				else setTimeout(attempt, 40)
			})
			req.on("error", () => {
				if (Date.now() > deadline) reject(new Error("health timeout"))
				else setTimeout(attempt, 40)
			})
		}
		attempt()
	})
}

function resolveExecutable(name) {
	const probe = spawnSync("which", [name], { encoding: "utf8" })
	const path = (probe.stdout ?? "").trim().split("\n")[0]
	if (probe.status !== 0 || !path) throw new Error(`cannot resolve ${name}`)
	return path
}

async function measurePtyConnectedMs(tuiPath, serverPath) {
	const port = await freePort()
	const dataDir = mkdtempSync(join(tmpdir(), "veasel-tui-bench-"))
	// Keep a small allowlisted env so IDE/agent host variables cannot crash the
	// packaged TUI under pty.fork (matches scripts/standalone-tui-smoke.py intent).
	const env = {
		PATH: process.env.PATH ?? "/usr/bin",
		HOME: process.env.HOME ?? "",
		USER: process.env.USER ?? "",
		LANG: process.env.LANG ?? "C.UTF-8",
		TERM: "xterm-256color",
		COLORTERM: process.env.COLORTERM ?? "",
		VEASEL_PORT: String(port),
		VEASEL_DATA_DIR: dataDir,
		VEASEL_PLUGIN_DIR: join(dataDir, "plugins"),
		VEASEL_API_URL: `http://127.0.0.1:${port}`,
	}
	for (const name of Object.keys(env)) {
		if (!env[name]) delete env[name]
		if (/API_KEY|_TOKEN|_PAT|_SECRET_KEY/.test(name)) delete env[name]
	}
	const server = spawn(serverPath, ["serve"], {
		env,
		stdio: "ignore",
	})
	const script = `
import fcntl, os, pty, re, select, struct, sys, termios, time
tui, = sys.argv[1:]
child, terminal = pty.fork()
if child == 0:
    os.execve(tui, [tui], dict(os.environ))
fcntl.ioctl(terminal, termios.TIOCSWINSZ, struct.pack("HHHH", 24, 100, 0, 0))
output = bytearray()
started = time.monotonic()
deadline = started + 12
markers = (b"connected", b"SESSIONS", b"VEASEL")
while time.monotonic() < deadline:
    readable, _, _ = select.select([terminal], [], [], 0.05)
    if readable:
        try:
            chunk = os.read(terminal, 65536)
        except OSError:
            chunk = b""
        if chunk:
            output.extend(chunk)
        visible = re.sub(rb"\\x1b\\[[0-?]*[ -/]*[@-~]|\\x1b\\][^\\x07]*(?:\\x07|\\x1b\\\\)", b"", output)
        if all(marker in visible for marker in markers):
            print(f"{(time.monotonic() - started) * 1000:.3f}")
            try:
                os.kill(child, 9)
                os.waitpid(child, 0)
            except ProcessLookupError:
                pass
            sys.exit(0)
    finished, _ = os.waitpid(child, os.WNOHANG)
    if finished:
        sys.exit(2)
sys.exit(3)
`
	try {
		await waitHealth(port, 12_000)
		// execve requires an absolute path; PATH lookup is not performed.
		const result = spawnSync("python3", ["-c", script, tuiPath], {
			encoding: "utf8",
			env,
			timeout: 20_000,
		})
		if (result.status !== 0) {
			return { error: `pty exit ${result.status}: ${(result.stderr ?? "").slice(0, 200)}` }
		}
		const ms = Number.parseFloat((result.stdout ?? "").trim())
		if (!Number.isFinite(ms)) return { error: `bad pty timing: ${result.stdout}` }
		return { elapsedMs: ms }
	} finally {
		if (server.exitCode === null && server.signalCode === null) {
			server.kill("SIGINT")
			await new Promise((resolve) => {
				const timer = setTimeout(() => {
					server.kill("SIGKILL")
					resolve()
				}, 3000)
				server.on("exit", () => {
					clearTimeout(timer)
					resolve()
				})
			})
		}
		rmSync(dataDir, { recursive: true, force: true })
	}
}

const operations = [
	{ id: "version", args: ["--version"] },
	{ id: "help", args: ["--help"] },
]

const versionProbe = runCli(["--version"])
const report = {
	kind: "tui-startup",
	measuredAt: new Date().toISOString(),
	host: {
		platform: process.platform,
		arch: process.arch,
		release: spawnSync("uname", ["-r"], { encoding: "utf8" }).stdout?.trim() ?? null,
		cpus: spawnSync("nproc", { encoding: "utf8" }).stdout?.trim() ?? null,
	},
	binaries: {
		tui: tuiBin,
		server: serverBin,
		tuiVersionLine: versionProbe.error ? null : versionProbe.stdout,
	},
	method: {
		cli: `${warmupCount} warmups + ${sampleCount} samples per --version/--help; wall via performance.now(); Linux RSS via RUSAGE_CHILDREN.ru_maxrss (kB)`,
		ptyConnected: `${ptySamples} samples; Python pty.fork against isolated veasel serve; wall until visible markers connected+SESSIONS+VEASEL`,
		exclusions: "Not interactive render FPS, not model/token latency, not coding-task quality.",
	},
	cli: {},
	ptyConnectedMs: null,
}

for (const operation of operations) {
	for (let i = 0; i < warmupCount; i++) runCli(operation.args)
	const walls = []
	const rss = []
	let failures = 0
	for (let i = 0; i < sampleCount; i++) {
		const sample = runCli(operation.args)
		if (sample.error) {
			failures += 1
			continue
		}
		walls.push(sample.elapsedMs)
		if (measureRss) {
			const rssSample = sampleRssKb(operation.args)
			if (!rssSample.error) rss.push(rssSample.rssKb)
		}
	}
	report.cli[operation.id] = {
		wall: summarize(walls),
		rssKb: measureRss ? summarize(rss.map((kb) => kb)) : null,
		failures,
	}
	if (report.cli[operation.id].rssKb) {
		// summarize expects ms field names; remap for RSS clarity in JSON consumers
		const stats = report.cli[operation.id].rssKb
		report.cli[operation.id].rssKb = {
			count: stats.count,
			minKb: stats.minMs,
			medianKb: stats.medianMs,
			p95Kb: stats.p95Ms,
			maxKb: stats.maxMs,
			meanKb: stats.meanMs,
		}
	}
}

const tuiPath = resolveExecutable(tuiBin)
const serverPath = resolveExecutable(serverBin)
report.binaries.tuiPath = tuiPath
report.binaries.serverPath = serverPath

const ptyWalls = []
let ptyFailures = 0
for (let i = 0; i < ptySamples; i++) {
	const sample = await measurePtyConnectedMs(tuiPath, serverPath)
	if (sample.error) {
		ptyFailures += 1
		continue
	}
	ptyWalls.push(sample.elapsedMs)
}
report.ptyConnectedMs = {
	wall: summarize(ptyWalls),
	failures: ptyFailures,
}

const out = process.argv.includes("--output")
	? process.argv[process.argv.indexOf("--output") + 1]
	: null
const json = `${JSON.stringify(report, null, 2)}\n`
if (out) writeFileSync(out, json)
process.stdout.write(json)
