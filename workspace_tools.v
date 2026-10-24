module main

import os
import encoding.utf8
import strings

const max_workspace_file_count = 5_000
const max_workspace_list_results = 500
const max_workspace_file_bytes = 512_000
const max_workspace_read_range_lines = 200
const max_workspace_read_range_bytes = 32_000
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

pub struct WorkspaceFileRange {
pub:
	path        string
	start_line  int
	end_line    int
	total_lines int
	content     string
	truncated   bool
}

struct WorkspaceRangeLineAppend {
	written   bool
	truncated bool
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

fn workspace_file_range(root string, relative_path string, start_line int, line_count int) !WorkspaceFileRange {
	if start_line < 1 || line_count < 1 || line_count > max_workspace_read_range_lines {
		return error('line range must start at 1 or greater and contain 1 to ${max_workspace_read_range_lines} lines')
	}
	resolved_root := canonical_workspace_root(root)!
	path := resolve_workspace_file_path(resolved_root, relative_path)!
	content := read_workspace_text_file(path)!
	mut output := strings.new_builder(4_096)
	mut line_start := 0
	mut total_lines := 0
	mut included_lines := 0
	mut byte_truncated := false
	mut index := 0
	for index < content.len {
		if content[index] == `\n` || content[index] == `\r` {
			line_number := total_lines + 1
			if line_number >= start_line && included_lines < line_count && !byte_truncated {
				append_result := append_workspace_range_line(mut output, content[line_start..index],
					line_number)
				if append_result.written {
					included_lines++
				}
				byte_truncated = append_result.truncated
			}
			total_lines++
			if content[index] == `\r` && index + 1 < content.len && content[index + 1] == `\n` {
				index++
			}
			line_start = index + 1
		}
		index++
	}
	if line_start < content.len {
		line_number := total_lines + 1
		if line_number >= start_line && included_lines < line_count && !byte_truncated {
			append_result := append_workspace_range_line(mut output, content[line_start..], line_number)
			if append_result.written {
				included_lines++
			}
			byte_truncated = append_result.truncated
		}
		total_lines++
	}
	if start_line > total_lines {
		return error('start_line exceeds the file line count')
	}
	return WorkspaceFileRange{
		path:        relative_path.replace('\\', '/')
		start_line:  start_line
		end_line:    start_line + included_lines - 1
		total_lines: total_lines
		content:     output.str()
		truncated:   byte_truncated || start_line - 1 + line_count < total_lines
	}
}

fn append_workspace_range_line(mut output strings.Builder, line string, line_number int) WorkspaceRangeLineAppend {
	prefix_bytes := if line_number < 10 {
		3
	} else if line_number < 100 {
		4
	} else if line_number < 1_000 {
		5
	} else if line_number < 10_000 {
		6
	} else if line_number < 100_000 {
		7
	} else {
		8
	}
	if max_workspace_read_range_bytes - output.len <= prefix_bytes {
		return WorkspaceRangeLineAppend{
			truncated: true
		}
	}
	output.write_decimal(i64(line_number))
	output.write_string(': ')
	remaining := max_workspace_read_range_bytes - output.len
	if line.len >= remaining {
		mut end := remaining
		if end > line.len {
			end = line.len
		}
		for end > 0 && end < line.len && (line[end] & 0xc0) == 0x80 {
			end--
		}
		output.write_string(line[..end])
		return WorkspaceRangeLineAppend{
			written:   true
			truncated: true
		}
	}
	output.write_string(line)
	output.write_byte(`\n`)
	return WorkspaceRangeLineAppend{
		written: true
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
		for line_number, line in content.split_into_lines() {
			if line.contains(query) {
				result.matches << WorkspaceSearchMatch{
					path: relative_path
					line: line_number + 1
					text: workspace_excerpt(line, 2_000)
				}
				if result.matches.len >= max_workspace_search_results {
					result.truncated = true
					return result
				}
			}
		}
	}
	if walker.stopped {
		result.truncated = true
	}
	return result
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
