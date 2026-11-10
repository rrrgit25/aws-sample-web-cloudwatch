#!/usr/bin/env bash
# Build the application image for linux/amd64 and push it to the ECR repository
# created by Terraform.
#
# Usage: scripts/build_and_push.sh [IMAGE_TAG]
#   IMAGE_TAG defaults to a timestamp, e.g. 20261109-153000
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TF_DIR="${ROOT_DIR}/terraform"
IMAGE_TAG="${1:-$(date +%Y%m%d-%H%M%S)}"

REGION="$(terraform -chdir="${TF_DIR}" output -raw aws_region)"
REPO_URL="$(terraform -chdir="${TF_DIR}" output -raw ecr_repository_url)"
REGISTRY="${REPO_URL%%/*}"

echo ">> Logging in to ${REGISTRY}"
aws ecr get-login-password --region "${REGION}" \
  | docker login --username AWS --password-stdin "${REGISTRY}"

echo ">> Building ${REPO_URL}:${IMAGE_TAG} (linux/amd64)"
docker build --platform linux/amd64 -t "${REPO_URL}:${IMAGE_TAG}" "${ROOT_DIR}/app"

echo ">> Pushing"
docker push "${REPO_URL}:${IMAGE_TAG}"

echo "${IMAGE_TAG}" > "${ROOT_DIR}/.last_image_tag"
echo ">> Done. Image: ${REPO_URL}:${IMAGE_TAG}"
