import { spawnSync } from "node:child_process"
import { writeFileSync } from "node:fs"
import process from "node:process"
import { performance } from "node:perf_hooks"

const warmupCount = Number.parseInt(process.env.VEASEL_BENCH_WARMUPS ?? "3", 10)
const sampleCount = Number.parseInt(process.env.VEASEL_BENCH_SAMPLES ?? "30", 10)
const timeoutMs = 15_000

if (!Number.isInteger(warmupCount) || warmupCount < 0 || warmupCount > 20) {
  throw new Error("VEASEL_BENCH_WARMUPS must be an integer from 0 to 20")
}
if (!Number.isInteger(sampleCount) || sampleCount < 5 || sampleCount > 500) {
  throw new Error("VEASEL_BENCH_SAMPLES must be an integer from 5 to 500")
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

function percentile(sortedValues, percentileValue) {
  const rank = Math.max(1, Math.ceil(percentileValue * sortedValues.length))
  return sortedValues[rank - 1]
}

function summarize(values) {
  const sorted = [...values].sort((left, right) => left - right)
  return {
    samples: sorted.length,
    min_ms: Number(sorted[0].toFixed(3)),
    p50_ms: Number(percentile(sorted, 0.50).toFixed(3)),
    p95_ms: Number(percentile(sorted, 0.95).toFixed(3)),
    max_ms: Number(sorted.at(-1).toFixed(3)),
    mean_ms: Number((sorted.reduce((sum, value) => sum + value, 0) / sorted.length).toFixed(3)),
  }
}

const measured = new Map(operations.map((operation) => [
  operation.id,
  new Map(agents.map((agent) => [agent.id, { durations: [], firstOutputLine: null, failures: 0, lastError: null }])),
]))
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
      }
      else {
        record.firstOutputLine = result.firstOutputLine
        record.durations.push(result.elapsedMs)
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
  operations: Object.fromEntries(operations.map((operation) => [
    operation.id,
    agents.map(({ id }) => {
      const record = measured.get(operation.id).get(id)
      return {
        id,
        first_output_line: record.firstOutputLine,
        failures: record.failures,
        last_error: record.lastError,
        ...(record.durations.length > 0 ? summarize(record.durations) : { samples: 0 }),
      }
    }),
  ])),
}

const output = `${JSON.stringify(report, null, 2)}\n`
const outputIndex = process.argv.indexOf("--output")
if (outputIndex >= 0) {
  const outputPath = process.argv[outputIndex + 1]
  if (!outputPath) throw new Error("--output requires a file path")
  writeFileSync(outputPath, output)
}
process.stdout.write(output)
