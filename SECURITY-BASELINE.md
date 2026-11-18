# Security Baseline scan (W-0001)

`.github/workflows/security-scan.yml` is the reusable security workflow for every repository owned by **Limitless-Enterprise**. It runs Trivy (dependencies, IaC/config, container images, CycloneDX SBOM) and TruffleHog (verified secrets, redacted on the runner), and posts one sticky comment on same-repository pull requests.

Repositories call it from `.github/workflows/security.yml`, pinned by commit SHA:

```yaml
jobs:
  security:
    uses: Limitless-Enterprise/pipelines/.github/workflows/security-scan.yml@<commit-sha> # security-vX.Y.Z
    permissions:
      contents: read
      pull-requests: write
```

- The pipeline is event-driven only (pull requests, pushes to the default branch, manual dispatch). It is report-only unless a caller sets `enforce-secrets` / `enforce-vulns`.
- Only repositories owned by Limitless-Enterprise call this copy. Other owners have their own `pipelines` repository.
- Releases are tagged `security-vX.Y.Z`. Tool tarballs (Trivy, TruffleHog, actionlint) are pinned by SHA-256 and every action by commit SHA.
- `security-self-lint.yml` runs actionlint and zizmor on these files on every pull request.

Design and decisions: `Limitless-Enterprise/srs`, `cross-app/W-0001-security-baseline/`.
