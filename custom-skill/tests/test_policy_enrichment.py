import os
import sys
import unittest

sys.path.insert(0, os.path.dirname(os.path.dirname(__file__)))

import policy_enrichment as enrichment


class PolicyEnrichmentTests(unittest.TestCase):
    def setUp(self):
        self.original_version = enrichment.ENRICHMENT_VERSION
        enrichment.ENRICHMENT_VERSION = "test-version"

    def tearDown(self):
        enrichment.ENRICHMENT_VERSION = self.original_version

    def test_exact_batch_shape_and_order(self):
        result = enrichment.enrich_batch([
            {"recordId": "a", "data": {"text": "POL-1 duplicate charge"}},
            {"recordId": "b", "data": {"text": "PROC-2 not received"}},
        ])
        self.assertEqual(["a", "b"], [item["recordId"] for item in result["values"]])
        self.assertEqual({
            "documentType", "disputeCategories", "networkRuleRefs", "requiresEscalation",
            "documentVersion", "effectiveDate", "authority", "accessScope",
            "enrichmentVersion", "enrichmentConfidence", "enrichmentWarnings",
        }, set(result["values"][0]["data"]))

    def test_duplicate_metadata_refs_and_confidence(self):
        text = (
            "POL-duplicate.md\n**Version:** 3\n**Effective Date:** 2024-01-01\n"
            "**Owner:** Operations\n**Classification:** Internal\n"
            "Duplicate processing under VISA-RULES-12-6-2 and 12.6.2."
        )
        item = enrichment.enrich_batch([{"recordId": "1", "data": {"text": text}}])["values"][0]
        self.assertEqual("policy", item["data"]["documentType"])
        self.assertEqual(["duplicate-charge"], item["data"]["disputeCategories"])
        self.assertEqual(["VISA-RULES-12-6-2", "12.6.2"], item["data"]["networkRuleRefs"])
        self.assertFalse(item["data"]["requiresEscalation"])
        self.assertEqual(0.9, item["data"]["enrichmentConfidence"])
        self.assertEqual("3", item["data"]["documentVersion"])
        self.assertEqual("test-version", item["data"]["enrichmentVersion"])

    def test_unauthorized_regulation_e_amount_escalates(self):
        item = enrichment.enrich_batch([{
            "recordId": "1",
            "data": {"text": "POL policy: unauthorized electronic fund transfer $500."},
        }])["values"][0]
        self.assertEqual(["unauthorized-transaction", "regulation-e"], item["data"]["disputeCategories"])
        self.assertTrue(item["data"]["requiresEscalation"])

    def test_goods_services_and_stable_codes(self):
        item = enrichment.enrich_batch([{
            "recordId": "1",
            "data": {"text": "PROC not received, not as described; Visa 13.2 and 10.1."},
        }])["values"][0]
        self.assertEqual(["goods-services-dispute"], item["data"]["disputeCategories"])
        self.assertEqual(["10.1", "13.2"], item["data"]["networkRuleRefs"])

    def test_unknown_low_confidence_warning_and_escalation(self):
        item = enrichment.enrich_batch([{
            "recordId": "1",
            "data": {"text": "General notes with no applicable terms."},
        }])["values"][0]
        self.assertEqual("unknown", item["data"]["documentType"])
        self.assertEqual(0.4, item["data"]["enrichmentConfidence"])
        self.assertTrue(item["data"]["requiresEscalation"])
        self.assertEqual(2, len(item["data"]["enrichmentWarnings"]))
        self.assertEqual(enrichment.WARNING_MESSAGE, item["warnings"][0]["message"])

    def test_malformed_record_isolated(self):
        result = enrichment.enrich_batch([
            {"recordId": "bad", "data": {"text": 7}},
            {"recordId": "good", "data": {"text": "POL duplicate charge"}},
        ])
        self.assertIn("errors", result["values"][0])
        self.assertIn("data", result["values"][1])

    def test_malformed_envelope_raises_value_error(self):
        with self.assertRaisesRegex(ValueError, "values must be a list"):
            enrichment.enrich_batch({})


if __name__ == "__main__":
    unittest.main()