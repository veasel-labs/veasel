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
