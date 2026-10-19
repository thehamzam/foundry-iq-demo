# Azure AI Search and Foundry IQ

This sample separates the retrieval engine from the managed agent lifecycle.
That distinction keeps architecture choices explicit and prevents capabilities
from being attributed to the wrong service.

## Responsibility matrix

| Concern | Azure AI Search responsibility | Foundry / Foundry IQ responsibility |
|---|---|---|
| Ingestion | Data sources, indexers, chunking, enrichment, vectorization, and index population | Connects managed agent experiences to the resulting knowledge layer |
| Retrieval | Query execution, source selection, ranking and reranking, merging, and retrieval reasoning | Presents managed connectivity to Search-backed knowledge |
| Grounded output | Answer synthesis and source citations when configured by the knowledge base | Uses grounded Search output in managed agent workflows |
| Authorization over content | Applies permission-aware filters when indexed permission metadata and query filters are configured | Integrates agent identity and connection lifecycle; it does not replace Search-side filtering |
| Agent operations | Search diagnostics cover Search behavior | Managed identity integration, evaluation, monitoring, governance, deployment, and agent lifecycle |

The default public quickstart's corpus is a single synthetic Blob container and
does not implement document-level or user-level permission filtering. The
separate [SharePoint extension](../sharepoint-permission-trimming.md) wires
group-based document trimming into both agents, but requires its own tenant
setup and live allow/deny validation. Do not use the default deployment as
evidence that a production authorization design has been validated.

## What the quickstart configures

Bicep configures:

- a Search index, Blob data source, skillset, and indexer;
- a Search knowledge source and knowledge base;
- a Foundry account, project, chat and embedding model deployments, and a Search
  connection;
- managed identities and resource-scoped role assignments.

The knowledge source and knowledge base are transported to the Search endpoint
using the Bicep-pinned Foundry IQ API profile. Search remains responsible for
retrieval execution.

## When direct Search is enough

Call Azure AI Search directly when the application:

- already owns its identity, connection, deployment, monitoring, and governance
  lifecycle;
- does not require a managed Foundry agent or Toolbox experience; and
- can implement its own application-level orchestration around Search results.

Use the Foundry layer when managed agent connectivity, identity integration,
evaluation, monitoring, governance, and lifecycle management are requirements.
This is an operating-model choice, not a claim that one path is universally
better.

## Preview boundary

The quickstart pins preview API versions in Bicep. API shape, model versions,
quota, and regional or subscription availability must be revalidated before a
live attempt. Static compilation and contract tests cannot establish service
availability or production support.

Return to the [Architecture](../architecture.md) or continue to the
[operator quickstart](../quickstart.md).
