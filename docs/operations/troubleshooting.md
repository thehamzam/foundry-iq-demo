# Troubleshooting

The quickstart fails closed. Preserve the exact phase and redacted error text;
do not bypass ownership, contract, identity, or verification checks.

## Deployment and rerun errors

| Symptom | Meaning | Safe action |
|---|---|---|
| `The active Azure subscription does not match SubscriptionId.` | Azure CLI is using a different subscription than the explicit input | Stop, display the active context, and obtain confirmation before changing or retrying it |
| `The deterministic resource group already exists, but no prior local contract proves a supported quickstart rerun.` | The wrapper cannot prove ownership of an existing group | Do not adopt it; choose a new deployment ID or recover the exact original ignored contract |
| `A stale local contract exists without its canonical resource group.` | The local file remains but its group is absent | Deliberately archive or remove only that ignored contract before reusing the deployment ID |
| `Subscription deployment what-if failed.` | ARM could not complete the pre-deployment diff | Resolve the reported permission, provider, parameter, API, or availability issue; do not continue to deployment |
| `NonInteractive deployment is not supported...` | `-NonInteractive` was used for a deployment | Use the reviewed interactive authorization flow; the switch is not a bypass |
| `Bicep deployment failed` | The control-plane deployment failed | Inspect the redacted deployment error and owned resource group; use the same contract for a safe rerun or guarded cleanup |

## Upload and data-plane errors

- **Package build or upload failed:** inspect the short-lived ACI logs for a
  dependency-install, ZIP-build, managed-identity login, or Blob upload error;
  confirm the Bicep role assignments completed, the active context is unchanged,
  and the owned package container exists. Do not build against the operator's
  Python environment or switch to account keys or SAS.
- **Function ZIP extraction failed:** inspect the Entra-authenticated `config-zip`
  result and SCM deployment logs. The supported path extracts files into
  `wwwroot`; it does not mount `WEBSITE_RUN_FROM_PACKAGE` from private Blob.
- **Synthetic corpus upload failed:** confirm the same Entra and storage
  conditions and that the repository corpus path still contains the expected
  Markdown files. The wrapper intentionally excludes JSON evaluation queries.
- **Unexpected HTTP status or exhausted retry:** capture the operation ID and
  redacted correlation ID. Revalidate the pinned API profile, regional preview
  support, identity, propagation state, and payload compatibility. Do not copy
  or patch the Bicep payload in PowerShell.

## Verification failures

| Failure | What to inspect |
|---|---|
| Contract binding or ownership mismatch | Saved contract, canonical subscription deployment output, exact subscription, deployment name, resource-group ID, provenance, and immutable tags |
| Data-plane contract drift | The corresponding Search object versus the Bicep-emitted body; verification intentionally does not repair it |
| Function health is not `ok` | Function ZIP deployment state, the narrow `/api/health` Easy Auth exclusion, the Function identity's Storage Reader plus Blob/Queue/Table data roles, extracted `wwwroot` contents, trigger-sync result, and startup logs |
| Indexer reaches `transientFailure` or `persistentFailure` | Search indexer status and logs, Blob access, custom-skill response, and model access |
| Indexer never reaches success | The last reported state after the bounded poll; investigate rather than extending the check without review |
| Document count is zero | Corpus upload, data source, skillset, index projections, and indexer result |
| Retrieval has no results or citations | Knowledge source/base state, indexed content, model availability, query response shape, and pinned preview API support |
| Citation lacks a source identifier | Retrieval response contract or knowledge-base behavior; treat as failure |

## Preview and regional failures

The Bicep resources and Search data-plane profile include preview APIs. A
compile-time success does not prove live support. If the selected context does
not support an API, model, quota, diagnostic category, or authentication
behavior, block deployment. Do not silently downgrade security or retrieval
semantics.

## Getting help

Remove credentials, tenant identifiers, subscription IDs, resource IDs,
document content, and tokens from diagnostics before sharing them. Follow
[Support](../../SUPPORT.md) for public issue scope and [Security](../../SECURITY.md)
for vulnerabilities.
