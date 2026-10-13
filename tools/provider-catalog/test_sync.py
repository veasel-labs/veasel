import io
import tarfile
import unittest
from unittest.mock import patch

from sync import compatible_preset, merge_presets, read_compatible_presets


class CompatiblePresetTest(unittest.TestCase):
    def setUp(self):
        self.metadata = {
            "name": "Example",
            "api": "https://api.example.test/v1",
            "env": ["EXAMPLE_API_KEY"],
            "doc": "https://docs.example.test",
            "npm": "@ai-sdk/openai-compatible",
        }

    def test_accepts_a_fixed_openai_compatible_endpoint(self):
        preset = compatible_preset("models.dev/providers/example/provider.toml", self.metadata)
        self.assertEqual(preset["id"], "example")
        self.assertEqual(preset["environment_key"], "EXAMPLE_API_KEY")
        self.assertEqual(preset["protocol"], "openai-compatible")

    def test_rejects_unsupported_or_unsafe_provider_metadata(self):
        cases = [
            {"npm": "@ai-sdk/anthropic"},
            {"api": "http://api.example.test/v1"},
            {"api": "https://api.example.test/v1?key=embedded"},
            {"api": "https://user:secret@api.example.test/v1"},
            {"api": "https://api.example.test:{account}/v1"},
            {"api": "https://api.example.test:99999/v1"},
            {"api": "https://api.example.test/accounts/{account}/v1"},
            {"env": ["A", "B"]},
            {"env": ["LOWERCASE_key"]},
            {"doc": "http://docs.example.test"},
        ]
        for change in cases:
            with self.subTest(change=change):
                metadata = self.metadata | change
                self.assertIsNone(compatible_preset("providers/example/provider.toml", metadata))

    def test_merge_preserves_existing_connection_contracts_and_removed_providers(self):
        existing = [
            {
                "id": "meta",
                "api": "https://api.meta.ai/v1",
                "environment_key": "MODEL_API_KEY",
                "documentation_url": "https://dev.meta.ai/docs/models",
                "protocol": "openai-responses",
                "source": "veasel-curated",
            },
            {
                "id": "scaleway",
                "api": "https://api.scaleway.ai/v1",
                "environment_key": "SCW_SECRET_KEY",
                "documentation_url": "https://www.scaleway.com/docs",
                "protocol": "openai-compatible",
                "source": "models.dev",
                "models_dev_source": "providers/scaleway/provider.toml",
            },
            {
                "id": "retired-provider",
                "api": "https://old.example/v1",
                "protocol": "openai-compatible",
                "source": "models.dev",
                "models_dev_source": "providers/retired-provider/provider.toml",
            },
            {
                "id": "optional-auth",
                "api": "https://optional.example/v1",
                "environment_key": "",
                "requires_api_key": False,
                "protocol": "openai-compatible",
                "source": "veasel-curated",
            },
        ]
        upstream = [
            {
                "id": "meta",
                "api": "https://changed.example/v1",
                "environment_key": "CHANGED_KEY",
                "documentation_url": "https://changed.example/docs",
                "protocol": "openai-compatible",
                "source": "models.dev",
                "models_dev_source": "providers/meta/provider.toml",
            },
            {
                "id": "scaleway",
                "api": "https://new.scaleway.example/v1",
                "environment_key": "SCALEWAY_API_KEY",
                "documentation_url": "https://new.scaleway.example/docs",
                "protocol": "openai-compatible",
                "source": "models.dev",
                "models_dev_source": "providers/scaleway/provider.toml",
            },
            {
                "id": "new-provider",
                "api": "https://new.example/v1",
                "environment_key": "NEW_KEY",
                "documentation_url": "https://new.example/docs",
                "protocol": "openai-compatible",
                "source": "models.dev",
                "models_dev_source": "providers/new-provider/provider.toml",
            },
            {
                "id": "optional-auth",
                "api": "https://changed.example/v1",
                "environment_key": "NEW_REQUIRED_KEY",
                "requires_api_key": True,
                "protocol": "openai-compatible",
                "source": "models.dev",
                "models_dev_source": "providers/optional-auth/provider.toml",
            },
        ]

        result = merge_presets(existing, upstream)

        self.assertEqual([provider["id"] for provider in result], ["meta", "new-provider", "optional-auth", "retired-provider", "scaleway"])
        self.assertEqual(result[0]["api"], "https://api.meta.ai/v1")
        self.assertEqual(result[0]["environment_key"], "MODEL_API_KEY")
        self.assertEqual(result[0]["documentation_url"], "https://dev.meta.ai/docs/models")
        self.assertEqual(result[0]["protocol"], "openai-responses")
        self.assertEqual(result[0]["source"], "veasel-curated")
        self.assertNotIn("models_dev_source", result[0])
        self.assertEqual(result[1]["environment_key"], "NEW_KEY")
        self.assertEqual(result[2]["source"], "veasel-curated")
        self.assertNotIn("models_dev_source", result[2])
        self.assertEqual(result[2]["api"], "https://optional.example/v1")
        self.assertEqual(result[2]["environment_key"], "")
        self.assertFalse(result[2]["requires_api_key"])
        self.assertEqual(result[3]["source"], "veasel-curated")
        self.assertNotIn("models_dev_source", result[3])
        self.assertEqual(result[4]["api"], "https://api.scaleway.ai/v1")
        self.assertEqual(result[4]["environment_key"], "SCW_SECRET_KEY")
        self.assertEqual(result[4]["documentation_url"], "https://www.scaleway.com/docs")

    def test_snapshot_reader_orders_and_deduplicates_provider_ids(self):
        fixture = io.BytesIO()
        with tarfile.open(fileobj=fixture, mode="w:gz") as bundle:
            for provider_id in ("zeta", "alpha"):
                content = (
                    'name = "Example"\n'
                    'api = "https://api.example.test/v1"\n'
                    'env = ["EXAMPLE_API_KEY"]\n'
                    'doc = "https://docs.example.test"\n'
                    'npm = "@ai-sdk/openai-compatible"\n'
                ).encode()
                info = tarfile.TarInfo(f"models.dev/providers/{provider_id}/provider.toml")
                info.size = len(content)
                bundle.addfile(info, io.BytesIO(content))
        presets = read_compatible_presets(fixture.getvalue())
        self.assertEqual([preset["id"] for preset in presets], ["alpha", "zeta"])

    def test_snapshot_reader_enforces_member_limit_incrementally(self):
        fixture = io.BytesIO()
        with tarfile.open(fileobj=fixture, mode="w:gz") as bundle:
            for name in ("first.txt", "second.txt"):
                info = tarfile.TarInfo(name)
                info.size = 0
                bundle.addfile(info)

        with patch("sync.MAX_ARCHIVE_MEMBERS", 1):
            with self.assertRaisesRegex(ValueError, "too many archive members"):
                read_compatible_presets(fixture.getvalue())


if __name__ == "__main__":
    unittest.main()
