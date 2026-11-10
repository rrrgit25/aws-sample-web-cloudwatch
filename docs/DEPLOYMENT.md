# Step-by-step deployment guide (AWS free tier)

This guide takes you from an empty AWS account to a running Python web app,
deployed with a **Helm chart** and watched by **CloudWatch alarms** that e-mail
you. All infrastructure is created with **Terraform**, and everything stays
inside the **AWS free tier**.

```
 Developer ──docker push──────────────────────────▶ ECR (private repo)
     │                                                   │ image pull
     ├─terraform apply──▶ VPC ─ public subnet ─ EC2 t3.micro + Elastic IP
     │                                   │
     │                                   ├─ k3s (single-node Kubernetes)
     │                                   │     └─ sample-web pods ◀── Internet :80
     │                                   ├─ CloudWatch agent ── mem/disk + app logs
     │                                   └─ app-monitor timer ─ health/pods/restarts
     │                                                   │
     │                         CloudWatch ── 9 alarms ──▶ SNS ──▶ e-mail
     │
     └─helm upgrade --install (via k3s API :6443) ──▶ Deployment / Service / PDB
```

## Why k3s on EC2 and not EKS?

Helm deploys to Kubernetes, but **Amazon EKS is never free** (≈ US$73/month for
the control plane alone), and the NAT gateway and load balancer an EKS setup
usually needs aren't free either. This project runs **k3s**, a lightweight,
CNCF-certified Kubernetes distribution, on one free-tier EC2 instance. The Helm
chart is standard and also works on EKS later.

## Free-tier budget used by this project

| Service | What this project uses | Free tier allowance |
|---|---|---|
| EC2 | 1 × `t3.micro`, standard CPU credits | 750 h/month of an eligible type |
| EBS | 20 GB gp3 root volume | 30 GB |
| Public IPv4 | 1 Elastic IP (attached) | 750 h/month |
| ECR | 1 private repo, ≤ 3 images (~60 MB each) | 500 MB/month |
| CloudWatch alarms | 9 standard-resolution | 10 |
| CloudWatch custom metrics | 6 | 10 |
| CloudWatch dashboards | 1 | 3 |
| CloudWatch Logs | app logs, 7-day retention (~100–200 MB/month) | 5 GB ingest + storage |
| EC2 basic monitoring | CPU, credits, status checks | always free |
| SNS | e-mail notifications | 1,000 e-mails/month |
| AWS Budgets | 1 budget | 2 budgets |
| VPC, subnet, IGW, security group, IAM | — | no charge |

Deliberately **not** used because they cost money: EKS, NAT gateway, Elastic
Load Balancer, detailed monitoring, Container Insights, composite alarms,
Route 53 health checks, CloudWatch Synthetics.

> **Read before you start**
> * Free-tier terms depend on your account. Accounts created **before 15 July
>   2025** have the 12-month free tier. Newer accounts are on the **Free plan**,
>   where usage is paid from free credits. Either way, check which instance types
>   are free for you (step 5) and keep an eye on **Billing → Free Tier**.
> * The allowances are **per account**. If you already run other instances or
>   alarms, they share the same 750 hours / 10 alarms.
> * A **US$1 budget** is created that e-mails you as soon as spend passes US$0.01.
> * **Destroy rather than stop** the instance when you're done. A stopped
>   instance still keeps its EBS volume and Elastic IP.

Time needed: about 20 minutes.

---

## Step 1 — Install the tools

| Tool       | Version | macOS install |
|------------|---------|---------------|
| AWS CLI    | v2      | `brew install awscli` |
| Terraform  | ≥ 1.5   | `brew install terraform` |
| kubectl    | ≥ 1.30  | `brew install kubectl` |
| Helm       | ≥ 3.12  | `brew install helm` |
| Docker     | any     | Docker Desktop, or `brew install colima docker && colima start` |
| Python     | ≥ 3.11  | `brew install python` (only to run tests locally) |

```bash
aws --version && terraform -version && kubectl version --client && helm version && docker version
```

## Step 2 — Configure AWS credentials

Use an IAM identity that can manage EC2, VPC, IAM, ECR, CloudWatch, Logs, SNS
and Budgets (`AdministratorAccess` is simplest for a personal sandbox).

```bash
aws configure            # or: aws configure sso / export AWS_PROFILE=...
aws sts get-caller-identity
```

## Step 3 — Create an SSH key (if you don't have one)

```bash
ls ~/.ssh/id_ed25519.pub || ssh-keygen -t ed25519 -f ~/.ssh/id_ed25519 -N ""
```

Terraform installs the public key on the instance. The scripts use the private
key to fetch the Kubernetes config. To use a different key, set
`ssh_public_key_path` in step 5 and `export SSH_KEY=<private key path>`.

## Step 4 — Run the app locally (optional)

```bash
cd app
python3 -m venv .venv && source .venv/bin/activate
pip install -r requirements-dev.txt
pytest                                    # 8 tests should pass
ENABLE_CHAOS_ENDPOINTS=true python -m src.app
# in another terminal:
curl localhost:8080/api/info
curl -X POST localhost:8080/api/items -H 'Content-Type: application/json' -d '{"name":"widget"}'
deactivate && cd ..
```

## Step 5 — Configure Terraform variables

```bash
cd terraform
cp terraform.tfvars.example terraform.tfvars
```

1. Find the instance types that are free for **your** account and region:

   ```bash
   aws ec2 describe-instance-types --filters Name=free-tier-eligible,Values=true \
     --query 'InstanceTypes[].InstanceType' --output text
   ```

   Pick an **x86_64** micro/small type from that list (usually `t3.micro`, or
   `t2.micro` on some older accounts) and set `instance_type`.

2. Set `admin_cidrs` to your own IP (`curl -s https://checkip.amazonaws.com`),
   e.g. `["203.0.113.10/32"]`. Only this IP can use SSH and the Kubernetes API.
3. Set `alarm_email_endpoints` to the e-mail address(es) for alarms and budget
   alerts.
4. Leave `app_name` / `app_namespace` as `sample-web` unless you also change
   `RELEASE` / `NAMESPACE` for the scripts.

## Step 6 — Create the infrastructure

```bash
terraform init
terraform plan -out tfplan       # review: no EKS, NAT gateway or load balancer
terraform apply tfplan           # ~2 minutes
terraform output
cd ..
```

| File | Resources |
|---|---|
| `network.tf`  | VPC, one public subnet, internet gateway, route table, security group (80 public; 22 + 6443 from `admin_cidrs` only) |
| `iam.tf`      | Instance role: CloudWatch agent, ECR read-only, SSM Session Manager |
| `ec2.tf`      | SSH key pair, Elastic IP, `t3.micro` (standard credits, IMDSv2, encrypted gp3) |
| `templates/user_data.sh.tftpl` | First-boot script: swap, **k3s**, CloudWatch agent, ECR pull-secret timer, app-monitor timer |
| `ecr.tf`      | ECR repository, keeps the newest 3 images |
| `cloudwatch.tf` | SNS topic + e-mail subscriptions, log group, metric filter, **9 alarms**, dashboard |
| `budget.tf`   | US$1 monthly cost budget with e-mail alerts |

**Confirm the SNS subscription.** Each address gets an "AWS Notification –
Subscription Confirmation" e-mail. Click the link, or no alarm e-mails will
arrive.

## Step 7 — Get cluster access

The instance installs k3s on first boot (3–5 minutes). This script waits for
it, then saves a kubeconfig to `./.kube/config`:

```bash
./scripts/get_kubeconfig.sh
export KUBECONFIG=$PWD/.kube/config
kubectl get nodes            # 1 node, Ready
```

## Step 8 — Build and push the Docker image

```bash
./scripts/build_and_push.sh            # tag = timestamp, or pass e.g. v1.0.0
```

This logs Docker into ECR, builds for `linux/amd64` (also from Apple Silicon),
pushes the image and records the tag in `.last_image_tag`.

## Step 9 — Deploy with Helm

```bash
./scripts/deploy.sh
```

<details><summary>What it runs</summary>

```bash
helm upgrade --install sample-web helm/sample-web \
  --namespace sample-web --create-namespace \
  --set image.repository=$(terraform -chdir=terraform output -raw ecr_repository_url) \
  --set image.tag=<tag> \
  --set fullnameOverride=sample-web \
  --wait
```
</details>

The chart creates:
* a Deployment with 2 replicas, rolling updates, liveness/readiness probes,
  a non-root user and a read-only root filesystem
* a ConfigMap and a ServiceAccount
* a Service of type `LoadBalancer`. k3s's built-in ServiceLB serves it on the
  instance's port 80, so no AWS load balancer is created.
* a PodDisruptionBudget

The image is pulled using the `ecr-pull` secret, which the server refreshes
every 6 hours. The HPA and Ingress templates are included but disabled for the
single node. Configure the chart in `helm/sample-web/values.yaml` or with
`--set`.

## Step 10 — Verify the deployment

```bash
URL=$(terraform -chdir=terraform output -raw app_url)
curl ${URL}health/ready
curl ${URL}api/info
curl -X POST ${URL}api/items -H 'Content-Type: application/json' -d '{"name":"hello"}'
curl ${URL}api/items
open $URL                                     # landing page in the browser
kubectl -n sample-web get pods,svc
kubectl -n sample-web logs -l app.kubernetes.io/instance=sample-web --tail=20
```

The same logs reach CloudWatch Logs in the `/sample-web/dev/app` log group.

## Step 11 — CloudWatch alarms

Open the dashboard: `terraform -chdir=terraform output -raw cloudwatch_dashboard_url`

| Alarm (`sample-web-dev-…`) | Metric (source) | Fires when | Automatic action |
|---|---|---|---|
| `app-health-failed` | `HealthCheck` (app monitor curls `/health/ready` on port 80 every minute) | 2 failures in 3 min, or no data | e-mail |
| `app-container-restarts` | `ContainerRestarts` (app monitor) | any restart in 5 min | e-mail |
| `app-error-logs` | `ApplicationErrorCount` (log metric filter `?ERROR ?CRITICAL`) | > 5 in 5 min | e-mail |
| `cpu-high` | `AWS/EC2 CPUUtilization` | > 80 % for 10 min | e-mail |
| `cpu-credits-low` | `AWS/EC2 CPUCreditBalance` | < 20 credits for 15 min | e-mail |
| `memory-high` | `CWAgent mem_used_percent` | > 90 % for 4 of 5 min | e-mail |
| `disk-high` | `CWAgent disk_used_percent` (`/`) | > 80 % | e-mail |
| `status-check-system` | `AWS/EC2 StatusCheckFailed_System` | 2 min | e-mail + **auto-recover** to new hardware |
| `status-check-instance` | `AWS/EC2 StatusCheckFailed_Instance` | 3 min | e-mail + **auto-reboot** |

Every alarm sends both ALARM and OK notifications. Thresholds are variables in
`terraform/variables.tf`. The project uses 9 alarms, which leaves 1 of the 10
free alarms for anything else in your account.

> `app-health-failed` is in ALARM between `terraform apply` and the first
> successful Helm deploy. That's expected, and it turns OK within ~3 minutes of
> step 9.

### Test the alarms

```bash
./scripts/deploy.sh "" --set env.ENABLE_CHAOS_ENDPOINTS=true   # enable chaos endpoints

./scripts/test_alarms.sh errors    # → app-error-logs
./scripts/test_alarms.sh crash     # → app-container-restarts
./scripts/test_alarms.sh down      # → app-health-failed (scales to 0 for 5 min)
./scripts/test_alarms.sh disk      # → disk-high (temporary file, removed after 10 min)
./scripts/test_alarms.sh notify    # forces cpu-high to ALARM to test e-mail delivery

aws cloudwatch describe-alarms --alarm-name-prefix sample-web-dev- \
  --query 'MetricAlarms[].[AlarmName,StateValue]' --output table

./scripts/deploy.sh                                             # chaos off again
```

The CPU alarm is tested with `notify` rather than a real CPU burn. With
standard credits, a long burn drains the credit balance and the instance is
throttled, which is free but makes the server sluggish.

## Step 12 — Tear everything down

```bash
./scripts/destroy.sh
```

This runs `terraform destroy`, which removes the instance, Elastic IP, VPC, ECR
repository and images, alarms, dashboard, log group, SNS topic and budget.
Afterwards, check **Billing → Free Tier** and **EC2 → Elastic IPs** to confirm
nothing is left behind.

---

## Day-2 operations

**Release a new version**
```bash
./scripts/build_and_push.sh v1.1.0 && ./scripts/deploy.sh v1.1.0
```

**Roll back**
```bash
helm history sample-web -n sample-web
helm rollback sample-web <REVISION> -n sample-web
```

**Shell on the server**: `ssh ec2-user@$(terraform -chdir=terraform output -raw public_ip)`
(or, without SSH, `aws ssm start-session --target <instance_id>` with the
Session Manager plugin installed).

**Change an alarm threshold**: edit `terraform.tfvars` (e.g.
`memory_threshold_percent = 85`) and run `terraform apply`. Alarm-only changes
don't touch the instance.

> Changing anything that feeds the user-data script (region, app name, k3s
> channel, swap size) **replaces the instance**. Re-run steps 7 and 9 afterwards.

## Troubleshooting

| Symptom | Fix |
|---|---|
| `get_kubeconfig.sh` hangs at "Waiting for SSH" | Your IP changed or isn't in `admin_cidrs`. Update it and run `terraform apply`. |
| `Bootstrap failed` | `ssh ec2-user@<ip> sudo tail -100 /var/log/user-data.log` |
| Pods in `ImagePullBackOff` | The tag isn't in ECR, the image was built for arm64, or the pull secret is missing. On the server, run `sudo /usr/local/bin/ecr-pull-secret.sh`, then `kubectl -n sample-web rollout restart deploy/sample-web`. |
| Pods `Pending` / `OOMKilled` | The 1 GB instance is full. Lower `replicaCount` to 1, or check `kubectl top pods -A`. |
| `curl` to the app URL times out | `kubectl -n kube-system get pods \| grep svclb` should show a Running pod. Check that the security group allows port 80 from your IP (`app_ingress_cidrs`). |
| Alarms stay `INSUFFICIENT_DATA` | On the server: `systemctl status app-monitor.timer amazon-cloudwatch-agent` and `sudo /usr/local/bin/app-monitor.sh`. |
| `disk-high` stays `INSUFFICIENT_DATA` | Compare the `CWAgent disk_used_percent` dimensions under CloudWatch → Metrics with `path=/`, `fstype=xfs` in `cloudwatch.tf`. |
| Free-tier usage alert e-mail | **Billing → Free Tier** shows which service. The usual cause is a second instance or Elastic IP in the account. |
