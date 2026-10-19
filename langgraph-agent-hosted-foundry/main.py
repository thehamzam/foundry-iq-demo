"""DemoFS dispute-support agent — LangGraph on Foundry Hosted Agents (Responses).

Uses `langchain.agents.create_agent` (LangChain 1.x prebuilt LangGraph agent) hosted
on Foundry via `ResponsesHostServer`. Tools are loaded from a Foundry Toolbox — one
managed MCP endpoint that fronts Azure AI Search over the knowledge index. Same
LangGraph runtime; Foundry owns the identity, sessions, tracing, and hosting.
"""

from __future__ import annotations

import asyncio
import logging
import os
from typing import Any, AsyncIterator

from azure.ai.agentserver.responses import CreateResponse, ResponseContext
from azure.ai.projects import AIProjectClient
from azure.identity import DefaultAzureCredential, get_bearer_token_provider
from dotenv import load_dotenv
from langchain.agents import create_agent
from langchain_azure_ai.agents.hosting import ResponsesHostServer
from langchain_azure_ai.tools import AzureAIProjectToolbox
from langchain_core.tools import BaseTool
from langchain_openai import ChatOpenAI

from prompt import SYSTEM_PROMPT

load_dotenv()

logging.basicConfig(level=logging.INFO)
logger = logging.getLogger(__name__)

_AZURE_AI_SCOPE = "https://ai.azure.com/.default"


def _build_chat_model() -> ChatOpenAI:
    project_endpoint = os.environ["FOUNDRY_PROJECT_ENDPOINT"].rstrip("/")
    deployment = os.environ.get("AZURE_AI_MODEL_DEPLOYMENT_NAME", "gpt-4o")

    credential = DefaultAzureCredential()
    project = AIProjectClient(endpoint=project_endpoint, credential=credential)
    openai_client = project.get_openai_client()
    token_provider = get_bearer_token_provider(credential, _AZURE_AI_SCOPE)

    return ChatOpenAI(
        model=deployment,
        base_url=str(openai_client.base_url),
        api_key=token_provider,
        use_responses_api=True,
        output_version="responses/v1",
        temperature=0.1,
    )


def _sanitize_tool_schema(tool: BaseTool) -> None:
    """Patch missing/empty JSON schema properties so OpenAI tool format accepts them."""
    schema: Any = tool.args_schema if isinstance(tool.args_schema, dict) else None
    if schema is None:
        return
    if schema.get("type") == "object" and "properties" not in schema:
        schema["properties"] = {}
    props = schema.get("properties", {})
    required = schema.get("required", [])
    if required and not props:
        for field_name in required:
            props[field_name] = {"type": "string"}
        schema["properties"] = props


async def _load_toolbox_tools() -> list[BaseTool]:
    toolbox = AzureAIProjectToolbox(toolbox_name=os.environ["TOOLBOX_NAME"])
    tools = await toolbox.get_tools()
    logger.info("Loaded %d tool(s) from Foundry Toolbox '%s'", len(tools), toolbox.toolbox_name)
    for t in tools:
        _sanitize_tool_schema(t)
        logger.info("  - %s", t.name)
    return tools


class _LazyToolboxHostServer(ResponsesHostServer):
    """Loads tools on first request so /readiness returns 200 before Foundry times out."""

    def __init__(self, chat_model: ChatOpenAI) -> None:
        super().__init__(create_agent(chat_model, tools=[], system_prompt=SYSTEM_PROMPT))
        self._chat_model = chat_model
        self._ready_lock = asyncio.Lock()
        self._ready = False

    async def _ensure_real_graph(self) -> None:
        if self._ready:
            return
        async with self._ready_lock:
            if self._ready:
                return
            tools = await _load_toolbox_tools()
            self._graph = create_agent(self._chat_model, tools=tools, system_prompt=SYSTEM_PROMPT)
            self._ready = True

    async def handle_create(
        self,
        request: CreateResponse,
        context: ResponseContext,
        cancellation_signal: asyncio.Event,
    ) -> AsyncIterator[Any]:
        await self._ensure_real_graph()
        async for event in super().handle_create(request, context, cancellation_signal):
            yield event


def main() -> None:
    port = int(os.environ.get("PORT", "8088"))
    _LazyToolboxHostServer(_build_chat_model()).run(port=port)


if __name__ == "__main__":
    main()
