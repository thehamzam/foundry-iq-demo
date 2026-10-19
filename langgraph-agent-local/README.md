# Run the Local LangGraph agent in WSL

This folder runs the dispute-support LangGraph agent in WSL and calls the Azure
AI Search knowledge base directly. It does not deploy Hosted Agent code and
does not require the Foundry Toolbox at runtime.

## Prerequisites

- WSL 2 with Ubuntu.
- Python 3.12 and Ubuntu's Python 3.12 venv support.
- Azure CLI installed inside WSL. A Windows Azure CLI login is not shared with
  WSL.
- An Azure AI Search knowledge environment already deployed and verified with
  the root [quickstart](../docs/quickstart.md).
- The quickstart contract at
  `.azure/quickstart-contract-<deployment-id>.json`.
- Search and model permissions for the identity you use.

Run `az login` yourself inside WSL before starting the agent. The local agent
uses `DefaultAzureCredential`, which reads the WSL Azure CLI credential cache.

## SharePoint document permission trimming

This agent already sends its Search-scoped caller token in both the MCP
`Authorization` header and `x-ms-query-source-authorization`. When the shared
knowledge base includes a SharePoint source with `groupIds` permission
ingestion and index filtering enabled, Search trims retrieved documents to the
groups of the identity in the selected Azure CLI cache.

Complete the repository's
[SharePoint group-based document permission trimming](../docs/sharepoint-permission-trimming.md)
guide before treating this as an authorization boundary. Persona names are
only credential-cache selectors; the signed-in identity and its actual
SharePoint group access determine results.

## Open the folder

For a repository stored on the Windows C: drive:

```bash
cd /mnt/c/Users/<windows-user>/path/to/<repo-folder>/langgraph-agent-local
```

Portable alternative when you know the Windows repository path:

```bash
REPO_WINDOWS_PATH='C:\path\to\<repo-folder>'
cd "$(wslpath "$REPO_WINDOWS_PATH")/langgraph-agent-local"
```

## Create the Python environment

Confirm `python3 --version` reports Python 3.12, then run:

```bash
python3 -m venv .venv
source .venv/bin/activate
python -m pip install --upgrade pip
python -m pip install -r requirements.txt
```

## Configure the agent

Create the ignored local configuration file:

```bash
cp .env.example .env
```

Never commit `.env`. Replace placeholders only with values from your own
quickstart contract or the deterministic names below.

| Variable | Required for the primary CLI? | Value source |
|---|---:|---|
| `AZURE_SEARCH_ENDPOINT` | Yes | `contract.resources.search.endpoint` |
| `FOUNDRY_KB_PROFILE` | Yes | Use `custom` for the root quickstart |
| `FOUNDRY_CUSTOM_KB_NAME` | Yes when profile is `custom` | Deterministic quickstart name `policy-knowledge-base-v2` |
| `KB_API_VERSION` | Yes | `contract.dataPlane.apiProfile.foundryIq` |
| `AZURE_OPENAI_ENDPOINT` | Yes | `contract.resources.foundry.accountEndpoint` |
| `AZURE_OPENAI_CHAT_DEPLOYMENT` | Yes | `contract.resources.foundry.chatDeploymentName` |
| `AZURE_OPENAI_API_VERSION` | No | Remove the placeholder to use the code default `2024-10-21`, or set a supported version you have validated |
| `FOUNDRY_PROJECT_ENDPOINT` | No for `cli.py` | Optional parity value from `contract.resources.foundry.projectEndpoint` |
| `TOOLBOX_NAME` | No for `cli.py` | Optional parity value; only the Hosted Agent uses the Toolbox |
| `FOUNDRY_BASELINE_KB_NAME` | Only when profile is `baseline` | Name of a separately deployed baseline KB; the root quickstart does not invent one |
| `FOUNDRY_KB_OVERRIDE` | No | Temporary explicit KB name for controlled evaluation |
| `KB_BLOB_HOST` / `KB_PORTAL_BLOB_PREFIX` | No | Optional private-Blob citation rewriting values |

The contract is JSON. From the repository root, inspect only the non-secret
fields listed above in
`.azure/quickstart-contract-<deployment-id>.json`. The Search connection name
and Hosted Toolbox are not required by this local direct-KB path.

### Optional LangSmith tracing

Tracing is off by default:

```dotenv
LANGSMITH_TRACING=false
LANGSMITH_PROJECT=<project-name>
```

To enable it, set `LANGSMITH_TRACING=true`, choose a project name, and place the
API key in the current shell only:

```bash
export LANGSMITH_API_KEY='<set-locally>'
```

Do not put the API key in `.env`. If tracing is enabled without a key,
[`cli.py`](./cli.py) disables tracing and continues.

## Run the agent

One question and exit:

```bash
python cli.py 'What evidence is required for a synthetic duplicate-dispute review?'
```

Interactive conversation:

```bash
python cli.py
```

Type `/quit` or `/exit` to stop.

### Optional local personas

[`cli.py`](./cli.py) supports `--persona admin` and
`--persona frontline`. These modes point Azure CLI at the advanced local-only
directories `/root/.azure-admin` and `/root/.azure-frontline`. Each directory
requires a separate user-driven Azure CLI login for the intended test identity,
and the process running Python must have access to that directory.

Use persona mode only when you deliberately maintain those isolated WSL login
caches:

```bash
python cli.py --persona admin 'Which synthetic documents can this identity retrieve?'
python cli.py --persona frontline 'Which synthetic documents can this identity retrieve?'
```

Do not treat persona names as authorization. Search evaluates the Azure
identity in the selected CLI cache.

## Optional direct knowledge-base diagnostic

[`query-foundry-iq-kb.py`](./query-foundry-iq-kb.py) bypasses LangGraph and the
chat model. It is useful for separating Search/KB problems from agent problems.
Unlike `cli.py`, it does not load `.env`, so export the local file into the
current shell first:

```bash
set -a
source .env
set +a
python query-foundry-iq-kb.py 'What is the synthetic duplicate-intake procedure?'
```

Each diagnostic question is an independent retrieval turn.

## Troubleshooting

- **Azure credential unavailable:** run `az login` inside WSL. A login from
  Windows PowerShell or Command Prompt is in a different credential cache.
- **Missing environment variable:** compare `.env` with
  [`.env.example`](./.env.example). For the selected KB profile, provide the
  matching KB name and remove unresolved placeholder values.
- **Model 404:** confirm `AZURE_OPENAI_ENDPOINT` is the contract's Foundry
  account endpoint and `AZURE_OPENAI_CHAT_DEPLOYMENT` is the contract's chat
  deployment name. Do not substitute the model family name when the deployment
  name differs.
- **Search 403:** confirm the WSL Azure identity has the required Search data
  role and that `AZURE_SEARCH_ENDPOINT` belongs to the same quickstart
  contract. Persona caches need their own role assignments and logins.
- **Tracing stays disabled:** set `LANGSMITH_TRACING=true` and export
  `LANGSMITH_API_KEY` in the same shell before launching the CLI. The CLI
  intentionally disables tracing when the key is absent.

The primary supported local run is `python cli.py`. The convenience
`launch-wsl.sh` script is not part of this guide because the direct foreground
CLI flow is easier to monitor and uses the environment created above.
