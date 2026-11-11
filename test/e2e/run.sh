#!/usr/bin/env bash
# policy e2e tests on k3d: compliant objects are admitted, violating Pods are refused, and
# violating controllers are admitted with a warning. Checks are server-side dry-runs.
#
# Usage: test/e2e/run.sh [scenario...]
#   Normally run through `make e2e`, which installs the pinned tools and sets the variables
#   below.
#
# Environment:
#   K3D, KUBECTL, HELM    tool binaries (default: from PATH)
#   K3S_IMAGE             pinned k3s image (set by the Makefile)
#   E2E_CLUSTER           cluster name (default policy-e2e)
#   E2E_KEEP=1            keep the cluster afterwards (and stop at the first failing scenario)
#   E2E_REUSE=1           use an existing cluster of that name (skips setup)
set -euo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ROOT=$(cd "$HERE/../.." && pwd)
CLUSTER=${E2E_CLUSTER:-policy-e2e}
K3D=${K3D:-k3d}
KUBECTL=${KUBECTL:-kubectl}
HELM=${HELM:-helm}
: "${K3S_IMAGE:?set K3S_IMAGE (make e2e sets it)}"
export HERE ROOT CLUSTER K3D KUBECTL HELM

# shellcheck source=test/e2e/lib.sh
source "$HERE/lib.sh"

teardown() {
  if [[ ${E2E_KEEP:-0} == 1 ]]; then
    log "keeping cluster ${CLUSTER} (E2E_KEEP=1); delete it with: $K3D cluster delete ${CLUSTER}"
  else
    delete_cluster
  fi
}
trap teardown EXIT

if [[ ${E2E_REUSE:-0} == 1 ]]; then
  log "reusing cluster ${CLUSTER}"
  "$K3D" kubeconfig merge "$CLUSTER" --kubeconfig-switch-context >/dev/null
else
  delete_cluster
  create_cluster
fi

scenarios=("$@")
if [[ ${#scenarios[@]} -eq 0 ]]; then
  scenarios=(smoke catalog settings)                  # every scenario, in order
fi
for s in "${scenarios[@]}"; do
  run_scenario "$s"
  if [[ -n $KEPT_SCENARIO ]]; then break; fi
done

summary
