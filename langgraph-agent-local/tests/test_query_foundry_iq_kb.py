import argparse
import contextlib
import importlib.util
import io
import os
import sys
import unittest
from pathlib import Path
from types import ModuleType, SimpleNamespace
from unittest import mock


MODULE_PATH = Path(__file__).resolve().parents[1] / "query-foundry-iq-kb.py"
SPEC = importlib.util.spec_from_file_location("query_foundry_iq_kb", MODULE_PATH)
if SPEC is None or SPEC.loader is None:
    raise RuntimeError(f"Could not load {MODULE_PATH}")
query_foundry_iq_kb = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(query_foundry_iq_kb)


def _args(**overrides):
    values = {
        "endpoint": None,
        "knowledge_base": None,
        "profile": None,
        "api_version": None,
    }
    values.update(overrides)
    return argparse.Namespace(**values)


class DirectKnowledgeBaseQueryTests(unittest.TestCase):
    def setUp(self) -> None:
        self.environ = {
            "AZURE_SEARCH_ENDPOINT": "https://search.example.test/",
            "FOUNDRY_CUSTOM_KB_NAME": "custom-kb",
            "FOUNDRY_BASELINE_KB_NAME": "baseline-kb",
            "KB_API_VERSION": "2026-08-01-preview",
        }

    def test_configuration_preserves_profile_and_override_compatibility(self) -> None:
        self.environ["FOUNDRY_KB_PROFILE"] = "baseline"
        self.environ["FOUNDRY_KB_OVERRIDE"] = "override-kb"

        self.assertEqual(
            query_foundry_iq_kb.resolve_configuration(_args(), self.environ),
            (
                "https://search.example.test",
                "override-kb",
                "2026-08-01-preview",
            ),
        )

    def test_cli_values_take_precedence(self) -> None:
        self.assertEqual(
            query_foundry_iq_kb.resolve_configuration(
                _args(
                    endpoint="https://cli.example.test/",
                    knowledge_base="cli-kb",
                    profile="custom",
                    api_version="2026-04-01",
                ),
                self.environ,
            ),
            ("https://cli.example.test", "cli-kb", "2026-04-01"),
        )

    def test_parser_rejects_non_positive_limits(self) -> None:
        parser = query_foundry_iq_kb.build_parser()

        for option in ("--max-output-tokens", "--max-runtime-seconds"):
            for value in ("0", "-1"):
                with self.subTest(option=option, value=value):
                    stderr = io.StringIO()
                    with contextlib.redirect_stderr(stderr):
                        with self.assertRaises(SystemExit) as raised:
                            parser.parse_args([option, value, "question"])
                    self.assertEqual(raised.exception.code, 2)
                    self.assertIn("must be a positive integer", stderr.getvalue())

    def test_request_contains_one_semantic_intent_and_limits(self) -> None:
        request = query_foundry_iq_kb.build_retrieval_request(
            "What policy applies?",
            max_output_tokens=900,
            max_runtime_seconds=20,
        )

        self.assertEqual(
            request,
            {
                "intents": [
                    {"type": "semantic", "search": "What policy applies?"}
                ],
                "maxRuntimeInSeconds": 20,
                "maxOutputSizeInTokens": 900,
                "includeActivity": False,
            },
        )

    def test_create_client_closes_credential_when_construction_fails(self) -> None:
        credential = SimpleNamespace(close=mock.Mock())
        identity_module = ModuleType("azure.identity")
        identity_module.DefaultAzureCredential = mock.Mock(return_value=credential)
        knowledgebases_module = ModuleType("azure.search.documents.knowledgebases")
        knowledgebases_module.KnowledgeBaseRetrievalClient = mock.Mock(
            side_effect=RuntimeError("construction failed")
        )

        with mock.patch.dict(
            sys.modules,
            {
                "azure.identity": identity_module,
                "azure.search.documents.knowledgebases": knowledgebases_module,
            },
        ):
            with self.assertRaisesRegex(RuntimeError, "construction failed"):
                query_foundry_iq_kb.create_client(
                    "https://search.example.test",
                    "custom-kb",
                    "2026-04-01",
                )

        credential.close.assert_called_once_with()

    def test_answer_and_references_support_sdk_objects_and_mapping_fallbacks(self) -> None:
        response = SimpleNamespace(
            response=[
                SimpleNamespace(
                    content=[SimpleNamespace(text="Grounded answer.")],
                )
            ],
            references=[
                SimpleNamespace(
                    type="azureBlob",
                    id="ref-1",
                    blob_url="https://storage.example.test/policy.md",
                    source_data={"title": "Policy"},
                    reranker_score=0.875,
                ),
                {
                    "type": "searchIndex",
                    "id": "ref-2",
                    "docKey": "doc-42",
                },
            ],
        )

        self.assertEqual(
            query_foundry_iq_kb.extract_answer(response),
            "Grounded answer.",
        )
        references = query_foundry_iq_kb.format_references(response)
        self.assertIn("Policy", references[0])
        self.assertIn("https://storage.example.test/policy.md", references[0])
        self.assertIn("score: 0.8750", references[0])
        self.assertIn("document key: doc-42", references[1])


if __name__ == "__main__":
    unittest.main()