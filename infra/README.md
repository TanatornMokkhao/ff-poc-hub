# infra (example, not applied)

Terraform for where the BE settings live in AWS. Nothing here has been applied to any account;
the **Terraform** workflow only checks it (`fmt`, `validate`).

| Where | Holds | Who changes it |
| --- | --- | --- |
| `.env.example` in `ff-poc-be` / `ff-poc-fe` | the **names** of every key the app reads; `# secret` marks a secret | a PR in that app, with the code |
| `config/be/<stage>.env` (git) | BE values that are not secret | a PR, like code |
| Parameter Store `/ff-poc/<stage>/be/<KEY>` (`SecureString`) | secret **values** | an admin, by hand |
| `config/fe/<stage>.json` (git) | all FE values (the browser sees them, so none is secret) | a PR |

Until this is applied, the hub's GitHub environments hold the BE secrets as `BE_<KEY>` (fake values)
in place of Parameter Store.

What it creates, per stage (`staging`, `prod`):

- `ff-poc-deploy-<stage>`: assumed by GitHub Actions through OIDC, only from a job in that stage's
  GitHub Environment (production needs an approval). It writes the non-secret settings and lists
  names, and is denied any decrypt, so CI never sees a secret.
- `ff-poc-be-runtime-<stage>`: what the BE server runs as. It reads and decrypts its own stage's
  path only, so staging can never read prod.

The secret parameters are not created by Terraform, because Terraform would copy each value into
its state file.

## Using it on a real account

```bash
cd infra
terraform init        # after setting the S3 backend in versions.tf
terraform apply
```

Then put each `deploy_role_arns` output in its GitHub Environment as the variable `AWS_ROLE_ARN`
(the ones there now are mocks on account `000000000000`). Repo variables `AWS_REGION`,
`TF_STATE_BUCKET` and `TF_ROLE_ARN` are mocks too.

An admin sets each secret once per stage, from their own machine:

```bash
aws ssm put-parameter --type SecureString --name /ff-poc/prod/be/DB_PASSWORD --value '...'
```

Adding a key: add it to the app's `.env.example` in the same PR as the code (with `# secret` if it
is one), then give it a value in each stage: `config/<app>/<stage>.*` for a public value,
Parameter Store for a secret. The deploy of a release whose `.env.example` has the key stops and
names it until every stage it deploys to has a value.
