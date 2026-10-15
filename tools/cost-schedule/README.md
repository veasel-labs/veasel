# Pinned cost schedule

Veasel prices provider-reported tokens only when a schedule entry exists for
the turn's provider and model. Rates come from the pinned Models.dev commit
recorded in `schedule.json` (`usd_per_million_tokens`). Missing models keep
`cost: "unavailable"`; Veasel never invents rates.

Override the embedded schedule with `VEASEL_COST_SCHEDULE=/path/to/schedule.json`.

Refresh curated rows by re-reading `[cost]` tables from the Models.dev pin and
updating `schedule.json`, then regenerating `cost_schedule.generated.v`:

```sh
python3 tools/cost-schedule/generate.py
python3 tools/cost-schedule/generate.py --check
```

`gemini` rows map Models.dev `google/` costs. `openai-responses` mirrors
`openai` rates for the Responses transport. Models without a Models.dev
`[cost]` table (for example Muse Wonder at this pin) stay unpriced.
