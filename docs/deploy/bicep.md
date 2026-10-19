# Bicep source of truth

[`../../infra/main.bicep`](../../infra/main.bicep) is the subscription-scope
infrastructure entrypoint. It creates the disposable resource group and composes
the resource-group modules.

## Ownership model

Bicep is authoritative for:

- resource names, types, properties, identities, and role assignments;
- the public-endpoint/keyless network and authentication posture;
- Search index, data source, skillset, indexer, knowledge-source, and
  knowledge-base payloads;
- pinned data-plane API versions, operation order, retries, and verification
  checks;
- immutable ownership/provenance tags and cleanup evidence;
- the non-secret `quickstartContract` schema `3.1.0`.

PowerShell transports these definitions but does not independently author them.

## Module map

| File | Responsibility |
|---|---|
| [`../../infra/main.bicep`](../../infra/main.bicep) | Subscription entrypoint, resource group, composition, and contract output |
| [`../../infra/resources.bicep`](../../infra/resources.bicep) | Search, Foundry account/project, models, Search connection, and core RBAC |
| [`../../infra/storage.bicep`](../../infra/storage.bicep) | Shared quickstart storage, containers, keyless settings, and storage RBAC |
| [`../../infra/custom-search-pipeline.bicep`](../../infra/custom-search-pipeline.bicep) | Function resources and all Search/Foundry IQ data-plane desired state |
| [`../../infra/observability.bicep`](../../infra/observability.bicep) | Log Analytics and Application Insights |

[`../../infra/main.bicepparam`](../../infra/main.bicepparam) contains replacement
markers and safe defaults only. It is for offline validation, not live
deployment.

## Inspect and compile without deployment

Review the entrypoint and compile to standard output:

```powershell
Get-Content .\infra\main.bicep
az bicep build --file .\infra\main.bicep --stdout
az bicep build-params --file .\infra\main.bicepparam --stdout
```

These commands inspect or compile source; they do not deploy it. Compilation
checks syntax and type/schema compatibility only. It does not prove provider
registration, regional availability, quota, permissions, preview acceptance,
network behavior, or successful deployment.

## Why raw direct deployment is unsupported

Do not use a raw `az deployment sub create` command. A direct subscription
deployment can upsert a deterministic resource group but cannot prove that the
group was historically absent or that an existing group belongs to this
quickstart.

The supported wrapper performs additional safeguards:

- first-run resource-group nonexistence checks;
- exact local-to-canonical contract binding for reruns;
- ownership, provenance, and protection-tag checks;
- synthetic corpus and package upload allowlists;
- Bicep-emitted data-plane transport;
- post-deployment verification.

Use the [operator quickstart](../quickstart.md) as the only supported public
deployment path.
