# shellcheck shell=bash
# Smoke test: the chart (examples/minimal.yaml) installs its CRD and policies, and they work.
#
#   apps         gets an empty posture-exceptions after install, as posture renders it
#   bare         never gets one, so its workloads fail closed
#   kube-system  never evaluated
#
# Also, in extra: every policy type-checks cleanly in the API server; the CRD accepts posture's
# documented output and rejects malformed objects; what Helm applied is exactly what
# `helm template` renders (values decide, not the cluster); the CRD survives uninstall.
#
# Every fixture in checks is first dry-run before the chart is installed (all must be
# admitted), then again after it. Exemption cases (exempt workload admitted, no warning) are
# phase 1e.

FIXTURES=test/e2e/fixtures

setup() {
  namespace apps
  namespace bare
}

checks() {
  # An empty posture-exceptions: compliant workloads pass, the policy's own CEL still applies.
  expect admit apps "$FIXTURES/smoke-pod.yaml"
  expect admit apps "$FIXTURES/smoke-deployment.yaml"
  expect deny apps "$FIXTURES/bad-registry-pod.yaml" restrict-image-registries
  expect warn apps "$FIXTURES/bad-registry-deployment.yaml" restrict-image-registries
  # No posture-exceptions: fail closed. The controller is only ever warned.
  expect deny bare "$FIXTURES/smoke-pod.yaml" restrict-image-registries
  expect warn bare "$FIXTURES/smoke-deployment.yaml" restrict-image-registries
  # Excluded.
  expect admit kube-system "$FIXTURES/bad-registry-pod.yaml"
}

install() {
  install_chart minimal.yaml
  quiet "$KUBECTL" apply -n apps -f "$ROOT/$FIXTURES/posture-exceptions-empty.yaml"
  info "empty posture-exceptions applied in apps"
}

extra() {
  local obj f
  for obj in "crd/$CRD" \
    validatingadmissionpolicy/restrict-image-registries \
    validatingadmissionpolicybinding/restrict-image-registries \
    validatingadmissionpolicybinding/restrict-image-registries-controllers; do
    if "$KUBECTL" get "$obj" >/dev/null 2>&1; then
      record PASS "$obj exists"
    else
      record FAIL "$obj exists"
    fi
  done

  check_type_checking

  # The CRD in a real API server: posture's documented output is accepted, malformed objects
  # are rejected (matched on the field that's wrong).
  verify admit apps examples/objects/posture-exceptions.yaml
  verify deny apps "$FIXTURES/crd/invalid/missing-policy.yaml" "policy"
  verify deny apps "$FIXTURES/crd/invalid/unknown-kind.yaml" "policy.kind"
  verify deny apps "$FIXTURES/crd/invalid/empty-matchlabels.yaml" "matchLabels"
  verify deny apps "$FIXTURES/crd/invalid/empty-workloads.yaml" "workloads"
  verify deny apps "$FIXTURES/crd/invalid/bad-expires.yaml" "expires"
  for f in "$ROOT/$FIXTURES"/crd/invalid/*.yaml; do
    [[ " missing-policy unknown-kind empty-matchlabels empty-workloads bad-expires " == *" $(basename "$f" .yaml) "* ]] \
      || record FAIL "test/e2e/fixtures/crd/invalid/$(basename "$f") has no verify line in smoke.sh"
  done

  local applied rendered
  applied=$("$HELM" get manifest "$RELEASE" -n "$RELEASE_NAMESPACE")
  rendered=$("$HELM" template "$RELEASE" "$ROOT/charts/policy" -n "$RELEASE_NAMESPACE" \
    -f "$ROOT/examples/minimal.yaml")
  if [[ $applied == "$rendered" ]]; then
    record PASS "helm get manifest matches helm template"
  else
    record FAIL "helm get manifest matches helm template" \
      "$(diff <(printf '%s\n' "$rendered") <(printf '%s\n' "$applied") || true)"
  fi

  # Last: uninstall, and the CRD (with every namespace's exceptions) stays. Cleanup deletes it.
  quiet "$HELM" uninstall "$RELEASE" -n "$RELEASE_NAMESPACE" --wait
  if "$KUBECTL" get "crd/$CRD" >/dev/null 2>&1 \
    && "$KUBECTL" -n apps get policyexceptions posture-exceptions >/dev/null 2>&1; then
    record PASS "the CRD and posture-exceptions survive helm uninstall (resource-policy: keep)"
  else
    record FAIL "the CRD and posture-exceptions survive helm uninstall (resource-policy: keep)"
  fi
}
