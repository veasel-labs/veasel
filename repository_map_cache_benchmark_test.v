module main

import os
import time
import strings
import json2

const repository_map_benchmark_warmups = 2
const repository_map_benchmark_samples = 7
const repository_map_benchmark_files = 96
const repository_map_benchmark_symbols_per_file = 48

fn build_repository_map_benchmark_fixture(root string) int {
	mut total_bytes := 0
	for file_index in 0 .. repository_map_benchmark_files {
		mut content := strings.new_builder(repository_map_benchmark_symbols_per_file * 64)
		content.writeln('module benchmark')
		for symbol_index in 0 .. repository_map_benchmark_symbols_per_file {
			content.writeln('fn benchmark_symbol_${file_index}_${symbol_index}(value int) int { return value + ${symbol_index} }')
		}
		text := content.str()
		total_bytes += text.len
		path := os.join_path(root, 'src', 'module_${file_index:03}.v')
		os.mkdir_all(os.dir(path)) or { panic('failed to create benchmark source directory: ${err}') }
		os.write_file(path, text) or { panic('failed to write benchmark source file: ${err}') }
	}
	return total_bytes
}

fn run_repository_map_benchmark_baseline(root string, hint string) (RepositoryMapResult, i64) {
	stopwatch := time.new_stopwatch()
	result := build_repository_map(root, hint, repository_map_default_budget_bytes) or {
		panic('uncached repository map build failed: ${err}')
	}
	return result, stopwatch.elapsed().microseconds()
}

fn run_repository_map_benchmark_cached(root string, hint string,
	mut cache &RepositoryMapSymbolCache) (RepositoryMapResult, i64) {
	stopwatch := time.new_stopwatch()
	result := build_repository_map_with_cache(root, hint, repository_map_default_budget_bytes,
		mut cache) or {
		panic('cached repository map build failed: ${err}')
	}
	return result, stopwatch.elapsed().microseconds()
}

fn test_benchmark_repository_map_symbol_cache() {
	if os.getenv('VEASEL_RUN_REPOSITORY_MAP_BENCHMARK') != '1' {
		return
	}
	requested_root := os.getenv('VEASEL_BENCH_REPOSITORY_MAP_ROOT')
	is_fixture := requested_root == ''
	root := if is_fixture {
		os.join_path(os.temp_dir(), 'veasel-repo-map-benchmark-${os.getpid()}')
	} else {
		os.real_path(requested_root)
	}
	if is_fixture {
		os.rmdir_all(root) or {}
		os.mkdir_all(root) or { panic('failed to create repository map benchmark fixture: ${err}') }
	} else if !os.is_dir(root) {
		panic('repository map benchmark root does not exist')
	}
	defer {
		if is_fixture {
			os.rmdir_all(root) or {}
		}
	}
	total_bytes := if is_fixture { build_repository_map_benchmark_fixture(root) } else { 0 }
	hint := if is_fixture {
		'Inspect benchmark_symbol_42_17 in src/module_042.v'
	} else {
		'repository map ranking symbol extraction and cache'
	}
	mut cache := new_repository_map_symbol_cache()
	mut baseline_samples := []i64{cap: repository_map_benchmark_samples}
	mut cached_samples := []i64{cap: repository_map_benchmark_samples}
	mut expected_text := ''
	mut expected_paths := []string{}
	mut source_files := 0
	mut selected_symbols := 0
	for sample in 0 .. repository_map_benchmark_warmups + repository_map_benchmark_samples {
		baseline, baseline_us := run_repository_map_benchmark_baseline(root, hint)
		cached, cached_us := run_repository_map_benchmark_cached(root, hint, mut cache)
		assert baseline.text == cached.text
		assert baseline.ranked_paths == cached.ranked_paths
		source_files = baseline.measurement.files_scanned
		selected_symbols = baseline.measurement.symbol_count
		if sample == 0 {
			expected_text = baseline.text
			expected_paths = baseline.ranked_paths.clone()
		} else {
			assert baseline.text == expected_text
			assert baseline.ranked_paths == expected_paths
		}
		if sample >= repository_map_benchmark_warmups {
			baseline_samples << baseline_us
			cached_samples << cached_us
		}
	}
	baseline_samples.sort()
	cached_samples.sort()
	platform := os.uname()
	cache_hits := repository_map_symbol_cache_hits(mut cache)
	dataset := if is_fixture { 'synthetic' } else { 'repository' }
	benchmark_command := if is_fixture {
		'VEASEL_RUN_REPOSITORY_MAP_BENCHMARK=1 v test . -run-only test_benchmark_repository_map_symbol_cache'
	} else {
		'VEASEL_RUN_REPOSITORY_MAP_BENCHMARK=1 VEASEL_BENCH_REPOSITORY_MAP_ROOT=<repository-root> v test . -run-only test_benchmark_repository_map_symbol_cache'
	}
	encoded_benchmark_command := json2.encode[string](benchmark_command)
	v_commit := (os.read_file('.v-version') or { 'unknown' }).trim_space()
	result := '{"benchmark":"repository_map_symbol_cache","dataset":"${dataset}",' +
		'"source_files_scanned":${source_files},"symbols_in_map":${selected_symbols},' +
		'"source_bytes":${if is_fixture { total_bytes.str() } else { 'null' }},' +
		'"symbols_per_file_fixture":${if is_fixture {
			repository_map_benchmark_symbols_per_file.str()
		} else {
			'null'
		}},' +
		'"warmup_pairs":${repository_map_benchmark_warmups},"sample_pairs":${repository_map_benchmark_samples},' +
		'"uncached_build_us":{"p50":${baseline_samples[3]},"p95":${baseline_samples[6]}},' +
		'"cached_build_us":{"p50":${cached_samples[3]},"p95":${cached_samples[6]}},' +
		'"cache_hits":${cache_hits},"platform":"${platform.sysname} ${platform.machine}",' +
		'"product_version":"${product_version}","v_commit":"${v_commit}",' +
		'"measured_scope":"filesystem walk, source reads, symbol parsing, ranking, and rendering",' +
		'"benchmark_command":${encoded_benchmark_command}}'
	_ = json2.decode[map[string]json2.Any](result) or {
		panic('failed to encode repository map benchmark JSON: ${err}')
	}
	output_path := os.getenv('VEASEL_BENCH_OUTPUT')
	if output_path == '' {
		println(result)
	} else {
		os.write_file(output_path, result) or { panic('failed to write repository map benchmark result: ${err}') }
	}
}
