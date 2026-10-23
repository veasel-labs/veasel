#!/usr/bin/env node
/** Real-repo repo-map recall: labeled queries against a real checkout via the
 * published API (POST /v1/sessions + GET /v1/sessions/{id}/workspace/map).
 * Usage: VEASEL_BIN=/path/veasel node repo-map-recall.mjs <repoDir> <cases.json>
 * cases.json: [{ "query": "...", "expected": "relative/path" }] */
import { spawn, spawnSync } from "node:child_process"
import { createHash } from "node:crypto"
import { basename, join, relative, resolve } from "node:path"
import { existsSync, mkdtempSync, readFileSync, realpathSync, rmSync, writeFileSync } from "node:fs"
import { tmpdir } from "node:os"
import net from "node:net"
import http from "node:http"

const [, , repo, casesPath, outputFlag, outputPath] = process.argv
if (!repo || !casesPath || (outputFlag && (outputFlag !== "--output" || !outputPath))) {
	throw new Error(
		"Usage: VEASEL_BIN=/path/veasel node repo-map-recall.mjs <repoDir> <cases.json> [--output report.json]",
	)
}
const cases = JSON.parse(readFileSync(casesPath, "utf8"))
const bin = process.env.VEASEL_BIN ?? "veasel"

function commandOutput(command, args, cwd) {
	const result = spawnSync(command, args, { cwd, encoding: "utf8" })
	if (result.status !== 0) return null
	return result.stdout.trim()
}

function sha256(value) {
	return createHash("sha256").update(value).digest("hex")
}

function resolveExecutable(command) {
	const lookup = spawnSync(process.platform === "win32" ? "where" : "which", [command], {
		encoding: "utf8",
	})
	const found = lookup.stdout?.split(/\r?\n/, 1)[0]?.trim()
	if (found && existsSync(found)) return realpathSync(found)
	const explicit = resolve(command)
	return existsSync(explicit) ? realpathSync(explicit) : null
}

function sourceDiffDigest(outputPath) {
	const hash = createHash("sha256")
	const diff = spawnSync("git", ["diff", "HEAD", "--binary"], { encoding: "buffer" })
	if (diff.status !== 0) return { digest: null, untrackedSourceFiles: [] }
	hash.update(diff.stdout)
	const untracked = spawnSync("git", ["ls-files", "--others", "--exclude-standard", "-z"], {
		encoding: "utf8",
	})
	if (untracked.status !== 0) return { digest: null, untrackedSourceFiles: [] }
	const outputRelative = outputPath ? relative(process.cwd(), resolve(outputPath)) : ""
	const sourceFiles = untracked.stdout
		.split("\0")
		.filter((path) => path && /\.(v|c|h|m|mm|cc|cpp|hpp|inc)$/i.test(path))
		.filter((path) => path !== outputRelative)
		.sort()
	for (const path of sourceFiles) {
		hash.update(path)
		hash.update("\0")
		hash.update(readFileSync(resolve(path)))
	}
	return { digest: hash.digest("hex"), untrackedSourceFiles: sourceFiles }
}

function freePort() {
	return new Promise((resolve, reject) => {
		const s = net.createServer()
		s.once("error", reject)
		s.listen(0, "127.0.0.1", () => {
			const p = s.address().port
			s.close(() => resolve(p))
		})
	})
}
function req(port, method, path, body) {
	return new Promise((resolve, reject) => {
		const r = http.request(
			{ host: "127.0.0.1", port, path, method, headers: { "content-type": "application/json" } },
			(res) => {
				let data = ""
				res.on("data", (c) => (data += c))
				res.on("end", () => resolve(JSON.parse(data)))
			},
		)
		r.once("error", reject)
		if (body) r.write(JSON.stringify(body))
		r.end()
	})
}
async function waitHealth(port) {
	for (let i = 0; i < 100; i++) {
		try {
			const h = await req(port, "GET", "/v1/health")
			if (h.healthy) return
		} catch {}
		await new Promise((r) => setTimeout(r, 100))
	}
	throw new Error("health timeout")
}

const port = await freePort()
const dataDir = mkdtempSync(join(tmpdir(), "veasel-recall-"))
const env = {
	...process.env,
	VEASEL_PORT: String(port),
	VEASEL_DATA_DIR: dataDir,
	VEASEL_PLUGIN_DIR: join(dataDir, "plugins"),
}
const server = spawn(bin, ["serve"], { env, stdio: "ignore" })
try {
	await waitHealth(port)
	const session = await req(port, "POST", "/v1/sessions", { title: "recall", directory: repo })
	let hit3 = 0
	let hit10 = 0
	const results = []
	for (const c of cases) {
		const map = await req(
			port,
			"GET",
			`/v1/sessions/${session.id}/workspace/map?hint=${encodeURIComponent(c.query)}`,
		)
		const ranked = map.ranked_paths ?? []
		const pos = ranked.indexOf(c.expected)
		const mark = pos >= 0 && pos < 3 ? "HIT@3" : pos >= 0 && pos < 10 ? "hit@10" : "MISS"
		if (pos >= 0 && pos < 3) hit3++
		if (pos >= 0 && pos < 10) hit10++
		results.push({
			query: c.query,
			expected: c.expected,
			rank: pos < 0 ? null : pos + 1,
			top3: ranked.slice(0, 3),
			rankedPaths: ranked,
			fileCount: map.file_count,
			filesScanned: map.files_scanned,
		})
		console.log(
			`${mark} pos=${pos} expected=${c.expected} files=${map.file_count} scanned=${map.files_scanned} top=${ranked.slice(0, 3).join(", ")}`,
		)
	}
	console.log(`recall@3 ${hit3}/${cases.length} recall@10 ${hit10}/${cases.length}`)
	if (outputPath) {
		const version = commandOutput(bin, ["--version"])
		const binaryPath = resolveExecutable(bin)
		const source = sourceDiffDigest(outputPath)
		const report = {
			generatedAt: new Date().toISOString(),
			veasel: {
				version,
				sourceRevision: commandOutput("git", ["rev-parse", "HEAD"], process.cwd()),
				sourceDiffSha256: source.digest,
				untrackedSourceFiles: source.untrackedSourceFiles,
				binarySha256: binaryPath ? sha256(readFileSync(binaryPath)) : null,
				compilerVersion: process.env.VEASEL_COMPILER_VERSION ?? null,
				buildFlags: process.env.VEASEL_BUILD_FLAGS ?? null,
			},
			platform: { os: process.platform, arch: process.arch },
			repository: {
				name: basename(repo),
				revision: commandOutput("git", ["-C", repo, "rev-parse", "HEAD"]),
			},
			summary: { cases: cases.length, recallAt3: hit3, recallAt10: hit10 },
			results,
		}
		writeFileSync(outputPath, `${JSON.stringify(report, null, 2)}\n`)
		console.log(`report ${outputPath}`)
	}
} finally {
	server.kill("SIGKILL")
	rmSync(dataDir, { recursive: true, force: true })
}
