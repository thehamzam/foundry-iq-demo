"""Run the LangGraph dispute agent in a local terminal."""

from __future__ import annotations

import argparse
import os
import sys
from collections.abc import Callable, Mapping, Sequence
from pathlib import Path
from typing import Any


EXIT_COMMANDS = {"/quit", "/exit", "quit", "exit"}
TRUTHY_VALUES = {"1", "true", "yes", "on"}
PERSONA_CONFIG_DIRS = {
    "admin": "/root/.azure-admin",
    "frontline": "/root/.azure-frontline",
}


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="Chat with the DemoFS LangGraph agent.")
    parser.add_argument(
        "question",
        nargs="?",
        help="Run one question and exit. Omit it for an interactive conversation.",
    )
    parser.add_argument(
        "--persona",
        choices=tuple(PERSONA_CONFIG_DIRS),
        help="Use the isolated Azure CLI login for admin or frontline.",
    )
    return parser


def extract_message_text(message: Any) -> str:
    content = getattr(message, "content", message)
    if isinstance(content, str):
        return content
    if isinstance(content, Sequence):
        parts: list[str] = []
        for block in content:
            if isinstance(block, str):
                parts.append(block)
            elif isinstance(block, Mapping) and block.get("text"):
                parts.append(str(block["text"]))
        if parts:
            return "\n".join(parts)
    return str(content)


def configure_tracing(environ: dict[str, str]) -> bool:
    tracing_enabled = environ.get("LANGSMITH_TRACING", "").strip().lower()
    if tracing_enabled not in TRUTHY_VALUES:
        return False
    if environ.get("LANGSMITH_API_KEY", "").strip():
        return True

    environ["LANGSMITH_TRACING"] = "false"
    environ["LANGCHAIN_TRACING_V2"] = "false"
    return False


def configure_persona(environ: dict[str, str], persona: str | None) -> str | None:
    if persona is None:
        return None
    environ["AZURE_CONFIG_DIR"] = PERSONA_CONFIG_DIRS[persona]
    return persona


def invoke_agent(
    compiled_graph: Any,
    messages: list[Any],
    question: str,
    message_factory: Callable[..., Any],
) -> tuple[list[Any], str]:
    result = compiled_graph.invoke(
        {"messages": [*messages, message_factory(content=question)]}
    )
    updated_messages = list(result.get("messages") or [])
    if not updated_messages:
        raise RuntimeError("The agent returned no messages.")
    return updated_messages, extract_message_text(updated_messages[-1])


def main(argv: Sequence[str] | None = None) -> int:
    args = build_parser().parse_args(argv)

    from dotenv import load_dotenv

    load_dotenv(Path(__file__).with_name(".env"))
    persona = configure_persona(os.environ, args.persona)
    tracing_enabled = configure_tracing(os.environ)

    from langchain_core.messages import HumanMessage

    from agent import graph

    messages: list[Any] = []
    if args.question:
        _, answer = invoke_agent(graph, messages, args.question, HumanMessage)
        print(answer)
        return 0

    print("DemoFS LangGraph agent CLI. Type /quit to exit.")
    if persona:
        print(f"Azure persona: {persona}")
    if not tracing_enabled:
        print("LangSmith tracing is off. Set LANGSMITH_API_KEY to enable it.")
    while True:
        try:
            question = input("\nYou> ").strip()
        except (EOFError, KeyboardInterrupt):
            print()
            return 0
        if question.lower() in EXIT_COMMANDS:
            return 0
        if not question:
            continue

        try:
            messages, answer = invoke_agent(graph, messages, question, HumanMessage)
        except Exception as exc:
            print(f"Error: {exc}", file=sys.stderr)
            continue
        print(f"\nAgent> {answer}")


if __name__ == "__main__":
    raise SystemExit(main())