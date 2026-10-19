import os
import sys
import unittest
from types import SimpleNamespace
from unittest.mock import patch


MODULE_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, MODULE_ROOT)

os.environ.setdefault("AZURE_OPENAI_CHAT_DEPLOYMENT", "test-chat")
os.environ.setdefault("AZURE_OPENAI_ENDPOINT", "https://openai.example.test")
os.environ.setdefault("AZURE_SEARCH_ENDPOINT", "https://search.example.test")
os.environ.setdefault("FOUNDRY_CUSTOM_KB_NAME", "custom-kb")
os.environ.setdefault("FOUNDRY_BASELINE_KB_NAME", "baseline-kb")
os.environ.setdefault("KB_API_VERSION", "2026-08-01-preview")
os.environ.setdefault("KB_BLOB_HOST", "storage.example.test")
os.environ.setdefault(
    "KB_PORTAL_BLOB_PREFIX",
    "https://portal.azure.com/#@example/blade/Microsoft_Azure_Storage/"
    "BlobPropertiesBladeV2/storageAccountId/example/path/",
)

import agent
from kb_config import build_kb_mcp_url


class _FakeCredential:
    def get_token(self, scope: str) -> SimpleNamespace:
        if scope != "https://search.azure.com/.default":
            raise AssertionError(f"Unexpected scope: {scope}")
        return SimpleNamespace(token="caller-token")


class _FakeResponse:
    def __init__(self, status_code: int, text: str) -> None:
        self.status_code = status_code
        self.text = text


class _FakeAsyncClient:
    def __init__(self, response: _FakeResponse, calls: list[dict], **kwargs) -> None:
        self.response = response
        self.calls = calls
        self.options = kwargs

    async def __aenter__(self):
        return self

    async def __aexit__(self, exc_type, exc, traceback) -> None:
        return None

    async def post(self, url: str, **kwargs) -> _FakeResponse:
        self.calls.append({"url": url, **kwargs})
        return self.response


class KnowledgeBaseRetrieveTests(unittest.IsolatedAsyncioTestCase):
    async def _call(self, response: _FakeResponse):
        calls: list[dict] = []

        def client_factory(**kwargs):
            return _FakeAsyncClient(response, calls, **kwargs)

        environ = {
            "AZURE_SEARCH_ENDPOINT": "https://search.example.test",
            "FOUNDRY_CUSTOM_KB_NAME": "custom-kb",
            "FOUNDRY_BASELINE_KB_NAME": "baseline-kb",
            "KB_API_VERSION": "2026-08-01-preview",
        }
        expected_url = build_kb_mcp_url(environ)
        with (
            patch.object(agent, "_credential", _FakeCredential()),
            patch.object(agent, "_KB_MCP_URL", expected_url),
            patch.object(agent.httpx, "AsyncClient", client_factory),
        ):
            result = await agent._call_kb_retrieve(
                [{"role": "user", "content": "What applies?"}],
                ["duplicate charge", "billing dispute"],
            )
        return result, calls, expected_url

    async def test_request_uses_both_auth_headers_json_rpc_body_and_configured_url(self) -> None:
        result, calls, expected_url = await self._call(
            _FakeResponse(200, '{"result":{"answer":"Policy applies"}}')
        )

        self.assertEqual(result, '{"answer": "Policy applies"}')
        self.assertEqual(len(calls), 1)
        self.assertEqual(calls[0]["url"], expected_url)
        self.assertEqual(calls[0]["headers"]["Authorization"], "Bearer caller-token")
        self.assertEqual(
            calls[0]["headers"]["x-ms-query-source-authorization"],
            "caller-token",
        )
        self.assertEqual(
            calls[0]["json"],
            {
                "jsonrpc": "2.0",
                "id": 1,
                "method": "tools/call",
                "params": {
                    "name": "knowledge_base_retrieve",
                    "arguments": {
                        "messages": [
                            {"role": "user", "content": "What applies?"}
                        ],
                        "query_variants": [
                            "duplicate charge",
                            "billing dispute",
                        ],
                    },
                },
            },
        )

    async def test_sse_response_is_parsed_and_citations_are_rewritten(self) -> None:
        blob_url = "https://storage.example.test/policies/policy.md"
        body = f'event: message\ndata: {{"result":{{"citation":"{blob_url}"}}}}\n\n'
        result, _, _ = await self._call(_FakeResponse(200, body))

        self.assertIn("https://portal.azure.com/", result)
        self.assertIn("policy.md/isDeleted~/false/tabToload~/0", result)
        self.assertNotIn(blob_url, result)

    async def test_http_failure_raises_bounded_response_detail(self) -> None:
        with self.assertRaisesRegex(RuntimeError, "KB MCP returned 503: unavailable"):
            await self._call(_FakeResponse(503, "unavailable"))


if __name__ == "__main__":
    unittest.main()