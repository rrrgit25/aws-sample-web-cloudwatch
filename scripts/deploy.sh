#!/usr/bin/env bash
# Deploy (install or upgrade) the Helm release onto the k3s cluster.
#
# Usage: scripts/deploy.sh [IMAGE_TAG] [extra helm args...]
#   IMAGE_TAG defaults to the tag written by build_and_push.sh
#
# Example (enable chaos endpoints for alarm testing):
#   scripts/deploy.sh "" --set env.ENABLE_CHAOS_ENDPOINTS=true
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TF_DIR="${ROOT_DIR}/terraform"
CHART_DIR="${ROOT_DIR}/helm/sample-web"

RELEASE="${RELEASE:-sample-web}"      # must equal Terraform var.app_name
NAMESPACE="${NAMESPACE:-sample-web}"  # must equal Terraform var.app_namespace

IMAGE_TAG="${1:-}"
shift || true
if [[ -z "${IMAGE_TAG}" ]]; then
  IMAGE_TAG="$(cat "${ROOT_DIR}/.last_image_tag" 2>/dev/null || true)"
fi
if [[ -z "${IMAGE_TAG}" ]]; then
  echo "No image tag given and no .last_image_tag found. Run scripts/build_and_push.sh first." >&2
  exit 1
fi

export KUBECONFIG="${ROOT_DIR}/.kube/config"
[[ -f "${KUBECONFIG}" ]] || "${ROOT_DIR}/scripts/get_kubeconfig.sh"

REPO_URL="$(terraform -chdir="${TF_DIR}" output -raw ecr_repository_url)"

echo ">> Deploying ${RELEASE} (${REPO_URL}:${IMAGE_TAG}) to namespace ${NAMESPACE}"
helm upgrade --install "${RELEASE}" "${CHART_DIR}" \
  --namespace "${NAMESPACE}" --create-namespace \
  --set image.repository="${REPO_URL}" \
  --set image.tag="${IMAGE_TAG}" \
  --set fullnameOverride="${RELEASE}" \
  --wait --timeout 10m \
  "$@"

kubectl -n "${NAMESPACE}" get pods,svc
echo
echo "App URL: $(terraform -chdir="${TF_DIR}" output -raw app_url)"
