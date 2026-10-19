import importlib.util
from pathlib import Path
from types import SimpleNamespace
import unittest


MODULE_PATH = Path(__file__).resolve().parents[1] / "cli.py"
SPEC = importlib.util.spec_from_file_location("agent_cli", MODULE_PATH)
assert SPEC and SPEC.loader
agent_cli = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(agent_cli)


class FakeGraph:
    def __init__(self) -> None:
        self.received_messages = []

    def invoke(self, state):
        self.received_messages = state["messages"]
        return {
            "messages": [
                *self.received_messages,
                SimpleNamespace(content=[{"type": "text", "text": "Grounded answer."}]),
            ]
        }


class AgentCliTests(unittest.TestCase):
    def test_build_parser_accepts_admin_persona(self):
        args = agent_cli.build_parser().parse_args(["--persona", "admin"])

        self.assertEqual(args.persona, "admin")

    def test_configure_persona_selects_isolated_azure_config(self):
        environ = {}

        persona = agent_cli.configure_persona(environ, "frontline")

        self.assertEqual(persona, "frontline")
        self.assertEqual(environ["AZURE_CONFIG_DIR"], "/root/.azure-frontline")

    def test_configure_persona_preserves_environment_when_unspecified(self):
        environ = {"AZURE_CONFIG_DIR": "/existing"}

        persona = agent_cli.configure_persona(environ, None)

        self.assertIsNone(persona)
        self.assertEqual(environ["AZURE_CONFIG_DIR"], "/existing")

    def test_configure_tracing_disables_tracing_without_api_key(self):
        environ = {"LANGSMITH_TRACING": "true"}

        enabled = agent_cli.configure_tracing(environ)

        self.assertFalse(enabled)
        self.assertEqual(environ["LANGSMITH_TRACING"], "false")
        self.assertEqual(environ["LANGCHAIN_TRACING_V2"], "false")

    def test_configure_tracing_preserves_tracing_with_api_key(self):
        environ = {
            "LANGSMITH_TRACING": "true",
            "LANGSMITH_API_KEY": "configured",
        }

        self.assertTrue(agent_cli.configure_tracing(environ))
        self.assertEqual(environ["LANGSMITH_TRACING"], "true")

    def test_extract_message_text_supports_content_blocks(self):
        message = SimpleNamespace(content=[{"text": "First"}, {"text": "Second"}])

        self.assertEqual(agent_cli.extract_message_text(message), "First\nSecond")

    def test_invoke_agent_preserves_conversation_messages(self):
        graph = FakeGraph()
        previous = [SimpleNamespace(content="Earlier answer")]

        messages, answer = agent_cli.invoke_agent(
            graph,
            previous,
            "Follow-up question",
            lambda **kwargs: SimpleNamespace(**kwargs),
        )

        self.assertEqual(graph.received_messages[0].content, "Earlier answer")
        self.assertEqual(graph.received_messages[1].content, "Follow-up question")
        self.assertEqual(messages[-1].content[0]["text"], "Grounded answer.")
        self.assertEqual(answer, "Grounded answer.")


if __name__ == "__main__":
    unittest.main()