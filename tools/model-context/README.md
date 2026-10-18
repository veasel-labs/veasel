# Pinned model context windows

Veasel knows a model's context window only when a curated entry exists in
`schedule.json` for the turn's provider and model. Values are `[limit] context`
from the pinned Models.dev commit recorded in `schedule.json`, mirroring the
provider/model rows of `tools/cost-schedule/schedule.json`. Missing models stay
unknown; Veasel never invents a window.

The window drives session-compaction pressure only: when the conservative
bytes/4 token bound reaches three quarters of a known window, compaction runs
even below the byte and message-count thresholds. It is not a token budget and
does not widen the submitted-input byte limit.

Refresh curated rows by re-reading `[limit]` tables from the Models.dev pin
(provider TOMLs, resolving `base_model` into the canonical `models/` tree) and
updating `schedule.json`, then regenerating `model_context.generated.v`:

```sh
python3 tools/model-context/generate.py
python3 tools/model-context/generate.py --check
```

`gemini` rows map Models.dev `google/` limits. `openai-responses` mirrors
`openai` rows for the Responses transport. Models without a Models.dev
`[limit]` table (for example Muse Wonder at this pin) stay unknown.
