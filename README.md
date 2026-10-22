# ff-poc-hub

The one place that says what runs where. App repos build and tag; this repo deploys.

| File | Meaning |
| --- | --- |
| `staging/versions.yaml` | What staging runs. App repos commit here when they tag an rc. |
| `prod/versions.yaml` | What production runs. Changes only through a PR. |
| `config/<stage>.json` | Runtime config and flags the FE reads at startup. |
| `scripts/deploy.sh` | Deploys a stage: BE first, then FE. |

Sites: [staging](https://tanatornmokkhao.github.io/ff-poc-hub/staging/) · [prod](https://tanatornmokkhao.github.io/ff-poc-hub/prod/)

The full release strategy is in [docs/RELEASE-STRATEGY.md](docs/RELEASE-STRATEGY.md).

## Release in one screen

1. Merge PRs into `main` of `ff-poc-be` or `ff-poc-fe`.
2. Tag `vX.Y.Z-rc.N` there. CI builds once and commits the version to `staging/versions.yaml`; staging deploys.
3. When the rc passes, tag `vX.Y.Z` on the same commit. CI reuses the rc build and opens a PR here changing `prod/versions.yaml`.
4. Merge the PR, then approve the `production` deployment.
5. Rollback: revert the commit in `prod/versions.yaml` and merge.
