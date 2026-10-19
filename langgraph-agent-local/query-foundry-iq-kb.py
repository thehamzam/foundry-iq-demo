"""Query a Foundry IQ knowledge base directly, without an agent or MCP."""

from __future__ import annotations

import argparse
import os
import sys
from collections.abc import Iterator, Mapping, Sequence
from typing import Any


DEFAULT_API_VERSION = "2026-04-01"
PROFILE_VARIABLES = {
    "custom": "FOUNDRY_CUSTOM_KB_NAME",
    "baseline": "FOUNDRY_BASELINE_KB_NAME",
}


class ConfigurationError(ValueError):
    """Raised when required non-secret configuration is missing or invalid."""


def positive_integer(value: str) -> int:
    parsed = int(value)
    if parsed <= 0:
        raise argparse.ArgumentTypeError("must be a positive integer")
    return parsed


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description=(
            "Query a Foundry IQ Knowledge Base directly with Azure identity. "
            "This is retrieval-grounded KB chat, not a conversational agent. "
            "The direct retrieve API accepts semantic intents but no prior messages, "
            "so every question is an independent turn."
        )
    )
    parser.add_argument(
        "question",
        nargs="?",
        help="Run one query and exit. Omit it to start an interactive prompt.",
    )
    parser.add_argument(
        "--endpoint",
        help="Search endpoint; defaults to AZURE_SEARCH_ENDPOINT.",
    )
    parser.add_argument(
        "--knowledge-base",
        dest="knowledge_base",
        help=(
            "Knowledge Base name. Takes precedence over FOUNDRY_KB_OVERRIDE and "
            "the selected profile variable."
        ),
    )
    parser.add_argument(
        "--profile",
        choices=tuple(PROFILE_VARIABLES),
        help="KB profile; defaults to FOUNDRY_KB_PROFILE or custom.",
    )
    parser.add_argument(
        "--api-version",
        help=f"API version; defaults to KB_API_VERSION or {DEFAULT_API_VERSION}.",
    )
    parser.add_argument(
        "--max-output-tokens",
        type=positive_integer,
        default=1200,
        help="Maximum retrieval response size in tokens (default: 1200).",
    )
    parser.add_argument(
        "--max-runtime-seconds",
        type=positive_integer,
        default=30,
        help="Maximum retrieval runtime in seconds (default: 30).",
    )
    return parser


def resolve_configuration(
    args: argparse.Namespace,
    environ: Mapping[str, str],
) -> tuple[str, str, str]:
    endpoint = (args.endpoint or environ.get("AZURE_SEARCH_ENDPOINT", "")).strip()
    if not endpoint:
        raise ConfigurationError(
            "Set AZURE_SEARCH_ENDPOINT or pass --endpoint with the Search service URL."
        )

    profile = (args.profile or environ.get("FOUNDRY_KB_PROFILE", "custom")).strip().lower()
    if profile not in PROFILE_VARIABLES:
        choices = ", ".join(PROFILE_VARIABLES)
        raise ConfigurationError(
            f"Invalid FOUNDRY_KB_PROFILE {profile!r}; expected one of: {choices}."
        )

    knowledge_base = (
        args.knowledge_base
        or environ.get("FOUNDRY_KB_OVERRIDE", "")
        or environ.get(PROFILE_VARIABLES[profile], "")
    ).strip()
    if not knowledge_base:
        variable = PROFILE_VARIABLES[profile]
        raise ConfigurationError(
            f"Set {variable}, set FOUNDRY_KB_OVERRIDE, or pass --knowledge-base."
        )

    api_version = (
        args.api_version or environ.get("KB_API_VERSION", DEFAULT_API_VERSION)
    ).strip()
    if not api_version:
        raise ConfigurationError("KB_API_VERSION or --api-version cannot be empty.")

    return endpoint.rstrip("/"), knowledge_base, api_version


def build_retrieval_request(
    question: str,
    max_output_tokens: int,
    max_runtime_seconds: int,
) -> dict[str, Any]:
    if not question.strip():
        raise ValueError("Question cannot be empty.")
    if max_output_tokens <= 0 or max_runtime_seconds <= 0:
        raise ValueError("Runtime and output-token limits must be positive integers.")

    return {
        "intents": [{"type": "semantic", "search": question.strip()}],
        "maxRuntimeInSeconds": max_runtime_seconds,
        "maxOutputSizeInTokens": max_output_tokens,
        "includeActivity": False,
    }


def _value(item: Any, *names: str) -> Any:
    for name in names:
        if isinstance(item, Mapping) and name in item:
            return item[name]
        value = getattr(item, name, None)
        if value is not None:
            return value
    return None


def extract_answer(response: Any) -> str:
    text_parts: list[str] = []
    for message in _value(response, "response") or []:
        for content in _value(message, "content") or []:
            text = _value(content, "text")
            if text:
                text_parts.append(str(text).strip())
    return "\n\n".join(part for part in text_parts if part) or "(No text answer returned.)"


def format_references(response: Any) -> list[str]:
    formatted: list[str] = []
    for index, reference in enumerate(_value(response, "references") or [], start=1):
        source_data = _value(reference, "source_data", "sourceData") or {}
        reference_type = _value(reference, "type") or "reference"
        reference_id = _value(reference, "id") or f"reference-{index}"
        title = _value(reference, "title") or _value(source_data, "title", "name")
        location = _value(
            reference,
            "url",
            "blob_url",
            "blobUrl",
            "doc_url",
            "docUrl",
        ) or _value(source_data, "url", "uri", "source", "path")
        doc_key = _value(reference, "doc_key", "docKey")
        score = _value(reference, "reranker_score", "rerankerScore")

        details = [str(title)] if title else []
        if location:
            details.append(str(location))
        elif doc_key:
            details.append(f"document key: {doc_key}")
        if score is not None:
            details.append(f"score: {score:.4f}" if isinstance(score, float) else f"score: {score}")

        suffix = " | ".join(details) if details else "No source location returned"
        formatted.append(f"[{index}] {reference_type} {reference_id}: {suffix}")
    return formatted


def print_response(response: Any) -> None:
    print("\nAnswer")
    print("------")
    print(extract_answer(response))

    references = format_references(response)
    if references:
        print("\nReferences")
        print("----------")
        for reference in references:
            print(reference)
    else:
        print("\nReferences: none returned")


def create_client(endpoint: str, knowledge_base: str, api_version: str) -> tuple[Any, Any]:
    try:
        from azure.identity import DefaultAzureCredential
        from azure.search.documents.knowledgebases import KnowledgeBaseRetrievalClient
    except ImportError as exc:
        raise RuntimeError(
            "Missing Azure dependencies. Install this project's requirements first."
        ) from exc

    credential = DefaultAzureCredential()
    try:
        client = KnowledgeBaseRetrievalClient(
            endpoint=endpoint,
            credential=credential,
            knowledge_base_name=knowledge_base,
            api_version=api_version,
        )
    except Exception:
        close_credential = getattr(credential, "close", None)
        if close_credential:
            close_credential()
        raise
    return client, credential


def run_query(client: Any, question: str, args: argparse.Namespace) -> bool:
    try:
        request = build_retrieval_request(
            question,
            max_output_tokens=args.max_output_tokens,
            max_runtime_seconds=args.max_runtime_seconds,
        )
        print_response(client.retrieve(request))
        return True
    except Exception as exc:  # Azure exception types vary across SDK releases.
        status_code = getattr(exc, "status_code", None)
        if status_code == 401 or exc.__class__.__name__ == "ClientAuthenticationError":
            detail = (
                "Authentication failed. Run 'az login' for local development or configure "
                "a supported DefaultAzureCredential identity."
            )
        elif status_code == 403:
            detail = (
                "Access was denied. Verify the signed-in identity has the required Search "
                "data-plane role for this Knowledge Base."
            )
        elif status_code == 404:
            detail = "Knowledge Base not found. Verify the endpoint, KB name, and API version."
        else:
            detail = (
                f"Retrieval failed ({exc.__class__.__name__}). Verify network access, "
                "endpoint, Knowledge Base name, API version, and Azure identity permissions."
            )
        print(f"Error: {detail}", file=sys.stderr)
        return False


def interactive_questions() -> Iterator[str]:
    print(
        "Direct Foundry IQ Knowledge Base retrieval. Each question is an independent turn.\n"
        "Type /quit to exit."
    )
    while True:
        try:
            question = input("\nKB> ").strip()
        except (EOFError, KeyboardInterrupt):
            print()
            return
        if question.lower() in {"/quit", "/exit", "quit", "exit"}:
            return
        if question:
            yield question


def main(argv: Sequence[str] | None = None) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)

    try:
        endpoint, knowledge_base, api_version = resolve_configuration(args, os.environ)
        client, credential = create_client(endpoint, knowledge_base, api_version)
    except (ConfigurationError, RuntimeError) as exc:
        parser.error(str(exc))

    success = True
    try:
        if args.question:
            success = run_query(client, args.question, args)
        else:
            for question in interactive_questions():
                success = run_query(client, question, args) and success
    finally:
        client.close()
        close_credential = getattr(credential, "close", None)
        if close_credential:
            close_credential()

    return 0 if success else 1


if __name__ == "__main__":
    raise SystemExit(main())