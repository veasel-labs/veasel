module main

// ModelContextEntry is one pinned provider/model context-window row in
// tokens, curated from the Models.dev commit in
// tools/model-context/schedule.json. Models without a row stay unknown.
struct ModelContextEntry {
	provider       string
	model          string
	context_tokens int
}

// model_context_tokens returns the curated context window for a provider and
// model, or none when Veasel has no pinned row. It never guesses a window
// from the model name.
fn model_context_tokens(provider string, model string) ?int {
	provider_key := provider.trim_space().to_lower()
	model_key := model.trim_space()
	if provider_key.len == 0 || model_key.len == 0 {
		return none
	}
	for entry in embedded_model_context_entries() {
		if entry.provider == provider_key && entry.model == model_key {
			if entry.context_tokens > 0 {
				return entry.context_tokens
			}
			return none
		}
	}
	return none
}

// annotate_model_catalog_with_context_schedule copies curated context
// windows onto matching catalog rows so clients can show the window next to
// the model. Unmatched models keep the field omitted.
fn annotate_model_catalog_with_context_schedule(provider string, models []ModelCatalogEntry) []ModelCatalogEntry {
	if models.len == 0 {
		return models
	}
	mut out := []ModelCatalogEntry{cap: models.len}
	for model in models {
		if tokens := model_context_tokens(provider, model.id) {
			out << ModelCatalogEntry{
				id:              model.id
				name:            model.name
				input_per_mtok:  model.input_per_mtok
				output_per_mtok: model.output_per_mtok
				cost_unit:       model.cost_unit
				context_tokens:  tokens
			}
			continue
		}
		out << model
	}
	return out
}
