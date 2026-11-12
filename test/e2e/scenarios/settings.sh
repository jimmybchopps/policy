# shellcheck shell=bash
# The values that change how policies act: enforcement, an optional policy's action, and a
# custom policy (test/e2e/values/settings.yaml: enforcement audit, plus custom
# require-team-label at action enforce).
#
#   apps   posture-exceptions excepting require-team-label for the fixtures
#          (e2e.test/fixture=true), so built-in fixtures need no team label
#
# Checks:
#   - enforcement audit: an optional policy with action inherit audits Pods (admitted, no
#     warning) and still warns on controllers;
#   - baked-in policies ignore enforcement: still denied;
#   - the custom policy, at its own action enforce, denies a Pod without the label, admits one
#     with it, warns on a Deployment, and honors a posture exception;
#   - the custom policy type-checks like the built-in ones.

CUSTOM=test/e2e/fixtures/custom

setup() {
  namespace apps
}

checks() {
  expect admit apps fixtures/require-read-only-root-filesystem/deny/pod-unset.yaml
  expect warn apps fixtures/require-read-only-root-filesystem/deny/deployment-init-writable.yaml
  expect deny apps fixtures/disallow-host-namespaces/deny/pod-host-pid.yaml
  expect deny apps "$CUSTOM/pod-no-team.yaml" require-team-label
  expect admit apps "$CUSTOM/pod-team.yaml"
  expect warn apps "$CUSTOM/deployment-no-team.yaml" require-team-label
  expect admit apps "$CUSTOM/pod-no-team-excepted.yaml"
}

install() {
  install_chart minimal.yaml -f "$ROOT/test/e2e/values/settings.yaml"
  exceptions_object apps require-team-label
  info "posture-exceptions applied in apps (require-team-label excepted for the fixtures)"
}

extra() {
  check_type_checking
}
