import { spawnSync } from "node:child_process"
import { writeFileSync } from "node:fs"
import process from "node:process"
import { performance } from "node:perf_hooks"

const warmupCount = Number.parseInt(process.env.VEASEL_BENCH_WARMUPS ?? "3", 10)
const sampleCount = Number.parseInt(process.env.VEASEL_BENCH_SAMPLES ?? "30", 10)
const rssSampleCount = Number.parseInt(
	process.env.VEASEL_BENCH_RSS_SAMPLES ?? String(Math.min(sampleCount, 15)),
	10,
)
const measureRss = process.env.VEASEL_BENCH_RSS !== "0" && process.platform === "linux"
const timeoutMs = 15_000

if (!Number.isInteger(warmupCount) || warmupCount < 0 || warmupCount > 20) {
	throw new Error("VEASEL_BENCH_WARMUPS must be an integer from 0 to 20")
}
if (!Number.isInteger(sampleCount) || sampleCount < 5 || sampleCount > 500) {
	throw new Error("VEASEL_BENCH_SAMPLES must be an integer from 5 to 500")
}
if (!Number.isInteger(rssSampleCount) || rssSampleCount < 0 || rssSampleCount > 500) {
	throw new Error("VEASEL_BENCH_RSS_SAMPLES must be an integer from 0 to 500")
}

const agents = [
	{ id: "veasel-code", executable: process.env.VEASEL_BIN ?? "veasel" },
	{ id: "claude-code", executable: "claude" },
	{ id: "codex", executable: "codex" },
	{ id: "opencode", executable: "opencode" },
	{ id: "pi", executable: "pi" },
]
const operations = [
	{ id: "version", args: ["--version"] },
	{ id: "help", args: ["--help"] },
]

function runCli(agent, operation) {
	const started = performance.now()
	const result = spawnSync(agent.executable, operation.args, {
		encoding: "utf8",
		timeout: timeoutMs,
		windowsHide: true,
	})
	const elapsedMs = performance.now() - started
	if (result.error || result.status !== 0) {
		const detail = result.error?.code ?? `exit ${result.status ?? "unknown"}`
		return { elapsedMs, error: detail, version: null }
	}
	const firstOutputLine = `${result.stdout ?? ""}\n${result.stderr ?? ""}`
		.split(/\r?\n/u)
		.map((line) => line.trim())
		.find((line) => line.length > 0)
	return { elapsedMs, error: null, firstOutputLine: firstOutputLine ?? "(no output)" }
}

// Isolated child so RUSAGE_CHILDREN.ru_maxrss is for this sample only (Linux kB).
function sampleRssKb(executable, args) {
	const script = `
import json, resource, subprocess, sys
exe, *args = sys.argv[1:]
proc = subprocess.run([exe, *args], capture_output=True, text=True, timeout=${Math.floor(timeoutMs / 1000)})
rss = resource.getrusage(resource.RUSAGE_CHILDREN).ru_maxrss
print(json.dumps({"status": proc.returncode, "rss_kb": rss}))
`
	const result = spawnSync("python3", ["-c", script, executable, ...args], {
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

function percentile(sortedValues, percentileValue) {
	const rank = Math.max(1, Math.ceil(percentileValue * sortedValues.length))
	return sortedValues[rank - 1]
}

function summarize(values) {
	const sorted = [...values].sort((left, right) => left - right)
	return {
		samples: sorted.length,
		min_ms: Number(sorted[0].toFixed(3)),
		p50_ms: Number(percentile(sorted, 0.5).toFixed(3)),
		p95_ms: Number(percentile(sorted, 0.95).toFixed(3)),
		max_ms: Number(sorted.at(-1).toFixed(3)),
		mean_ms: Number((sorted.reduce((sum, value) => sum + value, 0) / sorted.length).toFixed(3)),
	}
}

function summarizeRss(values) {
	const sorted = [...values].sort((left, right) => left - right)
	return {
		samples: sorted.length,
		min_kb: sorted[0],
		p50_kb: percentile(sorted, 0.5),
		p95_kb: percentile(sorted, 0.95),
		max_kb: sorted.at(-1),
		mean_kb: Number((sorted.reduce((sum, value) => sum + value, 0) / sorted.length).toFixed(1)),
		method: "Linux RUSAGE_CHILDREN.ru_maxrss (kilobytes)",
	}
}

const measured = new Map(
	operations.map((operation) => [
		operation.id,
		new Map(
			agents.map((agent) => [
				agent.id,
				{ durations: [], rss: [], firstOutputLine: null, failures: 0, lastError: null },
			]),
		),
	]),
)
for (const operation of operations) {
	const operationResults = measured.get(operation.id)
	for (let index = 0; index < warmupCount; index += 1) {
		for (const agent of agents) {
			const result = runCli(agent, operation)
			const record = operationResults.get(agent.id)
			if (!result.error) record.firstOutputLine = result.firstOutputLine
			else {
				record.failures += 1
				record.lastError = result.error
			}
		}
	}

	for (let sample = 0; sample < sampleCount; sample += 1) {
		const rotation = sample % agents.length
		const order = [...agents.slice(rotation), ...agents.slice(0, rotation)]
		for (const agent of order) {
			const result = runCli(agent, operation)
			const record = operationResults.get(agent.id)
			if (result.error) {
				record.failures += 1
				record.lastError = result.error
			} else {
				record.firstOutputLine = result.firstOutputLine
				record.durations.push(result.elapsedMs)
			}
		}
	}

	if (measureRss && rssSampleCount > 0) {
		for (let sample = 0; sample < rssSampleCount; sample += 1) {
			for (const agent of agents) {
				const result = sampleRssKb(agent.executable, operation.args)
				const record = operationResults.get(agent.id)
				if (result.error) {
					record.lastError = record.lastError ?? result.error
					continue
				}
				record.rss.push(result.rssKb)
			}
		}
	}
}

const report = {
	schema: "veasel-cli-startup-benchmark/v1",
	scope: "process launch plus local --version and --help commands; no model requests",
	generated_at: new Date().toISOString(),
	platform: process.platform,
	architecture: process.arch,
	runtime: `Node.js ${process.version}`,
	warmups: warmupCount,
	requested_samples: sampleCount,
	timeout_ms: timeoutMs,
	memory: measureRss
		? {
				unit: "kilobytes",
				method: "Linux resource.getrusage(RUSAGE_CHILDREN).ru_maxrss for an isolated child",
				scope:
					"Peak RSS for process launch only; not idle server, interactive TUI, or task working set",
				requested_samples: rssSampleCount,
			}
		: undefined,
	operations: Object.fromEntries(
		operations.map((operation) => [
			operation.id,
			agents.map(({ id }) => {
				const record = measured.get(operation.id).get(id)
				return {
					id,
					first_output_line: record.firstOutputLine,
					failures: record.failures,
					last_error: record.lastError,
					...(record.durations.length > 0 ? summarize(record.durations) : { samples: 0 }),
					...(record.rss.length > 0 ? { rss_kb: summarizeRss(record.rss) } : {}),
				}
			}),
		]),
	),
}

const output = `${JSON.stringify(report, null, 2)}\n`
const outputIndex = process.argv.indexOf("--output")
if (outputIndex >= 0) {
	const outputPath = process.argv[outputIndex + 1]
	if (!outputPath) throw new Error("--output requires a file path")
	writeFileSync(outputPath, output)
}
process.stdout.write(output)
