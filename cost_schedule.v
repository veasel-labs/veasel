module main

import json2
import math
import os

const cost_schedule_env = 'VEASEL_COST_SCHEDULE'
const cost_unavailable = 'unavailable'
const cost_tokens_per_rate_unit = 1_000_000.0

// CostScheduleEntry is one pinned provider/model rate row in USD per million
// tokens. Absent cache rates mean those counters are not priced (not assumed
// zero); missing models keep session cost unavailable.
struct CostScheduleEntry {
	provider    string
	model       string
	input       f64
	output      f64
	cache_read  ?f64
	cache_write ?f64
}

struct CostScheduleFile {
	schema_version int
	unit           string
	models         []CostScheduleFileModel
}

struct CostScheduleFileModel {
	provider    string
	model       string
	input       f64
	output      f64
	cache_read  ?f64
	cache_write ?f64
}

struct CostSchedule {
	unit    string
	entries map[string]CostScheduleEntry
}

struct CostScheduleTurn {
	provider              string
	model                 string
	input_tokens          i64
	output_tokens         i64
	usage_reported        bool
	cache_read_tokens     i64
	cache_creation_tokens i64
	cache_reported        bool
}

fn cost_schedule_key(provider string, model string) string {
	return '${provider.trim_space().to_lower()}\x00${model.trim_space()}'
}

fn cost_input_is_subset_provider(provider string) bool {
	return provider in ['openai', 'openai-responses', 'gemini']
}

fn load_cost_schedule_from_json(raw string) !CostSchedule {
	file := json2.decode[CostScheduleFile](raw) or { return error('cost schedule JSON is invalid') }
	if file.schema_version != 1 {
		return error('cost schedule schema_version is unsupported')
	}
	if file.unit.trim_space() != embedded_cost_schedule_unit {
		return error('cost schedule unit must be ${embedded_cost_schedule_unit}')
	}
	mut entries := map[string]CostScheduleEntry{}
	for item in file.models {
		provider := item.provider.trim_space().to_lower()
		model := item.model.trim_space()
		if provider.len == 0 || model.len == 0 {
			return error('cost schedule model entry is incomplete')
		}
		if item.input < 0 || item.output < 0 {
			return error('cost schedule rates must be non-negative')
		}
		if cache_read := item.cache_read {
			if cache_read < 0 {
				return error('cost schedule cache_read must be non-negative')
			}
		}
		if cache_write := item.cache_write {
			if cache_write < 0 {
				return error('cost schedule cache_write must be non-negative')
			}
		}
		key := cost_schedule_key(provider, model)
		entries[key] = CostScheduleEntry{
			provider:    provider
			model:       model
			input:       item.input
			output:      item.output
			cache_read:  item.cache_read
			cache_write: item.cache_write
		}
	}
	return CostSchedule{
		unit:    embedded_cost_schedule_unit
		entries: entries
	}
}

fn cost_schedule_from_embedded() CostSchedule {
	mut entries := map[string]CostScheduleEntry{}
	for item in embedded_cost_schedule_entries() {
		entries[cost_schedule_key(item.provider, item.model)] = item
	}
	return CostSchedule{
		unit:    embedded_cost_schedule_unit
		entries: entries
	}
}

// active_cost_schedule returns the embedded pinned schedule, or an override
// loaded from VEASEL_COST_SCHEDULE when that path is set. A bad override fails
// closed to an empty schedule (cost stays unavailable) rather than inventing rates.
fn active_cost_schedule() CostSchedule {
	if path := os.getenv_opt(cost_schedule_env) {
		trimmed := path.trim_space()
		if trimmed.len > 0 {
			raw := os.read_file(trimmed) or {
				return CostSchedule{
					unit:    embedded_cost_schedule_unit
					entries: map[string]CostScheduleEntry{}
				}
			}
			return load_cost_schedule_from_json(raw) or {
				CostSchedule{
					unit:    embedded_cost_schedule_unit
					entries: map[string]CostScheduleEntry{}
				}
			}
		}
	}
	return cost_schedule_from_embedded()
}

fn lookup_cost_schedule_entry(schedule CostSchedule, provider string, model string) ?CostScheduleEntry {
	key := cost_schedule_key(provider, model)
	if entry := schedule.entries[key] {
		return entry
	}
	return none
}

// annotate_model_catalog_with_cost_schedule copies pinned USD/MTok rates onto
// matching catalog rows so clients can prefer cheaper models without inventing
// prices. Unmatched models keep rates omitted.
fn annotate_model_catalog_with_cost_schedule(provider string, models []ModelCatalogEntry) []ModelCatalogEntry {
	schedule := active_cost_schedule()
	if schedule.entries.len == 0 || models.len == 0 {
		return models
	}
	mut out := []ModelCatalogEntry{cap: models.len}
	for model in models {
		if entry := lookup_cost_schedule_entry(schedule, provider, model.id) {
			out << ModelCatalogEntry{
				id:              model.id
				name:            model.name
				input_per_mtok:  entry.input
				output_per_mtok: entry.output
				cost_unit:       schedule.unit
				context_tokens:  model.context_tokens
			}
			continue
		}
		out << model
	}
	return out
}

fn cost_schedule_present() bool {
	return active_cost_schedule().entries.len > 0
}

fn format_usd_amount(amount f64) string {
	if amount < 0 || math.is_nan(amount) || math.is_inf(amount, 0) {
		return cost_unavailable
	}
	micros := i64(math.round(amount * 1_000_000.0))
	if micros < 0 {
		return cost_unavailable
	}
	whole := micros / 1_000_000
	frac := int(micros % 1_000_000)
	mut frac_str := '${frac:06}'
	for frac_str.len > 1 && frac_str.ends_with('0') {
		frac_str = frac_str[..frac_str.len - 1]
	}
	if frac_str == '0' {
		return '\$${whole}.00'
	}
	return '\$${whole}.${frac_str}'
}

fn price_tokens_usd(tokens i64, rate_per_million f64) f64 {
	if tokens <= 0 || rate_per_million < 0 {
		return 0
	}
	return f64(tokens) * rate_per_million / cost_tokens_per_rate_unit
}

fn compute_turn_cost_usd(schedule CostSchedule, turn CostScheduleTurn) !f64 {
	if !turn.usage_reported {
		return error('usage not reported')
	}
	entry := lookup_cost_schedule_entry(schedule, turn.provider, turn.model) or {
		return error('model not in cost schedule')
	}
	mut billable_input := turn.input_tokens
	mut cache_read := i64(0)
	mut cache_write := i64(0)
	if turn.cache_reported {
		cache_read = turn.cache_read_tokens
		cache_write = turn.cache_creation_tokens
		if cache_read < 0 {
			cache_read = 0
		}
		if cache_write < 0 {
			cache_write = 0
		}
		if cost_input_is_subset_provider(entry.provider) {
			if cache_read > billable_input {
				return error('cache_read exceeds input_tokens')
			}
			billable_input = billable_input - cache_read
		}
	}
	mut total := price_tokens_usd(billable_input, entry.input)
	total += price_tokens_usd(turn.output_tokens, entry.output)
	if turn.cache_reported && cache_read > 0 {
		rate := entry.cache_read or { return error('cache_read rate missing') }
		total += price_tokens_usd(cache_read, rate)
	}
	if turn.cache_reported && cache_write > 0 {
		rate := entry.cache_write or { return error('cache_write rate missing') }
		total += price_tokens_usd(cache_write, rate)
	}
	return total
}

// session_usage_cost_label returns a USD string only when every usage-reported
// turn has a schedule entry and can be priced. Otherwise returns unavailable.
fn session_usage_cost_label(turns []CostScheduleTurn) string {
	schedule := active_cost_schedule()
	if schedule.entries.len == 0 {
		return cost_unavailable
	}
	mut any_reported := false
	mut total := 0.0
	for turn in turns {
		if !turn.usage_reported {
			continue
		}
		any_reported = true
		amount := compute_turn_cost_usd(schedule, turn) or { return cost_unavailable }
		total += amount
	}
	if !any_reported {
		return cost_unavailable
	}
	return format_usd_amount(total)
}
