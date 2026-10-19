import os
import re
from typing import Any


WARNING_MESSAGE = (
    "Deterministic keyword enrichment is advisory; governing source and manual review "
    "control the final decision."
)
ENRICHMENT_VERSION = os.environ.get("ENRICHMENT_VERSION", "policy-rules-v1")

_DOC_TYPES = (
    ("POL", "policy"),
    ("PROC", "procedure"),
    ("RUN", "runbook"),
    ("COMP", "compliance"),
    ("VISA", "network-rule"),
    ("BOARD", "board-material"),
    ("LEGAL", "legal-guidance"),
    ("CONF", "threat-intelligence"),
)
_CATEGORIES = (
    ("duplicate-charge", ("duplicate processing", "duplicate charge", "paid by other means")),
    (
        "unauthorized-transaction",
        ("unauthorized", "lost", "stolen", "account takeover", "card-not-present"),
    ),
    (
        "goods-services-dispute",
        ("non-receipt", "not received", "not as described", "quality", "cancelled merchandise", "cancelled service"),
    ),
    ("regulation-e", ("regulation e", "12 cfr part 1005", "electronic fund transfer")),
)
_NETWORK_CODES = ("10.1", "10.4", "10.5", "12.6.1", "12.6.2", "13.1", "13.2", "13.3", "13.5", "13.7")


def _header(text: str, names: tuple[str, ...]) -> str | None:
    alternatives = "|".join(re.escape(name) for name in names)
    match = re.search(rf"(?im)^\s*\*\*(?:{alternatives})\s*:\*\*\s*(.+?)\s*$", text)
    return match.group(1).strip() if match else None


def _document_type(text: str, source_path: str | None) -> str:
    haystack = f"{source_path or ''} {text[:3000]}".upper()
    for prefix, value in _DOC_TYPES:
        if re.search(rf"(?<![A-Z0-9]){re.escape(prefix)}(?:[-_./\s]|$)", haystack):
            return value
    return "unknown"


def _categories(text: str) -> list[str]:
    lowered = text.casefold()
    return [
        category
        for category, phrases in _CATEGORIES
        if any(phrase in lowered for phrase in phrases)
    ]


def _network_refs(text: str) -> list[str]:
    refs: list[str] = []
    if re.search(r"(?i)\bVISA[-_ ]?RULES[-_ ]?12[-_]6[-_]2\b", text):
        refs.append("VISA-RULES-12-6-2")
    for code in _NETWORK_CODES:
        if re.search(rf"(?<![\w.$]){re.escape(code)}(?!\d|\.\d)", text):
            refs.append(code)
    return refs


def _requires_escalation(text: str, document_type: str, categories: list[str]) -> bool:
    lowered = text.casefold()
    explicit = (
        "fraud investigation",
        "legal counsel",
        "compliance escalation",
        "regulatory breach",
        "unlimited liability",
    )
    if any(term in lowered for term in explicit):
        return True
    if re.search(r"(?i)(?:\$|usd\s*)\s*([5-9]\d{2,}|[1-9]\d{3,})(?:\.\d{2})?", text):
        return True
    if re.search(r"(?i)\b(?:after|over|more than)\s+6[0-9]\s+days\b", text):
        return True
    return document_type == "unknown" and not categories


def enrich_record(record: Any) -> dict[str, Any]:
    if not isinstance(record, dict):
        return {"recordId": None, "errors": [{"message": "Each value must be an object"}]}
    record_id = record.get("recordId")
    data = record.get("data")
    if not isinstance(record_id, str):
        return {"recordId": record_id, "errors": [{"message": "recordId must be a string"}]}
    if not isinstance(data, dict):
        return {"recordId": record_id, "errors": [{"message": "data must be an object"}]}
    text = data.get("text")
    if not isinstance(text, str) or not text.strip():
        return {"recordId": record_id, "errors": [{"message": "data.text must be a non-empty string"}]}
    source_path = data.get("sourcePath")
    if source_path is not None and not isinstance(source_path, str):
        return {"recordId": record_id, "errors": [{"message": "data.sourcePath must be a string"}]}

    document_type = _document_type(text, source_path)
    categories = _categories(text)
    confidence = 0.9 if document_type != "unknown" and categories else 0.75 if document_type != "unknown" or categories else 0.4
    warnings = [WARNING_MESSAGE]
    if confidence < 0.75:
        warnings.append("Low confidence because no recognized document type or dispute category was found.")

    result = {
        "documentType": document_type,
        "disputeCategories": categories,
        "networkRuleRefs": _network_refs(text),
        "requiresEscalation": _requires_escalation(text, document_type, categories),
        "documentVersion": _header(text, ("Version",)),
        "effectiveDate": _header(text, ("Effective Date", "Effective")),
        "authority": _header(text, ("Owner", "Source")),
        "accessScope": _header(text, ("Classification",)),
        "enrichmentVersion": ENRICHMENT_VERSION,
        "enrichmentConfidence": confidence,
        "enrichmentWarnings": warnings,
    }
    return {
        "recordId": record_id,
        "data": result,
        "warnings": [{"message": WARNING_MESSAGE}],
    }


def enrich_batch(values: Any) -> dict[str, list[dict[str, Any]]]:
    if not isinstance(values, list):
        raise ValueError("values must be a list")
    return {"values": [enrich_record(record) for record in values]}