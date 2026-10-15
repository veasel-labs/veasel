module main

import encoding.utf8
import json2
import os
import yaml

const plugin_manifest_schema = 'https://agent-plugins.org/schemas/1.0.0/plugin.schema.json'
const plugin_mcp_schema = 'https://agent-plugins.org/schemas/1.0.0/mcp.schema.json'
const plugin_schema_key = '$' + 'schema'
const veasel_extension_namespace = 'com.veasel.code'
const max_veasel_extension_display_name_len = 64
const max_plugin_manifest_bytes = 1_000_000
const max_plugin_skill_bytes = 1_000_000
const max_plugin_skill_resource_bytes = 512_000
const max_plugin_skill_frontmatter_bytes = 64_000
const max_plugin_skills = 256
const max_agent_skill_listed_resources = 10
const max_agent_skill_list_scan_entries = 256
const max_plugin_mcp_servers = 128
const max_plugin_mcp_args = 4096
const max_plugin_mcp_env = 256
const max_plugin_mcp_env_key_len = 256
const max_plugin_mcp_headers = 128
const max_plugin_mcp_header_value_bytes = 4096
const max_plugin_mcp_server_name_len = 64

struct AgentPlugin {
pub:
	root     string
	manifest PluginManifest
pub mut:
	skills               []PluginSkill
	mcp_servers          []PluginMCPServer
	diagnostics          []PluginDiagnostic
	veasel_has_directory bool
}

struct PluginManifest {
pub:
	name                string
	version             string
	description         string
	license             string
	veasel_display_name string
	root_fields         map[string]json2.Any
}

struct PluginSkill {
pub:
	name        string
	description string
	path        string
	// Agent Skills hint only; it must never grant authority beyond user policy.
	allowed_tools          string
	allowed_tools_declared bool
mut:
	directory string
}

struct PluginMCPServer {
pub:
	name      string
	transport string
	command   string
	args      []string
	url       string
	headers   map[string]string
	cwd       string
	env       map[string]string
pub mut:
	plugin_name string
}

struct PluginDiagnostic {
pub:
	component string
	message   string
}

fn canonical_plugin_root(path string) !string {
	if path.len == 0 || path.len > os.max_path_len {
		return error('invalid plugin directory')
	}
	root := os.real_path(path)
	if !os.is_abs_path(root) || !os.is_dir(root) {
		return error('plugin directory does not exist')
	}
	return root
}

fn plugin_path(root string, relative string) !string {
	if relative.len == 0 || os.is_abs_path(relative) {
		return error('invalid plugin-relative path')
	}
	for segment in relative.replace('\\', '/').split('/') {
		if segment == '..' {
			return error('plugin-relative path must not ascend from its root')
		}
	}
	joined := os.join_path(root, relative)
	if !os.exists(joined) {
		return error('plugin-relative path does not exist')
	}
	resolved := os.real_path(joined)
	if !os.is_abs_path(resolved) {
		return error('plugin-relative path could not be resolved')
	}
	if !path_is_within(root, resolved) {
		return error('plugin path escapes its package root')
	}
	return resolved
}

// read_plugin_file bounds allocation even if a package changes after a size
// check. The extra byte detects growth beyond the supported limit.
fn read_plugin_file(path string, limit int) !string {
	if limit < 0 {
		return error('invalid plugin file size limit')
	}
	mut file := os.open(path)!
	defer {
		file.close()
	}
	mut bytes := []u8{len: limit + 1}
	count := file.read_bytes_into(0, mut bytes)!
	if count > limit {
		return error('plugin file exceeds the size limit')
	}
	return bytes[..count].bytestr()
}

fn path_is_within(root string, path string) bool {
	canonical_root := os.real_path(root).trim_right(os.path_separator)
	canonical_path := os.real_path(path)
	if canonical_root == '' {
		return canonical_path.starts_with(os.path_separator)
	}
	if canonical_path == canonical_root {
		return true
	}
	return canonical_path.starts_with(canonical_root + os.path_separator)
}

fn load_agent_plugin(directory string) !AgentPlugin {
	root := canonical_plugin_root(directory)!
	manifest_path := plugin_path(root, 'plugin.json')!
	if !os.is_file(manifest_path) {
		return error('plugin.json must be a regular file in the plugin root')
	}
	manifest_text := read_plugin_file(manifest_path, max_plugin_manifest_bytes)!
	fields := json2.decode[map[string]json2.Any](manifest_text) or {
		return error('plugin.json must be a JSON object')
	}
	manifest, diagnostics := parse_plugin_manifest(fields)!
	mut plugin := AgentPlugin{
		root:        root
		manifest:    manifest
		diagnostics: diagnostics
	}
	load_veasel_code_directory(root, mut plugin)
	load_plugin_skills(root, mut plugin)
	load_plugin_mcp(root, fields, mut plugin)
	for index in 0 .. plugin.mcp_servers.len {
		plugin.mcp_servers[index].plugin_name = plugin.manifest.name
	}
	return plugin
}

fn parse_plugin_manifest(fields map[string]json2.Any) !(PluginManifest, []PluginDiagnostic) {
	mut diagnostics := []PluginDiagnostic{}
	allowed_fields := [plugin_schema_key, 'name', 'version', 'description', 'author', 'homepage',
		'repository', 'license', 'keywords', 'extensions']
	for key, _ in fields {
		if key !in allowed_fields {
			diagnostics << PluginDiagnostic{
				component: 'plugin.json'
				message:   'Ignoring unknown top-level field `${key}`'
			}
		}
	}
	schema := plugin_required_string(fields, plugin_schema_key)!
	if schema != plugin_manifest_schema {
		return error('unsupported Agent Plugins manifest schema')
	}
	name := plugin_required_string(fields, 'name')!
	if !is_valid_plugin_name(name) {
		return error('plugin name does not satisfy the Agent Plugins v1.0.0 name rules')
	}
	mut optional := map[string]string{}
	for key in ['version', 'description', 'homepage', 'repository', 'license'] {
		if value := fields[key] {
			if value is string {
				optional[key] = value
			} else {
				return error('plugin field `${key}` must be a string')
			}
		}
	}
	if author := fields['author'] {
		if author is map[string]json2.Any {
			for key, value in author {
				if key !in ['name', 'email', 'url'] || value !is string {
					return error('plugin author fields are invalid')
				}
			}
		} else {
			return error('plugin author must be an object')
		}
	}
	if keywords := fields['keywords'] {
		if keywords is []json2.Any {
			for keyword in keywords {
				if keyword !is string {
					return error('plugin keywords must be strings')
				}
			}
		} else {
			return error('plugin keywords must be an array')
		}
	}
	mut veasel_display_name := ''
	if extensions := fields['extensions'] {
		if extensions !is map[string]json2.Any {
			diagnostics << PluginDiagnostic{
				component: 'plugin.json'
				message:   'Ignoring non-object extensions field'
			}
		} else {
			for namespace, value in extensions {
				if namespace != veasel_extension_namespace {
					continue
				}
				if value !is map[string]json2.Any {
					diagnostics << PluginDiagnostic{
						component: veasel_extension_namespace
						message:   'Ignoring invalid Veasel extension data'
					}
					continue
				}
				label, label_diagnostics := veasel_extension_display_name(value as map[string]json2.Any)
				veasel_display_name = label
				diagnostics << label_diagnostics
			}
		}
	}
	return PluginManifest{
		name:                name
		version:             optional['version']
		description:         optional['description']
		license:             optional['license']
		veasel_display_name: veasel_display_name
		root_fields:         fields
	}, diagnostics
}

// veasel_extension_display_name reads only the documented label. Other keys in
// the owned namespace are ignored so a future field cannot change loading.
fn veasel_extension_display_name(value map[string]json2.Any) (string, []PluginDiagnostic) {
	mut diagnostics := []PluginDiagnostic{}
	mut display_name := ''
	for key, raw in value {
		if key != 'display_name' {
			diagnostics << PluginDiagnostic{
				component: veasel_extension_namespace
				message:   'Ignoring unsupported Veasel extension field `${key}`'
			}
			continue
		}
		if raw !is string || !is_safe_veasel_extension_label((raw as string).trim_space()) {
			diagnostics << PluginDiagnostic{
				component: veasel_extension_namespace
				message:   'Ignoring invalid Veasel extension display_name'
			}
			continue
		}
		display_name = (raw as string).trim_space()
	}
	return display_name, diagnostics
}

fn is_safe_veasel_extension_label(value string) bool {
	if value.len < 1 || value.len > max_veasel_extension_display_name_len {
		return false
	}
	for character in value {
		if character < ` ` || character == 0x7f {
			return false
		}
	}
	return true
}

// load_veasel_code_directory records whether the exact client directory is
// contained in the package. It does not list, read, or execute the contents.
fn load_veasel_code_directory(root string, mut plugin AgentPlugin) {
	candidate := os.join_path(root, veasel_extension_namespace)
	if !os.exists(candidate) {
		return
	}
	resolved := plugin_path(root, veasel_extension_namespace) or {
		plugin.diagnostics << PluginDiagnostic{
			component: veasel_extension_namespace
			message:   'Ignoring Veasel extension directory outside the plugin root'
		}
		return
	}
	if !os.is_dir(resolved) {
		plugin.diagnostics << PluginDiagnostic{
			component: veasel_extension_namespace
			message:   'Ignoring Veasel extension path that is not a directory'
		}
		return
	}
	plugin.veasel_has_directory = true
}

fn plugin_required_string(fields map[string]json2.Any, key string) !string {
	value := fields[key] or { return error('plugin field `${key}` is required') }
	if value is string {
		text := value as string
		if text.trim_space().len > 0 {
			return text
		}
	}
	return error('plugin field `${key}` must be a non-empty string')
}

fn is_valid_plugin_name(name string) bool {
	if name.len < 1 || name.len > 64 || name[0] !in `a` .. `z` && name[0] !in `0` .. `9`
		|| name[name.len - 1] !in `a` .. `z` && name[name.len - 1] !in `0` .. `9`
		|| name.contains('--') || name.contains('..') {
		return false
	}
	for c in name {
		if c !in `a` .. `z` && c !in `0` .. `9` && c !in [`-`, `.`] {
			return false
		}
	}
	return true
}

fn load_plugin_skills(root string, mut plugin AgentPlugin) {
	_ := os.lstat(os.join_path(root, 'skills')) or { return }
	skills_path := plugin_path(root, 'skills') or {
		plugin.diagnostics << PluginDiagnostic{
			component: 'skills'
			message:   'Ignoring skills directory outside the plugin root'
		}
		return
	}
	if !os.is_dir(skills_path) {
		plugin.diagnostics << PluginDiagnostic{
			component: 'skills'
			message:   'Ignoring invalid skills component: expected a directory'
		}
		return
	}
	entries := os.ls(skills_path) or {
		plugin.diagnostics << PluginDiagnostic{
			component: 'skills'
			message:   'Unable to list skills directory'
		}
		return
	}
	if entries.len > max_plugin_skills {
		plugin.diagnostics << PluginDiagnostic{
			component: 'skills'
			message:   'Ignoring skills directory with more than ${max_plugin_skills} entries'
		}
		return
	}
	for entry in entries {
		resolved_candidate := plugin_path(root, os.join_path('skills', entry)) or {
			plugin.diagnostics << PluginDiagnostic{
				component: 'skills/${entry}'
				message:   'Skipping skill outside the plugin root'
			}
			continue
		}
		if !os.is_dir(resolved_candidate) {
			continue
		}
		_ := os.lstat(os.join_path(root, 'skills', entry, 'SKILL.md')) or { continue }
		resolved_skill := plugin_path(root, os.join_path('skills', entry, 'SKILL.md')) or {
			plugin.diagnostics << PluginDiagnostic{
				component: 'skills/${entry}'
				message:   'Skipping skill file outside the plugin root'
			}
			continue
		}
		if !os.is_file(resolved_skill) {
			continue
		}
		content := read_plugin_file(resolved_skill, max_plugin_skill_bytes) or {
			plugin.diagnostics << PluginDiagnostic{
				component: 'skills/${entry}'
				message:   'Unable to read skill file'
			}
			continue
		}
		mut skill := parse_agent_skill(entry, resolved_skill, content) or {
			plugin.diagnostics << PluginDiagnostic{
				component: 'skills/${entry}'
				message:   'Skipping invalid Agent Skill: ${err.msg()}'
			}
			continue
		}
		skill.directory = resolved_candidate
		plugin.skills << skill
	}
}

fn parse_agent_skill(directory_name string, path string, content string) !PluginSkill {
	lines := content.replace('\r\n', '\n').replace('\r', '\n').split('\n')
	if lines.len < 3 || lines[0].trim_space() != '---' {
		return error('missing YAML frontmatter')
	}
	mut closing := -1
	for index in 1 .. lines.len {
		if lines[index].trim_space() == '---' {
			closing = index
			break
		}
	}
	if closing < 0 {
		return error('unterminated YAML frontmatter')
	}
	frontmatter := lines[1..closing].join('\n')
	if frontmatter.len > max_plugin_skill_frontmatter_bytes {
		return error('YAML frontmatter exceeds the size limit')
	}
	doc := yaml.parse_text(frontmatter) or { return error('invalid YAML frontmatter') }
	if doc.root !is map[string]yaml.Any {
		return error('frontmatter must be a YAML mapping')
	}
	fields := doc.root as map[string]yaml.Any
	for key, _ in fields {
		if key !in ['name', 'description', 'license', 'compatibility', 'metadata', 'allowed-tools'] {
			return error('unknown Agent Skill frontmatter field `${key}`')
		}
	}
	name := skill_required_string(fields, 'name')!
	description := skill_required_string(fields, 'description')!
	if !is_valid_skill_name(name) || name != directory_name {
		return error('skill name must be valid and match its directory')
	}
	if description.runes().len > 1024 {
		return error('skill description exceeds 1024 characters')
	}
	if description.trim_space().len == 0 {
		return error('skill description must not be empty')
	}
	if skill_text_has_unsafe_controls(description) {
		return error('skill description must not contain control bytes')
	}
	mut allowed_tools := ''
	mut allowed_tools_declared := false
	for key in ['license', 'compatibility', 'allowed-tools'] {
		if value := fields[key] {
			if value !is string {
				return error('skill field `${key}` must be a string')
			}
			text := value as string
			if skill_text_has_unsafe_controls(text) {
				return error('skill field `${key}` must not contain control bytes')
			}
			if key == 'compatibility' && (text.runes().len == 0 || text.runes().len > 500) {
				return error('skill compatibility must contain 1 to 500 characters')
			}
			if key == 'allowed-tools' {
				allowed_tools = text
				allowed_tools_declared = true
			}
		}
	}
	if metadata := fields['metadata'] {
		if metadata !is map[string]yaml.Any {
			return error('skill metadata must be a mapping')
		}
		for _, value in metadata as map[string]yaml.Any {
			if value !is string {
				return error('skill metadata values must be strings')
			}
			if skill_text_has_unsafe_controls(value as string) {
				return error('skill metadata values must not contain control bytes')
			}
		}
	}
	return PluginSkill{
		name:                   name
		description:            description
		path:                   path
		allowed_tools:          allowed_tools
		allowed_tools_declared: allowed_tools_declared
	}
}

fn skill_text_has_unsafe_controls(value string) bool {
	for c in value {
		// Reject C0 controls and DEL so skill metadata cannot hide review-breaking bytes.
		// YAML already rejects many of these at parse time; catch survivors like TAB.
		if c < 32 || c == 127 {
			return true
		}
	}
	return false
}

// load_skill_instructions implements Agent Skills progressive disclosure: the
// host keeps metadata available for discovery and reads the body only when the
// user enables the skill for the session or the model calls agent_skill_load.
fn load_skill_instructions(plugin_root string, skill PluginSkill) !string {
	root := canonical_plugin_root(plugin_root)!
	path := os.real_path(skill.path)
	if !path_is_within(root, path) {
		return error('skill path escapes its plugin root')
	}
	if !os.is_file(path) {
		return error('skill file is missing or exceeds the size limit')
	}
	content := read_plugin_file(path, max_plugin_skill_bytes)!
	current := parse_agent_skill(skill.name, path, content)!
	if current.name != skill.name || current.description != skill.description {
		return error('skill metadata changed after discovery')
	}
	return extract_agent_skill_body(content)
}

fn load_agent_skill_resource(skill_root string, relative_path string) !string {
	if relative_path.len == 0 || relative_path.len > os.max_path_len || relative_path.contains('\0') {
		return error('invalid Agent Skill resource path')
	}
	root := canonical_plugin_root(skill_root)!
	if root != skill_root {
		return error('Agent Skill resource root changed after activation')
	}
	path := plugin_path(root, relative_path)!
	if !os.is_file(path) {
		return error('Agent Skill resource is not a regular file')
	}
	content := read_plugin_file(path, max_plugin_skill_resource_bytes)!
	if os.real_path(root) != root || os.real_path(path) != path {
		return error('Agent Skill resource path changed while reading')
	}
	content_bytes := content.bytes()
	if content.contains('\0') || (content_bytes.len > 0 && !utf8.validate(&content_bytes[0], content_bytes.len)) {
		return error('Agent Skill resource must be UTF-8 text')
	}
	return content
}

struct AgentSkillResourceLister {
mut:
	root      string
	files     []string
	scanned   int
	truncated bool
}

fn (mut lister AgentSkillResourceLister) visit(path string, entry os.WalkDirEntry) os.WalkDirAction {
	if entry.err != none {
		lister.truncated = true
		return .proceed
	}
	if entry.is_dir {
		return .proceed
	}
	if entry.typ != .regular || os.is_link(path) {
		return .proceed
	}
	lister.scanned++
	if lister.scanned > max_agent_skill_list_scan_entries {
		lister.truncated = true
		return .stop
	}
	if entry.name == 'SKILL.md' && os.dir(path) == lister.root {
		return .proceed
	}
	relative_path := os.path_rel(lister.root, path) or {
		lister.truncated = true
		return .proceed
	}
	normalized := relative_path.replace('\\', '/')
	if normalized.len == 0 || normalized.contains('\0') || normalized.contains('..') {
		return .proceed
	}
	lister.files << normalized
	if lister.files.len >= max_agent_skill_listed_resources {
		lister.truncated = lister.scanned < max_agent_skill_list_scan_entries
		return .stop
	}
	return .proceed
}

// list_agent_skill_resource_paths samples relative files inside a skill folder
// for model guidance. It never reads file contents and never follows symlinks.
fn list_agent_skill_resource_paths(skill_root string) !([]string, bool) {
	root := canonical_plugin_root(skill_root)!
	if root != skill_root {
		return error('Agent Skill resource root changed after discovery')
	}
	mut lister := AgentSkillResourceLister{
		root:  root
		files: []string{cap: max_agent_skill_listed_resources}
	}
	os.walk_dir(root, lister.visit)!
	lister.files.sort()
	if lister.files.len > max_agent_skill_listed_resources {
		lister.files = lister.files[..max_agent_skill_listed_resources]
		lister.truncated = true
	}
	return lister.files, lister.truncated
}

fn extract_agent_skill_body(content string) !string {
	lines := content.replace('\r\n', '\n').replace('\r', '\n').split('\n')
	if lines.len < 3 || lines[0].trim_space() != '---' {
		return error('skill frontmatter changed after discovery')
	}
	mut closing := -1
	for index in 1 .. lines.len {
		if lines[index].trim_space() == '---' {
			closing = index
			break
		}
	}
	if closing < 0 {
		return error('skill frontmatter changed after discovery')
	}
	mut position := 0
	mut line_index := 0
	for position < content.len {
		if line_index == closing + 1 {
			return content[position..]
		}
		if content[position] == `\r` {
			position++
			if position < content.len && content[position] == `\n` {
				position++
			}
			line_index++
		} else if content[position] == `\n` {
			position++
			line_index++
		} else {
			position++
		}
	}
	if line_index == closing {
		return ''
	}
	return error('skill frontmatter changed after discovery')
}

fn skill_required_string(fields map[string]yaml.Any, key string) !string {
	value := fields[key] or { return error('`${key}` is required') }
	if value is string {
		text := value as string
		if text.trim_space().len > 0 {
			return text
		}
	}
	return error('`${key}` must be a non-empty string')
}

fn is_valid_skill_name(name string) bool {
	if name.len == 0 {
		return false
	}
	mut rune_count := 0
	mut previous_was_hyphen := false
	for c in name.runes_iterator() {
		rune_count++
		if rune_count > 64 {
			return false
		}
		if c == `-` {
			if rune_count == 1 || previous_was_hyphen {
				return false
			}
			previous_was_hyphen = true
			continue
		}
		previous_was_hyphen = false
		if (!utf8.is_letter(c) && !utf8.is_number(c)) || c.to_lower() != c {
			return false
		}
	}
	return rune_count > 0 && !previous_was_hyphen
}
