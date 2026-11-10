#!/usr/bin/env bash
# Wait for the k3s server to finish bootstrapping, then copy its kubeconfig to
# ./.kube/config with the server address set to the instance's Elastic IP.
#
# Usage: scripts/get_kubeconfig.sh
#   SSH_KEY=~/.ssh/other_key scripts/get_kubeconfig.sh   (private key matching ssh_public_key_path)
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TF_DIR="${ROOT_DIR}/terraform"
SSH_KEY="${SSH_KEY:-$HOME/.ssh/id_ed25519}"
IP="$(terraform -chdir="${TF_DIR}" output -raw public_ip)"
SSH_OPTS=(-i "${SSH_KEY}" -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10)

echo ">> Waiting for SSH on ${IP}"
until ssh "${SSH_OPTS[@]}" "ec2-user@${IP}" true 2>/dev/null; do sleep 10; done

echo ">> Waiting for bootstrap (cloud-init) to finish - first boot takes 3-5 minutes"
ssh "${SSH_OPTS[@]}" "ec2-user@${IP}" "sudo cloud-init status --wait" || {
  echo "Bootstrap failed. Inspect with: ssh ec2-user@${IP} sudo tail -100 /var/log/user-data.log" >&2
  exit 1
}

mkdir -p "${ROOT_DIR}/.kube"
ssh "${SSH_OPTS[@]}" "ec2-user@${IP}" "cat /etc/rancher/k3s/k3s.yaml" \
  | sed "s/127\.0\.0\.1/${IP}/" > "${ROOT_DIR}/.kube/config"
chmod 600 "${ROOT_DIR}/.kube/config"

echo ">> Saved ${ROOT_DIR}/.kube/config"
KUBECONFIG="${ROOT_DIR}/.kube/config" kubectl get nodes
echo
echo "Use it with:  export KUBECONFIG=${ROOT_DIR}/.kube/config"
