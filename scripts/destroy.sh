#!/usr/bin/env bash
# Tear everything down (EC2 instance, Elastic IP, VPC, ECR repo, alarms,
# dashboard, log group, SNS topic, budget).
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

read -r -p "This destroys every resource in this project. Type 'yes' to continue: " answer
[[ "${answer}" == "yes" ]] || { echo "Aborted."; exit 1; }

terraform -chdir="${ROOT_DIR}/terraform" destroy
rm -f "${ROOT_DIR}/.kube/config" "${ROOT_DIR}/.last_image_tag"
