# Contributing

Thank you for helping improve this public sample.

## Before opening a change

- Use an issue for a reproducible bug, documentation gap, or focused feature
  proposal.
- Keep the public quickstart synthetic, customer-neutral, and disposable.
- Do not include secrets, tokens, tenant identifiers, subscription IDs,
  resource IDs, personal paths, service captures, or real customer data.
- Do not add a second deployment path or move infrastructure desired state out
  of Bicep. Keep the supported journey in
  [`docs/quickstart.md`](./docs/quickstart.md) and invoke infrastructure only
  through [`scripts/quickstart/deploy.ps1`](./scripts/quickstart/deploy.ps1).
- Keep public corpus files under [`sample-data/`](./sample-data/) and shared
  storage infrastructure in [`infra/storage.bicep`](./infra/storage.bicep).
- Do not weaken ownership, identity, verification, or cleanup guards.

## Pull requests

1. Create a focused branch and keep changes scoped to one concern.
2. Follow existing formatting and terminology.
3. Update documentation and tests when behavior changes.
4. Run the smallest relevant offline tests and `git diff --check`.
5. Describe validation honestly. Never claim an Azure deployment, cost result,
   or production readiness that was not demonstrated.
6. Complete the pull request template.

Contributions must not run or request deployment against another person's
subscription. Maintainers may require design review for changes to identity,
authorization, networking, Bicep ownership, preview APIs, or destructive
operations.

## Offline public CI

With PowerShell 7.4 or later, Python, Azure CLI, and Bicep CLI `0.47.16`
already available, restore the declared local-agent dependencies and run
the same credential-free, non-deploying checks as public CI:

```powershell
pwsh -NoProfile -File .\scripts\ci\Test-DependencyManifest.ps1 -SelfTest
pwsh -NoProfile -File .\scripts\ci\Test-DependencyManifest.ps1 -ManifestPath .\langgraph-agent-local\requirements.txt
python -m pip install --disable-pip-version-check --requirement .\langgraph-agent-local\requirements.txt
pwsh -NoProfile -File .\scripts\ci\Invoke-PublicCI.ps1
```

The command compiles the public and synthetic-tenant Bicep sources and parameter
files to temporary output, parses public PowerShell files, runs every focused
offline contract and parity suite, runs all 21 local-agent tests and the
custom-skill `unittest` suite, and checks repository hygiene. It does not
authenticate to Azure, run what-if, or deploy resources.

Do not commit generated Bicep or ARM output, local parameter files, deployment
captures, logs, caches, or packaged artifacts. The local-agent manifest pins
direct dependencies to versions already declared by the paired hosted-agent
sample where repository evidence exists. `azure-search-documents` remains
explicitly bounded to the required 12.x line because this repository has no
evidence for one exact compatible 12.x version. Transitive dependencies remain
an acknowledged reproducibility residual until a lock with real package-index
hashes can be generated; do not invent versions or hashes for it.

By contributing, you agree that your contribution is licensed under the
[MIT License](./LICENSE) and that you will follow the
[Code of Conduct](./CODE_OF_CONDUCT.md).
