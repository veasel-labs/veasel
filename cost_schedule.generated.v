// Generated from tools/cost-schedule/schedule.json. Do not edit by hand.
// Models.dev pin: https://github.com/anomalyco/models.dev/tree/2dd3beed38c41d2e4b425e4638a66f81e69e73c0
module main

const embedded_cost_schedule_unit = 'usd_per_million_tokens'
const embedded_cost_schedule_source_commit = '2dd3beed38c41d2e4b425e4638a66f81e69e73c0'

fn embedded_cost_schedule_entries() []CostScheduleEntry {
	return [
		CostScheduleEntry{ provider: 'anthropic', model: 'claude-haiku-4-5', input: 1.0, output: 5.0, cache_read: 0.1, cache_write: 1.25 },
		CostScheduleEntry{ provider: 'anthropic', model: 'claude-haiku-4-5-20251001', input: 1.0, output: 5.0, cache_read: 0.1, cache_write: 1.25 },
		CostScheduleEntry{ provider: 'anthropic', model: 'claude-opus-4-6', input: 5.0, output: 25.0, cache_read: 0.5, cache_write: 6.25 },
		CostScheduleEntry{ provider: 'anthropic', model: 'claude-sonnet-4-5', input: 3.0, output: 15.0, cache_read: 0.3, cache_write: 3.75 },
		CostScheduleEntry{ provider: 'anthropic', model: 'claude-sonnet-4-5-20250929', input: 3.0, output: 15.0, cache_read: 0.3, cache_write: 3.75 },
		CostScheduleEntry{ provider: 'gemini', model: 'gemini-2.5-flash', input: 0.3, output: 2.5, cache_read: 0.03, cache_write: none },
		CostScheduleEntry{ provider: 'gemini', model: 'gemini-2.5-pro', input: 1.25, output: 10.0, cache_read: 0.125, cache_write: none },
		CostScheduleEntry{ provider: 'openai', model: 'gpt-4.1', input: 2.0, output: 8.0, cache_read: 0.5, cache_write: none },
		CostScheduleEntry{ provider: 'openai', model: 'gpt-4.1-mini', input: 0.4, output: 1.6, cache_read: 0.1, cache_write: none },
		CostScheduleEntry{ provider: 'openai', model: 'gpt-4o', input: 2.5, output: 10.0, cache_read: 1.25, cache_write: none },
		CostScheduleEntry{ provider: 'openai', model: 'gpt-4o-mini', input: 0.15, output: 0.6, cache_read: 0.075, cache_write: none },
		CostScheduleEntry{ provider: 'openai', model: 'o3', input: 2.0, output: 8.0, cache_read: 0.5, cache_write: none },
		CostScheduleEntry{ provider: 'openai', model: 'o3-mini', input: 1.1, output: 4.4, cache_read: 0.55, cache_write: none },
		CostScheduleEntry{ provider: 'openai', model: 'o4-mini', input: 1.1, output: 4.4, cache_read: 0.275, cache_write: none },
		CostScheduleEntry{ provider: 'openai-responses', model: 'gpt-4.1', input: 2.0, output: 8.0, cache_read: 0.5, cache_write: none },
		CostScheduleEntry{ provider: 'openai-responses', model: 'gpt-4.1-mini', input: 0.4, output: 1.6, cache_read: 0.1, cache_write: none },
		CostScheduleEntry{ provider: 'openai-responses', model: 'gpt-4o', input: 2.5, output: 10.0, cache_read: 1.25, cache_write: none },
		CostScheduleEntry{ provider: 'openai-responses', model: 'gpt-4o-mini', input: 0.15, output: 0.6, cache_read: 0.075, cache_write: none },
		CostScheduleEntry{ provider: 'openai-responses', model: 'o3', input: 2.0, output: 8.0, cache_read: 0.5, cache_write: none },
		CostScheduleEntry{ provider: 'openai-responses', model: 'o3-mini', input: 1.1, output: 4.4, cache_read: 0.55, cache_write: none },
		CostScheduleEntry{ provider: 'openai-responses', model: 'o4-mini', input: 1.1, output: 4.4, cache_read: 0.275, cache_write: none },
	]
}
