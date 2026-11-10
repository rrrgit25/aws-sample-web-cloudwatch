# sample-web: Python on AWS (free tier) with Helm and CloudWatch alarms

A complete sample project:
* a Python (Flask + gunicorn) web app, packaged with Docker
* deployed with a **Helm chart** to single-node Kubernetes (**k3s**) on a
  free-tier **EC2** instance
* infrastructure and **CloudWatch alarms** defined in **Terraform**

Everything stays inside the **AWS free tier**: no EKS, NAT gateway, load
balancer or paid CloudWatch features.

**Step-by-step instructions: [docs/DEPLOYMENT.md](docs/DEPLOYMENT.md)**

## Layout

```
.
├── app/                         Python web application
│   ├── src/app.py               Flask app (REST API, health probes, chaos endpoints)
│   ├── tests/                   pytest unit tests
│   ├── Dockerfile               non-root, gunicorn
│   └── requirements*.txt
├── helm/sample-web/             Helm chart (Deployment, Service, PDB, ConfigMap, optional HPA/Ingress)
├── terraform/                   AWS infrastructure (free tier)
│   ├── network.tf               VPC, public subnet, IGW, security group
│   ├── ec2.tf                   t3.micro + Elastic IP
│   ├── templates/user_data.sh.tftpl   k3s, CloudWatch agent, monitors
│   ├── iam.tf                   instance role
│   ├── ecr.tf                   container registry
│   ├── cloudwatch.tf            SNS, 9 alarms, log metric filter, dashboard
│   ├── budget.tf                US$1 cost alert
│   └── terraform.tfvars.example
├── scripts/
│   ├── get_kubeconfig.sh        fetch kubeconfig from the server
│   ├── build_and_push.sh        build image, push to ECR
│   ├── deploy.sh                helm upgrade --install
│   ├── test_alarms.sh           trigger alarms on purpose
│   └── destroy.sh               tear everything down
└── docs/DEPLOYMENT.md           full guide
```

## Quick start

```bash
cd terraform && cp terraform.tfvars.example terraform.tfvars   # set admin_cidrs, e-mail, instance_type
terraform init && terraform apply && cd ..
./scripts/get_kubeconfig.sh
./scripts/build_and_push.sh
./scripts/deploy.sh
```

## API

| Method | Path | Description |
|---|---|---|
| GET | `/` | Landing page |
| GET | `/health/live`, `/health/ready` | Kubernetes probes |
| GET | `/api/info` | Version, pod hostname |
| GET / POST | `/api/items` | List / create items (in-memory) |
| GET / DELETE | `/api/items/<id>` | Get / delete an item |
| POST | `/chaos/cpu?seconds=N`, `/chaos/error`, `/chaos/crash` | Only with `ENABLE_CHAOS_ENDPOINTS=true`, for alarm testing |
