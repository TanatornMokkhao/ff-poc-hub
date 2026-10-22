# infra (example, not applied)

Terraform for where the BE settings live in AWS. Nothing here has been applied to any account;
the **Terraform** workflow only checks it (`fmt`, `validate`).

| Where | Holds | Who changes it |
| --- | --- | --- |
| `config/be/<stage>.env` (git) | BE settings that are not secret | a PR, like code |
| `config/be/secrets.list` (git) | the **names** of BE secrets | a PR |
| Parameter Store `/ff-poc/<stage>/be/<NAME>` (`SecureString`) | secret **values** | an admin, by hand |
| `config/fe/<stage>.json` (git) | all FE settings (the browser sees them, so none is secret) | a PR |

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

Adding a secret: add its name to `config/be/secrets.list` in a PR, set its value in each stage,
then merge. The deploy stops and names any secret that is missing.
