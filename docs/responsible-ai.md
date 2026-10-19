# Responsible AI guidance

This repository is an educational sample for grounded retrieval. It is not a
decision system and must not be used as legal, compliance, payment-network, or
institutional policy.

## Intended use

- Learn how to connect synthetic content to Azure AI Search.
- Inspect citations and source identifiers.
- Test whether an application abstains when evidence is absent.
- Compare direct Search integration with a managed Foundry agent lifecycle.

## Human responsibility

Any application built from this sample must keep a qualified human responsible
for interpretation and action. Generated summaries and classifications are
drafts. The system must not file a dispute, issue credit, block an account,
accuse a person, or make a final fraud or compliance determination.

## Grounding requirements

- Base material claims only on retrieved sources.
- Preserve citations and source identifiers through the user experience.
- State when retrieval is empty, incomplete, stale, ambiguous, or conflicting.
- Do not fill evidence gaps with model memory or general knowledge.
- Separate source facts from generated recommendations.
- Keep synthetic labels visible in demonstrations and screenshots.

## Evaluation

Evaluate more than fluent answers. Test:

- source selection and citation correctness;
- unsupported-claim and abstention behavior;
- conflicting and missing evidence;
- boundary exceptions and near-match distractors;
- identity and permission filters in any production design;
- model/API changes across regions and versions;
- harmful reliance, automation bias, and operator override behavior.

The included evaluation-query file is a small synthetic fixture, not a benchmark
or evidence of accuracy. No quality, latency, fairness, safety, or business
metric has been measured for the public quickstart.

## Data and privacy

Use synthetic data only. Do not place personal, financial, customer, member,
employee, transaction, account, case, legal, confidential, or regulated data in
the sample. Logs, prompts, citations, and monitoring can disclose content; apply
an approved data-governance and retention design before any non-synthetic use.

## Security and permissions

The default public quickstart does not implement document-level permissions.
The optional [SharePoint permission-trimming path](./sharepoint-permission-trimming.md)
preserves supported group ACLs for both agents only after separate tenant,
Search, and Toolbox configuration. A production solution must still validate
indexed permission metadata, identity propagation, denial tests, and
monitoring. Foundry identity integration does not replace Search-side
permission-aware filtering.

Public endpoints with Entra authentication are used for accessibility in the
sample. Production networking, threat modeling, abuse monitoring, incident
response, data residency, and recovery are separate requirements.

## Model and preview change

Pinned APIs and models may be preview or unavailable in a selected context.
Revalidate behavior after any model, API, prompt, index, corpus, enrichment, or
permission change. Block use when a required safety or security property cannot
be demonstrated.

Report vulnerabilities through [Security](../SECURITY.md). For ordinary sample
questions, see [Support](../SUPPORT.md).
