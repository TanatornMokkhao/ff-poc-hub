# infra (example, not applied)

Terraform for where the BE settings live in AWS. Nothing here has been applied to any account;
the **Terraform** workflow only checks it (`fmt`, `validate`).

| Where | Holds | Who changes it |
| --- | --- | --- |
| `.env.example` in `ff-poc-be` / `ff-poc-fe` | the **names** of every key the app reads; `# secret` marks a secret | a PR in that app, with the code |
| Parameter Store `/ff-poc/<stage>/be/<KEY>` | every BE **value**: `String` if public, `SecureString` if secret | an admin, by hand |
| `config/fe/<stage>.json` (git) | all FE values (the browser sees them, so none is secret) | a PR |

Until this is applied, the hub's GitHub environments stand in for Parameter Store: `BE_<KEY>`
variables for public values and `BE_<KEY>` secrets for secrets (fake values).

What it creates, per stage (`staging`, `prod`):

- `ff-poc-deploy-<stage>`: assumed by GitHub Actions through OIDC, only from a job in that stage's
  GitHub Environment (production needs an approval). It only lists parameter names, to check the
  release has every key; reading and decrypting are denied, so CI never sees a value.
- `ff-poc-be-runtime-<stage>`: what the BE server runs as. It reads and decrypts its own stage's
  path only, so staging can never read prod.

The parameters are not created by Terraform, because Terraform would copy each value into its
state file. Adding a key never needs a Terraform change: the roles cover the whole path.

## Using it on a real account

```bash
cd infra
terraform init        # after setting the S3 backend in versions.tf
terraform apply
```

Then put each `deploy_role_arns` output in its GitHub Environment as the variable `AWS_ROLE_ARN`
(the ones there now are mocks on account `000000000000`). Repo variables `AWS_REGION`,
`TF_STATE_BUCKET` and `TF_ROLE_ARN` are mocks too.

An admin sets each value once per stage, from their own machine:

```bash
aws ssm put-parameter --type String       --name /ff-poc/prod/be/LOG_LEVEL   --value info
aws ssm put-parameter --type SecureString --name /ff-poc/prod/be/DB_PASSWORD --value '...'
```

Adding a key: add it to the app's `.env.example` in the same PR as the code (with `# secret` if it
is one), then give it a value in each stage (Parameter Store for the BE, `config/fe/<stage>.json`
for the FE). The deploy of a release whose `.env.example` has the key stops and names it until
the stage it deploys to has a value.
