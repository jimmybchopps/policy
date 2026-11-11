# shellcheck shell=bash
# The policy catalog against a real API server: every fixture under fixtures/<policy>/, and
# every exception case (CLAUDE.md, "Testing").
#
#   apps             empty posture-exceptions    allow fixtures: admitted, no warning
#   only-<policy>    every other policy excepted the policy's deny fixtures: Pods denied,
#                                                controllers warned, by that policy alone
#   exempt           every policy excepted       deny fixtures admitted, no warning; plus the
#                    (+ the cases below)         exception cases in test/e2e/fixtures/exceptions
#   kube-system      none                        deny Pods admitted (never evaluated)
#
# A namespace with no posture-exceptions at all is covered by the smoke scenario (bare).
#
# Every expect is first checked before the chart is installed (all must be admitted), so a
# deny can't pass because the API server rejects the fixture itself.

EXC=test/e2e/fixtures/exceptions

setup() {
  namespace apps
  namespace exempt
  policy_namespaces
  # A pod that predates the policies: created for real now, never scheduled.
  quiet "$KUBECTL" apply -n apps -f "$ROOT/test/e2e/fixtures/old-bad-pod.yaml"
  # A compliant pod, created for real, to try kubectl debug on after install.
  quiet "$KUBECTL" apply -n apps -f "$ROOT/test/e2e/fixtures/smoke-pod.yaml"
}

checks() {
  expect_policy_fixtures
  # An exception covers only the workloads it selects, only for its own policy and kind.
  expect deny exempt "$EXC/unlabeled-pod.yaml" disallow-host-path
  expect deny exempt "$EXC/wrong-kind-pod.yaml" restrict-image-registries
  expect deny exempt "$EXC/partial-labels-pod.yaml" disallow-host-path
  expect admit exempt "$EXC/both-labels-pod.yaml"
}

install() {
  install_chart minimal.yaml
  exceptions_object apps
  policy_exceptions
  quiet "$KUBECTL" apply -n exempt -f "$ROOT/$EXC/posture-exceptions-exempt.yaml"
  info "posture-exceptions applied in apps (empty), only-<policy> (all but one), exempt"
}

extra() {
  # The Pod UPDATE match condition: a pod created before the policies (or whose exception
  # expired) can still have its metadata changed: labels, finalizers, ownerReferences.
  check_command admit "" "label a pre-existing non-compliant pod (spec unchanged)" -- \
    "$KUBECTL" -n apps label pod old-bad e2e.test/touched=true --dry-run=server
  # kubectl debug (pods/ephemeralcontainers) is evaluated, on a compliant pod so only the
  # debug container decides: an unlisted image is refused, a listed one admitted.
  check_command deny restrict-image-registries "kubectl debug with an unlisted image" -- \
    "$KUBECTL" -n apps patch pod smoke --subresource=ephemeralcontainers --type=strategic \
    --dry-run=server -p '{"spec":{"ephemeralContainers":[{"name":"debug","image":"docker.io/library/busybox:1.37","targetContainerName":"app"}]}}'
  check_command admit "" "kubectl debug with a listed image" -- \
    "$KUBECTL" -n apps patch pod smoke --subresource=ephemeralcontainers --type=strategic \
    --dry-run=server -p '{"spec":{"ephemeralContainers":[{"name":"debug","image":"registry.example.mil/debug:1.0","targetContainerName":"app"}]}}'
}
