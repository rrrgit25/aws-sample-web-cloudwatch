# Guidance for AI coding agents (Jules and others)

This repository is a sample Python web app deployed to AWS. Read this file
before making changes.

## Project map

| Path | What it is |
|---|---|
| `app/` | Flask + gunicorn app. Code in `app/src/app.py`, tests in `app/tests/` |
| `helm/sample-web/` | Helm chart that deploys the app to Kubernetes (k3s) |
| `terraform/` | AWS infrastructure: VPC, EC2 running k3s, ECR, IAM, CloudWatch alarms |
| `scripts/` | Build, deploy, alarm-test and destroy helpers |
| `Jenkinsfile` | CI pipeline |
| `spinnaker/` | CD pipelines (Spinnaker) |
| `docs/` | Deployment and CI/CD guides |

## Setup and checks

Run all of these before opening a pull request. CI runs the same checks.

```bash
# Python tests
python3 -m venv .venv && . .venv/bin/activate
pip install -r app/requirements-dev.txt
cd app && pytest -q && cd ..

# Helm chart
helm lint helm/sample-web
helm template sample-web helm/sample-web --set fullnameOverride=sample-web > /dev/null

# Terraform (no AWS credentials needed)
terraform -chdir=terraform fmt -check -recursive
terraform -chdir=terraform init -backend=false
terraform -chdir=terraform validate

# Shell scripts
for f in scripts/*.sh; do bash -n "$f"; done
```

## Rules

1. **AWS free tier only.** Don't add EKS, NAT gateways, load balancers, RDS,
   detailed monitoring, Container Insights, composite alarms or any other paid
   service. The project must stay within **10 CloudWatch alarms** (currently 9)
   and **10 custom metrics** (currently 6).
2. **No secrets or account-specific values in the repo.** No AWS account IDs,
   IP addresses, e-mail addresses, access keys or kubeconfigs. Use variables
   and `terraform.tfvars.example` placeholders.
3. **Don't run** `terraform apply`, `terraform destroy`, `helm install/upgrade`
   or the `scripts/*.sh` deploy scripts. Deployment goes through Jenkins and
   Spinnaker only.
4. **Keep names in sync.** The Helm release, the Kubernetes namespace and the
   Terraform variables `app_name` / `app_namespace` are all `sample-web`. The
   on-server monitor and the log collection depend on them.
5. **Add tests** in `app/tests/` for any new endpoint or behaviour change.
6. The app runs on a 1 GB instance: keep memory use small (1 gunicorn worker
   per pod, memory limit 160Mi).
7. Update `docs/` when behaviour, variables or deployment steps change.

## Pull requests

- Use a short imperative title, e.g. "Add /api/version endpoint".
- In the description, say what changed, why, and which checks you ran.
- Keep each PR to one task.
