# shellcheck shell=bash
# Smoke test: the chart installs from examples/minimal.yaml, a compliant Pod is admitted, and
# what Helm applied is exactly what `helm template` renders (values decide, not the cluster).
#
# Defines setup, checks, install, and optionally extra. Every fixture is first dry-run before
# the chart is installed (all must be admitted), then again after it.

setup() {
  namespace apps
}

checks() {
  expect admit apps test/e2e/fixtures/smoke-pod.yaml
}

install() {
  install_chart minimal.yaml
}

extra() {
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
