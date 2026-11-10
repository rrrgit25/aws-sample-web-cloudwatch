#!/usr/bin/env bash
# Halyard commands that wire Spinnaker to this project. Run them on the
# Halyard host of an existing Spinnaker install, then `hal deploy apply`.
#
# Before running, provide:
#   K3S_KUBECONFIG     kubeconfig for the k3s cluster (output of scripts/get_kubeconfig.sh).
#                      The Spinnaker host's public IP must be in admin_cidrs (port 6443).
#   GITHUB_TOKEN_FILE  file holding a GitHub token with read access to the repo
#   JENKINS_URL        e.g. https://jenkins.example.com
#   JENKINS_USER / JENKINS_API_TOKEN   Jenkins user + API token that igor polls with
set -euo pipefail

: "${K3S_KUBECONFIG:?set K3S_KUBECONFIG}"
: "${GITHUB_TOKEN_FILE:?set GITHUB_TOKEN_FILE}"
: "${JENKINS_URL:?set JENKINS_URL}"
: "${JENKINS_USER:?set JENKINS_USER}"
: "${JENKINS_API_TOKEN:?set JENKINS_API_TOKEN}"

# 1. Kubernetes account: the k3s cluster on EC2
hal config provider kubernetes enable
hal config provider kubernetes account add k3s-us-east-1 \
  --kubeconfig-file "${K3S_KUBECONFIG}" \
  --context default \
  --namespaces sample-web \
  --only-spinnaker-managed false

# 2. Artifacts: read the Helm chart straight from the GitHub repo
hal config artifact gitrepo enable
hal config artifact gitrepo account add github-sample-web \
  --token-file "${GITHUB_TOKEN_FILE}"

# 3. CI: Jenkins master that triggers the deploy pipeline
hal config ci jenkins enable
echo "${JENKINS_API_TOKEN}" | hal config ci jenkins master add jenkins \
  --address "${JENKINS_URL}" \
  --username "${JENKINS_USER}" \
  --password

hal deploy apply
