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

`be/` and `fe/` are submodules: the hub pins the exact commit of each app that a release ships. The FE repo holds the web app and the Capacitor mobile app.

## Release in one screen (all from this repo)

1. Merge PRs into `main` of `ff-poc-be` / `ff-poc-fe`.
2. Nothing to do: when CI passes on an app's `main`, its **Notify hub** workflow asks this repo to pin that commit, and **Bump submodule pins** commits the new pin to `main` here (about a minute). Run Bump by hand only to catch up.
3. **Releases → Draft a new release** here, tag `staging/v1.0.0-rc.1` on `main`, Publish. The hub tags the pinned commit in each app repo, each app builds once (web, image, Android, iOS), and staging deploys. The apps go to the test channels (simulated).
   If a pin is behind its app's `main` (a merge still in CI), the release stops and says which commits are missing; that rc number is used up, so release the next one. To ship older code on purpose, put `[skip-bump-check]` in the release notes.
4. A fix during testing: merge it in the app repo, wait for the pin, then release `staging/v1.0.0-rc.2`. An app whose commit did not change reuses its rc.1 build.
5. Staging passes: release `prod/v1.0.0` **on the same hub commit as the rc that passed** (Target: pick that rc's tag or commit). Each app reuses that rc's build; approve the `production` deployment here and the `app-store` step in `ff-poc-fe` (simulated).
6. Rollback: revert the last commit in `prod/versions.yaml` and approve the deploy.
