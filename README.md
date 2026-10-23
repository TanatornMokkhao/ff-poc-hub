# ff-poc-hub

The one place that says what runs where. App repos build and tag; this repo deploys.

## Running now

<!-- status:start -->
| Stage | be | fe | mobile | Last deployed |
| --- | --- | --- | --- | --- |
| staging | `1.0.2-rc.1` (7e5230e) | `1.0.2-rc.1` (810df54) | `1.0.2-rc.1` | 2026-10-23 07:31 UTC ([run](https://github.com/TanatornMokkhao/ff-poc-hub/actions/runs/39918226735)) |
| prod | `1.0.1` (8331f57) | `1.0.1` (f60cc62) | `1.0.1` | - |

_Each row is written by that stage's last successful deploy. mobile is the app build the testers or stores were last given, not what users have installed._
<!-- status:end -->

## What lives where

| File | Meaning |
| --- | --- |
| `staging/versions.yaml` | What staging runs. The Release workflow writes it when an rc is released. |
| `prod/versions.yaml` | What production runs. The Release workflow writes it for a prod release; Rollback production points it back. |
| FE settings | Variables of the `staging` / `production` environments in `ff-poc-fe`. Each rc bakes them into a staging and a prod build of the web and the apps; the hub deploys the stage's web build and adds the versions. |
| BE settings | Never in git or GitHub: AWS Parameter Store `/ff-poc/<stage>/be/<KEY>` (`String`, or `SecureString` for a secret), read by the server at boot. Which keys the BE needs is its own `.env.example`; the deploy checks every one is there, by name only, before it starts. See [infra/README.md](infra/README.md). |
| `infra/` | Terraform for the AWS side (account 375355731232, ap-southeast-1): `bootstrap/` applied once by hand, the rest applied by the Terraform workflow on merge. See [infra/README.md](infra/README.md). |
| `scripts/deploy.sh` | Deploys a stage: BE first, then FE. Before calling it healthy it checks that the image (revision label and `/version`) and the web build (`build-info.json`) hold the pinned commits; ECR tags are immutable. |
| Drift check (Actions, hourly) | Compares each stage's `versions.yaml` with what its live site says (`config.json`, `build-info.json`); fails and notifies on a difference unless a deploy is still running. |

Sites: [staging](https://d3cl8zzlgdpw98.cloudfront.net/) · [prod](https://d2qz35os9uekpn.cloudfront.net/) (S3 + CloudFront; the GitHub Pages copies under `/staging/` and `/prod/` mirror them)

The full release strategy is in [docs/RELEASE-STRATEGY.md](docs/RELEASE-STRATEGY.md).

`be/` and `fe/` are submodules: the hub pins the exact commit of each app that a release ships. The FE repo holds the web app and the Capacitor mobile app.

## Release in one screen (all from this repo)

1. Merge PRs into `main` of `ff-poc-be` / `ff-poc-fe`.
2. Nothing to do: when CI passes on an app's `main`, its **Notify hub** workflow asks this repo to pin that commit, and **Bump submodule pins** commits the new pin to `main` here (about a minute). Run Bump by hand only to catch up.
3. **Releases → Draft a new release** here, tag `staging/v1.0.0-rc.1` on `main`, Publish. The hub tags the pinned commit in each app repo, each app builds once (web, image, Android, iOS), and staging deploys. The apps go to the test channels (simulated).
   If a pin is behind its app's `main` (a merge still in CI), the release stops and says which commits are missing; that rc number is used up, so release the next one. To ship older code on purpose, put `[skip-bump-check]` in the release notes.
4. A fix during testing: merge it in the app repo, wait for the pin, then release `staging/v1.0.0-rc.2`. An app whose commit did not change reuses its rc.1 build.
5. Staging passes: Actions → **Promote to prod** → leave `rc` empty (promotes what staging runs now) or give a number to promote an older rc of the same version (rc.9 when rc.10 broke). It creates `prod/v1.0.0` on that rc's commit; each app reuses that rc's build; approve the `production` deployment here and the `app-store` step in `ff-poc-fe` (simulated).
   Tagging `prod/v1.0.0` by hand also works: it must ship the same be and fe as one of the 1.0.0 rcs, or the release stops and names the app. Release tags can never be moved or deleted, so a failed prod tag uses up that version: go on with the next one.
6. Rollback: Actions → **Rollback production** → leave the version empty (goes to the previous prod release), give a reason, then approve the deploy. No new tag and no rebuild; the mobile app stays as it is. Fix forward with the next patch version. Migrations never run down, so the rollback refuses a version older than any be contract migration's `removes-use-from` (see `MIGRATIONS.md` in ff-poc-be).
7. Hotfix while `main` holds work that cannot ship yet: fix on `main` first (a normal PR, squash is fine), then Actions → **Start hotfix** with the app and that `main` commit. It cherry-picks the commit onto `release/<next patch>` in the app repo, cut from what prod runs, runs the app's tests there, makes hub branch `hotfix/<next patch>` with only that pin moved, and releases its rc. Test staging, then **Promote to prod**. Nothing to merge back: the fix is already on `main`. On a cherry-pick conflict the run stops and says how to pick it by hand (then run again with `picked`). Promote refuses an rc whose app commits are not on `main` (or a cherry-pick of a `main` commit), unless the hotfix gave a `reason`. If `main` can ship, skip all this: merge the fix and release a normal rc.
