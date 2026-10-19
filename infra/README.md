# Public quickstart infrastructure

The public quickstart is a subscription-scope Bicep composition invoked only by
the guarded PowerShell deployment wrapper. The wrapper creates one new
disposable resource group and does not accept existing Azure resource IDs or a
caller-selected resource-group name for adoption.

## Source of truth

[`main.bicep`](./main.bicep) is the public entrypoint. Bicep owns:

- the resource group and immutable ownership tags;
- Search, Foundry account/project, model deployments, and Search connection;
- one shared corpus/package/Function-runtime storage account with separate private containers;
- the custom-skill Function and its network resources;
- Log Analytics and Application Insights;
- managed identities and deterministic, resource-scoped role assignments,
  including Function host-Storage Reader/data access and operator Foundry
  data-plane access required for Toolboxes and hosted agents;
- every Search and Foundry IQ provisioning payload and API version.

PowerShell does not carry a second copy of Search or Foundry IQ schemas. The
entrypoint emits one non-secret `quickstartContract` containing resource
identity, ordered Bicep-authored data-plane operations, read-only verification
checks, and cleanup ownership evidence.

## Parameters

| Name | Purpose |
|---|---|
| `location` | User-confirmed Azure region |
| `environment` | Lowercase quickstart name seed |
| `deploymentId` | Canonical GUID used for immutable ownership and deterministic resource-group naming |
| `operatorPrincipalId` | Explicit operator object ID for keyless bootstrap |
| `searchSku` | Search capacity selection |
| `chatModelName`, `chatModelVersion`, `chatCapacity` | Chat deployment |
| `embeddingModelName`, `embeddingModelVersion`, `embeddingCapacity` | Embedding deployment; this revision supports only `text-embedding-3-large` |
| `tags` | Additional non-secret tags; immutable ownership keys cannot be overridden |

[`main.bicepparam`](./main.bicepparam) contains non-deployable replacement
markers only and exists for offline `build-params` validation. It is not a
supported raw deployment entrypoint. Never commit subscription, tenant,
principal, or deployment values.

The PowerShell wrapper additionally requires `SubscriptionId` to select and
validate the subscription scope. It forwards every infrastructure parameter by
the same name to [`main.bicep`](./main.bicep). Although `embeddingModelName`
exists, it is not a supported model-selection override in this revision: the
Search vectorizer and knowledge-source payloads are fixed to
`text-embedding-3-large`. Any other embedding model name is unsupported and
must be treated as a failing configuration, not an interchangeable model
override.

## Contract

`quickstartContract.schemaVersion` is currently `3.1.0`. The envelope contains:

- `deployment`: subscription, resource group, deployment record, location, and
  immutable ownership tags;
- `resources`: non-secret IDs, names, endpoints, and managed-identity principal
  IDs;
- `dataPlane`: the pinned API profile and ordered idempotent `PUT` operations;
- `verification`: read-only checks, including the semantically read-only
  retrieval query;
- `cleanup`: the exact resource group, deployment record, expected subscription,
  and required ownership/protection tags.

The contract intentionally excludes tokens, keys, SAS values, package bytes,
document content, and credential-bearing connection strings.

## Network and identity

The sole public-keyless topology leaves HTTPS service endpoints reachable while
disabling local/key authentication where supported. The rejected partial
private profile is not offered: it did not provide complete Search and Foundry
private endpoints, DNS, and an in-VNet bootstrap path. Production deployments
must add customer-specific private networking and validate it as a separate
architecture rather than treating this public quickstart as production-ready.

Function authentication uses App Service authentication with only the Search
managed identity in its principal allowlist. The non-sensitive `/api/health`
route is the sole authentication exclusion so deployment verification does not
require an interactive operator token for the custom API audience. Gate C must
validate that the selected region/provider combination accepts this
configuration.

## Direct Bicep

Raw direct deployment is unsupported. ARM subscription deployment cannot prove
historical nonexistence of a resource group and would otherwise allow an
upsert. Follow the supported [operator quickstart](../docs/quickstart.md), which
uses [`deploy.ps1`](../scripts/quickstart/deploy.ps1) to require the
deterministic resource group to be absent on first deployment. A rerun requires
both the persisted local contract and the complete canonical subscription
deployment output to match before Bicep is invoked.

## Gate A

Offline checks are in [`tests/`](./tests/):

- `Test-PublicQuickstartContract.ps1`
- `Test-QuickstartAuthorization.ps1`
- `Test-OperationalScriptBoundary.ps1`
- `Test-InfraParity.ps1`
- `Test-TenantParity.ps1` for the separately retained tenant path

A successful Gate A proves static contracts and boundaries only. It does not
prove provider registration, regional availability, quota, model capacity,
network reachability, preview API acceptance, deployment, or production
readiness.
