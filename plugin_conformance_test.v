module main

import json2
import os

struct AgentPluginManifestFixture {
	name        string
	accepted    bool
	diagnostics []string
	document    map[string]json2.Any
}

struct AgentPluginMCPFixture {
	name        string
	accepted    bool
	servers     []string
	diagnostics []string
	document    map[string]json2.Any
}

struct AgentSkillFrontmatterFixture {
	name      string
	directory string
	accepted  bool
	content   string
}

fn test_agent_plugin_v1_manifest_fixture_corpus() {
	path := os.join_path(os.getwd(), 'tests', 'agent_plugins', 'v1.0.0', 'plugin-manifests.json')
	fixtures := json2.decode[[]AgentPluginManifestFixture](os.read_file(path) or {
		panic('unable to read pinned Agent Plugins manifest fixtures: ${err.msg()}')
	}) or { panic('unable to decode pinned Agent Plugins manifest fixtures: ${err.msg()}') }
	assert fixtures.len >= 10
	for fixture in fixtures {
		if fixture.accepted {
			manifest, diagnostics := parse_plugin_manifest(fixture.document) or {
				panic('manifest fixture `${fixture.name}` should be accepted: ${err.msg()}')
			}
			assert manifest.name.len > 0, fixture.name
			assert_fixture_diagnostics(fixture.name, fixture.diagnostics, diagnostics)
		} else {
			parse_plugin_manifest(fixture.document) or { continue }
			panic('manifest fixture `${fixture.name}` should be rejected')
		}
	}
}

fn test_agent_plugin_v1_mcp_fixture_corpus() {
	path := os.join_path(os.getwd(), 'tests', 'agent_plugins', 'v1.0.0', 'mcp-documents.json')
	fixtures := json2.decode[[]AgentPluginMCPFixture](os.read_file(path) or {
		panic('unable to read pinned Agent Plugins MCP fixtures: ${err.msg()}')
	}) or { panic('unable to decode pinned Agent Plugins MCP fixtures: ${err.msg()}') }
	assert fixtures.len >= 8
	manifest_json := '{"' + plugin_schema_key + '":"' + plugin_manifest_schema + '","name":"fixture"}'
	manifest := json2.decode[map[string]json2.Any](manifest_json) or {
		panic(err)
	}
	for fixture in fixtures {
		if fixture.accepted {
			mut diagnostics := []PluginDiagnostic{}
			servers := validate_plugin_mcp(os.getwd(), fixture.document, manifest, mut diagnostics) or {
				panic('MCP fixture `${fixture.name}` should be accepted: ${err.msg()}')
			}
			mut server_names := servers.map(it.name)
			server_names.sort()
			mut expected_servers := fixture.servers.clone()
			expected_servers.sort()
			assert server_names == expected_servers, fixture.name
			assert_fixture_diagnostics(fixture.name, fixture.diagnostics, diagnostics)
		} else {
			mut diagnostics := []PluginDiagnostic{}
			_ := validate_plugin_mcp(os.getwd(), fixture.document, manifest, mut diagnostics) or { continue }
			panic('MCP fixture `${fixture.name}` should be rejected')
		}
	}
}

fn test_agent_skill_v1_frontmatter_fixture_corpus() {
	path := os.join_path(os.getwd(), 'tests', 'agent_plugins', 'v1.0.0', 'skill-frontmatter.json')
	fixtures := json2.decode[[]AgentSkillFrontmatterFixture](os.read_file(path) or {
		panic('unable to read pinned Agent Skills fixtures: ${err.msg()}')
	}) or { panic('unable to decode pinned Agent Skills fixtures: ${err.msg()}') }
	assert fixtures.len >= 6
	for fixture in fixtures {
		if fixture.accepted {
			skill := parse_agent_skill(fixture.directory, '/fixture/skills/${fixture.directory}/SKILL.md',
				fixture.content) or {
				panic('Skill fixture `${fixture.name}` should be accepted: ${err.msg()}')
			}
			assert skill.name == fixture.directory, fixture.name
		} else {
			_ := parse_agent_skill(fixture.directory, '/fixture/skills/${fixture.directory}/SKILL.md',
				fixture.content) or { continue }
			panic('Skill fixture `${fixture.name}` should be rejected')
		}
	}
}

fn assert_fixture_diagnostics(fixture_name string, expected []string, actual []PluginDiagnostic) {
	assert actual.len == expected.len, '${fixture_name}: expected ${expected.len} diagnostics, got ${actual.len}'
	for fragment in expected {
		assert actual.any(it.message.contains(fragment) || it.component.contains(fragment)),
			'${fixture_name}: missing diagnostic `${fragment}`'
	}
}
