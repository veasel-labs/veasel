module main

import os

fn repository_map_stem(name string) string {
	dot := name.last_index('.') or { return name }
	if dot <= 0 {
		return name
	}
	return name[..dot]
}

fn repository_map_eq_ci(left string, right string) bool {
	return left.to_lower() == right.to_lower()
}

fn repository_map_path_matches_mention(path string, mentioned string) bool {
	if mentioned.len == 0 {
		return false
	}
	normalized_path := path.replace('\\', '/')
	path_l := normalized_path.to_lower()
	base_l := os.file_name(path_l)
	return repository_map_path_matches_lower(path_l, base_l, mentioned)
}

fn repository_map_path_matches_lower(path_l string, base_l string, mentioned string) bool {
	if mentioned.len == 0 {
		return false
	}
	mentioned_l := mentioned.to_lower().replace('\\', '/')
	if path_l == mentioned_l || path_l.ends_with('/' + mentioned_l) {
		return true
	}
	if base_l == mentioned_l || base_l == os.file_name(mentioned_l) {
		return true
	}
	return path_l.contains(mentioned_l)
}

struct RepositoryMapLexicalHints {
mut:
	unique  []string
	ordered []string
}

fn repository_map_lexical_hints(hints RepositoryMapHintSet) RepositoryMapLexicalHints {
	mut lexical_hints := RepositoryMapLexicalHints{
		unique:  []string{cap: hints.idents.len}
		ordered: []string{cap: hints.idents.len}
	}
	for ident in hints.idents {
		if !repository_map_is_lexical_hint(ident) {
			continue
		}
		normalized := ident.to_lower()
		lexical_hints.ordered << normalized
		if normalized !in lexical_hints.unique {
			lexical_hints.unique << normalized
		}
	}
	return lexical_hints
}

fn score_repository_map_path(path string, hints RepositoryMapHintSet) f64 {
	return score_repository_map_path_with_lexical_hints(path, hints, repository_map_lexical_hints(hints))
}

fn score_repository_map_path_with_lexical_hints(path string, hints RepositoryMapHintSet, lexical_hints RepositoryMapLexicalHints) f64 {
	mut score := 1.0
	// Ranking considers each path against several hints. Normalize and split it
	// once so those loops reuse the same strings instead of allocating a lower-
	// cased path or a new segment list for every hint.
	normalized_path := path.replace('\\', '/')
	path_l := normalized_path.to_lower()
	base := os.file_name(path)
	base_l := os.file_name(path_l)
	lower_segments := if hints.idents.len > 0 { path_l.split('/') } else { []string{} }
	mut path_ident_parts := []string{}
	if lexical_hints.unique.len > 0 {
		path_segments := normalized_path.split('/')
		path_ident_parts = []string{cap: path_segments.len * 2}
		for segment in path_segments {
			path_ident_parts << repository_map_ident_parts(repository_map_stem(segment))
		}
	}
	if base in repository_map_important_basenames || path in repository_map_important_basenames {
		// Static importance is a tie-breaker, not a relevance signal: at the
		// old +1000 every repo root (README, .gitignore, pyproject.toml...)
		// outranked the file a hint actually pointed at, and tripped the
		// >=500 hot-directory/stem boosts meant for real path mentions.
		score += 120.0
	}
	for mentioned in hints.paths {
		if repository_map_path_matches_lower(path_l, base_l, mentioned) {
			score += 500.0
			break
		}
	}
	// Directory / prefix mentions (e.g. "src/auth" or "auth/") pull related
	// children into budget before unrelated deep leaves — extractive, not
	// tree-sitter/PageRank.
	for mentioned in hints.paths {
		if repository_map_path_under_mention_lower(path_l, mentioned) {
			score += 220.0
			break
		}
	}
	for ident in hints.idents {
		ident_l := ident.to_lower()
		if base_l == ident_l || repository_map_stem(base_l) == ident_l {
			// A queried term used as the filename is stronger than the same
			// term inferred from declarations or general file contents. A
			// generic file name such as job.ts or lifecycle.ts is a weaker
			// clue when a query also names a specific subsystem; exact path
			// mentions still receive their stronger weight above.
			score += if repository_map_is_generic_filename(base) { 140.0 } else { 500.0 }
			break
		}
	}
	for ident in hints.idents {
		if repository_map_path_has_segment_lower(lower_segments, ident.to_lower()) {
			score += 120.0
			break
		}
	}
	// Natural-language task terms often differ from path spelling only by
	// pluralization or a common code abbreviation (argument/args). Keep this
	// signal weaker than exact mentions, so it helps without replacing them.
	mut exact_path_term_matches := 0
	for ident in lexical_hints.unique {
		for part in path_ident_parts {
			match_weight := repository_map_lexical_match_weight_normalized(part, ident)
			if match_weight > 0.0 {
				// An exact word inside a compound filename (subagent-job.ts)
				// is stronger path evidence than general source-token overlap.
				if part == ident {
					score += 120.0
					exact_path_term_matches++
				} else {
					score += match_weight
				}
				break
			}
		}
	}
	// A filename that names multiple distinct concepts from the query is a
	// stronger destination than a file matching one common word (e.g. tool.ts
	// versus tool/plugin/subagent.ts). Keep individual exact-word weight bounded
	// so generic documentation filenames do not swamp high-confidence aliases.
	if exact_path_term_matches > 1 {
		score += f64(exact_path_term_matches - 1) * 300.0
	}
	if lexical_hints.ordered.len > 1 && (!repository_map_is_test_path(path)
		|| repository_map_hint_mentions_tests(hints)) {
		base_parts := repository_map_ident_parts(repository_map_stem(base))
		if repository_map_path_has_ordered_hint_pair(base_parts, lexical_hints.ordered) {
			// Ordered query concepts in a compound filename ("subagent job" in
			// subagent-job.ts, or "running ... batch" in run_batch.py) identify a
			// more specific destination than separate hits on generic files.
			score += 600.0
		}
	}
	// For behavior questions, prefer implementation files over tests that
	// merely import the same symbols. A query explicitly about tests keeps them
	// eligible for the existing exact and source/test-pair signals.
	is_test_path := if hints.idents.len > 0 {
		repository_map_path_segments_are_test(lower_segments)
	} else {
		repository_map_is_test_path(normalized_path)
	}
	if is_test_path && !repository_map_hint_mentions_tests(hints) {
		score -= 240.0
	}
	// Test/source pairing: mention of foo.v or stem foo also elevates
	// foo_test.v / foo.test.ts / test_foo.py style neighbors.
	if !is_test_path || repository_map_hint_mentions_tests(hints) {
		for mentioned in hints.paths {
			if repository_map_is_test_pair(normalized_path, mentioned) {
				score += 280.0
				break
			}
		}
		for ident in hints.idents {
			if repository_map_is_test_pair_for_stem(normalized_path, ident) {
				score += 180.0
				break
			}
		}
	}
	depth := normalized_path.count('/')
	if depth == 0 {
		score += 25.0
	} else if depth == 1 {
		score += 10.0
	}
	return score
}

fn repository_map_path_has_ordered_hint_pair(name_parts []string, lexical_hints []string) bool {
	if name_parts.len < 2 {
		return false
	}
	for i in 0 .. name_parts.len - 1 {
		mut found_first := false
		for hint in lexical_hints {
			if !found_first {
				if repository_map_lexical_match_weight_normalized(name_parts[i], hint) > 0.0 {
					found_first = true
				}
			} else if repository_map_lexical_match_weight_normalized(name_parts[i + 1], hint) > 0.0 {
				return true
			}
		}
	}
	return false
}

fn repository_map_is_generic_filename(name string) bool {
	stem := repository_map_stem(name).to_lower()
	return stem in ['agent', 'context', 'event', 'handler', 'index', 'job', 'lifecycle', 'models',
		'provider', 'session', 'state', 'tool', 'types']
}

fn repository_map_is_lexical_hint(ident string) bool {
	return ident.len >= 3 && ident.to_lower() !in ['the', 'and', 'for', 'with', 'that', 'from',
		'into', 'where', 'when', 'what', 'how', 'why', 'are', 'was', 'were', 'has', 'have', 'had',
		'not', 'all', 'any', 'each', 'can', 'does', 'its']
}

fn repository_map_lexically_related(left string, right string) bool {
	return repository_map_lexical_match_weight(left, right) > 0.0
}

fn repository_map_lexical_candidates(term string) []string {
	lower := term.to_lower()
	mut candidates := [lower]
	if lower.len > 6 && lower.ends_with('ing') {
		stem := lower[..lower.len - 3]
		candidates << stem
		if stem.len > 2 && stem[stem.len - 1] == stem[stem.len - 2] {
			candidates << stem[..stem.len - 1]
		} else if !stem.ends_with('e') {
			candidates << '${stem}e'
		}
	} else if lower.len > 4 && lower.ends_with('ies') {
		candidates << '${lower[..lower.len - 3]}y'
	} else if lower.len > 4 && lower.ends_with('es')
		&& (lower.ends_with('sses') || lower.ends_with('xes') || lower.ends_with('zes')
			|| lower.ends_with('ches') || lower.ends_with('shes')) {
		candidates << lower[..lower.len - 2]
	} else if lower.len > 3 && lower.ends_with('ss') {
		candidates << '${lower}es'
	} else if lower.len > 3 && lower.ends_with('s') {
		candidates << lower[..lower.len - 1]
	} else if lower.len > 3 {
		plural := if lower.ends_with('y') && lower.len > 1 {
			'${lower[..lower.len - 1]}ies'
		} else if lower.ends_with('s') || lower.ends_with('x') || lower.ends_with('z')
			|| lower.ends_with('ch') || lower.ends_with('sh') {
			'${lower}es'
		} else {
			'${lower}s'
		}
		candidates << plural
	}
	if lower in ['arg', 'args', 'argument', 'arguments'] {
		for candidate in ['arg', 'args', 'argument', 'arguments'] {
			if candidate !in candidates {
				candidates << candidate
			}
		}
	}
	return candidates
}

fn repository_map_lexical_match_weight(left string, right string) f64 {
	return repository_map_lexical_match_weight_normalized(left.to_lower(), right.to_lower())
}

// Both arguments are normalized by repository_map_ident_parts and
// repository_map_lexical_hints in the path-ranking hot loop.
fn repository_map_lexical_match_weight_normalized(a string, b string) f64 {
	if a == b {
		// This also matches a word inside compound names such as
		// `litellm_model`; whole path-segment matches already scored above.
		return 45.0
	}
	if repository_map_ing_match(b, a) || repository_map_ing_match(a, b) {
		return 45.0
	}
	if a.len > 3 && a.ends_with('s') && a[..a.len - 1] == b {
		return 45.0
	}
	if b.len > 3 && b.ends_with('s') && b[..b.len - 1] == a {
		return 45.0
	}
	if a.len > 4 && a.ends_with('ies') && '${a[..a.len - 3]}y' == b {
		return 45.0
	}
	if b.len > 4 && b.ends_with('ies') && '${b[..b.len - 3]}y' == a {
		return 45.0
	}
	if a.len > 4 && a.ends_with('es') && a[..a.len - 2] == b {
		return 45.0
	}
	if b.len > 4 && b.ends_with('es') && b[..b.len - 2] == a {
		return 45.0
	}
	if (a in ['arg', 'args', 'argument', 'arguments'])
		&& (b in ['arg', 'args', 'argument', 'arguments']) {
		// Argument terminology is a high-confidence filename alias in codebases
		// that use `args` (e.g. `args.py`) instead of `arguments`.
		return 480.0
	}
	return 0.0
}

fn repository_map_ing_match(stem string, gerund string) bool {
	if gerund.len <= 6 || !gerund.ends_with('ing') {
		return false
	}
	stem_len := gerund.len - 3
	mut root_len := stem_len
	if stem_len > 2 && gerund[stem_len - 1] == gerund[stem_len - 2] {
		root_len--
	}
	if stem.len == root_len {
		for i in 0 .. root_len {
			if stem[i] != gerund[i] {
				return false
			}
		}
		return true
	}
	if stem.len != root_len + 1 || stem[root_len] != `e` {
		return false
	}
	for i in 0 .. root_len {
		if stem[i] != gerund[i] {
			return false
		}
	}
	return true
}

fn repository_map_is_test_path(path string) bool {
	normalized_path := path.replace('\\', '/').to_lower()
	return repository_map_path_segments_are_test(normalized_path.split('/'))
}

fn repository_map_path_segments_are_test(lower_segments []string) bool {
	for segment in lower_segments {
		stem := repository_map_stem(segment)
		if segment in ['test', 'tests', '__tests__', 'spec', 'specs', '__specs__']
			|| stem.starts_with('test_') || stem.starts_with('test-') || stem.ends_with('_test')
			|| stem.ends_with('.test') || stem.starts_with('spec_') || stem.starts_with('spec-')
			|| stem.ends_with('_spec') || stem.ends_with('.spec') {
			return true
		}
	}
	return false
}

fn repository_map_hint_mentions_tests(hints RepositoryMapHintSet) bool {
	for ident in hints.idents {
		if ident.to_lower() in ['test', 'tests', 'testing', 'spec', 'specs'] {
			return true
		}
	}
	return false
}

fn repository_map_is_package_index_path(path string) bool {
	base := os.file_name(path).to_lower()
	return base in ['__init__.py', '__init__.pyi', 'mod.rs', 'index.ts', 'index.tsx', 'index.js',
		'index.jsx', 'index.mjs', 'index.cjs', 'index.d.ts']
}

fn repository_map_hint_mentions_package_indexes(hints RepositoryMapHintSet) bool {
	for ident in hints.idents {
		if ident.to_lower() in ['entrypoint', 'entrypoints', 'export', 'exports', 'reexport',
			'reexports', 'index'] {
			return true
		}
	}
	return false
}

fn repository_map_content_is_reexport_only(content string) bool {
	mut found_reexport := false
	mut line_start := 0
	for index := 0; index <= content.len; index++ {
		if index < content.len && content[index] != `\n` {
			continue
		}
		is_reexport := repository_map_reexport_line(unsafe {
			content.substr_unsafe(line_start, index)
		}) or {
			line_start = index + 1
			continue
		}
		if !is_reexport {
			return false
		}
		found_reexport = true
		line_start = index + 1
	}
	return found_reexport
}

fn repository_map_reexport_line(raw_line string) ?bool {
	line := repository_map_trim_space_view(raw_line)
	if line.len == 0 || line.starts_with('#') || line.starts_with('//') || line.starts_with('/*')
		|| line.starts_with('*') {
		return none
	}
	is_python_import := line.starts_with('from ') && line.contains(' import ')
	is_import := line.starts_with('import ')
	is_export := line.starts_with('export ') && (line.contains(' from ') || line.starts_with('export *'))
	is_rust_reexport := line.starts_with('pub use ')
	is_python_all := line.starts_with('__all__')
	return is_python_import || is_import || is_export || is_rust_reexport || is_python_all
}

struct RepositoryMapContentQueryTerm {
	ident      string
	candidates []string
}

fn repository_map_content_query_terms(hints RepositoryMapHintSet) []RepositoryMapContentQueryTerm {
	mut query_terms := []RepositoryMapContentQueryTerm{cap: hints.idents.len}
	mut seen_hints := map[string]bool{}
	for ident in hints.idents {
		if !repository_map_is_lexical_hint(ident) {
			continue
		}
		normalized := ident.to_lower()
		if normalized in seen_hints {
			continue
		}
		seen_hints[normalized] = true
		query_terms << RepositoryMapContentQueryTerm{
			ident:      ident
			candidates: repository_map_lexical_candidates(ident)
		}
	}
	return query_terms
}

fn score_repository_map_content(content string, query_terms []RepositoryMapContentQueryTerm) f64 {
	// The map already reads bounded source files to extract declarations. Reuse
	// that text for a small lexical retrieval signal instead of another index or
	// embedding dependency. Count each query term once and cap total influence.
	mut terms := map[string]bool{}
	mut start := -1
	for offset, ch in content {
		if is_repository_map_ident_byte(ch) {
			if start < 0 {
				start = offset
			}
			continue
		}
		if start >= 0 {
			if offset - start >= repository_map_cross_reference_min_symbol_len {
				// The view is inspected only; the map stores owned lowercase keys.
				token := unsafe { content.substr_unsafe(start, offset) }
				repository_map_add_content_terms(mut terms, token)
			}
		}
		start = -1
	}
	if start >= 0 && content.len - start >= repository_map_cross_reference_min_symbol_len {
		token := unsafe { content.substr_unsafe(start, content.len) }
		repository_map_add_content_terms(mut terms, token)
	}
	mut matched_terms := 0
	mut score := 0.0
	for query_term in query_terms {
		for candidate in query_term.candidates {
			if candidate in terms {
				is_alias := query_term.ident != candidate
					&& query_term.ident in ['arg', 'args', 'argument', 'arguments']
				score += if is_alias { 48.0 } else { 24.0 }
				matched_terms++
				break
			}
		}
		if matched_terms >= 6 {
			break
		}
	}
	return score
}

fn repository_map_add_content_terms(mut terms map[string]bool, identifier string) {
	// The map contains normalized full names and parts. Skip repeated tokens
	// before lowercasing or splitting so large files do that work once per term.
	if identifier in terms {
		return
	}
	lower := identifier.to_lower()
	if lower in terms {
		return
	}
	terms[lower] = true
	for part in repository_map_ident_parts(identifier) {
		terms[part] = true
	}
}

fn repository_map_path_under_mention(path string, mentioned string) bool {
	if mentioned.len == 0 {
		return false
	}
	path_l := path.replace('\\', '/').to_lower()
	return repository_map_path_under_mention_lower(path_l, mentioned)
}

fn repository_map_path_under_mention_lower(path_l string, mentioned string) bool {
	if mentioned.len == 0 {
		return false
	}
	mentioned_l := mentioned.to_lower().replace('\\', '/').trim_right('/')
	if mentioned_l.len < 2 {
		return false
	}
	if path_l == mentioned_l {
		return false
	}
	prefix := mentioned_l + '/'
	if path_l.starts_with(prefix) {
		return true
	}
	return path_l.contains('/' + prefix)
}

fn repository_map_path_has_segment(path string, ident string) bool {
	if ident.len < 2 {
		return false
	}
	normalized_path := path.replace('\\', '/').to_lower()
	return repository_map_path_has_segment_lower(normalized_path.split('/'), ident.to_lower())
}

fn repository_map_path_has_segment_lower(lower_segments []string, ident_l string) bool {
	if ident_l.len < 2 {
		return false
	}
	for segment in lower_segments {
		if segment == ident_l || repository_map_stem(segment) == ident_l {
			return true
		}
	}
	return false
}

fn score_repository_map_symbol(name string, hints RepositoryMapHintSet) f64 {
	// Only hint-matching symbols carry relevance. A non-matching symbol used
	// to add 1-9 points each, which let symbol count alone dominate ranking.
	mut score := 0.0
	for ident in hints.idents {
		if repository_map_eq_ci(name, ident) {
			score += 200.0
			break
		}
	}
	if score == 0.0 {
		for ident in hints.idents {
			if repository_map_symbol_part_match(name, ident) {
				score += 80.0
				break
			}
		}
	}
	if score == 0.0 {
		return 0.0
	}
	if repository_map_ident_is_interesting(name) {
		score += 8.0
	}
	if name.starts_with('_') {
		score *= 0.1
	}
	return score
}

fn boost_repository_map_directory_neighbors(mut entries []RepositoryMapEntry) {
	mut hot_dirs := map[string]bool{}
	for entry in entries {
		// Path-mention tier from score_repository_map_path is +500.
		if entry.score < 500.0 {
			continue
		}
		dir := os.dir(entry.path).replace('\\', '/')
		if dir.len == 0 || dir == '.' {
			continue
		}
		hot_dirs[dir] = true
	}
	if hot_dirs.len == 0 {
		return
	}
	for mut entry in entries {
		if entry.score >= 500.0 {
			continue
		}
		dir := os.dir(entry.path).replace('\\', '/')
		if hot_dirs[dir] {
			entry.score += 90.0
		}
	}
}

fn boost_repository_map_same_stem_siblings(mut entries []RepositoryMapEntry) {
	mut hot_stems := map[string]bool{}
	for entry in entries {
		if entry.score < 500.0 {
			continue
		}
		stem := repository_map_stem(os.file_name(entry.path)).to_lower()
		if stem.len < 2 {
			continue
		}
		hot_stems[stem] = true
		base := repository_map_stem_base(stem)
		if base.len >= 2 {
			hot_stems[base] = true
		}
	}
	if hot_stems.len == 0 {
		return
	}
	for mut entry in entries {
		if entry.score >= 500.0 {
			continue
		}
		stem := repository_map_stem(os.file_name(entry.path)).to_lower()
		if stem.len < 2 {
			continue
		}
		base := repository_map_stem_base(stem)
		if hot_stems[stem] || (base.len >= 2 && hot_stems[base]) {
			entry.score += 70.0
		}
	}
}

fn boost_repository_map_stem_packages(mut entries []RepositoryMapEntry) {
	mut hot_package_prefixes := []string{}
	mut hot_package_files := map[string]bool{}
	for entry in entries {
		if entry.score < 500.0 {
			continue
		}
		path_l := entry.path.to_lower().replace('\\', '/')
		stem := repository_map_stem(os.file_name(path_l))
		if stem.len >= 2 {
			dir := os.dir(path_l).replace('\\', '/')
			prefix := if dir.len == 0 || dir == '.' {
				stem + '/'
			} else {
				dir + '/' + stem + '/'
			}
			if prefix !in hot_package_prefixes {
				hot_package_prefixes << prefix
			}
		}
		// Nested hot path lib/session/foo.v also elevates lib/session.v.
		parent := os.dir(path_l).replace('\\', '/')
		if parent.len > 0 && parent != '.' {
			hot_package_files[parent] = true
		}
	}
	if hot_package_prefixes.len == 0 && hot_package_files.len == 0 {
		return
	}
	for mut entry in entries {
		if entry.score >= 500.0 {
			continue
		}
		path_l := entry.path.to_lower().replace('\\', '/')
		mut boosted := false
		for prefix in hot_package_prefixes {
			if path_l.starts_with(prefix) {
				entry.score += 80.0
				boosted = true
				break
			}
		}
		if !boosted && hot_package_files[repository_map_stem(path_l)] {
			entry.score += 80.0
		}
	}
}

fn repository_map_is_test_pair(path string, mentioned string) bool {
	if mentioned.len == 0 {
		return false
	}
	path_stem := repository_map_stem(os.file_name(path)).to_lower()
	mentioned_stem := repository_map_stem(os.file_name(mentioned.replace('\\', '/'))).to_lower()
	if path_stem.len < 2 || mentioned_stem.len < 2 {
		return false
	}
	return repository_map_stems_are_test_pair(path_stem, mentioned_stem)
}

fn repository_map_is_test_pair_for_stem(path string, stem string) bool {
	if stem.len < 2 {
		return false
	}
	path_stem := repository_map_stem(os.file_name(path)).to_lower()
	return repository_map_stems_are_test_pair(path_stem, stem.to_lower())
}

fn repository_map_stems_are_test_pair(left string, right string) bool {
	if left == right {
		return false
	}
	return repository_map_stem_base(left) == right || repository_map_stem_base(right) == left
		|| repository_map_stem_base(left) == repository_map_stem_base(right)
}

fn repository_map_stem_base(stem string) string {
	mut s := stem
	for suffix in ['_test', '_spec', '.test', '.spec', '-test', '-spec'] {
		if s.ends_with(suffix) {
			s = s[..s.len - suffix.len]
			break
		}
	}
	for prefix in ['test_', 'spec_', 'test-', 'spec-'] {
		if s.starts_with(prefix) {
			s = s[prefix.len..]
			break
		}
	}
	return s
}

fn repository_map_symbol_part_match(name string, ident string) bool {
	if name.len < 3 || ident.len < 3 {
		return false
	}
	if repository_map_eq_ci(name, ident) {
		return false
	}
	name_parts := repository_map_ident_parts(name)
	ident_parts := repository_map_ident_parts(ident)
	if name_parts.len == 0 || ident_parts.len == 0 {
		return false
	}
	for part in ident_parts {
		if part.len < 3 {
			continue
		}
		for candidate in name_parts {
			if repository_map_eq_ci(candidate, part) {
				return true
			}
		}
	}
	return false
}

fn repository_map_ident_parts(name string) []string {
	mut parts := []string{}
	mut start := -1
	for offset, ch in name {
		if ch >= 128 {
			// Preserve the existing rune-aware fallback for non-ASCII names.
			return repository_map_ident_parts_unicode(name)
		}
		if ch == `_` || ch == `-` {
			if start >= 0 && offset - start >= 3 {
				part := unsafe { name.substr_unsafe(start, offset) }
				parts << part.to_lower_ascii()
			}
			start = -1
			continue
		}
		if ch >= `A` && ch <= `Z` && start >= 0 {
			if offset - start >= 3 {
				part := unsafe { name.substr_unsafe(start, offset) }
				parts << part.to_lower_ascii()
			}
			start = offset
		} else if start < 0 {
			start = offset
		}
	}
	if start >= 0 && name.len - start >= 3 {
		part := unsafe { name.substr_unsafe(start, name.len) }
		parts << part.to_lower_ascii()
	}
	return parts
}

fn repository_map_ident_parts_unicode(name string) []string {
	mut parts := []string{}
	mut current := ''
	for ch in name {
		if ch == `_` || ch == `-` {
			if current.len >= 3 {
				parts << current.to_lower()
			}
			current = ''
			continue
		}
		is_upper := ch >= `A` && ch <= `Z`
		if is_upper && current.len > 0 {
			if current.len >= 3 {
				parts << current.to_lower()
			}
			current = ''
		}
		current += ch.ascii_str()
	}
	if current.len >= 3 {
		parts << current.to_lower()
	}
	return parts
}

const repository_map_cross_reference_weight = 40.0
const repository_map_cross_reference_hint_multiplier = 2.0
const repository_map_cross_reference_hint_min_path_score = 120.0
const repository_map_cross_reference_max_boost = 400.0
const repository_map_cross_reference_max_definers = 8
const repository_map_cross_reference_min_symbol_len = 3

// boost_repository_map_cross_references raises files whose defined symbols
// are mentioned by other files. One distinct referring file contributes one
// weight unit regardless of mention count, symbols defined in many files
// are skipped as too generic, and the total boost per file is capped.
fn boost_repository_map_cross_references(mut entries []RepositoryMapEntry, contents map[string]string, hints RepositoryMapHintSet, lexical_hints RepositoryMapLexicalHints) {
	mut definers := map[string][]int{}
	for index, entry in entries {
		if entry.path !in contents {
			continue
		}
		mut seen := map[string]bool{}
		for symbol in entry.symbols {
			name := symbol.name
			// Module declarations (e.g. `module main`) and entrypoints are
			// not callable references; including them would link every file
			// in a package to every other file.
			if symbol.kind == 'module' || name == 'main' {
				continue
			}
			if name.len < repository_map_cross_reference_min_symbol_len || name in seen {
				continue
			}
			seen[name] = true
			definers[name] << index
		}
	}
	// Reuse index buffers instead of building a distinct-string map and a second
	// per-file map for every candidate. The mark value is the current entry
	// index, so repeated identifiers and references are deduplicated in O(1).
	mut seen_referrers := []int{len: entries.len, init: -1}
	mut referrers := []int{cap: entries.len}
	mut boosts := []f64{len: entries.len}
	for index, entry in entries {
		content := contents[entry.path] or { continue }
		referrers.clear()
		mut start := -1
		for offset, ch in content {
			if is_repository_map_ident_byte(ch) {
				if start < 0 {
					start = offset
				}
				continue
			}
			if start >= 0 {
				if offset - start >= repository_map_cross_reference_min_symbol_len {
					// This borrowed token is used only for map lookup, never retained.
					token := unsafe { content.substr_unsafe(start, offset) }
					if defs := definers[token] {
						if defs.len <= repository_map_cross_reference_max_definers {
							for definer in defs {
								if definer != index && seen_referrers[definer] != index {
									seen_referrers[definer] = index
									referrers << definer
								}
							}
						}
					}
				}
			}
			start = -1
		}
		if start >= 0 && content.len - start >= repository_map_cross_reference_min_symbol_len {
			token := unsafe { content.substr_unsafe(start, content.len) }
			if defs := definers[token] {
				if defs.len <= repository_map_cross_reference_max_definers {
					for definer in defs {
						if definer != index && seen_referrers[definer] != index {
							seen_referrers[definer] = index
							referrers << definer
						}
					}
				}
			}
		}
		// Personalization (Aider-style): a reference coming from a file the
		// hint already points at counts more than one from an unrelated file.
		// Keep the path-only relevance computed before content and structural
		// boosts. Re-scoring here repeats all hint/path matching for each source
		// file (up to repository_map_max_symbol_files candidates).
		referrer_score := if entry.path_score != 0.0 {
			entry.path_score
		} else {
			score_repository_map_path_with_lexical_hints(entry.path, hints, lexical_hints)
		}
		referrer_weight := if referrer_score >= repository_map_cross_reference_hint_min_path_score {
			repository_map_cross_reference_weight * repository_map_cross_reference_hint_multiplier
		} else {
			repository_map_cross_reference_weight
		}
		for definer in referrers {
			boosts[definer] += referrer_weight
		}
	}
	for index, boost in boosts {
		capped := if boost > repository_map_cross_reference_max_boost {
			repository_map_cross_reference_max_boost
		} else {
			boost
		}
		entries[index].score += capped
	}
}

fn compare_repository_map_entries(a &RepositoryMapEntry, b &RepositoryMapEntry) int {
	if a.score > b.score {
		return -1
	}
	if a.score < b.score {
		return 1
	}
	if a.path < b.path {
		return -1
	}
	if a.path > b.path {
		return 1
	}
	return 0
}

fn sort_repository_map_entries(mut entries []RepositoryMapEntry) {
	// The metadata-only path walk can produce thousands of candidates. Use V's
	// O(n log n) sort rather than insertion sort, then keep lexical ties stable.
	entries.sort_with_compare(compare_repository_map_entries)
}
