import os
import sys
import unittest


sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from kb_config import build_kb_mcp_url, resolve_kb_name


class KnowledgeBaseConfigTests(unittest.TestCase):
    def setUp(self) -> None:
        self.environ = {
            "AZURE_SEARCH_ENDPOINT": "https://search.example.net",
            "FOUNDRY_CUSTOM_KB_NAME": "demofs-policy-search-kb",
            "FOUNDRY_BASELINE_KB_NAME": "demofs-dispute-kb",
            "KB_API_VERSION": "2026-08-01-preview",
        }

    def test_custom_profile_is_the_default(self) -> None:
        self.environ["FOUNDRY_KB_NAME"] = "demofs-dispute-kb"
        self.assertEqual(resolve_kb_name(self.environ), "demofs-policy-search-kb")

    def test_baseline_profile_selects_existing_kb(self) -> None:
        self.environ["FOUNDRY_KB_PROFILE"] = "baseline"
        self.assertEqual(resolve_kb_name(self.environ), "demofs-dispute-kb")

    def test_explicit_kb_name_overrides_selected_profile(self) -> None:
        self.environ["FOUNDRY_KB_PROFILE"] = "baseline"
        self.environ["FOUNDRY_KB_OVERRIDE"] = "temporary-evaluation-kb"
        self.assertEqual(resolve_kb_name(self.environ), "temporary-evaluation-kb")

    def test_invalid_profile_fails_with_supported_choices(self) -> None:
        self.environ["FOUNDRY_KB_PROFILE"] = "preview"
        with self.assertRaisesRegex(
            ValueError,
            "Invalid FOUNDRY_KB_PROFILE.*custom, baseline",
        ):
            resolve_kb_name(self.environ)

    def test_mcp_url_preserves_endpoint_and_api_version_construction(self) -> None:
        self.assertEqual(
            build_kb_mcp_url(self.environ),
            "https://search.example.net/knowledgebases/"
            "demofs-policy-search-kb/mcp?api-version=2026-08-01-preview",
        )


if __name__ == "__main__":
    unittest.main()