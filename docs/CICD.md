# CI/CD with Jules, Jenkins and Spinnaker

This guide connects three tools into one delivery flow for this repository:

| Tool | Role | Config in this repo |
|---|---|---|
| **Jules** (Google's AI coding agent) | Turns GitHub issues into pull requests | `AGENTS.md`, `.github/ISSUE_TEMPLATE/jules-task.md` |
| **Jenkins** | CI: tests, lint, validation, image build; pushes to ECR on `main` | `Jenkinsfile`, `terraform/ci.tf` |
| **Spinnaker** | CD: bakes the Helm chart, approval gate, deploy to k3s, rollback | `spinnaker/` |

```
 GitHub issue ──label "jules"──▶ Jules ──▶ pull request
                                              │  webhook
                                              ▼
                     Jenkins (PR build): pytest · helm lint · terraform validate · docker build
                                              │  ✓ status check → human review → merge
                                              ▼
                     Jenkins (main build): … + push image to ECR + build.properties
                                              │  Jenkins trigger (igor)
                                              ▼
                     Spinnaker deploy-sample-web:
                       Bake Helm chart (from GitHub, image tag from Jenkins)
                         → Manual judgment → Deploy manifest to k3s → Smoke test
                     Spinnaker rollback-sample-web (manual): undo rollout
```

> **Status: configuration only.** These files have been checked locally (JSON
> syntax, Terraform validate, shell syntax). They haven't been run against a
> real Jenkins or Spinnaker server, because hosting those isn't free (see below).

---

## Hosting: what each tool needs

| Tool | Runs where | Rough size | Free tier? |
|---|---|---|---|
| Jules | Google-hosted | — | Jules has its own free usage tier (Google account) |
| Jenkins | Your server or laptop | 1–2 GB RAM, 1 vCPU, 10 GB disk | Not on the existing t3.micro (k3s already uses ~1 GB). Runs fine in Docker on a laptop. |
| Spinnaker | Kubernetes cluster or VM | **≥ 8 GB RAM**, 2–4 vCPU, 20 GB disk | **No.** The smallest free-tier-eligible type that fits is `m7i-flex.large` (8 GB), about $70/month. That's paid from Free-plan credits, and it exceeds the 30 GB EBS allowance alongside the app server. |

Network access each tool needs:
- **GitHub → Jenkins**: HTTPS webhook to `https://<jenkins>/github-webhook/`. Jenkins on a laptop needs a tunnel (e.g. smee.io or ngrok), or switch the multibranch job to periodic scanning.
- **Spinnaker → Jenkins**: igor polls the Jenkins API.
- **Spinnaker → GitHub**: reads the Helm chart (git/repo artifact).
- **Spinnaker → k3s API (port 6443)**: add the Spinnaker host's public IP to `admin_cidrs` in `terraform.tfvars` and run `terraform apply`.

---

## Part 1 — Jules (issue → pull request)

1. Go to <https://jules.google>, sign in with your Google account, and connect
   GitHub. Install the **Jules GitHub app** and grant it access to
   `rrrgit25/aws-sample-web-cloudwatch` only.
2. In Jules, select the repository and open its **environment / setup
   script** settings. Paste:

   ```bash
   python3 -m venv .venv && . .venv/bin/activate
   pip install -r app/requirements-dev.txt
   cd app && pytest -q
   ```

   Jules runs this to prepare its VM and check the project builds.
3. Jules reads **`AGENTS.md`** automatically. It sets the rules: free tier only,
   no secrets, no deploy commands, and which checks to run before a PR.
4. Create the `jules` label once:

   ```bash
   gh label create jules --color 6f42c1 --description "Assign to the Jules coding agent"
   ```

5. To give Jules a task, open an issue with the **"Task for Jules"** template
   (it applies the `jules` label). You can also start a task from the Jules web
   UI. Jules posts a plan, works in its VM and opens a pull request.
6. **Review Jules's PRs like any other.** Jenkins tests them (part 2), and
   nothing deploys until a human merges to `main` *and* approves in Spinnaker.

---

## Part 2 — Jenkins (CI)

### 2.1 Install Jenkins (example: Docker on your laptop, $0)

```bash
docker volume create jenkins_home
docker run -d --name jenkins -p 8080:8080 -p 50000:50000 \
  -v jenkins_home:/var/jenkins_home \
  -v /var/run/docker.sock:/var/run/docker.sock \
  jenkins/jenkins:lts-jdk21
docker exec jenkins cat /var/jenkins_home/secrets/initialAdminPassword
```

Open <http://localhost:8080>, finish the setup wizard, and install the
suggested plugins.

The `Jenkinsfile` runs stages inside Docker containers and needs an agent
labelled **`docker`** with the Docker CLI and AWS CLI v2. On a single-node
setup, give the built-in node the label `docker` and install `docker` + `awscli`
in a custom Jenkins image. Alternatively, attach a separate agent.

### 2.2 Plugins

**Manage Jenkins → Plugins**, install: *Pipeline*, *Docker Pipeline*,
*GitHub Branch Source*, *AWS Credentials*, *Pipeline: AWS Steps* (optional),
*JUnit*, *Timestamper*.

### 2.3 AWS credential for pushing to ECR

1. Enable the least-privilege CI user in Terraform. It can push and pull only
   the `sample-web` repository:

   ```bash
   # terraform/terraform.tfvars
   create_ci_user = true
   ```
   ```bash
   terraform -chdir=terraform apply      # adds 1 IAM user + 1 inline policy; IAM is free
   ```

2. In the IAM console, open user `sample-web-dev-jenkins` → **Security
   credentials → Create access key → Third-party service**. Creating the key by
   hand keeps the secret out of Terraform state.
3. In Jenkins: **Manage Jenkins → Credentials → (global) → Add credentials →
   AWS Credentials**, ID **`aws-ecr-push`**, and paste the key.

### 2.4 Create the multibranch job

1. **New Item → Multibranch Pipeline**, name it **`aws-sample-web-cloudwatch`**.
   The Spinnaker trigger refers to `aws-sample-web-cloudwatch/main`.
2. **Branch Sources → GitHub**, repository
   `https://github.com/rrrgit25/aws-sample-web-cloudwatch`. The repo is public,
   so a credential is optional, but a GitHub token avoids API rate limits and
   lets Jenkins post commit statuses.
3. **Build Configuration**: by Jenkinsfile, path `Jenkinsfile`.
4. Save. Jenkins scans branches and PRs and runs the pipeline.

### 2.5 GitHub webhook

Repo **Settings → Webhooks → Add webhook**: payload URL
`https://<jenkins-host>/github-webhook/`, content type `application/json`,
events *Pushes* and *Pull requests*.

### 2.6 Require CI before merging (recommended)

After the first PR build, protect `main` so Jules's PRs (and everyone's)
can't merge until Jenkins passes:

```bash
gh api -X PUT repos/rrrgit25/aws-sample-web-cloudwatch/branches/main/protection \
  --input - <<'EOF'
{
  "required_status_checks": { "strict": true, "contexts": ["continuous-integration/jenkins/pr-merge"] },
  "enforce_admins": false,
  "required_pull_request_reviews": { "required_approving_review_count": 1 },
  "restrictions": null
}
EOF
```

### What the pipeline does

| Stage | PRs / branches | `main` |
|---|---|---|
| Unit tests (pytest, JUnit report) | ✓ | ✓ |
| Helm lint + template | ✓ | ✓ |
| Terraform fmt + validate | ✓ | ✓ |
| Shell syntax check | ✓ | ✓ |
| Docker build (`linux/amd64`) | ✓ | ✓ |
| Push to ECR as `<commit>-<build>` | — | ✓ |
| Archive `build.properties` (triggers Spinnaker) | — | ✓ |

ECR keeps the newest 3 images (lifecycle policy), so frequent builds stay
inside the 500 MB free tier.

---

## Part 3 — Spinnaker (CD)

### 3.1 Install Spinnaker

Follow the official guide (<https://spinnaker.io/docs/setup/install/>), using
Halyard or the Spinnaker Operator on a Kubernetes cluster with ≥ 8 GB RAM.
**Don't install it on the t3.micro app server.**

### 3.2 Connect it to this project

On the Halyard host, run `spinnaker/halyard-config.sh` with these set:

```bash
export K3S_KUBECONFIG=/path/to/k3s-kubeconfig      # from scripts/get_kubeconfig.sh
export GITHUB_TOKEN_FILE=/path/to/github-token      # read access to the repo
export JENKINS_URL=https://jenkins.example.com
export JENKINS_USER=spinnaker
export JENKINS_API_TOKEN=...                        # Jenkins user → Configure → API token
./spinnaker/halyard-config.sh
```

It creates:

| Spinnaker account | Type | Used by |
|---|---|---|
| `k3s-us-east-1` | Kubernetes provider | Deploy and rollback stages |
| `github-sample-web` | git/repo artifact | Bake stage reads `helm/sample-web` |
| `jenkins` | Jenkins CI master | Pipeline trigger |

### 3.3 Create the application and pipelines

With the `spin` CLI configured against your Gate endpoint:

```bash
spin application save --file spinnaker/application.json
spin pipeline save --file spinnaker/pipeline-deploy.json
spin pipeline save --file spinnaker/pipeline-rollback.json
```

Before saving `pipeline-deploy.json`, replace these placeholders:
- `<ACCOUNT_ID>` in the `imageRepository` default (used for manual runs only)
- `<APP_PUBLIC_IP>` in the smoke test URL (`terraform output -raw public_ip`)

You can also paste each JSON file into **Pipeline → Pipeline actions → Edit as
JSON** in the Deck UI.

### 3.4 What the pipelines do

**`deploy-sample-web`**, triggered by a successful `aws-sample-web-cloudwatch/main` Jenkins build:

1. **Bake (Manifest), HELM3**: renders `helm/sample-web` from GitHub `main`,
   with `image.repository` and `image.tag` taken from Jenkins's
   `build.properties`.
2. **Manual Judgment**: a human approves the deploy. The prompt shows the image
   tag.
3. **Deploy (Manifest)**: applies the rendered manifests to namespace
   `sample-web` on `k3s-us-east-1` and waits until the rollout is stable.
4. **Webhook smoke test**: calls `GET /health/ready` and fails on a 5xx
   response.

You can also start it by hand with the `imageTag` / `imageRepository`
parameters, e.g. to redeploy an older image.

**`rollback-sample-web`**, started by hand: after a confirmation step, it runs
**Undo Rollout (Manifest)** on `deployment sample-web` to go back N revisions
(default 1).

### 3.5 Hand over from `scripts/deploy.sh` to Spinnaker

Until now the app was installed with `helm upgrade --install`. Spinnaker
renders the chart and applies plain manifests, so **pick one deployment method
and stick to it**:

- After the first successful Spinnaker deploy, stop using `scripts/deploy.sh`.
- Optionally remove Helm's release record without touching the running
  resources:

  ```bash
  kubectl -n sample-web delete secret -l owner=helm,name=sample-web
  ```

- Rollback then happens through `rollback-sample-web`, not `helm rollback`.

CloudWatch monitoring is unaffected: the Deployment is still named
`sample-web` in namespace `sample-web`.

---

## End-to-end example

1. Open an issue with the "Task for Jules" template: *"Add a `GET /api/version`
   endpoint returning the app version, with a test."*
2. Jules opens PR `#N`. Jenkins runs the PR build, and the status check turns
   green.
3. Review and merge.
4. Jenkins builds `main`, pushes `sample-web:<sha>-<build>` to ECR and archives
   `build.properties`.
5. Spinnaker's `deploy-sample-web` starts, bakes the chart and waits at
   **Approve deploy**.
6. Approve. Spinnaker deploys, the smoke test passes, and
   `curl http://<ip>/api/version` returns the new endpoint.
7. If something is wrong, run `rollback-sample-web`. The `app-health-failed`
   and `app-container-restarts` CloudWatch alarms e-mail you meanwhile.

## Troubleshooting

| Symptom | Check |
|---|---|
| Jenkins can't find agent `docker` | Give a node the label `docker`, with Docker + AWS CLI installed. |
| `AmazonWebServicesCredentialsBinding` not found | Install the *AWS Credentials* plugin. |
| ECR push `AccessDenied` | Credential ID must be `aws-ecr-push`, the key must belong to `sample-web-dev-jenkins`, and the region must be `us-east-1`. |
| Spinnaker never triggers | Job name must be exactly `aws-sample-web-cloudwatch/main`, the build must archive `build.properties`, and igor needs access to Jenkins. |
| Bake fails: chart not found | The `github-sample-web` gitrepo artifact account must exist, and `helmChartFilePath` must be `helm/sample-web/Chart.yaml`. |
| Deploy times out connecting to k3s | Add the Spinnaker host's public IP to `admin_cidrs` (port 6443). The kubeconfig server must be the Elastic IP. |
| Pods `ImagePullBackOff` after a Spinnaker deploy | The manifests still reference the `ecr-pull` secret, which the server refreshes every 6 h. Check `kubectl -n sample-web get secret ecr-pull`. |
