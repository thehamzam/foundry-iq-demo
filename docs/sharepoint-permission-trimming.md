# SharePoint group-based document permission trimming

The optional SharePoint path preserves supported SharePoint group permissions
in Azure AI Search and applies them when either agent retrieves from the shared
Foundry IQ knowledge base. The default Blob quickstart does not enable this
path. Treat it as a separate, preview-sensitive extension that requires tenant
administration, SharePoint configuration, and live allow/deny testing.

Microsoft's current guidance is the source of truth:

- [Create an indexed SharePoint knowledge source](https://learn.microsoft.com/azure/search/agentic-knowledge-source-how-to-sharepoint-indexed)
- [Query-time ACL and RBAC enforcement](https://learn.microsoft.com/azure/search/search-query-access-control-rbac-enforcement)
- [Toolbox authentication in Microsoft Foundry](https://learn.microsoft.com/azure/foundry/agents/how-to/tools/tool-authentication)

## What is already wired into both agents

Both agents use the same permission-aware knowledge base, but they preserve the
calling user differently:

| Agent | Caller identity path |
|---|---|
| Local LangGraph agent | Obtains a Search-scoped token from `DefaultAzureCredential` and sends it as both the MCP `Authorization` token and `x-ms-query-source-authorization`. The selected Azure CLI identity is therefore the identity evaluated by Search. |
| Hosted Foundry agent | Uses `AzureAIProjectToolbox` with hosted protocol `2.0.0`. The pinned `langchain-azure-ai` package forwards the request-scoped Foundry call ID, and the Toolbox connection uses `user-entra-token` with the `https://search.azure.com` audience. Foundry resolves the signed-in caller and supplies that user's Search token to the knowledge-base MCP endpoint. |

The shared Search setup also contains all three required enforcement points:

1. the indexed SharePoint knowledge source requests
   `ingestionPermissionOptions = groupIds`;
2. the generated SharePoint index enables `permissionFilterOption`;
3. the generated `GroupIds` field is marked with the `groupIds` permission
   filter.

These paths are built in, but they become effective only after the SharePoint
site, ingestion identity, knowledge source, index, and caller identities are
configured and validated.

## Configure your SharePoint site

### 1. Design groups before assigning document access

Create or reuse Microsoft Entra security groups or Microsoft 365 groups that
represent durable business access, such as `Dispute-Frontline` and
`Dispute-Restricted`. Add test users to each group and keep one test user
outside both groups.

Use group assignments rather than individual-user grants for this repository's
`groupIds` path. Do not use persona labels, prompt text, or application roles as
substitutes for SharePoint permissions.

### 2. Apply the groups to SharePoint content

In the target SharePoint site:

1. open the document library and review its current members, visitors, owners,
   sharing links, and inherited access;
2. grant the intended Entra or Microsoft 365 group the minimum required access
   at the site, library, folder, or document level;
3. break permission inheritance only where a narrower boundary is required;
4. remove broad grants such as organization-wide visitors when they would make
   restricted documents visible;
5. confirm access in SharePoint itself with both an allowed and a denied test
   user before indexing.

Search trims to the permissions it ingests. It cannot make an overly broad
SharePoint ACL restrictive.

### 3. Configure the ingestion application and Search identity

Follow the official indexed SharePoint knowledge-source prerequisites to:

1. create a tenant application for SharePoint ingestion;
2. grant only the documented Microsoft Graph application permissions and obtain
   tenant administrator consent;
3. configure the Azure AI Search managed identity to use a federated credential
   for that application;
4. grant the operator the documented Search roles needed to create knowledge
   sources;
5. grant the Search managed identity `Cognitive Services User` on the Foundry
   resource that hosts the embedding model.

This repository's
[`03d-add-sharepoint-source.ps1`](../scripts/setup/03d-add-sharepoint-source.ps1)
shows the secretless federated-credential pattern. It is environment-specific
reference automation, not part of the default quickstart. Adapt its validated
inputs to your tenant rather than copying local configuration files.

### 4. Create the indexed SharePoint knowledge source

Create an `indexedSharePoint` knowledge source for the target site and library.
Set `ingestionPermissionOptions` to `groupIds`, keep image serving disabled
because it is incompatible with permission ingestion, and attach the source to
the knowledge base used by both agents. Set `includeReferenceSourceData` to
`true` on the SharePoint knowledge-source reference so citations include the
source document URL.

The repository reference implementation is
[`03d-add-sharepoint-source.ps1`](../scripts/setup/03d-add-sharepoint-source.ps1).
After the initial ingestion completes,
[`07b-enable-trimming.ps1`](../scripts/setup/07b-enable-trimming.ps1) enables
the index-level permission filter and marks `GroupIds` as the group permission
field.

### 5. Preserve the caller identity for each agent

For the local agent, sign in with the user being tested and run the agent under
that Azure CLI credential cache. The local code supplies the required
`x-ms-query-source-authorization` header automatically.

For the hosted agent, create the knowledge-base MCP project connection with:

- authentication type `user-entra-token`;
- audience `https://search.azure.com`;
- a target that is the permission-aware knowledge-base MCP endpoint.

Then put that connection in the Toolbox consumed by the hosted agent. The
repository's
[`04-rewire-toolbox.ps1`](../scripts/maintenance/04-rewire-toolbox.ps1)
enforces this connection shape. Each hosted user also needs permission to
consume the Foundry agent, must be in the same tenant as the Foundry project,
and must complete any required per-user consent.

Do not replace `user-entra-token` with a shared secret or service identity if
you expect per-user trimming. That would change which principal Search
evaluates.

### 6. Reindex and test both allow and deny cases

Run or wait for the SharePoint knowledge-source ingestion, then verify:

1. the generated index contains `GroupIds` values for restricted documents;
2. `permissionFilterOption` is enabled and `GroupIds` is the group permission
   field;
3. an allowed user receives the expected restricted citation through the local
   agent;
4. a denied user cannot retrieve that citation through the local agent;
5. the same allow and deny outcomes hold through the hosted agent.

Test a unique phrase from a restricted synthetic document so a result cannot be
mistaken for a public or duplicate source. Missing user tokens fail closed in
current preview APIs, but that is not a substitute for explicit denial tests.

### 7. Operate the permission lifecycle

Re-run SharePoint ingestion after document ACL changes. Group expansion occurs
at query time, but repeat the two-user tests after membership changes and after
changes to APIs, SDKs, Toolbox connections, or agent protocols. Monitor
indexing failures and authorization errors separately. Never infer successful
trimming from a single allowed-user query.

## Current boundaries

- This path is preview-sensitive and is not covered by the default
  quickstart's Gate A validation.
- It implements group-based trimming through `groupIds`; it does not claim
  repository support for direct individual-user ACL ingestion.
- The SharePoint source, Search service, ingestion application, Foundry project,
  and hosted users must satisfy the same-tenant requirements in the official
  guides; cross-tenant hosted-user token exchange isn't supported.
- SharePoint indexer limitations, supported formats, synchronization behavior,
  and permission support from the official documentation still apply.
- Only synthetic content is approved for this repository's demonstrations.
