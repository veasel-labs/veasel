module main

import os
import encoding.utf8

const max_workspace_file_count = 5_000
const max_workspace_list_results = 500
const max_workspace_file_bytes = 512_000
const max_workspace_search_bytes = 32_000_000
const max_workspace_search_results = 100
const max_workspace_query_bytes = 256
const ignored_workspace_directories = ['.git', '.hg', '.svn', 'node_modules', 'vendor', '.venv',
	'venv', 'target', 'dist', 'build', '.next', '.turbo']

pub struct WorkspaceFileList {
pub:
	files     []string
	truncated bool
}

pub struct WorkspaceFileContent {
pub:
	path    string
	content string
}

pub struct WorkspaceSearchMatch {
pub:
	path string
	line int
	text string
}

pub struct WorkspaceSearchResult {
pub mut:
	matches   []WorkspaceSearchMatch
	truncated bool
}

struct WorkspaceWalker {
mut:
	root      string
	files     []string
	max_files int
	stopped   bool
}

fn (mut walker WorkspaceWalker) visit(path string, entry os.WalkDirEntry) os.WalkDirAction {
	if entry.err != none {
		walker.stopped = true
		return .proceed
	}
	if entry.is_dir {
		if path != walker.root && entry.name in ignored_workspace_directories {
			return .skip_dir
		}
		return .proceed
	}
	if entry.typ != .regular || os.is_link(path) {
		return .proceed
	}
	if walker.files.len >= walker.max_files {
		walker.stopped = true
		return .stop
	}
	relative_path := os.path_rel(walker.root, path) or {
		walker.stopped = true
		return .proceed
	}
	walker.files << relative_path
	return .proceed
}

fn workspace_files(root string, limit int) !WorkspaceFileList {
	if limit < 1 || limit > max_workspace_list_results {
		return error('file listing limit must be from 1 to ${max_workspace_list_results}')
	}
	canonical_root := canonical_workspace_root(root)!
	mut walker := WorkspaceWalker{
		root:      canonical_root
		max_files: max_workspace_file_count + 1
		files:     []string{cap: 256}
	}
	os.walk_dir(canonical_root, walker.visit)!
	walker.files.sort()
	truncated := walker.stopped || walker.files.len > max_workspace_file_count
	if walker.files.len > max_workspace_file_count {
		walker.files = walker.files[..max_workspace_file_count]
	}
	if walker.files.len > limit {
		walker.files = walker.files[..limit]
		return WorkspaceFileList{
			files:     walker.files
			truncated: true
		}
	}
	return WorkspaceFileList{
		files:     walker.files
		truncated: truncated
	}
}

fn workspace_file(root string, relative_path string) !WorkspaceFileContent {
	resolved_root := canonical_workspace_root(root)!
	path := resolve_workspace_file_path(resolved_root, relative_path)!
	content := read_workspace_text_file(path)!
	return WorkspaceFileContent{
		path:    relative_path.replace('\\', '/')
		content: content
	}
}

fn workspace_search(root string, query string) !WorkspaceSearchResult {
	if query.trim_space().len == 0 || query.len > max_workspace_query_bytes {
		return error('search query must contain 1 to ${max_workspace_query_bytes} bytes')
	}
	canonical_root := canonical_workspace_root(root)!
	mut walker := WorkspaceWalker{
		root:      canonical_root
		max_files: max_workspace_file_count + 1
		files:     []string{cap: 256}
	}
	os.walk_dir(canonical_root, walker.visit)!
	walker.files.sort()
	mut result := WorkspaceSearchResult{
		matches: []WorkspaceSearchMatch{cap: 32}
	}
	mut bytes_scanned := 0
	for relative_path in walker.files {
		path := resolve_workspace_file_path(canonical_root, relative_path) or { continue }
		if os.file_size(path) > max_workspace_file_bytes {
			continue
		}
		content := read_workspace_text_file(path) or { continue }
		bytes_scanned += content.len
		if bytes_scanned > max_workspace_search_bytes {
			result.truncated = true
			break
		}
		if workspace_search_content(mut result, relative_path, content, query) {
			return result
		}
	}
	if walker.stopped {
		result.truncated = true
	}
	return result
}

// workspace_search_content scans newline-delimited views without materializing
// an allocated string for every line. Only matching excerpts are copied into
// the result, keeping dense generated files within the existing scan budget.
fn workspace_search_content(mut result WorkspaceSearchResult, path string, content string,
	query string) bool {
	mut line_start := 0
	mut line_number := 1
	mut index := 0
	for index < content.len {
		if content[index] in [`\r`, `\n`] {
			line := unsafe { content.substr_unsafe(line_start, index) }
			if workspace_search_record_match(mut result, path, line_number, line, query) {
				return true
			}
			if content[index] == `\r` && index + 1 < content.len && content[index + 1] == `\n` {
				index++
			}
			line_start = index + 1
			line_number++
		}
		index++
	}
	if line_start < content.len {
		line := unsafe { content.substr_unsafe(line_start, content.len) }
		if workspace_search_record_match(mut result, path, line_number, line, query) {
			return true
		}
	}
	return false
}

fn workspace_search_record_match(mut result WorkspaceSearchResult, path string, line_number int,
	line string, query string) bool {
	if !line.contains(query) {
		return false
	}
	result.matches << WorkspaceSearchMatch{
		path: path
		line: line_number
		text: workspace_excerpt(line, 2_000)
	}
	if result.matches.len >= max_workspace_search_results {
		result.truncated = true
		return true
	}
	return false
}

fn workspace_excerpt(line string, max_bytes int) string {
	trimmed := line.trim_space()
	if trimmed.len <= max_bytes {
		return trimmed
	}
	mut end := max_bytes
	for end > 0 && end < trimmed.len && (trimmed[end] & 0xc0) == 0x80 {
		end--
	}
	return trimmed[..end]
}

fn resolve_workspace_file_path(root string, relative_path string) !string {
	if relative_path.len == 0 || relative_path.len > 4_096 || os.is_abs_path(relative_path)
		|| relative_path.contains('\x00') {
		return error('workspace path must be a non-empty relative path')
	}
	for segment in relative_path.replace('\\', '/').split('/') {
		if segment == '..' {
			return error('workspace path must not leave the selected root')
		}
	}
	joined := os.join_path(root, relative_path)
	if !os.exists(joined) {
		return error('workspace file does not exist')
	}
	resolved := os.real_path(joined)
	if !os.is_abs_path(resolved) || !path_is_within(root, resolved) {
		return error('workspace file escapes the selected root')
	}
	if !os.is_file(resolved) || os.is_link(joined) && !path_is_within(root, resolved) {
		return error('workspace path is not a regular in-root file')
	}
	if os.file_size(resolved) > max_workspace_file_bytes {
		return error('workspace file exceeds the ${max_workspace_file_bytes} byte limit')
	}
	return resolved
}

fn read_workspace_text_file(path string) !string {
	mut file := os.open(path)!
	defer {
		file.close()
	}
	mut bytes := []u8{len: max_workspace_file_bytes + 1}
	count := file.read_bytes_into(0, mut bytes)!
	if count > max_workspace_file_bytes {
		return error('workspace file exceeds the ${max_workspace_file_bytes} byte limit')
	}
	content := bytes[..count].clone()
	if content.contains(0) {
		return error('binary files are not supported by workspace text tools')
	}
	if content.len > 0 && !utf8.validate(&content[0], content.len) {
		return error('workspace file is not valid UTF-8 text')
	}
	return content.bytestr()
}
