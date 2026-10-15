module main

import json2
import os
import uuid

fn write_standalone_skill(root string, name string, description string, body string) {
	skill_dir := os.join_path(root, name)
	os.mkdir_all(skill_dir) or { panic(err) }
	os.write_file(os.join_path(skill_dir, 'SKILL.md'), '---\nname: ${name}\ndescription: ${description}\n---\n\n${body}') or {
		panic(err)
	}
}

fn test_standalone_skills_discover_multi_source_with_precedence_and_metadata_only() {
	home := os.join_path(os.temp_dir(), 'veasel-skills-home-${uuid.new_v4().str()}')
	project := os.join_path(os.temp_dir(), 'veasel-skills-project-${uuid.new_v4().str()}')
	configured := os.join_path(os.temp_dir(), 'veasel-skills-configured-${uuid.new_v4().str()}')
	os.mkdir_all(os.join_path(home, '.agents', 'skills')) or { panic(err) }
	os.mkdir_all(os.join_path(home, '.claude', 'skills')) or { panic(err) }
	os.mkdir_all(os.join_path(project, '.agents', 'skills')) or { panic(err) }
	os.mkdir_all(os.join_path(project, 'nested', '.cursor', 'skills')) or { panic(err) }
	os.mkdir_all(configured) or { panic(err) }
	defer {
		os.rmdir_all(home) or {}
		os.rmdir_all(project) or {}
		os.rmdir_all(configured) or {}
	}

	write_standalone_skill(os.join_path(home, '.agents', 'skills'), 'shared-review', 'User agents review.',
		'USER BODY MUST STAY HIDDEN')
	write_standalone_skill(os.join_path(project, '.agents', 'skills'), 'shared-review', 'Project agents review.',
		'PROJECT BODY MUST STAY HIDDEN')
	write_standalone_skill(os.join_path(home, '.claude', 'skills'), 'claude-notes', 'Claude-compatible notes.',
		'CLAUDE BODY')
	write_standalone_skill(os.join_path(project, 'nested', '.cursor', 'skills'), 'cursor-lint', 'Cursor lint helper.',
		'CURSOR BODY')
	write_standalone_skill(configured, 'configured-check', 'Configured directory skill.', 'CONFIG BODY')

	prior_home := os.getenv('HOME')
	prior_skills_dirs := os.getenv('VEASEL_SKILLS_DIRS')
	had_skills_dirs := 'VEASEL_SKILLS_DIRS' in os.environ()
	os.setenv('HOME', home, true)
	os.setenv('VEASEL_SKILLS_DIRS', configured, true)
	defer {
		os.setenv('HOME', prior_home, true)
		if had_skills_dirs {
			os.setenv('VEASEL_SKILLS_DIRS', prior_skills_dirs, true)
		} else {
			os.unsetenv('VEASEL_SKILLS_DIRS')
		}
	}

	discovery := discover_standalone_agent_skills(os.join_path(project, 'nested'))
	catalog := skills_catalog_from_discovery(discovery)
	encoded := json2.encode[SkillsCatalog](catalog)
	assert !encoded.contains('USER BODY')
	assert !encoded.contains('PROJECT BODY')
	assert !encoded.contains('CLAUDE BODY')
	assert !encoded.contains('CURSOR BODY')
	assert !encoded.contains('CONFIG BODY')

	mut by_key := map[string]StandaloneSkillSummary{}
	for skill in catalog.skills {
		by_key[skill.key] = skill
	}
	assert by_key['agents/shared-review'].description == 'Project agents review.'
	assert by_key['agents/shared-review'].scope == 'project'
	assert by_key['agents/shared-review'].source == 'agents'
	assert by_key['claude/claude-notes'].scope == 'user'
	assert by_key['cursor/cursor-lint'].scope == 'project'
	assert by_key['configured/configured-check'].scope == 'configured'
	assert discovery.diagnostics.any(it.message.contains('shadowed'))

	root, skill := find_standalone_skill(os.join_path(project, 'nested'), 'agents', 'shared-review') or {
		panic(err)
	}
	assert load_skill_instructions(root, skill) or { panic(err) }.contains('PROJECT BODY MUST STAY HIDDEN')
}

fn test_standalone_skills_nested_malformed_symlink_and_platform_roots() {
	root := os.join_path(os.temp_dir(), 'veasel-skills-nested-${uuid.new_v4().str()}')
	skills_root := os.join_path(root, '.agents', 'skills')
	outside := os.join_path(root, 'outside')
	os.mkdir_all(os.join_path(skills_root, 'team', 'deep-review')) or { panic(err) }
	os.mkdir_all(os.join_path(skills_root, 'broken')) or { panic(err) }
	os.mkdir_all(os.join_path(skills_root, 'linked-target')) or { panic(err) }
	os.mkdir_all(outside) or { panic(err) }
	defer { os.rmdir_all(root) or {} }

	os.write_file(os.join_path(skills_root, 'team', 'deep-review', 'SKILL.md'), '---\nname: deep-review\ndescription: Nested skill under a team folder.\n---\n\nNested body.') or {
		panic(err)
	}
	os.write_file(os.join_path(skills_root, 'broken', 'SKILL.md'), 'not frontmatter') or { panic(err) }
	write_standalone_skill(os.join_path(skills_root, 'linked-target'), 'linked-review', 'Linked skill.',
		'LINK BODY')
	os.symlink(os.join_path(skills_root, 'linked-target', 'linked-review'), os.join_path(skills_root, 'alias-review')) or {
		panic(err)
	}
	os.symlink(outside, os.join_path(skills_root, 'escape')) or { panic(err) }
	os.write_file(os.join_path(outside, 'SKILL.md'), '---\nname: escape\ndescription: Outside skill.\n---\n\nNO') or {
		panic(err)
	}

	discovery := discover_standalone_agent_skills_from_roots([StandaloneSkillRoot{
		path:   skills_root
		source: 'agents'
		scope:  'project'
		label:  '.agents/skills'
	}])
	names := discovery.skills.map(it.name).sorted()
	assert names == ['deep-review', 'linked-review']
	assert discovery.diagnostics.any(it.component.contains('broken'))
	assert !discovery.skills.any(it.name == 'escape')

	home := os.join_path(root, 'home')
	os.mkdir_all(home) or { panic(err) }
	prior_codex := os.getenv('CODEX_HOME')
	prior_xdg := os.getenv('XDG_CONFIG_HOME')
	had_codex := 'CODEX_HOME' in os.environ()
	had_xdg := 'XDG_CONFIG_HOME' in os.environ()
	codex_home := os.join_path(home, 'codex-home')
	xdg_config := os.join_path(home, 'xdg-config')
	os.mkdir_all(os.join_path(codex_home, 'skills')) or { panic(err) }
	os.mkdir_all(os.join_path(xdg_config, 'opencode', 'skills')) or { panic(err) }
	os.setenv('CODEX_HOME', codex_home, true)
	os.setenv('XDG_CONFIG_HOME', xdg_config, true)
	defer {
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
	roots := user_skill_roots(home)
	assert roots.any(it.path == os.join_path(codex_home, 'skills') && it.source == 'codex')
	assert roots.any(it.path == os.join_path(xdg_config, 'opencode', 'skills') && it.source == 'opencode')
	assert roots.any(it.path == os.join_path(home, '.copilot', 'skills') && it.source == 'copilot')
	assert roots.any(it.path == os.join_path(home, '.pi', 'agent', 'skills') && it.source == 'pi')
}

fn test_opencode_appdata_skills_directory_helper() {
	assert opencode_appdata_skills_directory('') == none
	assert opencode_appdata_skills_directory('   ') == none
	path := opencode_appdata_skills_directory(os.join_path('C:', 'Users', 'veasel', 'AppData', 'Roaming')) or {
		panic('expected APPDATA skills path')
	}
	assert path.ends_with(os.join_path('opencode', 'skills'))
	assert path.contains('Roaming')
}

fn test_windows_opencode_appdata_skills_are_discovered() {
	$if windows {
		sandbox := os.join_path(os.temp_dir(), 'veasel-skills-appdata-${uuid.new_v4().str()}')
		appdata := os.join_path(sandbox, 'AppData', 'Roaming')
		home := os.join_path(sandbox, 'home')
		project := os.join_path(sandbox, 'project')
		os.mkdir_all(os.join_path(appdata, 'opencode', 'skills')) or { panic(err) }
		os.mkdir_all(home) or { panic(err) }
		os.mkdir_all(project) or { panic(err) }
		defer { os.rmdir_all(sandbox) or {} }
		write_standalone_skill(os.join_path(appdata, 'opencode', 'skills'), 'win-opencode',
			'Windows APPDATA OpenCode skill.', 'APPDATA BODY')
		prior_home := os.getenv('HOME')
		prior_appdata := os.getenv('APPDATA')
		prior_skills_dirs := os.getenv('VEASEL_SKILLS_DIRS')
		prior_xdg := os.getenv('XDG_CONFIG_HOME')
		had_appdata := 'APPDATA' in os.environ()
		had_skills_dirs := 'VEASEL_SKILLS_DIRS' in os.environ()
		had_xdg := 'XDG_CONFIG_HOME' in os.environ()
		os.setenv('HOME', home, true)
		os.setenv('APPDATA', appdata, true)
		os.unsetenv('VEASEL_SKILLS_DIRS')
		os.unsetenv('XDG_CONFIG_HOME')
		defer {
			os.setenv('HOME', prior_home, true)
			if had_appdata {
				os.setenv('APPDATA', prior_appdata, true)
			} else {
				os.unsetenv('APPDATA')
			}
			if had_skills_dirs {
				os.setenv('VEASEL_SKILLS_DIRS', prior_skills_dirs, true)
			} else {
				os.unsetenv('VEASEL_SKILLS_DIRS')
			}
			if had_xdg {
				os.setenv('XDG_CONFIG_HOME', prior_xdg, true)
			} else {
				os.unsetenv('XDG_CONFIG_HOME')
			}
		}
		roots := user_skill_roots(home)
		expected := opencode_appdata_skills_directory(appdata) or { panic(err) }
		assert roots.any(it.path == expected && it.source == 'opencode' && it.label.contains('APPDATA'))
		discovery := discover_standalone_agent_skills(project)
		assert discovery.skills.any(it.name == 'win-opencode' && it.source == 'opencode' && it.scope == 'user')
	}
}

fn test_standalone_skill_roots_reject_windows_junction_escape() {
	$if windows {
		root := os.join_path(os.temp_dir(), 'veasel-skills-junction-${uuid.new_v4().str()}')
		external := os.join_path(os.temp_dir(), 'veasel-skills-junction-ext-${uuid.new_v4().str()}')
		skills_root := os.join_path(root, '.agents', 'skills')
		os.mkdir_all(skills_root) or { panic(err) }
		os.mkdir_all(external) or { panic(err) }
		defer {
			os.rmdir_all(root) or {}
			os.rmdir_all(external) or {}
		}
		write_standalone_skill(external, 'escape', 'Outside via junction.', 'ESCAPE BODY')
		link := os.join_path(skills_root, 'escape')
		result := os.execute('cmd /c mklink /J "${link}" "${external}"')
		assert result.exit_code == 0
		discovery := discover_standalone_agent_skills_from_roots([StandaloneSkillRoot{
			path:   skills_root
			source: 'agents'
			scope:  'project'
			label:  '.agents/skills'
		}])
		assert !discovery.skills.any(it.name == 'escape')
	}
}

fn test_plugin_catalog_merges_standalone_skills_without_instruction_bodies() {
	plugin_dir := os.join_path(os.temp_dir(), 'veasel-skills-plugins-${uuid.new_v4().str()}')
	project := os.join_path(os.temp_dir(), 'veasel-skills-merge-${uuid.new_v4().str()}')
	os.mkdir_all(os.join_path(plugin_dir, 'review-package', 'skills', 'review')) or { panic(err) }
	os.mkdir_all(os.join_path(project, '.agents', 'skills')) or { panic(err) }
	defer {
		os.rmdir_all(plugin_dir) or {}
		os.rmdir_all(project) or {}
	}
	os.write_file(os.join_path(plugin_dir, 'review-package', 'plugin.json'), '{"' + plugin_schema_key + '":"' + plugin_manifest_schema + '","name":"review-tools"}') or {
		panic(err)
	}
	os.write_file(os.join_path(plugin_dir, 'review-package', 'skills', 'review', 'SKILL.md'), '---\nname: review\ndescription: Plugin review skill.\n---\n\nPLUGIN BODY') or {
		panic(err)
	}
	write_standalone_skill(os.join_path(project, '.agents', 'skills'), 'repo-check', 'Repo check skill.',
		'STANDALONE BODY')

	prior_home := os.getenv('HOME')
	empty_home := os.join_path(os.temp_dir(), 'veasel-skills-empty-home-${uuid.new_v4().str()}')
	os.mkdir_all(empty_home) or { panic(err) }
	os.setenv('HOME', empty_home, true)
	defer {
		os.setenv('HOME', prior_home, true)
		os.rmdir_all(empty_home) or {}
	}

	catalog := discover_agent_plugins_with_standalone(plugin_dir, project) or { panic(err) }
	assert catalog.plugins.any(it.name == 'review-tools' && it.origin == '')
	agents := catalog.plugins.filter(it.name == 'agents')
	assert agents.len == 1
	assert agents[0].origin == 'standalone'
	assert agents[0].skills.len == 1
	assert agents[0].skills[0].name == 'repo-check'
	assert agents[0].skills[0].source == 'agents'
	assert agents[0].skills[0].scope == 'project'
	encoded := json2.encode[PluginCatalog](catalog)
	assert !encoded.contains('PLUGIN BODY')
	assert !encoded.contains('STANDALONE BODY')

	context := load_session_skill_context_for_project(plugin_dir, project, [
		SessionPluginSkill{
			plugin_name: 'agents'
			skill_name:  'repo-check'
		},
		SessionPluginSkill{
			plugin_name: 'review-tools'
			skill_name:  'review'
		},
	]) or { panic(err) }
	assert context.instructions.contains('STANDALONE BODY')
	assert context.instructions.contains('PLUGIN BODY')
	assert context.resource_access.len == 2
}

fn test_standalone_skills_qualify_when_plugin_name_collides() {
	plugin_dir := os.join_path(os.temp_dir(), 'veasel-skills-collide-plugins-${uuid.new_v4().str()}')
	project := os.join_path(os.temp_dir(), 'veasel-skills-collide-project-${uuid.new_v4().str()}')
	os.mkdir_all(os.join_path(plugin_dir, 'agents-package', 'skills', 'plugin-skill')) or {
		panic(err)
	}
	os.mkdir_all(os.join_path(project, '.agents', 'skills')) or { panic(err) }
	defer {
		os.rmdir_all(plugin_dir) or {}
		os.rmdir_all(project) or {}
	}
	os.write_file(os.join_path(plugin_dir, 'agents-package', 'plugin.json'), '{"' +
		plugin_schema_key + '":"' + plugin_manifest_schema + '","name":"agents"}') or {
		panic(err)
	}
	os.write_file(os.join_path(plugin_dir, 'agents-package', 'skills', 'plugin-skill', 'SKILL.md'),
		'---\nname: plugin-skill\ndescription: Real plugin skill.\n---\n\nPLUGIN COLLIDE BODY') or {
		panic(err)
	}
	write_standalone_skill(os.join_path(project, '.agents', 'skills'), 'repo-check',
		'Standalone repo check.', 'STANDALONE COLLIDE BODY')

	prior_home := os.getenv('HOME')
	empty_home := os.join_path(os.temp_dir(), 'veasel-skills-collide-home-${uuid.new_v4().str()}')
	os.mkdir_all(empty_home) or { panic(err) }
	os.setenv('HOME', empty_home, true)
	defer {
		os.setenv('HOME', prior_home, true)
		os.rmdir_all(empty_home) or {}
	}

	catalog := discover_agent_plugins_with_standalone(plugin_dir, project) or { panic(err) }
	assert catalog.plugins.any(it.name == 'agents' && it.origin == '')
	assert !catalog.plugins.any(it.name == 'agents' && it.origin == 'standalone')
	qualified := catalog.plugins.filter(it.name == 'standalone-agents')
	assert qualified.len == 1
	assert qualified[0].origin == 'standalone'
	assert qualified[0].skills.len == 1
	assert qualified[0].skills[0].name == 'repo-check'
	assert qualified[0].skills[0].source == 'agents'
	assert catalog.diagnostics.any(it.message.contains('exposed as `standalone-agents`'))
	assert !catalog.diagnostics.any(it.message.contains('are omitted because an Agent Plugin'))

	root, skill := find_session_skill(plugin_dir, project, 'standalone-agents', 'repo-check') or {
		panic(err)
	}
	assert skill.name == 'repo-check'
	assert os.is_dir(root)
	loaded := load_skill_instructions(root, skill) or { panic(err) }
	assert loaded.contains('STANDALONE COLLIDE BODY')

	entries, _ := available_skill_entries_from_catalog(catalog)
	assert entries.any(it.plugin_name == 'standalone-agents' && it.skill_name == 'repo-check')
	assert entries.any(it.plugin_name == 'agents' && it.skill_name == 'plugin-skill')
}

fn test_project_skill_roots_stop_at_git_worktree_root() {
	sandbox := os.join_path(os.temp_dir(), 'veasel-skills-git-bound-${uuid.new_v4().str()}')
	// Parent checkout sits above the git worktree so an unbounded ancestor walk
	// would otherwise pick up its skills.
	outside := os.join_path(sandbox, 'parent-checkout')
	repo := os.join_path(outside, 'repo')
	nested := os.join_path(repo, 'packages', 'app')
	home := os.join_path(sandbox, 'home')
	os.mkdir_all(os.join_path(outside, '.agents', 'skills')) or { panic(err) }
	os.mkdir_all(os.join_path(repo, '.agents', 'skills')) or { panic(err) }
	os.mkdir_all(os.join_path(nested, '.agents', 'skills')) or { panic(err) }
	os.mkdir_all(os.join_path(repo, '.git')) or { panic(err) }
	os.mkdir_all(home) or { panic(err) }
	defer { os.rmdir_all(sandbox) or {} }
	write_standalone_skill(os.join_path(outside, '.agents', 'skills'), 'leaked-parent',
		'Must not be discovered from inside the git worktree.', 'LEAKED PARENT BODY')
	write_standalone_skill(os.join_path(repo, '.agents', 'skills'), 'repo-root-skill',
		'Skill at the git worktree root.', 'REPO ROOT BODY')
	write_standalone_skill(os.join_path(nested, '.agents', 'skills'), 'nested-skill',
		'Skill under a nested package.', 'NESTED BODY')

	prior_home := os.getenv('HOME')
	prior_skills_dirs := os.getenv('VEASEL_SKILLS_DIRS')
	had_skills_dirs := 'VEASEL_SKILLS_DIRS' in os.environ()
	os.setenv('HOME', home, true)
	os.unsetenv('VEASEL_SKILLS_DIRS')
	defer {
		os.setenv('HOME', prior_home, true)
		if had_skills_dirs {
			os.setenv('VEASEL_SKILLS_DIRS', prior_skills_dirs, true)
		} else {
			os.unsetenv('VEASEL_SKILLS_DIRS')
		}
	}

	assert directory_is_git_worktree_root(repo)
	assert !directory_is_git_worktree_root(nested)
	assert !directory_is_git_worktree_root(outside)

	discovery := discover_standalone_agent_skills(nested)
	mut by_key := map[string]StandaloneSkillSummary{}
	for skill in skills_catalog_from_discovery(discovery).skills {
		by_key[skill.key] = skill
	}
	assert by_key['agents/nested-skill'].scope == 'project'
	assert by_key['agents/repo-root-skill'].scope == 'project'
	assert 'agents/leaked-parent' !in by_key

	// Non-git trees keep walking past the would-be repo boundary.
	os.rmdir_all(os.join_path(repo, '.git')) or { panic(err) }
	assert !directory_is_git_worktree_root(repo)
	unbounded := discover_standalone_agent_skills(nested)
	mut unbounded_keys := map[string]bool{}
	for skill in skills_catalog_from_discovery(unbounded).skills {
		unbounded_keys[skill.key] = true
	}
	assert unbounded_keys['agents/leaked-parent']
}
