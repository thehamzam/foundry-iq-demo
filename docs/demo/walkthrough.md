# Demo walkthrough

This walkthrough uses a fictional duplicate-charge scenario to explain the
retrieval flow. It is not a script for handling real disputes.

## Before the demo

Confirm that:

- the deployment was separately authorized and completed through
  [`deploy.ps1`](../../scripts/quickstart/deploy.ps1);
- [Verification](../quickstart.md#5-verify) passes against the exact emitted
  contract;
- only the repository's synthetic Markdown corpus was uploaded;
- the audience understands that all procedures, dates, thresholds, codes, and
  queues are invented.

The repository is currently at offline Gate A, so these live prerequisites have
not yet been demonstrated.

## Scenario

A fictional cardholder sees two transactions with the same merchant label and
amount. A support representative wants the synthetic lab procedure for deciding
whether the pair should enter the duplicate-intake drill.

## Walkthrough

1. **Show the source boundary.** Open
   [`PROC-CHUNKLAB-101-synthetic-duplicate-intake.md`](../../sample-data/documents/PROC-CHUNKLAB-101-synthetic-duplicate-intake.md)
   and point out its synthetic notice, document ID, version, and section
   headings.
2. **Explain ingestion.** The wrapper uploads the Markdown file to the owned
   Blob container. Azure AI Search indexes it, splits it into chunks, invokes
   deterministic enrichment, creates embeddings, and preserves source metadata.
3. **Run the implemented verification query.** Verification asks:

   ```text
   What synthetic procedure applies to duplicate dispute intake?
   ```

4. **Inspect grounding.** A passing check requires a non-empty response,
   citations, and a source identifier for every citation. Do not judge success
   from fluent wording alone.
5. **Trace responsibility.** Azure AI Search performs selection, ranking,
   synthesis, and citation generation. Foundry supplies the connected project,
   model, identity, and managed-lifecycle context.
6. **Test abstention behavior in an application client.** Ask for material that
   is not in the synthetic corpus. The responsible behavior is to state that the
   guidance was not retrieved rather than inventing policy.
7. **Show the lifecycle.** Verification detects drift but does not repair it.
   Cleanup removes the whole owned resource group through the guarded script.

## Optional synthetic questions

The offline file
[`evaluation-queries.json`](../../sample-data/evaluation-queries.json)
contains expected-document questions for local evaluation design. The deploy
wrapper does not upload this JSON file. Example topics include:

- the duplicate correlation key;
- the synthetic duplicate-pair review target;
- the split-tender exclusion;
- the ordered synthetic escalation sequence;
- the fictional Lane B exception.

Do not present expected facts as real policy, and do not claim an accuracy,
latency, or quality result without a separately designed and executed
evaluation.

## Close

Reiterate:

- the data and scenario are synthetic;
- direct Azure AI Search is sufficient when the managed Foundry agent lifecycle
  is unnecessary;
- public endpoints are a quickstart choice, not production hardening;
- the environment continues to incur charges until
  [guarded cleanup](../quickstart.md#6-clean-up) completes.
