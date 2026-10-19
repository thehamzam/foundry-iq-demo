"""Local agent — vanilla LangGraph calling the KB MCP endpoint directly.

Same LangGraph runtime as the hosted Foundry agent, same knowledge index — the ONLY
difference is where the agent runs and how it authenticates to the KB:

    Hosted Foundry agent: runs inside Foundry Hosted Agents; user identity flows through
            the Foundry Toolbox, which internally sets `x-ms-query-source-authorization`
            so the KB permission-trims per user.

        Local agent: runs locally via `langgraph dev`, or hosted on
                        LangGraph Platform Plus). DefaultAzureCredential supports Azure CLI
                        locally and workload/service-principal identity when hosted. We bypass
                        the Foundry Toolbox and call the KB MCP endpoint directly so we can
                        explicitly send BOTH headers required by Azure AI Search query-time
                        ACL enforcement:
                            - Authorization: Bearer <caller-search-token>
                            - x-ms-query-source-authorization: <caller-search-token>
            (See https://learn.microsoft.com/azure/search/search-query-access-control-rbac-enforcement)

Both agents hit the SAME knowledge base and therefore return the same permission-
trimmed passages for a given identity.
"""

from __future__ import annotations

import asyncio
import json
import os
import uuid
from typing import Annotated, Any, TypedDict

import httpx
from azure.identity import DefaultAzureCredential, get_bearer_token_provider
from langchain_core.messages import AnyMessage, SystemMessage
from langchain_core.tools import StructuredTool
from langchain_openai import AzureChatOpenAI
from langgraph.graph import END, StateGraph, add_messages
from langgraph.prebuilt import ToolNode, tools_condition
from pydantic import BaseModel, Field

from kb_config import build_kb_mcp_url
from prompt import SYSTEM_PROMPT

_credential = DefaultAzureCredential(exclude_interactive_browser_credential=True)
_aoai_token_provider = get_bearer_token_provider(
    _credential, "https://cognitiveservices.azure.com/.default"
)

_SEARCH_SCOPE = "https://search.azure.com/.default"
_KB_MCP_URL = build_kb_mcp_url(os.environ)

_BLOB_HOST = os.getenv("KB_BLOB_HOST", "").strip()
_PORTAL_BLOB_PREFIX = os.getenv("KB_PORTAL_BLOB_PREFIX", "").strip()
if _PORTAL_BLOB_PREFIX and not _PORTAL_BLOB_PREFIX.endswith("/"):
    _PORTAL_BLOB_PREFIX += "/"


# BlobPropertiesBladeV2 requires isDeleted + tabToload params; without them
# the portal shows "missing required parameter(s)".
_PORTAL_BLOB_SUFFIX = "/isDeleted~/false/tabToload~/0"


def _rewrite_blob_urls(text: str) -> str:
    """Rewrite configured private Blob URLs to configured Azure Portal URLs."""
    import re
    from urllib.parse import quote

    if not _BLOB_HOST or not _PORTAL_BLOB_PREFIX:
        return text

    def _sub(match: "re.Match[str]") -> str:
        path = match.group(1)
        return _PORTAL_BLOB_PREFIX + quote(path, safe="") + _PORTAL_BLOB_SUFFIX

    return re.sub(rf"https://{re.escape(_BLOB_HOST)}/([^\s\"'<>)]+)", _sub, text)



class _KBRetrieveArgs(BaseModel):
    """Arguments for the KB retrieve tool — matches the Foundry KB MCP schema."""

    messages: list[dict[str, str]] = Field(
        description=(
            "The conversation so far, as a list of role/content dicts. "
            "The retriever uses this to bias which chunks it fetches."
        )
    )
    query_variants: list[str] = Field(
        description=(
            "Two to five short natural-language phrases the retriever should try "
            "in parallel. Cover the different angles of the user's question."
        )
    )


async def _call_kb_retrieve(messages: list[dict], query_variants: list[str]) -> str:
    """Call the KB MCP `knowledge_base_retrieve` tool with per-user trimming.

    The KB MCP endpoint is stateless — no initialize handshake, no session id.
    Just POST tools/call directly with both auth headers.
    """
    token = (await asyncio.to_thread(_credential.get_token, _SEARCH_SCOPE)).token

    async with httpx.AsyncClient(timeout=60.0) as client:
        headers = {
            "Authorization": f"Bearer {token}",
            "x-ms-query-source-authorization": token,
            "Content-Type": "application/json",
            "Accept": "application/json, text/event-stream",
        }

        resp = await client.post(
            _KB_MCP_URL,
            headers=headers,
            json={
                "jsonrpc": "2.0",
                "id": 1,
                "method": "tools/call",
                "params": {
                    "name": "knowledge_base_retrieve", # MCP TOOL NAME*
                    "arguments": {"messages": messages, "query_variants": query_variants},
                },
            },
        )
        if resp.status_code >= 400:
            raise RuntimeError(
                f"KB MCP returned {resp.status_code}: {resp.text[:1000]}"
            )

    body = resp.text
    # Streamable HTTP responses may be SSE-wrapped: "event: message\ndata: <json>"
    if body.startswith("event:"):
        for line in body.splitlines():
            if line.startswith("data: "):
                body = line[len("data: "):]
                break

    try:
        parsed = json.loads(body)
        # Rewrite blob URLs to portal deep-links before the model sees them,
        # so no matter what the LLM does the citations stay clickable.
        result = json.dumps(parsed.get("result", parsed), ensure_ascii=False)
        return _rewrite_blob_urls(result)
    except json.JSONDecodeError:
        return _rewrite_blob_urls(body)


def _sync_kb_retrieve(messages: list[dict], query_variants: list[str]) -> str:
    """Sync entry-point so LangGraph's ToolNode can call us without an event loop."""
    return asyncio.run(_call_kb_retrieve(messages, query_variants))


_kb_tool = StructuredTool.from_function(
    name="demofs_kb___knowledge_base_retrieve",
    description=(
        "Retrieve DemoFS dispute + fraud guidance from the permission-trimmed "
        "Foundry IQ knowledge base. Returns synthesized answer + references. "
        "Always call this before answering; the caller's identity is used to "
        "trim SharePoint content by group ACL."
    ),
    func=_sync_kb_retrieve,
    coroutine=_call_kb_retrieve,
    args_schema=_KBRetrieveArgs,
)


class AgentState(TypedDict):
    messages: Annotated[list[AnyMessage], add_messages]


TOOLS: list[Any] = [_kb_tool]

_llm = AzureChatOpenAI(
    azure_deployment=os.environ["AZURE_OPENAI_CHAT_DEPLOYMENT"],
    api_version=os.environ.get("AZURE_OPENAI_API_VERSION", "2024-10-21"),
    azure_endpoint=os.environ["AZURE_OPENAI_ENDPOINT"],
    azure_ad_token_provider=_aoai_token_provider,
    temperature=0.1,
).bind_tools(TOOLS)


def _repair_portal_urls(text: str) -> str:
    """The LLM sometimes strips the trailing `/isDeleted~/false/tabToload~/0`
    from portal deep-links because it looks like junk params. Re-append it to
    any portal Blob-properties URL that's missing it so the citation opens."""
    import re
    pattern = re.compile(
        r"(https://portal\.azure\.com/#@[^/]+/blade/Microsoft_Azure_Storage/"
        r"BlobPropertiesBladeV2/storageAccountId/[^/]+/path/[^\s\)\]\"']+?\.md)"
        r"(?!/isDeleted~/false/tabToload~/0)"
    )
    return pattern.sub(r"\1/isDeleted~/false/tabToload~/0", text)


def _call_model(state: AgentState) -> dict:
    messages = state["messages"]
    if not messages or messages[0].type != "system":
        messages = [SystemMessage(content=SYSTEM_PROMPT), *messages]
    ai = _llm.invoke(messages)
    # AIMessage.content can be str or a list of blocks. Fix any portal URL that
    # dropped the /isDeleted~/false/tabToload~/0 suffix. model_copy so we don't
    # mutate a shared pydantic instance in place.
    if isinstance(ai.content, str):
        ai = ai.model_copy(update={"content": _repair_portal_urls(ai.content)})
    elif isinstance(ai.content, list):
        new_content = []
        for block in ai.content:
            if isinstance(block, dict) and isinstance(block.get("text"), str):
                new_content.append({**block, "text": _repair_portal_urls(block["text"])})
            else:
                new_content.append(block)
        ai = ai.model_copy(update={"content": new_content})
    return {"messages": [ai]}


def _build_graph() -> StateGraph:
    workflow = StateGraph(AgentState)
    workflow.add_node("agent", _call_model)
    workflow.add_node("tools", ToolNode(TOOLS))
    workflow.set_entry_point("agent")
    workflow.add_conditional_edges("agent", tools_condition, {"tools": "tools", END: END})
    workflow.add_edge("tools", "agent")
    return workflow


# LangGraph Cloud / langgraph dev reads this exported symbol.
graph = _build_graph().compile()
