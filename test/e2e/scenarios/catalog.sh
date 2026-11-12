# shellcheck shell=bash
# The policy catalog against a real API server: every fixture under fixtures/<policy>/, and
# every exception case (CLAUDE.md, "Testing"). Installed with every optional policy on, at
# enforce (optional_policy_flags reads them from the definitions).
#
#   apps             empty posture-exceptions    allow fixtures: admitted, no warning
#   only-<policy>    every other policy excepted the policy's deny fixtures: Pods denied,
#                                                controllers warned, by that policy alone
#   exempt           every policy excepted       deny fixtures admitted, no warning; plus the
#                    (+ the cases below)         exception cases in test/e2e/fixtures/exceptions
#   kube-system      none                        deny Pods admitted (never evaluated)
#   exec-allowed     none                        listed in disallow-pod-exec.namespaces
#   lb-allowed       empty posture-exceptions    listed in restrict-loadbalancer-services.namespaces
#   debug-allowed    disallow-ephemeral-         kubectl debug on the smoke pod (the other
#                    containers excepted         policies still judge the debug container)
#   default          every other policy excepted disallow-default-namespace's deny fixtures
#                                                (only-<policy> doesn't apply: the namespace
#                                                is what it refuses)
#
# Policies without exceptions (the RBAC policies, disallow-pod-exec) have no only-<policy> or
# exempt case: their deny fixtures are denied in apps (so each breaks only its own policy), and
# their allowlist settings are checked instead (allowedRoles, allowedSubjects, a system: name,
# the exec namespaces).
#
# A namespace with no posture-exceptions at all is covered by the smoke scenario (bare).
#
# Every expect is first checked before the chart is installed (all must be admitted), so a
# deny can't pass because the API server rejects the fixture itself.

EXC=test/e2e/fixtures/exceptions
RBAC=test/e2e/fixtures/rbac

setup() {
  require_exempt_covers "$EXC/posture-exceptions-exempt.yaml"
  namespace apps
  namespace exempt
  namespace exec-allowed
  namespace debug-allowed
  namespace lb-allowed
  policy_namespaces
  # A pod that predates the policies: created for real now, never scheduled.
  quiet "$KUBECTL" apply -n apps -f "$ROOT/test/e2e/fixtures/old-bad-pod.yaml"
  # A compliant pod, created for real, to try kubectl debug on after install.
  quiet "$KUBECTL" apply -n apps -f "$ROOT/test/e2e/fixtures/smoke-pod.yaml"
  # And one where exec is allowed, to try kubectl exec on.
  quiet "$KUBECTL" apply -n exec-allowed -f "$ROOT/test/e2e/fixtures/smoke-pod.yaml"
  # And one where kubectl debug is allowed.
  quiet "$KUBECTL" apply -n debug-allowed -f "$ROOT/test/e2e/fixtures/smoke-pod.yaml"
}

checks() {
  expect_policy_fixtures
  # An exception covers only the workloads it selects, only for its own policy and kind.
  expect deny exempt "$EXC/unlabeled-pod.yaml" disallow-host-namespaces
  expect deny exempt "$EXC/wrong-kind-pod.yaml" restrict-image-registries
  expect deny exempt "$EXC/partial-labels-pod.yaml" disallow-host-namespaces
  expect admit exempt "$EXC/both-labels-pod.yaml"
  # restrict-wildcard-rbac's allowlists: a name in allowedRoles, and Kubernetes' own system: names.
  expect admit apps "$RBAC/allowed-wildcard-clusterrole.yaml"
  expect admit apps "$RBAC/system-wildcard-clusterrole.yaml"
  # The other RBAC allowlists: allowedSubjects and system:masters for cluster-admin bindings,
  # allowedRoles for the escalation verbs.
  expect admit apps "$RBAC/allowed-cluster-admin-binding.yaml"
  expect admit apps "$RBAC/masters-cluster-admin-binding.yaml"
  expect admit apps "$RBAC/allowed-escalation-clusterrole.yaml"
  # A LoadBalancer Service in a namespace listed in restrict-loadbalancer-services.namespaces.
  expect admit lb-allowed test/e2e/fixtures/services/loadbalancer.yaml
  # disallow-latest-tag admits a tag (also after a registry port) when require-image-digest is
  # excepted; in apps both apply, so these can't be allow fixtures.
  expect admit only-disallow-latest-tag test/e2e/fixtures/optional/pod-tag-only.yaml
  expect admit only-disallow-latest-tag test/e2e/fixtures/optional/pod-port-tag.yaml
}

install() {
  # shellcheck disable=SC2046 # one flag per word
  install_chart minimal.yaml $(optional_policy_flags enforce) \
    --set-json 'policies.restrict-wildcard-rbac.allowedRoles=["e2e-allowed-wildcard"]' \
    --set-json 'policies.disallow-pod-exec.namespaces=["exec-allowed"]' \
    --set-json 'policies.restrict-loadbalancer-services.namespaces=["lb-allowed"]' \
    --set-json 'policies.restrict-cluster-admin-binding.allowedSubjects=[{"kind":"Group","name":"e2e-admins"}]' \
    --set-json 'policies.disallow-rbac-escalation-verbs.allowedRoles=["e2e-allowed-escalation"]'
  exceptions_object apps
  exceptions_object debug-allowed disallow-ephemeral-containers
  exceptions_object lb-allowed
  policy_exceptions
  quiet "$KUBECTL" apply -n exempt -f "$ROOT/$EXC/posture-exceptions-exempt.yaml"
  info "posture-exceptions applied in apps and lb-allowed (empty), debug-allowed, only-<policy> and default (all but one), exempt"
}

extra() {
  # The Pod UPDATE match condition: a pod created before the policies (or whose exception
  # expired) can still have its metadata changed: labels, finalizers, ownerReferences.
  check_command admit "" "label a pre-existing non-compliant pod (spec unchanged)" -- \
    "$KUBECTL" -n apps label pod old-bad e2e.test/touched=true --dry-run=server
  # kubectl debug (pods/ephemeralcontainers). The debug containers are otherwise compliant
  # (digest-pinned, read-only root, no escalation, all capabilities dropped), so only the
  # image, or disallow-ephemeral-containers itself, decides.
  check_command deny disallow-ephemeral-containers "kubectl debug, without an exception" -- \
    "$KUBECTL" -n apps patch pod smoke --subresource=ephemeralcontainers --type=strategic \
    --dry-run=server -p '{"spec":{"ephemeralContainers":[{"name":"debug","image":"registry.example.mil/debug@sha256:0000000000000000000000000000000000000000000000000000000000000000","targetContainerName":"app","securityContext":{"readOnlyRootFilesystem":true,"allowPrivilegeEscalation":false,"capabilities":{"drop":["ALL"]}}}]}}'
  # In debug-allowed the pod is excepted from disallow-ephemeral-containers, and the debug
  # container is still evaluated by everything else: an unlisted image is refused, a listed
  # one admitted.
  check_command deny restrict-image-registries "kubectl debug with an unlisted image" -- \
    "$KUBECTL" -n debug-allowed patch pod smoke --subresource=ephemeralcontainers --type=strategic \
    --dry-run=server -p '{"spec":{"ephemeralContainers":[{"name":"debug","image":"docker.io/library/busybox@sha256:0000000000000000000000000000000000000000000000000000000000000000","targetContainerName":"app","securityContext":{"readOnlyRootFilesystem":true,"allowPrivilegeEscalation":false,"capabilities":{"drop":["ALL"]}}}]}}'
  check_command admit "" "kubectl debug with a listed image" -- \
    "$KUBECTL" -n debug-allowed patch pod smoke --subresource=ephemeralcontainers --type=strategic \
    --dry-run=server -p '{"spec":{"ephemeralContainers":[{"name":"debug","image":"registry.example.mil/debug@sha256:0000000000000000000000000000000000000000000000000000000000000000","targetContainerName":"app","securityContext":{"readOnlyRootFilesystem":true,"allowPrivilegeEscalation":false,"capabilities":{"drop":["ALL"]}}}]}}'
  # disallow-pod-exec (CONNECT on pods/exec): refused in apps; in exec-allowed, admission lets
  # it through (the exec itself then fails, because the pod's container never starts).
  check_command deny disallow-pod-exec "kubectl exec, outside disallow-pod-exec.namespaces" -- \
    "$KUBECTL" --request-timeout=20s -n apps exec smoke -c app -- true
  check_command not-denied disallow-pod-exec "kubectl exec, in disallow-pod-exec.namespaces" -- \
    "$KUBECTL" --request-timeout=20s -n exec-allowed exec smoke -c app -- true
}
