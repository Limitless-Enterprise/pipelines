# PR preview shared pipelines

This repository owns the reusable GitHub Actions contracts and generic helper scripts for Limitless owned-code Railway PR previews.

## Central vs local split

Central `pipelines` owns:

- reusable source-app quality workflow scaffolding and accepted branch-pair classification;
- reusable source preview pointer open/update and close workflow contracts;
- generic source-pointer helper scripts for same-SHA quality gating, OpenBao-backed Railway deploy-bot token minting, deployment-pointer PR upsert/close, and source PR comments;
- reusable `railway-deployments` workflow contracts that call provider-specific scripts from the deployment repository.

Consuming source app repositories still own:

- triggers, concurrency, and local permissions;
- repo-specific quality commands and any repo-specific quality jobs;
- source subdirectory and service identity inputs.

`Limitless-Enterprise/railway-deployments` still owns:

- Railway service roots and source pointer files;
- provider-specific OpenBao, Neon, Convex, Railway redeploy, cleanup, maintenance, context parsing, and evidence scripts;
- deployment-repo documentation for provider behavior and required setup.

## Accepted behavior preserved

- `feature/*` and `fix/*` PRs must target `release/*` to publish previews.
- `hotfix/*` PRs must target `main` to publish previews.
- Draft PRs run quality but do not publish pointers until `ready_for_review` and a green quality run.
- Preview pointer publishing requires a successful `app-pr-quality.yml` run for the current source PR head SHA.
- Source app workflows write only non-secret source pointers and never deploy directly to Railway.
- Railway PR environment creation/deletion remains Railway-native from `railway-deployments` PRs.
- OpenBao PR config uses mount `platform-secrets` and `apps/<railway-project-name>/development/pr/...` key paths.
- Maintenance does not proactively recreate expired or missing Neon/Convex resources.

Consumers currently reference this task branch while the central PR is under review. After the central PR lands, follow-up consumer commits should move `pipelines_ref` and `uses` refs to the reviewed stable ref chosen by maintainers.
