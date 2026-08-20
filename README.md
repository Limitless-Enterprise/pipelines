# Limitless Enterprise Pipelines

Central repository for reusable Limitless Enterprise GitHub Actions automation.

Current contents:

- reusable source app quality and PR-preview pointer workflows under `.github/workflows/`;
- generic PR-preview source-pointer helpers under `scripts/source-preview/`;
- reusable `railway-deployments` workflow contracts for provider orchestration wrappers;
- detailed PR-preview pipeline documentation in [`docs/pr-preview-pipelines.md`](docs/pr-preview-pipelines.md), including Mermaid diagrams for each source and deployment workflow plus an end-to-end authority-boundary diagram.

This repository must not contain application source code, Railway service roots, real infrastructure programs, secrets, provider credentials, or environment-specific secret values.
