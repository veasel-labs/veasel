module main

import os
import time
import json2

const repository_map_benchmark_files = 256
const repository_map_benchmark_source_bytes = 4096
const repository_map_benchmark_warmups = 2
const repository_map_benchmark_samples = 11

struct RepositoryMapRankingFixture {
mut:
	entries  []RepositoryMapEntry
	contents map[string]string
}

fn test_benchmark_repository_map_ranking() {
	if os.getenv('VEASEL_RUN_REPOSITORY_MAP_BENCHMARK') != '1' {
		return
	}
	mut elapsed_samples := []i64{cap: repository_map_benchmark_samples}
	mut score_samples := []f64{cap: repository_map_benchmark_samples}
	for _ in 0 .. repository_map_benchmark_warmups {
		_ = run_repository_map_ranking_sample()
	}
	for _ in 0 .. repository_map_benchmark_samples {
		elapsed, score := run_repository_map_ranking_sample()
		elapsed_samples << elapsed
		score_samples << score
	}
	mut sorted := elapsed_samples.clone()
	sorted.sort()
	mut raw := []string{cap: repository_map_benchmark_samples}
	for i, elapsed in elapsed_samples {
		raw << '{"sample":${i + 1},"elapsed_microseconds":${elapsed},"score_checksum":${score_samples[i]}}'
	}
	platform := os.uname()
	result := '{"benchmark":"repository_map_cross_reference_ranking",' +
		'"file_count":${repository_map_benchmark_files},' +
		'"source_bytes_per_file":${repository_map_benchmark_source_bytes},' +
		'"warmup_runs":${repository_map_benchmark_warmups},' +
		'"sample_count":${repository_map_benchmark_samples},' +
		'"elapsed_microseconds":{"p50":${sorted[5]},"p90":${sorted[9]}},' +
		'"samples":[${raw.join(',')}],' +
		'"platform":${json2.encode[string](platform.sysname + ' ' + platform.machine)},' +
		'"build_profile":${json2.encode[string](os.getenv('VEASEL_BENCH_BUILD_PROFILE'))},' +
		'"compiler_version":${json2.encode[string](os.getenv('VEASEL_BENCH_COMPILER_VERSION'))},' +
		'"source_revision":${json2.encode[string](os.getenv('VEASEL_BENCH_SOURCE_REVISION'))},' +
		'"scope":"cross-reference ranking only; fixture construction excluded"}'
	output_path := os.getenv('VEASEL_BENCH_OUTPUT')
	if output_path == '' {
		println(result)
	} else {
		os.write_file(output_path, result) or { panic('failed to write benchmark report: ${err}') }
	}
}

fn run_repository_map_ranking_sample() (i64, f64) {
	mut fixture := repository_map_ranking_fixture()
	stopwatch := time.new_stopwatch()
	boost_repository_map_cross_references(mut fixture.entries, fixture.contents, RepositoryMapHintSet{
		paths:  ['src/feature-17']
		idents: ['shared_handler']
	})
	elapsed := stopwatch.elapsed().microseconds()
	mut checksum := 0.0
	for entry in fixture.entries {
		checksum += entry.score
	}
	assert checksum > 0.0
	return elapsed, checksum
}

fn repository_map_ranking_fixture() RepositoryMapRankingFixture {
	mut entries := []RepositoryMapEntry{cap: repository_map_benchmark_files}
	mut contents := map[string]string{}
	for index in 0 .. repository_map_benchmark_files {
		path := 'src/feature-${index}/module_${index}.v'
		mut symbols := []RepositoryMapSymbol{cap: 4}
		for symbol_index in 0 .. 4 {
			symbols << RepositoryMapSymbol{
				name: 'fn_symbol_${index * 4 + symbol_index}'
				kind: 'fn'
			}
		}
		entries << RepositoryMapEntry{
			path:    path
			score:   1.0
			symbols: symbols
		}
		mut content := 'module feature_${index}\n'
		for mention_index in 0 .. 8 {
			target := (index + repository_map_benchmark_files - 1 - mention_index % 4) % repository_map_benchmark_files
			content += 'fn_symbol_${target * 4 + mention_index % 4} '
		}
		content = content.repeat(repository_map_benchmark_source_bytes / content.len + 1)
		contents[path] = content[..repository_map_benchmark_source_bytes]
	}
	return RepositoryMapRankingFixture{
		entries:  entries
		contents: contents
	}
}
