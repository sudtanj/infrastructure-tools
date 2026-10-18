# Security Policy

This is a personal infrastructure collection that is public so others can learn from it. It is maintained on a best-effort basis by one person, but security reports are taken seriously and are always welcome.

## Supported versions

There are no releases. Only the current `main` branch is supported, along with the container images that `builder-tools/` publishes to `docker.io/sudtanj/*` from it (`:latest` and the most recent tag).

## Reporting a vulnerability

**Please do not open a public issue, pull request or discussion for a security problem.**

Report it privately through GitHub instead: go to the [Security tab](https://github.com/sudtanj/infrastructure-tools/security), choose **Report a vulnerability**, and fill in the form. Only the maintainer can see the report.

A useful report includes:

- the file, workflow or image affected, with a link to the line if you can
- what an attacker can do, and what access they need first (none, a GitHub account, a fork, …)
- steps to reproduce, or a proof of concept

Never include real credentials in a report. If you found one, say where it is and leave the value out.

### Leaked secrets

If you see a credential in this repository, its history, an Actions log or a published image, please report it the same way as soon as you can. The value will be revoked and rotated first, then the source of the leak fixed.

## What to expect

- Acknowledgement within **7 days**.
- An assessment and a fix, or an explanation of why no fix is planned, as soon as practical after that. Credential leaks and anything exploitable from a fork or pull request come first.
- Credit in the fix commit or the published advisory, if you'd like it.

Confirmed issues are fixed on `main`, and where it helps others, published as a [GitHub security advisory](https://github.com/sudtanj/infrastructure-tools/security/advisories).

## Scope

**In scope**

- GitHub Actions workflows in `.github/workflows/`: secret exposure, script injection from untrusted input (PR titles, branch names, issue text), unsafe `pull_request_target` use, overly broad token permissions, anything that leaks to the public Actions logs
- Scripts in `bash-scripts/` and `.github/scripts/`
- Dockerfiles in `builder-tools/` and the images published from them
- Terraform and cloud-init in `terraform_free_tier_gcp/` and `terraform_free_tier_oci/`
- Defaults in any of the above that would leave someone who reuses this code exposed, such as a service listening publicly without authentication

**Out of scope**

- Vulnerabilities in third-party software these files install or run (n8n, Tailscale, Docker images from other publishers, …). Please report those upstream. A report that the code here pins a known-vulnerable version is still welcome.
- Problems that need write access to this repository or its secrets. Anyone with that access controls what the workflows run, by design.
- Automated scanner output with no demonstrated impact.

## Testing guidelines

Good-faith research that follows these rules is welcome, and the maintainer will not take action against it:

- Test against your own fork and your own accounts and infrastructure.
- Do not attack the maintainer's live machines, tailnet, cloud accounts or services, and do not attempt denial of service.
- Do not open pull requests designed to exploit a workflow in this repository. Describe the issue in a private report instead.
- If you come across a secret or other data that isn't yours, stop, don't use or keep it, and report it.

## How this repository protects itself

For context when assessing a finding:

- Workflows default to a read-only `GITHUB_TOKEN`, and jobs ask only for the permissions they need.
- Workflows that run scripts receive only the secrets those scripts read, named individually rather than via `toJSON(secrets)`.
- Successful script output is kept out of the public Actions logs, and workflow runs are deleted every 30 minutes.
- Secret scanning with push protection, CodeQL code scanning and Dependabot are enabled.
