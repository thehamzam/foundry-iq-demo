## Summary

Describe the focused change and the user need it addresses.

## Validation

List the exact offline checks run and their results. State clearly if Azure
validation, what-if, deployment, cost measurement, or live verification was not
performed.

## Safety checklist

- [ ] The change uses synthetic data only.
- [ ] No secret, credential, tenant/subscription identifier, personal path, or
      private capture is included.
- [ ] Bicep remains authoritative for infrastructure and data-plane desired
      state.
- [ ] Public deployment still uses the guarded PowerShell wrapper.
- [ ] Identity, ownership, verification, and cleanup guardrails are preserved.
- [ ] Documentation and tests are updated for behavior changes.
- [ ] Preview, cost, security, and production-readiness claims are qualified.
- [ ] `git diff --check` passes.

## Related issue

Link the issue when one exists.
