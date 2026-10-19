#!/usr/bin/env node
/**
 * Interactive PTY journey baseline: boots the packaged TUI against an isolated
 * local backend, waits for the connected home screen, opens /help with real
 * keystrokes, verifies the Help dialog renders, closes it with Esc, and checks
 * the home screen returns. Records per-step wall times and the visible screen
 * tail on failure so interactive regressions are diagnosable, not just counted.
 *
 * This proves one keyboard journey on this host only. It does not measure
 * model quality, coding-task success, or rendering fidelity beyond the
 * asserted markers.
 */
import { spawn, spawnSync } from "node:child_process"
import { mkdtempSync, rmSync, writeFileSync } from "node:fs"
import process from "node:process"
import { join } from "node:path"
import { tmpdir } from "node:os"
import net from "node:net"
import http from "node:http"

const tuiBin = process.env.VEASEL_TUI_BIN ?? "veasel-tui"
const serverBin = process.env.VEASEL_BIN ?? "veasel"
const out = process.argv.includes("--output")
	? process.argv[process.argv.indexOf("--output") + 1]
	: undefined

function freePort() {
	return new Promise((resolve, reject) => {
		const server = net.createServer()
		server.once("error", reject)
		server.listen(0, "127.0.0.1", () => {
			const port = server.address().port
			server.close(() => resolve(port))
		})
	})
}

function waitHealth(port, timeoutMs) {
	const started = Date.now()
	return new Promise((resolve, reject) => {
		const attempt = () => {
			const req = http.get(`http://127.0.0.1:${port}/v1/health`, (res) => {
				res.resume()
				if (res.statusCode === 200) return resolve()
				retry()
			})
			req.once("error", retry)
		}
		const retry = () => {
			if (Date.now() - started > timeoutMs) return reject(new Error("health timeout"))
			setTimeout(attempt, 100)
		}
		attempt()
	})
}

const journeyScript = `
import fcntl, os, pty, re, select, struct, sys, termios, time
tui, = sys.argv[1:]
child, terminal = pty.fork()
if child == 0:
    os.execve(tui, [tui], dict(os.environ))
fcntl.ioctl(terminal, termios.TIOCSWINSZ, struct.pack("HHHH", 24, 100, 0, 0))
output = bytearray()
started = time.monotonic()
ANSI = rb"\\x1b\\[[0-?]*[ -/]*[@-~]|\\x1b\\][^\\x07]*(?:\\x07|\\x1b\\\\)|\\x1b[()][0-9A-B]|\\x1b."

def visible():
    return re.sub(ANSI, b"", bytes(output))

def wait_for(markers, timeout, label, offset=0):
    global started
    step_started = time.monotonic()
    deadline = step_started + timeout
    while time.monotonic() < deadline:
        readable, _, _ = select.select([terminal], [], [], 0.05)
        if readable:
            try:
                chunk = os.read(terminal, 65536)
            except OSError:
                chunk = b""
            if chunk:
                output.extend(chunk)
            window = re.sub(ANSI, b"", bytes(output[offset:]))
            if all(marker in window for marker in markers):
                return (time.monotonic() - step_started) * 1000
        finished, _ = os.waitpid(child, os.WNOHANG)
        if finished:
            sys.stderr.write("JOURNEY_FAIL:" + label + ":tui exited\\n")
            sys.stderr.write("VISIBLE_TAIL:" + visible()[-800:].decode("utf-8", "replace"))
            sys.exit(2)
    sys.stderr.write("JOURNEY_FAIL:" + label + ":timeout\\n")
    sys.stderr.write("VISIBLE_TAIL:" + visible()[-800:].decode("utf-8", "replace"))
    sys.exit(3)

def send(data):
    os.write(terminal, data)

steps = []
steps.append(("connected", wait_for((b"connected", b"SESSIONS", b"VEASEL"), 12, "connected")))
send(b"/help\\r")
steps.append(("help-dialog", wait_for((b"Help", b"/connect"), 6, "help-dialog")))
esc_offset = len(output)
send(b"\\x1b")
steps.append(("help-dismissed", wait_for((b"SESSIONS",), 6, "help-dismissed", esc_offset)))
for name, ms in steps:
    print(f"{name}={ms:.3f}")
try:
    os.kill(child, 9)
    os.waitpid(child, 0)
except ProcessLookupError:
    pass
`

async function main() {
	const port = await freePort()
	const dataDir = mkdtempSync(join(tmpdir(), "veasel-tui-journey-"))
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
	for (const name of Object.keys(env)) if (!env[name]) delete env[name]
	const server = spawn(serverBin, ["serve"], { env, stdio: "ignore" })
	try {
		await waitHealth(port, 12_000)
		const result = spawnSync("python3", ["-c", journeyScript, tuiBin], {
			encoding: "utf8",
			env,
			timeout: 45_000,
		})
		const steps = {}
		for (const line of (result.stdout ?? "").split("\n")) {
			const eq = line.indexOf("=")
			if (eq > 0) steps[line.slice(0, eq)] = Number.parseFloat(line.slice(eq + 1))
		}
		const report = {
			generatedAt: new Date().toISOString(),
			platform: `${process.platform}-${process.arch}`,
			tuiBin,
			serverBin,
			journey: "connected -> /help dialog -> Esc -> home",
			pass: result.status === 0,
			stepsMs: steps,
		}
		if (result.status !== 0) {
			report.error = (result.stderr ?? "").slice(-1200)
		}
		const json = JSON.stringify(report, null, 2) + "\n"
		if (out) writeFileSync(out, json)
		process.stdout.write(json)
		process.exitCode = result.status === 0 ? 0 : 1
	} finally {
		server.kill("SIGKILL")
		rmSync(dataDir, { recursive: true, force: true })
	}
}

await main()
