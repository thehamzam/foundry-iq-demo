# Sample data

The public quickstart uploads only the files in
[`../sample-data/documents/`](../sample-data/documents/).
The corpus is intentionally artificial and designed to exercise chunking,
ranking, boundary conditions, citations, and abstention.

## Uploaded corpus

| File | Synthetic purpose |
|---|---|
| [`PROC-CHUNKLAB-101-synthetic-duplicate-intake.md`](../sample-data/documents/PROC-CHUNKLAB-101-synthetic-duplicate-intake.md) | Multi-stage duplicate-intake drill with exclusions, evidence markers, and handoff terms |
| [`RUN-CHUNKLAB-202-synthetic-fraud-escalation.md`](../sample-data/documents/RUN-CHUNKLAB-202-synthetic-fraud-escalation.md) | Escalation rehearsal with invented tiers, ordered response steps, and narrow exceptions |
| [`COMP-CHUNKLAB-303-synthetic-network-rules.md`](../sample-data/documents/COMP-CHUNKLAB-303-synthetic-network-rules.md) | Fictional network-rule simulation with invented lanes, deadlines, and retention periods |

Every document labels itself `SYNTHETIC DEMO CONTENT - PUBLIC TEST DATA` and
states that its names, dates, codes, thresholds, queues, and workflows must not
be used for live decisions.

The wrapper uploads `*.md` only. It does not upload
[`evaluation-queries.json`](../sample-data/evaluation-queries.json),
which contains offline expected-document questions for evaluation design.

## Enrichment

The custom skill produces deterministic metadata such as document type,
recognized synthetic categories, network-rule references, and an advisory
escalation flag. Its output includes a warning that governing source and manual
review control the final decision.

This keyword enrichment is not a classifier certified for real disputes and is
not a legal or compliance control.

## Allowed use

- Demonstrate indexing, retrieval, citations, and source-bound answers.
- Design offline retrieval and boundary-condition tests.
- Practice abstention when evidence is absent or conflicting.
- Replace the corpus with other fully synthetic material in a private fork,
  after reviewing the index and evaluation assumptions.

## Prohibited use

- Do not treat any included fact as real policy or law.
- Do not upload customer, member, employee, card, transaction, account, case,
  legal, regulated, confidential, or personal data.
- Do not use the sample to make eligibility, fraud, credit, legal, disciplinary,
  or operational decisions.
- Do not claim quality, accuracy, latency, or business outcomes from the presence
  of the sample files or expected answers.

See [Responsible AI](./responsible-ai.md) for evaluation and human-review
expectations.
