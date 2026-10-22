# infra

Terraform for the AWS side, on a personal test account (`375355731232`, `ap-southeast-1`).
Every name starts with `ff-poc`.

| Where | Holds | Who changes it |
| --- | --- | --- |
| `.env.example` in `ff-poc-be` / `ff-poc-fe` | the **names** of every key the app reads; `# secret` marks a secret | a PR in that app, with the code |
| Parameter Store `/ff-poc/<stage>/be/<KEY>` | every BE **value**: `String` if public, `SecureString` if secret | an admin, by hand |
| variables of the `staging` / `production` environments in `ff-poc-fe` | all FE values (the browser and the apps expose them, so none is secret) | Settings in ff-poc-fe |

## Two parts

**`bootstrap/`: applied once by a person with admin rights, never by CI.** It makes what CI needs
before it can reach AWS: the GitHub OIDC provider, the `ff-poc-terraform` role, the
`ff-poc-boundary` policy and the `ff-poc-tfstate-<account>` state bucket. Its own state stays on
the machine that applied it (ignored by git).

- `ff-poc-terraform` can be assumed only by a job in this repo's `infra` environment, which needs
  an approval and runs only from `main`.
- It can create roles named `ff-poc-*` only while they carry `ff-poc-boundary`, and can never
  change itself, the boundary, or take a boundary off a role.
- `ff-poc-boundary` caps every such role at: list parameter names, read `/ff-poc/*`, decrypt
  through SSM, push and pull `ff-poc-*` images. Nothing else, whatever policy a role gets.

**`*.tf` here: applied by the Terraform workflow** after a merge to `main` and an approval on
`infra`. Pull requests only run `fmt` and `validate`.

| Made here | Who uses it | Can do |
| --- | --- | --- |
| ECR `ff-poc-be` (keeps 10 images) | | |
| `ff-poc-be-push` | ff-poc-be tag builds | push and retag `ff-poc-be` images |
| `ff-poc-deploy-<stage>` | hub deploy job in that stage's environment | pull the image, list parameter names; reading or decrypting a value is denied |
| `ff-poc-be-runtime-<stage>` | the BE server | read and decrypt `/ff-poc/<stage>/be/*` only, so staging can never read prod |
| S3 `ff-poc-web-<stage>-<account>` + CloudFront (`web.tf`) | the FE web app | private bucket; only that stage's distribution reads it; the stage's deploy role writes it and refreshes the distribution |

The runtime role would be assumed only by ECS tasks in real use. This POC has no ECS, so the hub
deploy job may assume it too and hand its short-lived credentials to the container it runs.

The parameters are not created by Terraform, because Terraform would copy each value into its
state file. Adding a key never needs a Terraform change: the roles cover the whole path.

## Variables set from the outputs (by hand, once)

| Where | Variable | Value |
| --- | --- | --- |
| hub (repo) | `TF_ROLE_ARN`, `TF_STATE_BUCKET`, `AWS_REGION` | bootstrap outputs |
| hub `staging` / `production` | `AWS_ROLE_ARN`, `AWS_RUNTIME_ROLE_ARN` | `deploy_role_arns`, `runtime_role_arns` |
| hub (repo), ff-poc-be (repo) | `ECR_REPOSITORY_URL` | `be_repository_url` |
| ff-poc-be (repo) | `AWS_PUSH_ROLE_ARN`, `AWS_REGION` | `be_push_role_arn` |

## Setting a value

From an admin's own machine:

```bash
aws ssm put-parameter --type String       --name /ff-poc/prod/be/LOG_LEVEL   --value info
aws ssm put-parameter --type SecureString --name /ff-poc/prod/be/DB_PASSWORD --value '...'
```

Adding a key: add it to the app's `.env.example` in the same PR as the code (with `# secret` if it
is one), then give it a value in each stage (Parameter Store for the BE, the ff-poc-fe environment
variables for the FE). The deploy of a release whose `.env.example` has the key stops and names it
until the stage it deploys to has a value.
