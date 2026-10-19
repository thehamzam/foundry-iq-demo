# Operator quickstart

This is the complete supported operator journey for the public quickstart:
prepare, inspect, run what-if, obtain authorization, deploy, verify, and clean
up. Run commands from the repository root with PowerShell 7.4 or later.

> **Current validation status:** The current public quickstart revision has
> passed static/offline Gate A only. It has not received Azure subscription
> validation, Azure what-if, live deployment, cost measurement, penetration
> testing, or production certification.

The only supported deployment entrypoint is
[`../scripts/quickstart/deploy.ps1`](../scripts/quickstart/deploy.ps1). Do not
run a raw `az deployment sub create`: direct Bicep deployment cannot enforce the
wrapper's historical non-adoption, contract-binding, artifact-allowlist, and
post-deployment verification safeguards.

## 1. Prepare

### Local tools

Install these tools before starting:

- PowerShell 7.4 or later, invoked as `pwsh`;
- Azure CLI with Bicep support;
- Git to obtain the repository.

```powershell
pwsh --version
az version
az bicep version
```

The quickstart does not install tools and no script reads `.env` files.

### Confirm Azure context

Obtain and independently confirm:

- an active Azure CLI sign-in and the exact subscription ID;
- a location where every required service, preview API, model version, and
  quota is available;
- the Microsoft Entra object ID of the human operator;
- a new canonical GUID to keep as the stable deployment ID.

The wrapper compares the active Azure CLI subscription ID with
`-SubscriptionId` and fails on a case-sensitive mismatch. It does not change the
active subscription.

### Confirm permissions and availability

The deployer needs permissions to create the inventory in
[Architecture](./architecture.md) and
`Microsoft.Authorization/roleAssignments/write`. Use an organization-approved
least-privilege combination instead of assuming blanket Owner access. The
operator principal receives Bicep-defined Search bootstrap and storage upload
roles; validate the exact role policy with an Azure administrator.

Before a live attempt, validate:

- Azure AI Search SKU and agentic-retrieval/knowledge-base support;
- Foundry account, project, connection, and model-deployment support;
- the exact chat model name/version and embedding model version;
- model capacity and quota;
- App Service PremiumV3 quota for `P1v3`;
- Azure AI Search S1-or-higher availability for a skillset indexer using a shared private link;
- required diagnostic categories, resource providers, role assignments, and
  App Service authentication behavior.

This revision supports only `text-embedding-3-large` for embeddings because the
Search vectorizer and knowledge-source payloads are fixed to that model.
Although `EmbeddingModelName` is exposed, any other value is unsupported and
must fail; it is not an interchangeable model-selection override.

### Review cost, security, and data boundaries

Search, model deployments, Functions on App Service PremiumV3, private endpoints, storage, and
monitoring are billable. Cost varies by context and has not been measured for this
revision. Review the proposed resources and cost controls before authorization,
then clean up promptly.

The sample disables Storage public network access and uses Blob, Queue, Table,
and File private endpoints, private DNS, Function regional VNet integration,
and a short-lived managed-identity ACI uploader. Search, Foundry, and Function
inbound endpoints remain public with Entra/keyless controls. The topology does
not implement customer-specific policy, production retention, or a complete
production security baseline.

Upload only the included synthetic Markdown in
[`../sample-data/documents/`](../sample-data/documents/). Never upload customer,
member, employee, transaction, account, case, legal, regulated, confidential,
or personal data. The wrapper does not upload
[`evaluation-queries.json`](../sample-data/evaluation-queries.json).

## 2. Understand inputs and ownership

| Parameter | Required | Validation or default |
|---|---:|---|
| `SubscriptionId` | Yes | Must exactly match the active Azure CLI subscription ID |
| `Location` | Yes | Passed to the subscription deployment after confirmation |
| `Environment` | Yes | Lowercase letter, then lowercase letters/digits/hyphens; 3-24 characters |
| `DeploymentId` | Yes | Canonicalizable GUID; drives deployment and resource-group names |
| `OperatorPrincipalId` | Yes | 36-character GUID-shaped object ID |
| `FunctionAuthClientId` | Yes | Canonical client ID of a single-tenant Microsoft Entra app registration protecting the custom-skill Function API |
| `FunctionAuthAudience` | Yes | Must exactly equal `api://<FunctionAuthClientId>` and be configured as that app registration's Application ID URI |
| `SearchSku` | No | `standard`; `standard` or `standard2` because skillset indexers require S1 or higher for shared private links |
| `FunctionPlanSku` | No | `P1v3`; private host Storage uses VNet-capable App Service PremiumV3 hosting |
| `ChatModelName` | No | `gpt-4o` |
| `ChatModelVersion` | Yes | Exact validated version |
| `ChatCapacity` | No | `10`; range 1-1000 |
| `EmbeddingModelName` | No | Fixed to `text-embedding-3-large` |
| `EmbeddingModelVersion` | Yes | Exact validated version |
| `EmbeddingCapacity` | No | `50`; range 1-1000. The bundled long-form corpus can exceed the effective request budget at 10K TPM. |
| `Tags` | No | Empty hashtable; immutable ownership keys cannot be overridden |
| `WhatIf` | No | Runs preflight and ARM what-if, then exits before writes |
| `NonInteractive` | No | Not implemented; throws instead of bypassing authorization |

The wrapper derives:

- resource group: `rg-<environment>-<canonical-deployment-id>`;
- subscription deployment: `quickstart-<canonical-deployment-id>`;
- ignored local contract:
  `.azure/quickstart-contract-<canonical-deployment-id>.json`.

The Bicep output and local contract use schema `3.1.0`. Before deployment,
create a single-tenant Microsoft Entra app registration for the Function API,
set its Application ID URI to `api://<client-id>`, and ensure its service
principal exists. The quickstart deliberately accepts this registration as an
explicit prerequisite instead of creating or deleting tenant-level objects.
Tags cannot override
`quickstart.owner`, `quickstart.schemaVersion`, `quickstart.deploymentId`,
`quickstart.deploymentName`, `quickstart.provenanceId`, or
`quickstart.protected`.

First deployment requires the deterministic resource group not to exist. A
rerun requires exact agreement among the saved local contract, complete
canonical subscription deployment output, and live ownership/protection tags.
Matching tags alone never authorize adoption.

## 3. Run what-if

Replace every placeholder with a value that has passed the checks above:

```powershell
pwsh -NoProfile -File .\scripts\quickstart\deploy.ps1 `
  -SubscriptionId '<confirmed-subscription-id>' `
  -Location '<confirmed-location>' `
  -Environment 'foundry-quickstart' `
  -DeploymentId '<stable-deployment-id>' `
  -OperatorPrincipalId '<operator-object-id>' `
  -FunctionAuthClientId '<function-api-app-client-id>' `
  -FunctionAuthAudience 'api://<function-api-app-client-id>' `
  -ChatModelVersion '<validated-version>' `
  -EmbeddingModelVersion '<validated-version>' `
  -WhatIf
```

What-if still reads Azure context and resource-group state and invokes Azure
Resource Manager what-if. It exits before deployment, package upload, corpus
upload, or data-plane writes. Review the complete output. Do not proceed when a
permission, provider, API, model, quota, identity, network, or ownership issue
is unresolved.

## 4. Deploy only after authorization

After what-if review and separate deployment authorization, run the same command
without `-WhatIf`:

```powershell
pwsh -NoProfile -File .\scripts\quickstart\deploy.ps1 `
  -SubscriptionId '<confirmed-subscription-id>' `
  -Location '<confirmed-location>' `
  -Environment 'foundry-quickstart' `
  -DeploymentId '<stable-deployment-id>' `
  -OperatorPrincipalId '<operator-object-id>' `
  -FunctionAuthClientId '<function-api-app-client-id>' `
  -FunctionAuthAudience 'api://<function-api-app-client-id>' `
  -ChatModelVersion '<validated-version>' `
  -EmbeddingModelVersion '<validated-version>'
```

Optional Search SKU, chat model name, capacities, and tags may be supplied only
through the implemented parameters above. Never use `-NonInteractive` as an
authorization bypass.

The wrapper:

1. validates repository paths, the active subscription, and resource-group
   ownership state;
2. runs subscription-scope ARM what-if;
3. invokes Bicep and saves the emitted non-secret schema `3.1.0` contract;
4. sends four allowlisted custom-skill files to a short-lived Linux ACI job,
   installs `requirements.txt` into `.python_packages/lib/site-packages`, validates
   trigger discovery, builds and privately archives the Function ZIP, and deletes
   the job; it then uses Entra-authenticated ZIP deployment to extract the same
   reviewed source allowlist into the Function app before restart and trigger sync;
5. uploads only `*.md` from `sample-data/documents/` with Entra authentication;
6. applies the six ordered Bicep-authored data-plane operations;
7. runs contract-based verification.

Any failed phase returns nonzero. The wrapper does not report partial failure as
success or automatically delete the resource group. Inspect the failure and
rerun the exact same contract only when safe, or use guarded cleanup.

A resource group with no matching local and canonical contract is never
adopted. A local contract whose resource group is absent is stale and blocks
reuse of that deployment ID until the operator deliberately archives or removes
that one ignored file.

## 5. Verify

Verify from the saved local contract:

```powershell
pwsh -NoProfile -File .\scripts\quickstart\verify.ps1 `
  -ContractPath '.\.azure\quickstart-contract-<deployment-id>.json'
```

Or verify from the subscription deployment:

```powershell
pwsh -NoProfile -File .\scripts\quickstart\verify.ps1 `
  -SubscriptionId '<confirmed-subscription-id>' `
  -DeploymentName 'quickstart-<deployment-id>'
```

`ContractPath` is one parameter set. `SubscriptionId` and `DeploymentName`
together are the alternate set; do not mix them.

Verification is read-only and does not repair drift. It checks:

- resource-group ownership, provenance, and cleanup-protection evidence;
- Search, Foundry account/project, shared storage, Function, Log Analytics, and
  Application Insights existence and location;
- Storage public-network denial, four approved private endpoints and DNS zones,
  Search shared-private-link approval, and Function VNet integration;
- managed identity, local-auth, shared-key, public-Blob, TLS, and HTTPS settings;
- diagnostic settings and exact RBAC IDs, scopes, principals, types, and roles;
- canonical Bicep-authored data-plane objects after provider fields are removed;
- public, non-sensitive custom-skill health on the sole Easy Auth exclusion;
- indexer terminal success with a bounded poll and at least one document, proving Search managed identity can invoke the protected custom skill;
- retrieval results, citations, and a non-empty source ID for every citation.

The retrieval `POST` is allowed only for the exact Bicep-emitted path and body
shape and is semantically read-only. Any drift, empty retrieval, missing source
identifier, nonterminal indexing, or identity/RBAC mismatch is a failed
verification; do not weaken checks to make the sample pass.

Continue to the [demo walkthrough](./demo/walkthrough.md) only after a separately
authorized deployment and verification succeed.

To use the verified knowledge environment from an agent, follow the separate
[Hosted Foundry deployment guide](../langgraph-agent-hosted-foundry/README.md)
or [Local WSL run guide](../langgraph-agent-local/README.md). Neither agent flow
is part of the infrastructure deployment above.

## Optional: Add SharePoint group-based document trimming

The default quickstart indexes only the repository's synthetic Blob corpus and
does not configure SharePoint permissions. After the default deployment is
verified, both agents can use the optional permission-aware SharePoint path.

Follow [SharePoint group-based document permission trimming](./sharepoint-permission-trimming.md)
to configure groups and document permissions in your own SharePoint site,
enable `groupIds` permission ingestion and Search enforcement, preserve the
calling user through the local and hosted agent paths, and run required
allow/deny tests.

Do not present the optional path as validated by the default Gate A checks. It
requires separate tenant administration, live ingestion, user consent, and
identity-specific verification.

## 6. Clean up

Cleanup is destructive: it permanently deletes the complete quickstart-owned
resource group and everything in it. There is no force bypass, per-resource
target, or detached deletion. Before invocation:

1. identify the exact saved local contract;
2. confirm the subscription ID;
3. read the resource-group name from the bound contract;
4. review the complete deletion scope;
5. obtain immediate explicit operator confirmation.

When an assistant is driving the process, it must ask for confirmation
immediately before running:

```powershell
pwsh -NoProfile -File .\scripts\quickstart\cleanup.ps1 `
  -ContractPath '.\.azure\quickstart-contract-<deployment-id>.json' `
  -SubscriptionId '<confirmed-subscription-id>' `
  -ConfirmResourceGroupName '<exact-owned-resource-group>' `
  -ConfirmDeletion
```

Before deletion, the script validates the local schema `3.1.0` contract,
resolves the canonical deployment output, requires exact contract equality and
case-sensitive resource-group confirmation, and verifies subscription,
resource-group identity, ownership, provenance, and protection tags. It refuses
missing, mismatched, shared, pre-existing, or protected ownership evidence.

Cleanup calls synchronous `az group delete` and returns nonzero on failure. It
does not delete the ignored local contract or subscription deployment record.
Retain the contract as evidence when required. Reusing the deployment ID later
requires deliberately archiving or removing that specific stale local contract.
No cleanup has been run for the current Gate A status.

## Next references

- [Bicep source and offline inspection](./deploy/bicep.md)
- [Architecture](./architecture.md)
- [Azure AI Search and Foundry IQ](./concepts/search-and-foundry-iq.md)
- [Troubleshooting](./operations/troubleshooting.md)
- [Sample data](./sample-data.md)
- [Responsible AI](./responsible-ai.md)
