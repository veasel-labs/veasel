module main

import os
import time
import json2

const benchmark_default_iterations = 500
const benchmark_max_iterations = 10_000
const benchmark_warmup_runs = 2
const benchmark_sample_runs = 21

fn run_session_store_sample(iterations int) int {
	mut store := open_store(':memory:') or { panic('failed to open SQLite store: ${err}') }
	defer {
		store.close() or { panic('failed to close SQLite store: ${err}') }
	}
	mut event_cursor := 0
	stopwatch := time.new_stopwatch()
	for i in 0 .. iterations {
		session := store.create_session(SessionInput{
			title:     'benchmark ${i}'
			directory: os.temp_dir()
		}) or { panic('failed to create benchmark session: ${err}') }
		_ = store.append_exchange(session.id, '', 'user prompt ${i}', 'assistant response ${i}',
			'', '') or {
			panic('failed to persist benchmark exchange: ${err}')
		}
		messages := store.messages_for_session(session.id, 20) or {
			panic('failed to load benchmark messages: ${err}')
		}
		assert messages.len == 2
		events := store.events_after(event_cursor) or { panic('failed to load benchmark events: ${err}') }
		assert events.len == 3
		event_cursor = events[events.len - 1].id
	}
	elapsed_us := stopwatch.elapsed().microseconds()
	assert elapsed_us > 0
	return elapsed_us
}

fn test_benchmark_session_store() {
	if os.getenv('VEASEL_RUN_BENCHMARK') != '1' {
		return
	}
	requested_iterations := os.getenv('VEASEL_BENCH_ITERATIONS').int()
	iterations := if requested_iterations > 0 && requested_iterations <= benchmark_max_iterations {
		requested_iterations
	} else {
		benchmark_default_iterations
	}
	for _ in 0 .. benchmark_warmup_runs {
		_ = run_session_store_sample(iterations)
	}
	mut elapsed_samples := []int{cap: benchmark_sample_runs}
	mut throughput_samples := []int{cap: benchmark_sample_runs}
	for _ in 0 .. benchmark_sample_runs {
		elapsed_us := run_session_store_sample(iterations)
		elapsed_samples << elapsed_us
		throughput_samples << iterations * 1_000_000 / elapsed_us
	}
	mut sorted_elapsed := elapsed_samples.clone()
	sorted_elapsed.sort()
	mut sorted_throughput := throughput_samples.clone()
	sorted_throughput.sort()
	mut samples_json := []string{cap: benchmark_sample_runs}
	for i, elapsed_us in elapsed_samples {
		samples_json << '{"sample":${i + 1},"elapsed_microseconds":${elapsed_us},"sessions_per_second":${throughput_samples[i]}}'
	}
	platform := os.uname()
	build_manifest_path := os.getenv('VEASEL_BENCH_BUILD_MANIFEST')
	build_manifest := if build_manifest_path == '' {
		'null'
	} else {
		os.read_file(build_manifest_path) or { panic('failed to read build manifest: ${err}') }
	}
	benchmark_command := json2.encode[string](os.getenv('VEASEL_BENCH_COMMAND'))
	result := '{"benchmark":"sqlite_session_roundtrip","iterations_per_sample":${iterations},' +
		'"warmup_runs":${benchmark_warmup_runs},"sample_count":${benchmark_sample_runs},' +
		'"elapsed_microseconds":{"p50":${sorted_elapsed[10]},"p90":${sorted_elapsed[18]},"p95":${sorted_elapsed[19]}},' +
		'"sessions_per_second":{"p50":${sorted_throughput[10]},"p90":${sorted_throughput[18]},"p95":${sorted_throughput[19]}},' +
		'"samples":[${samples_json.join(',')}],' +
		'"database":"sqlite_in_memory","platform":"${platform.sysname} ${platform.machine}",' +
		'"product_version":"${product_version}","operations_per_iteration":"create session, persist exchange, load messages and events",' +
		'"benchmark_command":${benchmark_command},"release_build":${build_manifest}}'
	output_path := os.getenv('VEASEL_BENCH_OUTPUT')
	if output_path == '' {
		println(result)
	} else {
		os.write_file(output_path, result) or { panic('failed to write benchmark result: ${err}') }
	}
}
