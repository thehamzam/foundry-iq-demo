"""Knowledge-base configuration for the local LangGraph agent."""

from __future__ import annotations

from collections.abc import Mapping


_PROFILE_VARIABLES = {
    "custom": "FOUNDRY_CUSTOM_KB_NAME",
    "baseline": "FOUNDRY_BASELINE_KB_NAME",
}


def resolve_kb_name(environ: Mapping[str, str]) -> str:
    """Resolve the selected KB name, allowing an explicit per-run override."""
    profile = environ.get("FOUNDRY_KB_PROFILE", "custom").strip().lower()
    if profile not in _PROFILE_VARIABLES:
        choices = ", ".join(_PROFILE_VARIABLES)
        raise ValueError(
            f"Invalid FOUNDRY_KB_PROFILE {profile!r}; expected one of: {choices}."
        )

    explicit_name = environ.get("FOUNDRY_KB_OVERRIDE", "").strip()
    if explicit_name:
        return explicit_name

    variable = _PROFILE_VARIABLES[profile]
    kb_name = environ.get(variable, "").strip()
    if not kb_name:
        raise ValueError(
            f"{variable} must be set when FOUNDRY_KB_PROFILE={profile}."
        )
    return kb_name


def build_kb_mcp_url(environ: Mapping[str, str]) -> str:
    """Build the Foundry IQ MCP URL using the selected KB and API version."""
    return (
        f"{environ['AZURE_SEARCH_ENDPOINT']}/knowledgebases/"
        f"{resolve_kb_name(environ)}/mcp?api-version={environ['KB_API_VERSION']}"
    )