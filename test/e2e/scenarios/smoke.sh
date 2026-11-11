# shellcheck shell=bash
# Smoke test: the chart installs from examples/minimal.yaml and its policies are live.
#
# Until the PolicyExceptions CRD lands (phase 1d) no namespace can have a posture-exceptions
# object, so every workload outside kube-system fails closed:
#   - a compliant Pod in apps is denied (parameterNotFoundAction: Deny);
#   - a compliant Deployment in apps is admitted with a warning (its binding only warns);
#   - a Pod from an unlisted registry in kube-system is admitted (kube-system is excluded).
# Also checks the objects exist and that what Helm applied is exactly what `helm template`
# renders (values decide, not the cluster).
#
# Defines setup, checks, install, and optionally extra. Every fixture is first dry-run before
# the chart is installed (all must be admitted), then again after it.

setup() {
  namespace apps
}

checks() {
  expect deny apps test/e2e/fixtures/smoke-pod.yaml restrict-image-registries
  expect warn apps test/e2e/fixtures/smoke-deployment.yaml restrict-image-registries
  expect admit kube-system test/e2e/fixtures/bad-registry-pod.yaml
}

install() {
  install_chart minimal.yaml
}

extra() {
  local obj
  for obj in validatingadmissionpolicy/restrict-image-registries \
    validatingadmissionpolicybinding/restrict-image-registries \
    validatingadmissionpolicybinding/restrict-image-registries-controllers; do
    if "$KUBECTL" get "$obj" >/dev/null 2>&1; then
      record PASS "$obj exists"
    else
      record FAIL "$obj exists"
    fi
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
}
