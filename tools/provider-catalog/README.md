# Provider catalog maintenance

The binary embeds the generated catalog from `providers.json`; provider
discovery does not require a Models.dev request or Python at runtime. Each
Models.dev snapshot is pinned to an exact source commit. Refreshes preserve
endpoints and credential variable names already shipped by Veasel. Providers
removed upstream remain as curated presets; change those connection values
only in a separately reviewed catalog update.

To refresh the compatible endpoint presets from a reviewed Models.dev commit:

```sh
python3 tools/provider-catalog/sync.py --commit <40-character-models.dev-commit>
node tools/provider-catalog/generate.mjs
node tools/provider-catalog/generate.mjs --check
python3 -m unittest discover -s tools/provider-catalog -p 'test_*.py' -v
```

The synchronizer includes only providers whose upstream adapter marker is
`@ai-sdk/openai-compatible`, whose API endpoint is a fixed HTTPS URL, whose
authentication has exactly one environment variable, and whose metadata has a
documentation URL. Providers requiring account-specific endpoint templates,
multiple credentials, custom SDKs, or non-HTTPS endpoints need an explicit
Veasel integration instead. Existing curated native protocols and local
loopback presets are retained.

These entries are endpoint presets, not a claim that every account has access
or that every listed model supports coding tools. Veasel uses its common
Chat Completions transport for them; each endpoint still needs successful
model discovery and a real tool-call contract test before provider-specific
compatibility can be claimed.
