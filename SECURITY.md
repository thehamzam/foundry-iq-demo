# Security policy

## Scope

Security fixes target the current `main` branch. This personal sample does not
promise support for old commits, forks, preview APIs, or production deployments.

## Reporting a vulnerability

Do not open a public issue for a suspected vulnerability.

Use GitHub private vulnerability reporting for this repository when it is
available. If it is unavailable, contact the repository owner through a private
channel listed on the owner's GitHub profile. Include:

- the affected file and commit;
- a concise reproduction using synthetic data;
- the security impact;
- any safe mitigation you have tested.

Do not include live credentials, tokens, tenant or subscription identifiers,
personal data, customer data, or destructive proof-of-concept steps. Allow time
for confirmation and remediation before public disclosure.

## Deployment disclaimer

The quickstart uses public HTTPS endpoints with Entra/keyless controls and is not
a production security baseline. The current public quickstart revision has
passed static/offline Gate A only. It has not received Azure subscription
validation, Azure what-if, live deployment, cost measurement, penetration
testing, or production certification.
