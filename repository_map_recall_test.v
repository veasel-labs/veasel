module main

import os

// Labeled recall evaluation for the repository map: one shared corpus, a set
// of natural-language queries, and the file a human would open first for each.
// Every labeled file must land in the top 3 ranked paths; the aggregate hit
// count is asserted so a ranking regression fails loudly instead of silently
// degrading context quality.
fn write_recall_fixture(root string, rel string, content string) {
	path := os.join_path(root, ...rel.split('/'))
	os.mkdir_all(os.dir(path)) or { panic(err) }
	os.write_file(path, content) or { panic(err) }
}

fn test_repository_map_labeled_recall_top3() {
	root := os.join_path(os.temp_dir(), 'veasel-repo-map-${os.getpid()}-recall')
	os.rmdir_all(root) or {}
	os.mkdir_all(root) or { panic(err) }
	defer {
		os.rmdir_all(root) or {}
	}
	write_recall_fixture(root, 'src/auth/session.v', 'module auth\n\npub fn open_session() {}\n\npub fn close_session() {}\n')
	write_recall_fixture(root, 'src/auth/tokens.v', 'module auth\n\npub fn validate_token() {}\n\npub fn mint_token() {}\n\nfn token_expiry() {}\n')
	write_recall_fixture(root, 'src/auth/session_test.v', 'module auth\n\nfn test_open_session() {}\n')
	write_recall_fixture(root, 'src/billing/invoice.v', 'module billing\n\npub fn invoice_total() {}\n\npub fn render_invoice() {}\n')
	write_recall_fixture(root, 'src/billing/tax.v', 'module billing\n\npub fn tax_rate() {}\n\npub fn apply_tax() {}\n')
	write_recall_fixture(root, 'src/billing/invoice_test.v', 'module billing\n\nfn test_invoice_total() {}\n')
	write_recall_fixture(root, 'src/report/render.v', 'module report\n\npub fn render_report() {}\n\npub fn report_chart() {}\n')
	write_recall_fixture(root, 'src/report/export.v', 'module report\n\npub fn export_csv() {}\n')
	write_recall_fixture(root, 'src/util/log.v', 'module util\n\npub fn log_line() {}\n')
	write_recall_fixture(root, 'src/util/time.v', 'module util\n\npub fn now_stamp() {}\n')
	write_recall_fixture(root, 'README.md', '# Recall corpus\n')

	cases := [
		RecallCase{'fix validate_token expiry handling', 'src/auth/tokens.v'},
		RecallCase{'invoice totals are wrong in billing', 'src/billing/invoice.v'},
		RecallCase{'render_report chart looks broken', 'src/report/render.v'},
		RecallCase{'please read src/billing/tax.v', 'src/billing/tax.v'},
		RecallCase{'session login flow opens a session', 'src/auth/session.v'},
		RecallCase{'export_csv writes the wrong columns', 'src/report/export.v'},
	]
	mut hits := 0
	for c in cases {
		result := build_repository_map(root, c.query, repository_map_default_budget_bytes) or {
			panic(err)
		}
		top := if result.ranked_paths.len > 3 {
			result.ranked_paths[..3]
		} else {
			result.ranked_paths
		}
		if top.any(it == c.expected) {
			hits++
		} else {
			eprintln('recall miss: query=${c.query} expected=${c.expected} top=${top}')
		}
	}
	assert hits == cases.len, 'repo-map recall ${hits}/${cases.len}, expected all labeled files in top 3'
}

struct RecallCase {
	query    string
	expected string
}

// Harder labeled cases: cross-reference centrality (the definer is named by
// nobody in the query), camelCase symbol mentions, and distractor files that
// repeat the query words without defining anything relevant.
fn test_repository_map_labeled_recall_hard_cases() {
	root := os.join_path(os.temp_dir(), 'veasel-repo-map-${os.getpid()}-recall-hard')
	os.rmdir_all(root) or {}
	os.mkdir_all(root) or { panic(err) }
	defer {
		os.rmdir_all(root) or {}
	}
	write_recall_fixture(root, 'src/core/engine.v', 'module core\n\npub fn schedule_loop() {}\n\npub fn engine_tick() {}\n')
	write_recall_fixture(root, 'src/core/job.v', 'module core\n\npub fn resume() {}\n')
	write_recall_fixture(root, 'src/core/subagent_job.v', 'module core\n\npub fn resume_subagent_job() {}\n')
	write_recall_fixture(root, 'src/desktop/lifecycle.v', 'module desktop\n\npub fn resume_extension() {}\n')
	write_recall_fixture(root, 'src/auth/session.v', 'module auth\n\npub fn open_session() { schedule_loop() }\n')
	write_recall_fixture(root, 'src/billing/invoice.v', 'module billing\n\npub fn invoice_total() { schedule_loop() }\n')
	write_recall_fixture(root, 'src/report/render.v', 'module report\n\npub fn render_report() { schedule_loop() }\n\npub fn generate_report() {}\n')
	write_recall_fixture(root, 'src/report/notes.v', 'module report\n\n// report report report generation notes\npub fn scratch_notes() {}\n')
	write_recall_fixture(root, 'src/util/log.v', 'module util\n\npub fn log_line() {}\n')
	write_recall_fixture(root, 'src/util/time.v', 'module util\n\npub fn now_stamp() {}\n')

	cases := [
		RecallCase{'the scheduling loop is slow under load', 'src/core/engine.v'},
		RecallCase{'report generation fails for big inputs', 'src/report/render.v'},
		RecallCase{'generateReport produces empty output', 'src/report/render.v'},
		RecallCase{'open_session never returns', 'src/auth/session.v'},
		RecallCase{'subagent job lifecycle resume', 'src/core/subagent_job.v'},
	]
	mut hits := 0
	for c in cases {
		result := build_repository_map(root, c.query, repository_map_default_budget_bytes) or {
			panic(err)
		}
		top := if result.ranked_paths.len > 3 {
			result.ranked_paths[..3]
		} else {
			result.ranked_paths
		}
		if top.any(it == c.expected) {
			hits++
		} else {
			eprintln('hard recall miss: query=${c.query} expected=${c.expected} top=${top}')
		}
	}
	assert hits == cases.len, 'hard repo-map recall ${hits}/${cases.len}, expected all labeled files in top 3'
}
