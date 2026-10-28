module main

import http
import json2
import os
import context as vcontext
import time
import uuid

fn test_sanitize_agent_tool_result_rejects_nul_bytes() {
	assert sanitize_agent_tool_result('ok') == 'ok'
	assert sanitize_agent_tool_result('bad\0data') == 'tool result rejected: contained a NUL byte'
	assert !sanitize_agent_tool_result('bad\0data').contains('\0')
}

fn test_plugin_mcp_tool_result_failure_classification() {
	assert plugin_mcp_tool_result_failed('{"error":"transport failed"}')
	assert plugin_mcp_tool_result_failed('{"content":[{"type":"text","text":"tool failed"}],"isError":true}')
	assert !plugin_mcp_tool_result_failed('{"content":[{"type":"text","text":"ok"}],"isError":false}')
	assert !plugin_mcp_tool_result_failed('{"content":[{"type":"text","text":"legacy result"}]}')
}

fn test_skill_tool_restrictions_filter_advertising_and_reject_execution() {
	root := os.join_path(os.temp_dir(), 'veasel-skill-tool-policy-${uuid.new_v4().str()}')
	os.mkdir_all(root) or { panic(err) }
	defer { os.rmdir_all(root) or {} }
	path := os.join_path(root, 'source.txt')
	os.write_file(path, 'must remain unchanged') or { panic(err) }
	store := open_store(':memory:') or { panic(err) }
	defer { store.close() or {} }
	plugin_directory := os.join_path(root, 'plugins')
	os.mkdir_all(plugin_directory) or { panic(err) }
	mut app := new_app(store, plugin_directory)
	defer { app.close() }
	session := store.create_session(SessionInput{
		title:     'Restricted skill tools'
		directory: root
	}) or { panic(err) }
	policy := agent_tool_policy_for_skills([PluginSkill{
		name:                   'read-only'
		allowed_tools:          'workspace_read_file fabricated_tool'
		allowed_tools_declared: true
	}])
	advertised := restrict_agent_tools(workspace_agent_tools(), policy)
	assert advertised.map(it.name) == ['workspace_read_file']
	mut mcp_connections := []PluginMCPConnection{}
	mut skill_context := SessionSkillContext{
		tool_policy: policy
	}
	denied_edit := execute_test_agent_tool(app, root, session.id, ProviderToolCall{
		id:       'denied-edit'
		function: ProviderFunctionCall{
			name:      'workspace_propose_file_edit'
			arguments: '{"path":"source.txt","content":"changed"}'
		}
	}, mut skill_context, {}, mut mcp_connections)
	assert denied_edit.contains('active Agent Skill tool restrictions')
	assert os.read_file(path) or { panic(err) } == 'must remain unchanged'
	assert (store.workspace_edits(session.id) or { panic(err) }).len == 0
	assert (store.shell_commands(session.id) or { panic(err) }).len == 0
	denied_mcp := execute_test_agent_tool(app, root, session.id, ProviderToolCall{
		id:       'denied-mcp'
		function: ProviderFunctionCall{
			name:      'mcp_trusted_action'
			arguments: '{}'
		}
	}, mut skill_context, {
		'mcp_trusted_action': PluginMCPToolBinding{
			connection_index: 0
			native_name:      'action'
		}
	}, mut mcp_connections)
	assert denied_mcp.contains('active Agent Skill tool restrictions')
}

fn test_agent_skill_resource_tool_reads_only_resources_from_enabled_skills() {
	root := os.join_path(os.temp_dir(), 'veasel-skill-resource-${uuid.new_v4().str()}')
	skill_root := os.join_path(root, 'skills', 'review')
	os.mkdir_all(os.join_path(skill_root, 'references')) or { panic(err) }
	defer { os.rmdir_all(root) or {} }
	os.write_file(os.join_path(skill_root, 'references', 'guide.md'), 'Reference instructions.') or {
		panic(err)
	}
	store := open_store(':memory:') or { panic(err) }
	defer { store.close() or {} }
	os.mkdir_all(os.join_path(root, 'workspace')) or { panic(err) }
	mut app := new_app(store, os.join_path(root, 'plugins'))
	defer { app.close() }
	session := store.create_session(SessionInput{
		title:     'Skill resource'
		directory: os.join_path(root, 'workspace')
	}) or { panic(err) }
	access := [AgentSkillResourceAccess{
		plugin_name: 'review-tools'
		skill_name:  'review'
		skill_root:  skill_root
	}]
	definitions := agent_skill_resource_tools()
	assert definitions.map(it.name) == ['agent_skill_read_resource']
	load_definitions := agent_skill_load_tools(AvailableSkillsDisclosure{
		entries: [
			AvailableSkillEntry{
				plugin_name: 'review-tools'
				skill_name:  'review'
				description: 'Review carefully.'
				location:    '/tmp/review-tools/skills/review'
			},
		]
	})
	assert load_definitions.map(it.name) == ['agent_skill_load']
	assert load_definitions[0].description.contains('<available_skills>')
	assert load_definitions[0].description.contains('review-tools')
	assert load_definitions[0].description.contains('Review carefully.')
	assert load_definitions[0].description.contains('<location>')
	assert load_definitions[0].parameters.properties['plugin_name'].enum_values == ['review-tools']
	assert load_definitions[0].parameters.properties['skill_name'].enum_values == ['review']
	assert agent_skill_load_tools(AvailableSkillsDisclosure{}).len == 0
	resource_policy := agent_tool_policy_for_skills([PluginSkill{
		name:                   'references'
		allowed_tools:          'agent_skill_read_resource'
		allowed_tools_declared: true
	}])
	assert restrict_agent_tools(definitions, resource_policy).map(it.name) == ['agent_skill_read_resource']
	mut mcp_connections := []PluginMCPConnection{}
	call := ProviderToolCall{
		id:       'read-reference'
		function: ProviderFunctionCall{
			name:      'agent_skill_read_resource'
			arguments: '{"plugin_name":"review-tools","skill_name":"review","path":"references/guide.md"}'
		}
	}
	mut allowed_context := SessionSkillContext{
		resource_access: access
	}
	allowed := execute_test_agent_tool(app, os.join_path(root, 'workspace'), session.id, call,
		mut allowed_context, {}, mut mcp_connections)
	assert allowed.contains('Reference instructions.')
	assert allowed.contains('references/guide.md')
	mut blocked_context := SessionSkillContext{
		tool_policy:     agent_tool_policy_for_skills([PluginSkill{
			name:                   'read-only'
			allowed_tools:          'workspace_read_file'
			allowed_tools_declared: true
		}])
		resource_access: access
	}
	blocked := execute_test_agent_tool(app, os.join_path(root, 'workspace'), session.id, call,
		mut blocked_context, {}, mut mcp_connections)
	assert blocked.contains('active Agent Skill tool restrictions')
	assert restrict_agent_tools(definitions, blocked_context.tool_policy).len == 0
	mut disabled_context := SessionSkillContext{}
	disabled := execute_test_agent_tool(app, os.join_path(root, 'workspace'), session.id, call,
		mut disabled_context, {}, mut mcp_connections)
	assert disabled.contains('has not been loaded in this turn')
}

fn test_available_skills_catalog_discloses_metadata_without_bodies() {
	root := os.join_path(os.temp_dir(), 'veasel-available-skills-${uuid.new_v4().str()}')
	project := os.join_path(root, 'workspace')
	plugin_dir := os.join_path(root, 'plugins')
	home := os.join_path(root, 'home')
	os.mkdir_all(os.join_path(project, '.agents', 'skills', 'deep-review', 'references')) or {
		panic(err)
	}
	os.mkdir_all(os.join_path(home, '.agents', 'skills', 'quick-check')) or { panic(err) }
	os.mkdir_all(plugin_dir) or { panic(err) }
	os.mkdir_all(home) or { panic(err) }
	defer { os.rmdir_all(root) or {} }
	prior_home := os.getenv('HOME')
	prior_skills_dirs := os.getenv('VEASEL_SKILLS_DIRS')
	prior_codex := os.getenv('CODEX_HOME')
	prior_xdg := os.getenv('XDG_CONFIG_HOME')
	had_skills_dirs := 'VEASEL_SKILLS_DIRS' in os.environ()
	had_codex := 'CODEX_HOME' in os.environ()
	had_xdg := 'XDG_CONFIG_HOME' in os.environ()
	os.setenv('HOME', home, true)
	os.unsetenv('VEASEL_SKILLS_DIRS')
	os.unsetenv('CODEX_HOME')
	os.unsetenv('XDG_CONFIG_HOME')
	defer {
		os.setenv('HOME', prior_home, true)
		if had_skills_dirs {
			os.setenv('VEASEL_SKILLS_DIRS', prior_skills_dirs, true)
		} else {
			os.unsetenv('VEASEL_SKILLS_DIRS')
		}
		if had_codex {
			os.setenv('CODEX_HOME', prior_codex, true)
		} else {
			os.unsetenv('CODEX_HOME')
		}
		if had_xdg {
			os.setenv('XDG_CONFIG_HOME', prior_xdg, true)
		} else {
			os.unsetenv('XDG_CONFIG_HOME')
		}
	}
	os.write_file(os.join_path(project, '.agents', 'skills', 'deep-review', 'SKILL.md'),
		'---\nname: deep-review\ndescription: Review carefully with references.\n---\n\nSECRET_BODY_SHOULD_STAY_OFF_CATALOG\nUse the reference guide.') or {
		panic(err)
	}
	os.write_file(os.join_path(project, '.agents', 'skills', 'deep-review', 'references', 'guide.md'),
		'Turn-loaded reference.') or { panic(err) }
	os.write_file(os.join_path(home, '.agents', 'skills', 'quick-check', 'SKILL.md'),
		'---\nname: quick-check\ndescription: Fast lint-oriented check.\n---\n\nQUICK_BODY_SHOULD_STAY_OFF_CATALOG') or {
		panic(err)
	}
	store := open_store(':memory:') or { panic(err) }
	defer { store.close() or {} }
	mut app := new_app(store, plugin_dir)
	defer { app.close() }
	session := store.create_session(SessionInput{
		title:     'Catalog trust'
		directory: project
	}) or { panic(err) }
	disclosure := app.available_skills_for_turn(project, session.id)
	catalog := format_available_skills_catalog(disclosure.entries, disclosure.truncated)
	assert catalog.contains('<available_skills>')
	assert !catalog.contains('<skill_name>deep-review</skill_name>')
	assert catalog.contains('<plugin_name>agents</plugin_name>')
	assert catalog.contains('<skill_name>quick-check</skill_name>')
	assert catalog.contains('Fast lint-oriented check.')
	assert catalog.contains('<location>')
	assert !catalog.contains('SECRET_BODY_SHOULD_STAY_OFF_CATALOG')
	assert !catalog.contains('QUICK_BODY_SHOULD_STAY_OFF_CATALOG')
	assert !catalog.contains('Use the reference guide.')
	tools := agent_skill_load_tools(disclosure)
	assert tools.len == 1
	assert tools[0].name == 'agent_skill_load'
	assert tools[0].description.starts_with('Load one matching skill body')
	assert !tools[0].description.contains('fail-closed trust')
	assert !tools[0].description.contains('deep-review')
	assert tools[0].description.contains('quick-check')
	assert tools[0].parameters.properties['plugin_name'].enum_values == ['agents']
	assert tools[0].parameters.properties['skill_name'].enum_values == ['quick-check']
	assert !tools[0].description.contains('SECRET_BODY_SHOULD_STAY_OFF_CATALOG')
	store.set_session_plugin_skill(session.id, 'agents', 'deep-review', true) or { panic(err) }
	trusted := app.available_skills_for_turn(project, session.id)
	trusted_catalog := format_available_skills_catalog(trusted.entries, trusted.truncated)
	assert trusted_catalog.contains('<skill_name>deep-review</skill_name>')
	assert trusted_catalog.contains('Review carefully with references.')
	assert trusted_catalog.contains('<skill_name>quick-check</skill_name>')
	assert !trusted_catalog.contains('SECRET_BODY_SHOULD_STAY_OFF_CATALOG')
	escaped, _ := available_skill_entries_from_catalog(PluginCatalog{
		plugins: [
			PluginCatalogEntry{
				name:   'demo'
				skills: [
					PluginSkillSummary{
						name:        'ampersand'
						description: 'Use A < B & C > D "quoted"'
						enabled:     true
					},
				]
			},
		]
	}, map[string]bool{})
	formatted := format_available_skills_catalog(escaped, false)
	assert formatted.contains('Use A &lt; B &amp; C &gt; D &quot;quoted&quot;')
	assert !formatted.contains('Use A < B & C > D "quoted"')
}

fn test_available_skills_catalog_omits_disabled_components() {
	root := os.join_path(os.temp_dir(), 'veasel-available-skills-disabled-${uuid.new_v4().str()}')
	project := os.join_path(root, 'workspace')
	plugin_dir := os.join_path(root, 'plugins')
	home := os.join_path(root, 'home')
	os.mkdir_all(os.join_path(home, '.agents', 'skills', 'deep-review')) or { panic(err) }
	os.mkdir_all(plugin_dir) or { panic(err) }
	os.mkdir_all(project) or { panic(err) }
	os.mkdir_all(home) or { panic(err) }
	defer { os.rmdir_all(root) or {} }
	prior_home := os.getenv('HOME')
	prior_skills_dirs := os.getenv('VEASEL_SKILLS_DIRS')
	prior_codex := os.getenv('CODEX_HOME')
	prior_xdg := os.getenv('XDG_CONFIG_HOME')
	had_skills_dirs := 'VEASEL_SKILLS_DIRS' in os.environ()
	had_codex := 'CODEX_HOME' in os.environ()
	had_xdg := 'XDG_CONFIG_HOME' in os.environ()
	os.setenv('HOME', home, true)
	os.unsetenv('VEASEL_SKILLS_DIRS')
	os.unsetenv('CODEX_HOME')
	os.unsetenv('XDG_CONFIG_HOME')
	defer {
		os.setenv('HOME', prior_home, true)
		if had_skills_dirs {
			os.setenv('VEASEL_SKILLS_DIRS', prior_skills_dirs, true)
		} else {
			os.unsetenv('VEASEL_SKILLS_DIRS')
		}
		if had_codex {
			os.setenv('CODEX_HOME', prior_codex, true)
		} else {
			os.unsetenv('CODEX_HOME')
		}
		if had_xdg {
			os.setenv('XDG_CONFIG_HOME', prior_xdg, true)
		} else {
			os.unsetenv('XDG_CONFIG_HOME')
		}
	}
	os.write_file(os.join_path(home, '.agents', 'skills', 'deep-review', 'SKILL.md'),
		'---\nname: deep-review\ndescription: Review carefully.\n---\n\nBody') or {
		panic(err)
	}
	store := open_store(':memory:') or { panic(err) }
	defer { store.close() or {} }
	mut app := new_app(store, plugin_dir)
	defer { app.close() }
	before := app.available_skills_for_turn(project, '')
	assert before.entries.any(it.skill_name == 'deep-review')
	mut components := app.plugin_components
	components.set_enabled(PluginComponentToggleInput{
		plugin:  'agents'
		kind:    plugin_component_kind_skill
		name:    'deep-review'
		enabled: false
	}) or { panic(err) }
	catalog := app.available_skills_for_turn(project, '')
	assert catalog.entries.len == 0
	assert agent_skill_load_tools(catalog).len == 0
}

fn test_available_skills_catalog_omits_disable_model_invocation() {
	root := os.join_path(os.temp_dir(), 'veasel-available-skills-dmi-${uuid.new_v4().str()}')
	project := os.join_path(root, 'workspace')
	plugin_dir := os.join_path(root, 'plugins')
	home := os.join_path(root, 'home')
	os.mkdir_all(os.join_path(home, '.agents', 'skills', 'manual-only')) or { panic(err) }
	os.mkdir_all(os.join_path(home, '.agents', 'skills', 'auto-open')) or { panic(err) }
	os.mkdir_all(os.join_path(home, '.claude', 'skills', 'no-autoinvoke')) or { panic(err) }
	os.mkdir_all(plugin_dir) or { panic(err) }
	os.mkdir_all(project) or { panic(err) }
	os.mkdir_all(home) or { panic(err) }
	defer { os.rmdir_all(root) or {} }
	prior_home := os.getenv('HOME')
	prior_skills_dirs := os.getenv('VEASEL_SKILLS_DIRS')
	prior_codex := os.getenv('CODEX_HOME')
	prior_xdg := os.getenv('XDG_CONFIG_HOME')
	had_skills_dirs := 'VEASEL_SKILLS_DIRS' in os.environ()
	had_codex := 'CODEX_HOME' in os.environ()
	had_xdg := 'XDG_CONFIG_HOME' in os.environ()
	os.setenv('HOME', home, true)
	os.unsetenv('VEASEL_SKILLS_DIRS')
	os.unsetenv('CODEX_HOME')
	os.unsetenv('XDG_CONFIG_HOME')
	defer {
		os.setenv('HOME', prior_home, true)
		if had_skills_dirs {
			os.setenv('VEASEL_SKILLS_DIRS', prior_skills_dirs, true)
		} else {
			os.unsetenv('VEASEL_SKILLS_DIRS')
		}
		if had_codex {
			os.setenv('CODEX_HOME', prior_codex, true)
		} else {
			os.unsetenv('CODEX_HOME')
		}
		if had_xdg {
			os.setenv('XDG_CONFIG_HOME', prior_xdg, true)
		} else {
			os.unsetenv('XDG_CONFIG_HOME')
		}
	}
	os.write_file(os.join_path(home, '.agents', 'skills', 'manual-only', 'SKILL.md'),
		'---\nname: manual-only\ndescription: Slash or explicit load only.\ndisable-model-invocation: true\n---\n\nMANUAL BODY') or {
		panic(err)
	}
	os.write_file(os.join_path(home, '.agents', 'skills', 'auto-open', 'SKILL.md'),
		'---\nname: auto-open\ndescription: Shown in the model catalog.\n---\n\nAUTO BODY') or {
		panic(err)
	}
	os.write_file(os.join_path(home, '.claude', 'skills', 'no-autoinvoke', 'SKILL.md'),
		'---\nname: no-autoinvoke\ndescription: Hidden via OpenCode autoinvoke metadata.\nmetadata:\n  opencode/autoinvoke: "false"\n---\n\nNO AUTO BODY') or {
		panic(err)
	}
	store := open_store(':memory:') or { panic(err) }
	defer { store.close() or {} }
	mut app := new_app(store, plugin_dir)
	defer { app.close() }
	disclosure := app.available_skills_for_turn(project, '')
	assert disclosure.entries.any(it.skill_name == 'auto-open')
	assert !disclosure.entries.any(it.skill_name == 'manual-only')
	assert !disclosure.entries.any(it.skill_name == 'no-autoinvoke')
	catalog := format_available_skills_catalog(disclosure.entries, disclosure.truncated)
	assert catalog.contains('auto-open')
	assert !catalog.contains('manual-only')
	assert !catalog.contains('no-autoinvoke')
	assert !catalog.contains('MANUAL BODY')
}

fn test_available_skills_catalog_budget_shortens_before_omitting() {
	mut skills := []PluginSkillSummary{cap: 12}
	for index in 0 .. 12 {
		skills << PluginSkillSummary{
			name:        'skill-${index:02}'
			description: 'D'.repeat(400)
			location:    '/tmp/budget/skills/skill-${index:02}'
			enabled:     true
		}
	}
	entries, truncated := available_skill_entries_from_catalog(PluginCatalog{
		plugins: [
			PluginCatalogEntry{
				name:   'budget'
				skills: skills
			},
		]
	}, map[string]bool{})
	assert entries.len > 0
	xml := format_available_skills_catalog(entries, truncated)
	assert xml.len <= max_available_skills_catalog_chars
	assert entries[0].description.len <= max_available_skill_catalog_description_bytes + 3
	assert entries.any(it.location.len > 0)
}

fn test_agent_skill_load_tool_loads_body_without_session_enable() {
	root := os.join_path(os.temp_dir(), 'veasel-skill-load-${uuid.new_v4().str()}')
	project := os.join_path(root, 'workspace')
	home := os.join_path(root, 'home')
	project_skill := os.join_path(project, '.agents', 'skills', 'deep-review')
	user_skill := os.join_path(home, '.agents', 'skills', 'user-review')
	os.mkdir_all(os.join_path(project_skill, 'references')) or { panic(err) }
	os.mkdir_all(user_skill) or { panic(err) }
	defer { os.rmdir_all(root) or {} }
	prior_home := os.getenv('HOME')
	prior_skills_dirs := os.getenv('VEASEL_SKILLS_DIRS')
	prior_codex := os.getenv('CODEX_HOME')
	prior_xdg := os.getenv('XDG_CONFIG_HOME')
	had_skills_dirs := 'VEASEL_SKILLS_DIRS' in os.environ()
	had_codex := 'CODEX_HOME' in os.environ()
	had_xdg := 'XDG_CONFIG_HOME' in os.environ()
	os.setenv('HOME', home, true)
	os.unsetenv('VEASEL_SKILLS_DIRS')
	os.unsetenv('CODEX_HOME')
	os.unsetenv('XDG_CONFIG_HOME')
	defer {
		os.setenv('HOME', prior_home, true)
		if had_skills_dirs {
			os.setenv('VEASEL_SKILLS_DIRS', prior_skills_dirs, true)
		} else {
			os.unsetenv('VEASEL_SKILLS_DIRS')
		}
		if had_codex {
			os.setenv('CODEX_HOME', prior_codex, true)
		} else {
			os.unsetenv('CODEX_HOME')
		}
		if had_xdg {
			os.setenv('XDG_CONFIG_HOME', prior_xdg, true)
		} else {
			os.unsetenv('XDG_CONFIG_HOME')
		}
	}
	os.write_file(os.join_path(project_skill, 'SKILL.md'), '---\nname: deep-review\ndescription: Review carefully.\n---\n\nUse the reference guide.') or {
		panic(err)
	}
	os.write_file(os.join_path(project_skill, 'references', 'guide.md'), 'Turn-loaded reference.') or {
		panic(err)
	}
	os.write_file(os.join_path(user_skill, 'SKILL.md'), '---\nname: user-review\ndescription: User-scoped review.\n---\n\nUser skill body.') or {
		panic(err)
	}
	store := open_store(':memory:') or { panic(err) }
	defer { store.close() or {} }
	mut app := new_app(store, os.join_path(root, 'plugins'))
	defer { app.close() }
	session := store.create_session(SessionInput{
		title:     'On-demand skill load'
		directory: project
	}) or { panic(err) }
	mut mcp_connections := []PluginMCPConnection{}
	mut denied_context := SessionSkillContext{}
	project_denied := execute_test_agent_tool(app, project, session.id, ProviderToolCall{
		id:       'load-project-untrusted'
		function: ProviderFunctionCall{
			name:      'agent_skill_load'
			arguments: '{"plugin_name":"agents","skill_name":"deep-review"}'
		}
	}, mut denied_context, {}, mut mcp_connections)
	assert project_denied.contains('Project-scoped skills require explicit session')
	mut user_context := SessionSkillContext{}
	user_loaded := execute_test_agent_tool(app, project, session.id, ProviderToolCall{
		id:       'load-user-skill'
		function: ProviderFunctionCall{
			name:      'agent_skill_load'
			arguments: '{"plugin_name":"agents","skill_name":"user-review"}'
		}
	}, mut user_context, {}, mut mcp_connections)
	assert user_loaded.contains('User skill body.')
	assert user_context.resource_access.len == 1
	store.set_session_plugin_skill(session.id, 'agents', 'deep-review', true) or { panic(err) }
	mut skill_context := SessionSkillContext{}
	loaded := execute_test_agent_tool(app, project, session.id, ProviderToolCall{
		id:       'load-skill'
		function: ProviderFunctionCall{
			name:      'agent_skill_load'
			arguments: '{"plugin_name":"agents","skill_name":"deep-review"}'
		}
	}, mut skill_context, {}, mut mcp_connections)
	assert loaded.contains('Use the reference guide.')
	assert loaded.contains('references/guide.md')
	assert loaded.contains('untrusted')
	assert skill_context.resource_access.len == 1
	assert skill_context.resource_access[0].plugin_name == 'agents'
	assert skill_context.resource_access[0].skill_name == 'deep-review'
	read_after_load := execute_test_agent_tool(app, project, session.id, ProviderToolCall{
		id:       'read-after-load'
		function: ProviderFunctionCall{
			name:      'agent_skill_read_resource'
			arguments: '{"plugin_name":"agents","skill_name":"deep-review","path":"references/guide.md"}'
		}
	}, mut skill_context, {}, mut mcp_connections)
	assert read_after_load.contains('Turn-loaded reference.')
	mut batch_skill_context := SessionSkillContext{}
	mut batch_connections := []PluginMCPConnection{}
	mut batch_read_paths := map[string]bool{}
	mut batch_background := vcontext.background()
	mut batch_turn, cancel_batch := vcontext.with_timeout(mut batch_background, 2 * time.second)
	defer { cancel_batch() }
	batch_results := execute_agent_tool_batch(app, mut batch_turn, project, session.id,
		'test-skill-resource-barrier', [
			ProviderToolCall{
				id:       'load-before-resource'
				function: ProviderFunctionCall{
					name:      'agent_skill_load'
					arguments: '{"plugin_name":"agents","skill_name":"deep-review"}'
				}
			},
			ProviderToolCall{
				id:       'resource-after-load'
				function: ProviderFunctionCall{
					name:      'agent_skill_read_resource'
					arguments: '{"plugin_name":"agents","skill_name":"deep-review","path":"references/guide.md"}'
				}
			},
		], mut batch_skill_context, {}, mut batch_connections, ExecutionPolicyTurn{
			mode:        .ask
			interactive: true
		}, mut batch_read_paths, {}) or { panic(err) }
	assert batch_results.len == 2
	assert batch_results[0].contains('Use the reference guide.')
	assert batch_results[1].contains('Turn-loaded reference.')
	mut missing_context := SessionSkillContext{}
	missing := execute_test_agent_tool(app, project, session.id, ProviderToolCall{
		id:       'missing-skill'
		function: ProviderFunctionCall{
			name:      'agent_skill_load'
			arguments: '{"plugin_name":"agents","skill_name":"missing"}'
		}
	}, mut missing_context, {}, mut mcp_connections)
	assert missing.contains('not found')
}

fn execute_test_agent_tool(app &App, root string, session_id string, call ProviderToolCall,
	mut skill_context SessionSkillContext, bindings map[string]PluginMCPToolBinding,
	mut connections []PluginMCPConnection) string {
	mut background := vcontext.background()
	mut turn_ctx, cancel := vcontext.with_timeout(mut background, time.second)
	defer { cancel() }
	return execute_agent_tool_if_allowed(app, mut turn_ctx, root, session_id, 'test-operation', call,
		mut skill_context, bindings, mut connections, ExecutionPolicyTurn{
			mode:        .ask
			interactive: true
		}) or { panic(err) }
}

fn test_autonomous_benchmark_tools_apply_workspace_edits_and_record_shell_results() {
	root := os.join_path(os.temp_dir(), 'veasel-autonomous-tools-${uuid.new_v4().str()}')
	os.mkdir_all(root) or { panic(err) }
	defer { os.rmdir_all(root) or {} }
	file_path := os.join_path(root, 'target.txt')
	os.write_file(file_path, 'before') or { panic(err) }
	store := open_store(':memory:') or { panic(err) }
	defer { store.close() or {} }
	os.mkdir_all(os.join_path(root, 'plugins')) or { panic(err) }
	mut app := new_app(store, os.join_path(root, 'plugins'))
	defer { app.close() }
	session := store.create_session(SessionInput{ title: 'Autonomous fixture', directory: root }) or {
		panic(err)
	}
	edit := execute_autonomous_workspace_agent_tool(app, root, session.id, ProviderToolCall{
		id:       'edit'
		function: ProviderFunctionCall{
			name:      'workspace_propose_file_edit'
			arguments: '{"path":"target.txt","content":"after"}'
		}
	})
	assert edit.contains('Applied by graduated execution policy')
	assert os.read_file(file_path) or { panic(err) } == 'after'
	edits := store.workspace_edits(session.id) or { panic(err) }
	assert edits.len == 1
	assert edits[0].status == 'applied'

	command := execute_autonomous_workspace_agent_tool(app, root, session.id, ProviderToolCall{
		id:       'command'
		function: ProviderFunctionCall{
			name:      'workspace_propose_shell_command'
			arguments: '{"command":"printf benchmark-ok","cwd":".","timeout_seconds":5}'
		}
	})
	assert command.contains('benchmark-ok')
	assert command.contains('succeeded')
	commands := store.shell_commands(session.id) or { panic(err) }
	assert commands.len == 1
	assert commands[0].status == 'succeeded'
}

fn test_autonomous_shell_environment_does_not_forward_credentials() {
	environment := autonomous_shell_environment_from({
		'PATH':                  'tools'
		'HOME':                  '/tmp/home'
		'SYSTEMROOT':            'C:\\Windows'
		'WINDIR':                'C:\\Windows'
		'COMSPEC':               'C:\\Windows\\System32\\cmd.exe'
		'PATHEXT':               '.COM;.EXE;.BAT;.CMD'
		'TEMP':                  'C:\\Temp'
		'TMP':                   'C:\\Temp'
		'USERPROFILE':           'C:\\Users\\tester'
		'LOCALAPPDATA':          'C:\\Users\\tester\\AppData\\Local'
		'TMPDIR':                '/tmp'
		'LANG':                  'en_US.UTF-8'
		'LC_ALL':                'en_US.UTF-8'
		'LC_CTYPE':              'en_US.UTF-8'
		'LC_MESSAGES':           'en_US.UTF-8'
		'TERM':                  'xterm-256color'
		'VEASEL_MODEL_API_KEY':  'secret'
		'OPENAI_API_KEY':        'secret'
		'AWS_SECRET_ACCESS_KEY': 'secret'
		'GITHUB_TOKEN':          'secret'
	})
	assert environment['PATH'] == 'tools'
	$if windows {
		assert environment['SYSTEMROOT'] == 'C:\\Windows'
		assert environment['COMSPEC'] == 'C:\\Windows\\System32\\cmd.exe'
		assert environment['PATHEXT'] == '.COM;.EXE;.BAT;.CMD'
		assert !environment.keys().contains('HOME')
		assert environment.keys().sorted() == ['COMSPEC', 'LOCALAPPDATA', 'PATH', 'PATHEXT',
			'SYSTEMROOT', 'TEMP', 'TMP', 'USERPROFILE', 'WINDIR']
	} $else {
		assert environment['HOME'] == '/tmp/home'
		assert environment.keys().sorted() == ['HOME', 'LANG', 'LC_ALL', 'LC_CTYPE', 'LC_MESSAGES',
			'PATH', 'TERM', 'TMPDIR']
	}
	assert !environment.keys().any(it.ends_with('_API_KEY') || it.contains('TOKEN') || it.contains('SECRET'))
}

fn test_windows_autonomous_shell_environment_matches_windows_name_casing() {
	$if !windows {
		return
	}
	environment := autonomous_shell_environment_from({
		'Path':         'C:\\tools'
		'PathExt':      '.COM;.EXE;.BAT;.CMD'
		'SystemRoot':   'C:\\Windows'
		'ComSpec':      'C:\\Windows\\System32\\cmd.exe'
		'LocalAppData': 'C:\\Users\\tester\\AppData\\Local'
	})
	assert environment['PATH'] == 'C:\\tools'
	assert environment['PATHEXT'] == '.COM;.EXE;.BAT;.CMD'
	assert environment['SYSTEMROOT'] == 'C:\\Windows'
	assert environment['COMSPEC'] == 'C:\\Windows\\System32\\cmd.exe'
	assert environment['LOCALAPPDATA'] == 'C:\\Users\\tester\\AppData\\Local'
}

fn test_autonomous_shell_runs_in_fail_closed_os_sandbox() {
	parent := os.join_path(os.temp_dir(), 'veasel-autonomous-sandbox-${uuid.new_v4().str()}')
	root := os.join_path(parent, 'workspace')
	os.mkdir_all(parent) or { panic(err) }
	os.mkdir_all(root) or { panic(err) }
	defer { os.rmdir_all(parent) or {} }
	outside_secret := os.join_path(parent, 'outside-secret.txt')
	os.write_file(outside_secret, 'must stay hidden') or { panic(err) }
	$if linux {
		result := run_approved_shell_command_with_policy(root, ShellCommandSummary{
			command:         'touch sandbox-write.txt; test ! -e "${outside_secret}"; test ! -e /run/user; printf sandbox-ok'
			cwd:             '.'
			timeout_seconds: 5
		}, true)
		assert result.status == 'succeeded', result.output
		assert result.output.contains('sandbox-ok')
		assert os.is_file(os.join_path(root, 'sandbox-write.txt'))
		assert os.read_file(outside_secret) or { panic(err) } == 'must stay hidden'
	} $else $if macos {
		if seatbelt_available() {
			result := run_approved_shell_command_with_policy(root, ShellCommandSummary{
				command:         'touch sandbox-write.txt; test ! -e "${outside_secret}"; printf sandbox-ok'
				cwd:             '.'
				timeout_seconds: 5
			}, true)
			assert result.status == 'succeeded', result.output
			assert result.output.contains('sandbox-ok')
			assert os.is_file(os.join_path(root, 'sandbox-write.txt'))
			assert os.read_file(outside_secret) or { panic(err) } == 'must stay hidden'
		} else {
			result := run_approved_shell_command_with_policy(root, ShellCommandSummary{
				command:         'printf must-not-run'
				cwd:             '.'
				timeout_seconds: 5
			}, true)
			assert result.status == 'failed'
			assert result.output.contains('sandbox-exec')
			assert !result.output.contains('must-not-run')
		}
	} $else $if windows {
		if windows_appcontainer_sandbox_available() {
			result := run_approved_shell_command_with_policy(root, ShellCommandSummary{
				command:         'echo sandbox-ok> sandbox-write.txt'
				cwd:             '.'
				timeout_seconds: 5
			}, true)
			assert result.status == 'succeeded', result.output
			assert os.is_file(os.join_path(root, 'sandbox-write.txt'))
		} else {
			result := run_approved_shell_command_with_policy(root, ShellCommandSummary{
				command:         'echo must-not-run'
				cwd:             '.'
				timeout_seconds: 5
			}, true)
			assert result.status == 'failed'
			assert result.output.contains('AppContainer')
			assert !result.output.contains('must-not-run')
		}
	} $else {
		result := run_approved_shell_command_with_policy(root, ShellCommandSummary{
			command:         'printf must-not-run'
			cwd:             '.'
			timeout_seconds: 5
		}, true)
		assert result.status == 'failed'
		assert !result.output.contains('must-not-run')
	}
}

fn test_workspace_agent_tools_validate_arguments_and_never_apply_edits_without_approval() {
	root := os.join_path(os.temp_dir(), 'veasel-agent-tools-${uuid.new_v4().str()}')
	os.mkdir_all(os.join_path(root, 'src')) or { panic(err) }
	defer { os.rmdir_all(root) or {} }
	os.write_file(os.join_path(root, 'src', 'main.v'), 'module fixture\nworkspace-sentinel\n') or {
		panic(err)
	}
	store := open_store(':memory:') or { panic(err) }
	defer { store.close() or {} }
	plugin_directory := os.join_path(root, 'plugins')
	os.mkdir_all(plugin_directory) or { panic(err) }
	mut app := new_app(store, plugin_directory)
	defer { app.close() }
	session := store.create_session(SessionInput{ title: 'Edit fixture', directory: root }) or {
		panic(err)
	}

	definitions := workspace_agent_tools()
	assert definitions.map(it.name) == ['workspace_list_files', 'workspace_read_file',
		'workspace_search', 'subagent_run', 'workspace_propose_file_edit',
		'workspace_propose_shell_command']
	assert agent_tool_allows_parallel_readonly('workspace_list_files')
	assert agent_tool_allows_parallel_readonly('workspace_read_file')
	assert agent_tool_allows_parallel_readonly('workspace_search')
	assert !agent_tool_allows_parallel_readonly('subagent_run')
	assert !agent_tool_allows_parallel_readonly('workspace_propose_file_edit')
	assert !agent_tool_allows_parallel_readonly('agent_skill_load')
	parallel_calls := [
		ProviderToolCall{
			id:       'list-p'
			function: ProviderFunctionCall{ name: 'workspace_list_files', arguments: '{}' }
		},
		ProviderToolCall{
			id:       'read-p'
			function: ProviderFunctionCall{
				name:      'workspace_read_file'
				arguments: '{"path":"src/main.v"}'
			}
		},
		ProviderToolCall{
			id:       'search-p'
			function: ProviderFunctionCall{
				name:      'workspace_search'
				arguments: '{"query":"workspace-sentinel"}'
			}
		},
	]
	assert agent_tool_readonly_run_end(parallel_calls, 0) == parallel_calls.len
	mut parallel_read_paths := map[string]bool{}
	mut parallel_context := vcontext.background()
	mut parallel_turn, cancel_parallel := vcontext.with_timeout(mut parallel_context, 2 * time.second)
	defer { cancel_parallel() }
	mut parallel_skill_context := SessionSkillContext{}
	mut parallel_connections := []PluginMCPConnection{}
	parallel_results := execute_agent_tool_batch(app, mut parallel_turn, root, session.id,
		'test-parallel-operation', parallel_calls, mut parallel_skill_context, {},
		mut parallel_connections, ExecutionPolicyTurn{ mode: .ask, interactive: true },
		mut parallel_read_paths, {}) or { panic(err) }
	assert parallel_results.len == 3
	assert parallel_results[0].contains('src/main.v')
	assert parallel_results[1].contains('workspace-sentinel')
	assert parallel_results[2].contains('workspace-sentinel')
	assert parallel_read_paths['src/main.v']
	mixed_calls := [
		parallel_calls[0],
		parallel_calls[1],
		ProviderToolCall{
			id:       'edit-between-waves'
			function: ProviderFunctionCall{
				name:      'workspace_propose_file_edit'
				arguments: '{"path":"src/main.v","content":"module fixture\\nchanged\n"}'
			}
		},
		parallel_calls[2],
		parallel_calls[1],
	]
	assert agent_tool_readonly_run_end(mixed_calls, 0) == 2
	assert agent_tool_readonly_run_end(mixed_calls, 2) == 2
	assert agent_tool_readonly_run_end(mixed_calls, 3) == 5
	mut mixed_context := vcontext.background()
	mut mixed_turn, cancel_mixed := vcontext.with_timeout(mut mixed_context, 2 * time.second)
	defer { cancel_mixed() }
	mut mixed_skill_context := SessionSkillContext{}
	mut mixed_connections := []PluginMCPConnection{}
	mut mixed_read_paths := map[string]bool{}
	mixed_results := execute_agent_tool_batch(app, mut mixed_turn, root, session.id,
		'test-mixed-operation', mixed_calls, mut mixed_skill_context, {}, mut mixed_connections,
		ExecutionPolicyTurn{ mode: .ask, interactive: true }, mut mixed_read_paths, {}) or {
		panic(err)
	}
	assert mixed_results.len == mixed_calls.len
	assert mixed_results[0].contains('src/main.v')
	assert mixed_results[1].contains('workspace-sentinel')
	assert mixed_results[2].contains('Stored for human review')
	assert mixed_results[3].contains('workspace-sentinel')
	assert mixed_results[4].contains('workspace-sentinel')
	assert !mixed_results[4].contains('Already provided this turn')
	assert os.read_file(os.join_path(root, 'src', 'main.v')) or { '' } == 'module fixture\nworkspace-sentinel\n'

	// A real auto-edit between reads must invalidate prior content for this path.
	auto_edit_path := os.join_path(root, 'src', 'auto-edit.txt')
	os.write_file(auto_edit_path, 'before edit') or { panic(err) }
	auto_edit_calls := [
		ProviderToolCall{
			id:       'read-before-edit'
			function: ProviderFunctionCall{
				name:      'workspace_read_file'
				arguments: '{"path":"src/auto-edit.txt"}'
			}
		},
		ProviderToolCall{
			id:       'apply-edit'
			function: ProviderFunctionCall{
				name:      'workspace_propose_file_edit'
				arguments: '{"path":"src/auto-edit.txt","content":"after edit"}'
			}
		},
		ProviderToolCall{
			id:       'read-after-edit'
			function: ProviderFunctionCall{
				name:      'workspace_read_file'
				arguments: '{"path":"src/auto-edit.txt"}'
			}
		},
	]
	mut auto_edit_context := vcontext.background()
	mut auto_edit_turn, cancel_auto_edit := vcontext.with_timeout(mut auto_edit_context, 2 * time.second)
	defer { cancel_auto_edit() }
	mut auto_edit_skill_context := SessionSkillContext{}
	mut auto_edit_connections := []PluginMCPConnection{}
	mut auto_edit_read_paths := map[string]bool{}
	auto_edit_results := execute_agent_tool_batch(app, mut auto_edit_turn, root, session.id,
		'test-auto-edit-operation', auto_edit_calls, mut auto_edit_skill_context, {},
		mut auto_edit_connections, ExecutionPolicyTurn{ mode: .auto_edit },
		mut auto_edit_read_paths, {}) or { panic(err) }
	assert auto_edit_results[0].contains('before edit')
	assert auto_edit_results[1].contains('Applied by graduated execution policy')
	assert auto_edit_results[2].contains('after edit')
	assert !auto_edit_results[2].contains('Already provided this turn')
	assert os.read_file(auto_edit_path) or { panic(err) } == 'after edit'

	// A Skill-denied read must leave no stale cache entry that could mask a later grant.
	mut denied_read_context := vcontext.background()
	mut denied_read_turn, cancel_denied_read := vcontext.with_timeout(mut denied_read_context,
		2 * time.second)
	defer { cancel_denied_read() }
	mut denied_read_skill_context := SessionSkillContext{
		tool_policy: agent_tool_policy_for_skills([PluginSkill{
			name:                   'search-only'
			allowed_tools:          'workspace_search'
			allowed_tools_declared: true
		}])
	}
	mut denied_read_connections := []PluginMCPConnection{}
	mut denied_read_paths := map[string]bool{}
	denied_read_results := execute_agent_tool_batch(app, mut denied_read_turn, root, session.id,
		'test-denied-read-operation', [parallel_calls[1]], mut denied_read_skill_context, {},
		mut denied_read_connections, ExecutionPolicyTurn{ mode: .ask, interactive: true },
		mut denied_read_paths, {}) or { panic(err) }
	assert denied_read_results[0].contains('active Agent Skill tool restrictions')
	assert denied_read_paths.len == 0

	skipped_edit := ProviderToolCall{
		id:       'loop-skipped-edit'
		function: ProviderFunctionCall{
			name:      'workspace_propose_file_edit'
			arguments: '{"path":"src/main.v","content":"loop must not apply"}'
		}
	}
	mut skip_context := vcontext.background()
	mut skip_turn, cancel_skip := vcontext.with_timeout(mut skip_context, 2 * time.second)
	defer { cancel_skip() }
	mut skip_skill_context := SessionSkillContext{}
	mut skip_connections := []PluginMCPConnection{}
	mut skip_read_paths := map[string]bool{}
	edits_before_skipped_call := (store.workspace_edits(session.id) or { panic(err) }).len
	skipped_results := execute_agent_tool_batch(app, mut skip_turn, root, session.id,
		'test-loop-skipped-operation', [skipped_edit], mut skip_skill_context, {}, mut skip_connections,
		ExecutionPolicyTurn{ mode: .ask, interactive: true }, mut skip_read_paths,
		{
			'loop-skipped-edit': agent_tool_loop_stop_note(skipped_edit)
		}) or { panic(err) }
	assert skipped_results[0].contains('was not run')
	assert (store.workspace_edits(session.id) or { panic(err) }).len == edits_before_skipped_call
	assert os.read_file(os.join_path(root, 'src', 'main.v')) or { '' } == 'module fixture\nworkspace-sentinel\n'

	duplicate_batch := [
		ProviderToolCall{
			id:       'read-a'
			function: ProviderFunctionCall{
				name:      'workspace_read_file'
				arguments: '{"path":"src/main.v"}'
			}
		},
		ProviderToolCall{
			id:       'read-b'
			function: ProviderFunctionCall{
				name:      'workspace_read_file'
				arguments: '{"path":"src/main.v"}'
			}
		},
	]
	mut batch_paths := map[string]bool{}
	dup_results := execute_parallel_readonly_workspace_tools(app, root, session.id, duplicate_batch,
		AgentToolPolicy{}, mut batch_paths, {})
	assert dup_results.len == 2
	assert dup_results[0].contains('workspace-sentinel')
	assert dup_results[1].contains('Already provided this turn')
	assert dup_results[1].contains('src/main.v')
	assert !dup_results[1].contains('workspace-sentinel')
	assert batch_paths['src/main.v']

	late_path := 'src/late-file.txt'
	late_read_calls := [
		ProviderToolCall{
			id:       'late-read-a'
			function: ProviderFunctionCall{
				name:      'workspace_read_file'
				arguments: '{"path":"${late_path}"}'
			}
		},
		ProviderToolCall{
			id:       'late-read-b'
			function: ProviderFunctionCall{
				name:      'workspace_read_file'
				arguments: '{"path":"${late_path}"}'
			}
		},
	]
	mut late_read_paths := map[string]bool{}
	mut late_read_context := vcontext.background()
	mut late_read_turn, cancel_late_read := vcontext.with_timeout(mut late_read_context,
		2 * time.second)
	defer { cancel_late_read() }
	mut late_read_skills := SessionSkillContext{}
	mut late_read_connections := []PluginMCPConnection{}
	late_read_results := execute_agent_tool_batch(app, mut late_read_turn, root, session.id,
		'test-late-file-operation', late_read_calls, mut late_read_skills, {},
		mut late_read_connections, ExecutionPolicyTurn{ mode: .ask, interactive: true },
		mut late_read_paths, {}) or { panic(err) }
	assert late_read_results[0].contains('invalid or unavailable')
	assert late_read_results[1] == late_read_results[0]
	assert !late_read_results[1].contains('Already provided this turn')
	assert !late_read_paths[late_path]
	os.write_file(os.join_path(root, late_path), 'appeared after the failed read') or {
		panic(err)
	}
	mut late_retry_context := vcontext.background()
	mut late_retry_turn, cancel_late_retry := vcontext.with_timeout(mut late_retry_context,
		2 * time.second)
	defer { cancel_late_retry() }
	mut late_retry_skills := SessionSkillContext{}
	mut late_retry_connections := []PluginMCPConnection{}
	late_retry_call := ProviderToolCall{
		id:       'late-read-retry'
		function: ProviderFunctionCall{
			name:      'workspace_read_file'
			arguments: '{"path":"${late_path}"}'
		}
	}
	late_retry_results := execute_agent_tool_batch(app, mut late_retry_turn, root, session.id,
		'test-late-file-retry-operation', [late_retry_call], mut late_retry_skills, {},
		mut late_retry_connections, ExecutionPolicyTurn{ mode: .ask, interactive: true },
		mut late_read_paths, {}) or { panic(err) }
	assert late_retry_results[0].contains('appeared after the failed read')
	assert late_read_paths[late_path]
	assert workspace_read_path_from_call(ProviderToolCall{
		id:       'read-spaced-path'
		function: ProviderFunctionCall{
			name:      'workspace_read_file'
			arguments: '{"path":" src/main.v "}'
		}
	}) or { '' } == ' src/main.v '
	assert workspace_read_path_from_call(ProviderToolCall{
		id:       'read-extra-argument'
		function: ProviderFunctionCall{
			name:      'workspace_read_file'
			arguments: '{"path":"src/main.v","extra":true}'
		}
	}) == none

	mut turn_paths := map[string]bool{}
	turn_paths['src/main.v'] = true
	skipped := execute_parallel_readonly_workspace_tools(app, root, session.id, [
		ProviderToolCall{
			id:       'read-again'
			function: ProviderFunctionCall{
				name:      'workspace_read_file'
				arguments: '{"path":"src/main.v"}'
			}
		},
	], AgentToolPolicy{}, mut turn_paths, {})
	assert skipped.len == 1
	assert skipped[0].contains('Already provided this turn')
	assert !skipped[0].contains('workspace-sentinel')
	assert workspace_read_path_from_call(duplicate_batch[0]) or { '' } == 'src/main.v'
	assert workspace_read_path_from_call(ProviderToolCall{
		id:       'list'
		function: ProviderFunctionCall{
			name:      'workspace_list_files'
			arguments: '{}'
		}
	}) == none
	listing := execute_workspace_agent_tool(app, root, session.id, ProviderToolCall{
		id:       'list-1'
		function: ProviderFunctionCall{
			name:      'workspace_list_files'
			arguments: '{}'
		}
	})
	assert listing.contains('src/main.v')
	assert !listing.contains(root)

	read := execute_workspace_agent_tool(app, root, session.id, ProviderToolCall{
		id:       'read-1'
		function: ProviderFunctionCall{
			name:      'workspace_read_file'
			arguments: '{"path":"src/main.v"}'
		}
	})
	assert read.contains('workspace-sentinel')

	search := execute_workspace_agent_tool(app, root, session.id, ProviderToolCall{
		id:       'search-1'
		function: ProviderFunctionCall{
			name:      'workspace_search'
			arguments: '{"query":"workspace-sentinel"}'
		}
	})
	assert search.contains('workspace-sentinel')

	traversal := execute_workspace_agent_tool(app, root, session.id, ProviderToolCall{
		id:       'read-escape'
		function: ProviderFunctionCall{
			name:      'workspace_read_file'
			arguments: '{"path":"../outside.txt"}'
		}
	})
	assert traversal.contains('error')
	assert !traversal.contains(root)

	unexpected_argument := execute_workspace_agent_tool(app, root, session.id, ProviderToolCall{
		id:       'read-extra'
		function: ProviderFunctionCall{
			name:      'workspace_read_file'
			arguments: '{"path":"src/main.v","extra":"value"}'
		}
	})
	assert unexpected_argument.contains('Unexpected tool argument')

	unknown := execute_workspace_agent_tool(app, root, session.id, ProviderToolCall{
		id:       'unknown'
		function: ProviderFunctionCall{
			name:      'shell'
			arguments: '{}'
		}
	})
	assert unknown.contains('not available')

	edits_before_proposal := (store.workspace_edits(session.id) or { panic(err) }).len
	proposal_result := execute_workspace_agent_tool(app, root, session.id, ProviderToolCall{
		id:       'propose-1'
		function: ProviderFunctionCall{
			name:      'workspace_propose_file_edit'
			arguments: '{"path":"src/main.v","content":"module fixture\\nchanged\\n"}'
		}
	})
	assert proposal_result.contains('Stored for human review')
	assert proposal_result.contains('"id"')
	assert !proposal_result.contains('module fixture')
	assert os.read_file(os.join_path(root, 'src', 'main.v')) or { panic(err) } == 'module fixture\nworkspace-sentinel\n'
	assert (store.workspace_edits(session.id) or { panic(err) }).len == edits_before_proposal + 1

	shell_proposal := execute_workspace_agent_tool(app, root, session.id, ProviderToolCall{
		id:       'shell-propose-1'
		function: ProviderFunctionCall{
			name:      'workspace_propose_shell_command'
			arguments: '{"command":"touch shell-must-not-run","cwd":".","timeout_seconds":10}'
		}
	})
	assert shell_proposal.contains('No command was executed'), shell_proposal
	assert !os.exists(os.join_path(root, 'shell-must-not-run'))
	fractional_timeout := execute_workspace_agent_tool(app, root, session.id, ProviderToolCall{
		id:       'shell-fractional-timeout'
		function: ProviderFunctionCall{
			name:      'workspace_propose_shell_command'
			arguments: '{"command":"touch fractional-timeout-must-not-run","cwd":".","timeout_seconds":1.5}'
		}
	})
	assert fractional_timeout.contains('invalid')
	shell_commands := store.shell_commands(session.id) or { panic(err) }
	assert shell_commands.len == 1
	assert shell_commands[0].command == 'touch shell-must-not-run'
	assert shell_commands[0].status == 'pending'

	assert message_validation_error_contains([ChatMessage{
		role:       'assistant'
		content:    'not trusted'
		tool_calls: [ProviderToolCall{
			id:       'injected'
			function: ProviderFunctionCall{
				name:      'workspace_read_file'
				arguments: '{"path":"src/main.v"}'
			}
		}]
	}], 'tool metadata')
}

fn message_validation_error_contains(messages []ChatMessage, expected string) bool {
	validate_messages(messages) or { return err.msg().contains(expected) }
	return false
}

fn test_agent_tool_loop_tracker_warns_then_stops_canonical_repeats() {
	call := ProviderToolCall{
		id:       'repeat-1'
		function: ProviderFunctionCall{
			name:      'workspace_search'
			arguments: '{"path":"src","filter":{"z":1,"a":2}}'
		}
	}
	reordered_call := ProviderToolCall{
		id:       'repeat-2'
		function: ProviderFunctionCall{
			name:      'workspace_search'
			arguments: '{ "filter": {"a":2,"z":1}, "path":"src" }'
		}
	}
	assert agent_tool_call_signature(call) == agent_tool_call_signature(reordered_call)
	mut tracker := AgentToolLoopTracker{}
	assert tracker.inspect(call) == .ok
	assert tracker.inspect(reordered_call) == .ok
	assert tracker.inspect(call) == .warning
	assert tracker.inspect(reordered_call) == .ok
	assert tracker.inspect(call) == .stop
	assert tracker.inspect(call) == .stop
	assert tracker.inspect(ProviderToolCall{
		id:       'different-tool'
		function: ProviderFunctionCall{
			name:      'workspace_list_files'
			arguments: '{}'
		}
	}) == .ok
}

fn test_agent_tool_loop_warnings_match_provider_context_in_atif_trace() {
	warning := 'Repeated workspace_search calls; change approach.'
	mut messages := []ChatMessage{}
	mut trace_steps := [ATIFStep{
		step_id: 1
		source:  'agent'
		message: 'Searching the workspace.'
	}]

	append_agent_tool_loop_warnings(mut messages, mut trace_steps, [warning], true)

	assert messages.len == 1
	assert messages[0].role == 'user'
	assert messages[0].content == warning
	assert trace_steps.len == 2
	assert trace_steps[1].step_id == 2
	assert trace_steps[1].source == 'system'
	assert trace_steps[1].message == warning
}

fn test_provider_tool_transcripts_preserve_native_context() {
	messages := [
		ChatMessage{
			role:    'user'
			content: 'Find the sentinel.'
		},
		ChatMessage{
			role:       'assistant'
			content:    ''
			tool_calls: [ProviderToolCall{
				id:                 'native-call-1'
				provider_call_id:   'native-call-1'
				provider_signature: 'gemini-signature'
				function:           ProviderFunctionCall{
					name:      'workspace_search'
					arguments: '{"query":"sentinel"}'
				}
			}]
		},
		ChatMessage{
			role:                  'tool'
			name:                  'workspace_search'
			tool_call_id:          'native-call-1'
			provider_tool_call_id: 'native-call-1'
			content:               '{"matches":[{"path":"src/main.v","line":2,"text":"sentinel"}]}'
		},
	]

	_, anthropic := anthropic_messages(messages)
	assert anthropic.len == 3
	assert anthropic[1].content[0].id == 'native-call-1'
	assert anthropic[1].content[0].input['query'] or { panic('Anthropic tool arguments were lost') }.str() == 'sentinel'
	assert anthropic[2].role == 'user'
	assert anthropic[2].content[0].type == 'tool_result'
	assert anthropic[2].content[0].tool_use_id == 'native-call-1'
	assert anthropic[2].content[0].content.contains('src/main.v')

	_, gemini := gemini_messages(messages)
	assert gemini.len == 3
	assert gemini[1].parts[0].function_call or { panic('Gemini function call was lost') }.id == 'native-call-1'
	assert gemini[1].parts[0].thought_signature == 'gemini-signature'
	assert gemini[2].role == 'user'
	assert gemini[2].parts[0].function_response or {
		panic('Gemini function response was lost')
	}.id == 'native-call-1'
	function_response := gemini[2].parts[0].function_response or {
		panic('Gemini function response was lost')
	}
	matches := function_response.response['matches'] or { panic('Gemini tool result was lost') }
	match_items := matches.as_array()
	assert match_items.len == 1
	match_fields := match_items[0].as_map()
	assert match_fields['path'] or { panic('Gemini tool result path was lost') }.str() == 'src/main.v'
	assert match_fields['line'] or { panic('Gemini tool result line was lost') }.int() == 2
	assert match_fields['text'] or { panic('Gemini tool result text was lost') }.str() == 'sentinel'

	openai_transcript := json2.encode[[]ChatMessage](messages[1..])
	assert openai_transcript.contains('tool_call_id')
	assert openai_transcript.contains('native-call-1')
	assert openai_transcript.contains('tool_calls')
	_ = json2.decode[json2.Any](openai_transcript) or { panic(err) }
	public_completion := json2.encode[CompletionResponse](CompletionResponse{
		provider: 'fixture'
		model:    'fixture-model'
		content:  'Done.'
	})
	assert !public_completion.contains('tool_calls')
}

fn test_tool_budget_summary_keeps_history_and_does_not_mutate_the_system_prompt() {
	messages := [
		ChatMessage{
			role:    'system'
			content: 'You are Veasel.'
		},
		ChatMessage{
			role:    'user'
			content: 'Fix the test.'
		},
		ChatMessage{
			role:         'tool'
			content:      'file contents'
			tool_call_id: 'call-1'
		},
	]
	blocked := [
		ProviderToolCall{
			function: ProviderFunctionCall{
				name: 'workspace_read_file'
			}
		},
		ProviderToolCall{
			function: ProviderFunctionCall{
				name: 'workspace_read_file'
			}
		},
	]
	summary := messages_for_tool_budget_summary(messages, blocked)
	assert summary.len == messages.len
	assert summary[0].role == 'system'
	assert summary[0].content.starts_with('You are Veasel.')
	assert summary[0].content.contains('tool budget')
	assert summary[0].content.contains('Not run: workspace_read_file.')
	assert !summary[0].content.contains('workspace_read_file, workspace_read_file')
	assert summary[1].content == 'Fix the test.'
	assert summary[2].tool_call_id == 'call-1'
	assert messages[0].content == 'You are Veasel.'
	without_system := messages_for_tool_budget_summary(messages[1..], []ProviderToolCall{})
	assert without_system.len == 3
	assert without_system[0].role == 'system'
	assert without_system[0].content.contains('were not run')
	assert without_system[1].content == 'Fix the test.'
}

fn test_agent_context_byte_limit_accounts_for_opaque_provider_context() {
	messages := [
		ChatMessage{
			role:             'assistant'
			provider_context: ['opaque-reasoning-context']
		},
	]
	assert agent_context_bytes(messages) == 'opaque-reasoning-context'.len
}

fn test_approved_shell_command_revalidates_reviewed_working_directory() {
	root := os.join_path(os.temp_dir(), 'veasel-shell-cwd-${uuid.new_v4().str()}')
	os.mkdir_all(root) or { panic(err) }
	defer { os.rmdir_all(root) or {} }
	result := run_approved_shell_command(root, ShellCommandSummary{
		command:         'touch must-not-run'
		cwd:             '../'
		timeout_seconds: 10
	})
	assert result.status == 'failed'
	assert result.exit_code == -1
	assert result.output.contains('no process was started')
	assert !os.exists(os.join_path(root, 'must-not-run'))
}

fn test_approved_shell_command_rejects_replaced_workspace_root() {
	$if windows {
		return
	}
	parent := os.join_path(os.temp_dir(), 'veasel-shell-root-${uuid.new_v4().str()}')
	original := os.join_path(parent, 'workspace')
	moved := os.join_path(parent, 'workspace-original')
	other := os.join_path(parent, 'other')
	os.mkdir_all(original) or { panic(err) }
	os.mkdir_all(other) or { panic(err) }
	defer { os.rmdir_all(parent) or {} }
	canonical_root := canonical_workspace_root(original) or { panic(err) }
	os.rename(original, moved) or { panic(err) }
	os.symlink(other, original) or { panic(err) }
	result := run_approved_shell_command(canonical_root, ShellCommandSummary{
		command:         'touch must-not-run'
		cwd:             '.'
		timeout_seconds: 10
	})
	assert result.status == 'failed'
	assert result.exit_code == -1
	assert result.output.contains('no process was started')
	assert !os.exists(os.join_path(other, 'must-not-run'))
}

struct AgentProviderRetryFixture {
mut:
	hits   int
	script []int
}

// handle replays a per-hit script: a 0 entry answers with a successful SSE
// text stream ('retry-fixed'), any other entry is a non-2xx provider status
// with a JSON error body. Unscripted hits succeed, so the last script entry
// is usually 0 to finish the turn.
fn (mut fixture AgentProviderRetryFixture) handle(request http.Request) http.Response {
	fixture.hits++
	status := if fixture.hits <= fixture.script.len { fixture.script[fixture.hits - 1] } else { 0 }
	mut response := http.Response{}
	if status == 0 {
		response.set_status(.ok)
		response.header.set(.content_type, 'text/event-stream')
		chunk := OpenAIStreamChunk{
			choices: [OpenAIStreamChoice{
				delta: OpenAIStreamDelta{
					content: 'retry-fixed'
				}
			}]
		}
		response.body = 'data: ${json2.encode(chunk)}\n\ndata: [DONE]\n\n'
		return response
	}
	response.set_status(match status {
		401 { .unauthorized }
		429 { .too_many_requests }
		else { .internal_server_error }
	})
	response.header.set(.content_type, 'application/json')
	response.body = '{"error":{"message":"provider fixture status"}}'
	return response
}

fn start_agent_provider_retry_fixture(mut fixture AgentProviderRetryFixture) !(&http.Server, thread) {
	mut server := &http.Server{
		accept_timeout:       100 * time.millisecond
		handler:              fixture
		addr:                 '127.0.0.1:0'
		show_startup_message: false
	}
	server_thread := spawn server.listen_and_serve()
	server.wait_till_running() or {
		server.stop()
		server_thread.wait()
		return error(err.msg())
	}
	return server, server_thread
}

fn run_agent_retry_exchange(mut turn_ctx vcontext.Context, app &App, session Session,
	operation_id string, input ChatMessageInput, deadline time.Time) (ChatExchange, string) {
	exchange := app.run_session_message(mut turn_ctx, session.id, session, input, operation_id,
		deadline) or {
		return ChatExchange{}, err.msg()
	}
	return exchange, ''
}

struct AgentProviderRetryOutcome {
	hits       int
	content    string
	op_status  string
	op_error   string
	turn_error string
}

fn run_agent_provider_retry_turn(script []int) AgentProviderRetryOutcome {
	root := os.join_path(os.temp_dir(), 'veasel-provider-retry-${uuid.new_v4().str()}')
	workspace := os.join_path(root, 'workspace')
	os.mkdir_all(workspace) or { panic(err) }
	os.mkdir_all(os.join_path(root, 'data')) or { panic(err) }
	os.mkdir_all(os.join_path(root, 'plugins')) or { panic(err) }
	defer { os.rmdir_all(root) or {} }
	os.write_file(os.join_path(workspace, 'README.md'), 'fixture workspace\n') or { panic(err) }
	mut fixture := &AgentProviderRetryFixture{ script: script }
	mut server, server_thread := start_agent_provider_retry_fixture(mut fixture) or {
		panic(err)
	}
	defer {
		server.stop()
		server_thread.wait()
	}
	mut store := open_store(os.join_path(root, 'data', 'veasel.sqlite3')) or { panic(err) }
	defer { store.close() or {} }
	mut app := new_app(store, os.join_path(root, 'plugins'))
	defer { app.close() }
	app.model_settings.update(ModelSettingsInput{
		provider: 'openai-compatible'
		model:    'local-fixture'
		base_url: 'http://${server.addr}/v1'
		api_key:  'fixture-only'
	}) or { panic(err) }
	session := store.create_session(SessionInput{
		title:     'Provider retry regression'
		directory: workspace
	}) or { panic(err) }
	operation_id := uuid.new_v4().str()
	_ = store.create_session_operation(session.id, operation_id) or { panic(err) }
	mut background := vcontext.background()
	mut turn_ctx, cancel := vcontext.with_timeout(mut background, 20 * time.second)
	defer { cancel() }
	exchange, turn_error := run_agent_retry_exchange(mut turn_ctx, app, session, operation_id,
		ChatMessageInput{
			content: 'Answer with a short confirmation.'
		}, turn_ctx.deadline() or { panic('expected a turn deadline') })
	mut content := ''
	mut op_status := ''
	mut op_error := ''
	if turn_error.len == 0 && exchange.messages.len > 1 {
		content = exchange.messages[1].content
		operation := store.get_session_operation(session.id, operation_id) or { panic(err) }
		op_status = operation.status
		op_error = operation.error
	}
	return AgentProviderRetryOutcome{
		hits:       fixture.hits
		content:    content
		op_status:  op_status
		op_error:   op_error
		turn_error: turn_error
	}
}

fn test_agent_turn_retries_two_transient_failures_then_completes() {
	outcome := run_agent_provider_retry_turn([500, 500])
	assert outcome.turn_error == ''
	assert outcome.hits == 3
	assert outcome.content == 'retry-fixed'
	assert outcome.op_status == 'completed'
	assert outcome.op_error == ''
}

fn test_agent_turn_retries_one_rate_limit_then_completes() {
	outcome := run_agent_provider_retry_turn([429])
	assert outcome.turn_error == ''
	assert outcome.hits == 2
	assert outcome.content == 'retry-fixed'
	assert outcome.op_status == 'completed'
}

fn test_agent_turn_returns_auth_failure_without_retry() {
	outcome := run_agent_provider_retry_turn([401])
	assert outcome.turn_error == 'HTTP 401'
	assert outcome.hits == 1
	assert outcome.content == ''
}

fn test_provider_retryable_failure_classification() {
	assert provider_retryable_failure('HTTP 500')
	assert provider_retryable_failure('HTTP 429')
	assert provider_retryable_failure('OpenCode Go rate-limited the request (HTTP 429). Wait before retrying and check your current Go usage limits.')
	assert provider_retryable_failure('workspace summary HTTP 502')
	assert !provider_retryable_failure('HTTP 400')
	assert !provider_retryable_failure('HTTP 401')
	assert !provider_retryable_failure('HTTP 403')
	assert !provider_retryable_failure('OpenCode rejected the API key (HTTP 401). Console keys can expire.')
	assert !provider_retryable_failure('HTTP 404')
	assert !provider_retryable_failure('HTTP 050')
	assert !provider_retryable_failure('provider stream size limit exceeded')
	assert !provider_retryable_failure('response_parse')
	assert !provider_retryable_failure('cancelled')
	assert !provider_retryable_failure('deadline_exceeded')
	// The pinned net.http backend reports connection failures with numeric
	// errno text and hard mid-stream closes with an ended-early message.
	assert provider_retryable_failure('http.request: response body ended early: received 53 of 100000 bytes')
	assert !provider_retryable_failure('empty_response')
	$if $linux {
		assert provider_retryable_failure('dial_tcp failed for address 127.0.0.1:33097\ntried addrs:\n    127.0.0.1:33097: net: socket error: 111; code: 111')
		assert provider_retryable_failure('net: socket error: 104; code: 104')
		assert provider_retryable_failure('net: socket error: 110; code: 110')
		assert !provider_retryable_failure('net: socket error: 13; code: 13')
	}
	$if $macos {
		assert provider_retryable_failure('net: socket error: 61; code: 61')
		assert provider_retryable_failure('net: socket error: 54; code: 54')
		assert !provider_retryable_failure('net: socket error: 1; code: 1')
	}
	$if $windows {
		assert provider_retryable_failure('net: socket error: 10061')
		assert !provider_retryable_failure('net: socket error: 10013')
	}
}

fn test_provider_retry_never_replays_after_delivered_text() {
	mut background := vcontext.background()
	mut turn_ctx, cancel := vcontext.with_timeout(mut background, 30 * time.second)
	defer { cancel() }
	// This V build captures closure variables by value, so the stub counts
	// through a shared slice cell instead of a captured primitive.
	mut attempts := []int{len: 1}
	stub := fn [mut attempts] (mut _ctx vcontext.Context, _ []ChatMessage, _ []AgentToolDefinition,
		on_text_delta ProviderTextDeltaFn, _ ModelConfig) ProviderTurnResult {
		attempts[0]++
		if attempts[0] == 1 {
			on_text_delta('partial') or { panic('the delta sink must not fail') }
			return ProviderTurnResult{ error: 'HTTP 500' }
		}
		return ProviderTurnResult{ error: 'unreachable second attempt' }
	}
	result := complete_with_turn_context_retry_attempts(mut turn_ctx, []ChatMessage{},
		[]AgentToolDefinition{}, ignore_provider_text_delta, ModelConfig{}, stub)
	assert result.error == 'HTTP 500'
	assert attempts[0] == 1
}

fn test_provider_retry_recovers_transient_failure_without_delivered_text() {
	mut background := vcontext.background()
	mut turn_ctx, cancel := vcontext.with_timeout(mut background, 30 * time.second)
	defer { cancel() }
	mut attempts := []int{len: 1}
	stub := fn [mut attempts] (mut _ctx vcontext.Context, _ []ChatMessage, _ []AgentToolDefinition,
		_on_text_delta ProviderTextDeltaFn, _ ModelConfig) ProviderTurnResult {
		attempts[0]++
		if attempts[0] == 1 {
			return ProviderTurnResult{ error: 'HTTP 502' }
		}
		return ProviderTurnResult{ output: CompletionOutput{ content: 'recovered' } }
	}
	result := complete_with_turn_context_retry_attempts(mut turn_ctx, []ChatMessage{},
		[]AgentToolDefinition{}, ignore_provider_text_delta, ModelConfig{}, stub)
	assert result.error == ''
	assert result.output.content == 'recovered'
	assert attempts[0] == 2
}

fn test_provider_retry_backoff_poll_refuses_tight_deadline() {
	mut background := vcontext.background()
	mut turn_ctx, cancel := vcontext.with_timeout(mut background, 1 * time.second)
	defer { cancel() }
	deadline := turn_ctx.deadline() or { panic('expected a turn deadline') }
	start := time.now()
	assert !provider_retry_backoff_poll(mut turn_ctx, deadline, 250)
	// The deadline floor is 2s, so a 1s-out deadline must refuse instantly.
	assert time.now() - start < 100 * time.millisecond
}

fn test_agent_turn_retries_connection_refused_transport_errors() {
	root := os.join_path(os.temp_dir(), 'veasel-provider-refused-${uuid.new_v4().str()}')
	workspace := os.join_path(root, 'workspace')
	os.mkdir_all(workspace) or { panic(err) }
	os.mkdir_all(os.join_path(root, 'data')) or { panic(err) }
	os.mkdir_all(os.join_path(root, 'plugins')) or { panic(err) }
	defer { os.rmdir_all(root) or {} }
	os.write_file(os.join_path(workspace, 'README.md'), 'fixture workspace\n') or { panic(err) }
	// Reserve a loopback port and release it, so the provider dial is refused
	// deterministically with the pinned backend's real socket wording.
	mut dummy := &AgentProviderRetryFixture{}
	mut server, server_thread := start_agent_provider_retry_fixture(mut dummy) or {
		panic(err)
	}
	refused_addr := server.addr
	server.stop()
	server_thread.wait()
	mut store := open_store(os.join_path(root, 'data', 'veasel.sqlite3')) or { panic(err) }
	defer { store.close() or {} }
	mut app := new_app(store, os.join_path(root, 'plugins'))
	defer { app.close() }
	app.model_settings.update(ModelSettingsInput{
		provider: 'openai-compatible'
		model:    'local-fixture'
		base_url: 'http://${refused_addr}/v1'
		api_key:  'fixture-only'
	}) or { panic(err) }
	session := store.create_session(SessionInput{
		title:     'Connection refused retry regression'
		directory: workspace
	}) or { panic(err) }
	operation_id := uuid.new_v4().str()
	_ = store.create_session_operation(session.id, operation_id) or { panic(err) }
	mut background := vcontext.background()
	mut turn_ctx, cancel := vcontext.with_timeout(mut background, 20 * time.second)
	defer { cancel() }
	start := time.now()
	_, turn_error := run_agent_retry_exchange(mut turn_ctx, app, session, operation_id,
		ChatMessageInput{
			content: 'Answer with a short confirmation.'
		}, turn_ctx.deadline() or { panic('expected a turn deadline') })
	// The failure wording carries the pinned backend's socket error; the
	// retry window (500ms + 2s) must have run before the turn failed closed.
	assert turn_error.contains('socket error') || turn_error.to_lower().contains('refused')
	assert dummy.hits == 0
	assert time.now() - start >= 2400 * time.millisecond
}

fn test_provider_retry_backoff_poll_yields_to_cancellation() {
	mut background := vcontext.background()
	mut turn_ctx, cancel := vcontext.with_cancel(mut background)
	defer { cancel() }
	cancel()
	start := time.now()
	assert !provider_retry_backoff_poll(mut turn_ctx, none, 250)
	assert time.now() - start < time.second
}

fn test_provider_retry_backoff_poll_confirms_waited_room() {
	mut background := vcontext.background()
	mut turn_ctx, cancel := vcontext.with_timeout(mut background, 30 * time.second)
	defer { cancel() }
	start := time.now()
	assert provider_retry_backoff_poll(mut turn_ctx, none, 120)
	assert time.now() - start >= 120 * time.millisecond
	assert time.now() - start < time.second
}
