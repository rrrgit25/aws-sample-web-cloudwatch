#!/usr/bin/env bash
# Trigger the CloudWatch alarms on purpose.
#
# Usage: scripts/test_alarms.sh <errors|crash|down|disk|notify>
#   errors  - 20 simulated app errors          -> app-error-logs
#   crash   - kill one container               -> app-container-restarts
#   down    - scale the app to 0 for 5 min     -> app-health-failed
#   disk    - fill the root disk to ~85 %      -> disk-high   (file removed after 10 min)
#   notify  - force the CPU alarm into ALARM   -> checks e-mail delivery only
#
# errors and crash need the chaos endpoints:
#   scripts/deploy.sh "" --set env.ENABLE_CHAOS_ENDPOINTS=true
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TF_DIR="${ROOT_DIR}/terraform"
RELEASE="${RELEASE:-sample-web}"
NAMESPACE="${NAMESPACE:-sample-web}"
SSH_KEY="${SSH_KEY:-$HOME/.ssh/id_ed25519}"
export KUBECONFIG="${ROOT_DIR}/.kube/config"

IP="$(terraform -chdir="${TF_DIR}" output -raw public_ip)"
REGION="$(terraform -chdir="${TF_DIR}" output -raw aws_region)"
PREFIX="$(terraform -chdir="${TF_DIR}" output -raw alarm_name_prefix)"
URL="http://${IP}"

case "${1:-}" in
  errors)
    echo ">> Sending 20 simulated errors to ${URL}"
    for _ in $(seq 1 20); do curl -s -o /dev/null -w "%{http_code} " -X POST "${URL}/chaos/error"; done
    echo
    ;;
  crash)
    echo ">> Crashing one container"
    curl -s -X POST "${URL}/chaos/crash"; echo
    ;;
  down)
    echo ">> Scaling ${RELEASE} to 0 replicas for 5 minutes"
    kubectl -n "${NAMESPACE}" scale deployment "${RELEASE}" --replicas=0
    sleep 300
    echo ">> Restoring 2 replicas"
    kubectl -n "${NAMESPACE}" scale deployment "${RELEASE}" --replicas=2
    ;;
  disk)
    echo ">> Filling the root disk to ~85 % for 10 minutes"
    ssh -i "${SSH_KEY}" "ec2-user@${IP}" '
      set -e
      used=$(df --output=pcent / | tail -1 | tr -dc 0-9)
      size_kb=$(df --output=size / | tail -1)
      need_kb=$(( size_kb * (85 - used) / 100 ))
      [ "$need_kb" -gt 0 ] || { echo "disk already above 85%"; exit 0; }
      sudo fallocate -l "${need_kb}K" /var/tmp/alarm-test.fill
      df -h /
      (sleep 600; sudo rm -f /var/tmp/alarm-test.fill) >/dev/null 2>&1 &
    '
    ;;
  notify)
    aws cloudwatch set-alarm-state --region "${REGION}" --alarm-name "${PREFIX}cpu-high" \
      --state-value ALARM --state-reason "Manual notification test"
    echo ">> ${PREFIX}cpu-high forced to ALARM; it returns to its real state at the next evaluation"
    ;;
  *)
    sed -n '2,13p' "$0"; exit 1 ;;
esac

echo ">> Watch alarm state (allow 5-10 minutes):"
echo "   aws cloudwatch describe-alarms --region ${REGION} --alarm-name-prefix ${PREFIX} --query 'MetricAlarms[].[AlarmName,StateValue]' --output table"
