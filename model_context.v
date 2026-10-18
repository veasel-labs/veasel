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
