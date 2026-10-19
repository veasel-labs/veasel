#!/usr/bin/env node
/** Real-repo repo-map recall: labeled queries against a real checkout via the
 * published API (POST /v1/sessions + GET /v1/sessions/{id}/workspace/map).
 * Usage: VEASEL_BIN=/path/veasel node repo-map-recall.mjs <repoDir> <cases.json>
 * cases.json: [{ "query": "...", "expected": "relative/path" }] */
import { spawn } from "node:child_process"
import { mkdtempSync, readFileSync, rmSync } from "node:fs"
import { tmpdir } from "node:os"
import { join } from "node:path"
import net from "node:net"
import http from "node:http"

const repo = process.argv[2]
const cases = JSON.parse(readFileSync(process.argv[3], "utf8"))
const bin = process.env.VEASEL_BIN ?? "veasel"

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
		console.log(
			`${mark} pos=${pos} expected=${c.expected} files=${map.file_count} scanned=${map.files_scanned} top=${ranked.slice(0, 3).join(", ")}`,
		)
	}
	console.log(`recall@3 ${hit3}/${cases.length} recall@10 ${hit10}/${cases.length}`)
} finally {
	server.kill("SIGKILL")
	rmSync(dataDir, { recursive: true, force: true })
}
