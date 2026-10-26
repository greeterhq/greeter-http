#!/usr/bin/env bash
#
# rollback.sh — roll a greeter-http CloudFormation stack back to its last known
# good state after a failed deploy / failed smoke test.
#
# Strategy, in order of what CloudFormation allows:
#   1. If a stack update is still IN PROGRESS, cancel it — CloudFormation then
#      rolls back to the previous template automatically.
#   2. If the stack is in a *_ROLLBACK_FAILED / UPDATE_ROLLBACK_FAILED state,
#      continue the rollback.
#   3. Otherwise (a completed-but-bad deploy), there is no automatic "undo":
#      redeploy the previous release artifact. This script does NOT guess an
#      artifact; it reports the situation and exits non-zero so the operator /
#      pipeline redeploys the prior version explicitly (see docs/observability.md).
#
# Usage:
#   infra/rollback.sh <stack-name> [region]
#
# Environment: relies on ambient AWS credentials (in CI: the OIDC-assumed role).
#
set -euo pipefail

STACK="${1:?usage: rollback.sh <stack-name> [region]}"
REGION="${2:-${AWS_REGION:-eu-west-2}}"

echo "rollback: stack=${STACK} region=${REGION}"

status="$(aws cloudformation describe-stacks \
  --stack-name "${STACK}" --region "${REGION}" \
  --query 'Stacks[0].StackStatus' --output text 2>/dev/null || echo 'NOT_FOUND')"

echo "rollback: current stack status = ${status}"

case "${status}" in
  UPDATE_IN_PROGRESS|UPDATE_CLEANUP_IN_PROGRESS)
    echo "rollback: cancelling in-flight update (triggers automatic rollback)..."
    aws cloudformation cancel-update-stack --stack-name "${STACK}" --region "${REGION}"
    aws cloudformation wait stack-rollback-complete --stack-name "${STACK}" --region "${REGION}"
    echo "rollback: stack rolled back to the previous good state."
    ;;
  UPDATE_ROLLBACK_FAILED)
    echo "rollback: continuing a failed rollback..."
    aws cloudformation continue-update-rollback --stack-name "${STACK}" --region "${REGION}"
    aws cloudformation wait stack-rollback-complete --stack-name "${STACK}" --region "${REGION}"
    echo "rollback: rollback continued to completion."
    ;;
  UPDATE_COMPLETE|CREATE_COMPLETE)
    # A completed deploy that later failed its smoke check. CloudFormation has
    # no "revert last change set" — the previous good version must be redeployed
    # from its release artifact. Fail loudly so the pipeline/operator does so.
    echo "rollback: stack is ${status} — a completed deploy cannot be auto-reverted." >&2
    echo "rollback: redeploy the previous release artifact (see docs/observability.md 'Rollback')." >&2
    exit 1
    ;;
  NOT_FOUND)
    echo "rollback: stack ${STACK} not found in ${REGION}." >&2
    exit 1
    ;;
  *)
    echo "rollback: stack in state ${status}; no safe automatic action. Inspect manually." >&2
    exit 1
    ;;
esac
