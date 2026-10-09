module main

import os
import time

const benchmark_default_iterations = 500
const benchmark_max_iterations = 10_000

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
		_ = store.append_exchange(session.id, 'user prompt ${i}', 'assistant response ${i}') or {
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
	platform := os.uname()
	result := '{"benchmark":"sqlite_session_roundtrip","iterations":${iterations},"sessions_per_second":${iterations * 1_000_000 / elapsed_us},"elapsed_microseconds":${elapsed_us},"database":"sqlite_in_memory","platform":"${platform.sysname} ${platform.machine}","product_version":"${product_version}","operations_per_iteration":"create session, persist exchange, load messages and events"}'
	output_path := os.getenv('VEASEL_BENCH_OUTPUT')
	if output_path == '' {
		println(result)
	} else {
		os.write_file(output_path, result) or { panic('failed to write benchmark result: ${err}') }
	}
}
