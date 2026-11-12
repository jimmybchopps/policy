#!/usr/bin/env bash
# Helpers for the policy e2e tests. Sourced by run.sh; expects CLUSTER, ROOT, HERE, and the tool
# variables (K3D, KUBECTL, HELM, K3S_IMAGE) to be set.
#
# Every check is a server-side dry-run (kubectl apply --dry-run=server): the API server runs
# admission, including every ValidatingAdmissionPolicy, without persisting anything. So
# fixtures never need images pulled or pods scheduled.

# ---------------------------------------------------------------------------------------------
# Output

log() { printf '\n==> %s\n' "$*"; }
info() { printf '    %s\n' "$*"; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

quiet() { # quiet <command...>: runs it silently; prints its output only if it fails
  local out
  if ! out=$("$@" 2>&1); then
    printf '%s\n' "$out" >&2
    return 1
  fi
}

PASSED=0
FAILED=0
FAILURES=()

record() { # record <PASS|FAIL> <message> [detail]: detail (e.g. command output) is shown on FAIL
  printf '%s %s\n' "$1" "$2"
  if [[ $1 == PASS ]]; then
    PASSED=$((PASSED + 1))
  else
    FAILED=$((FAILED + 1))
    FAILURES+=("$2")
    if [[ -n ${3:-} ]]; then printf '%s\n' "$3" | sed 's/^/      | /'; fi
  fi
}

summary() {
  log "summary: ${PASSED} passed, ${FAILED} failed"
  local f
  for f in "${FAILURES[@]}"; do printf '  FAIL %s\n' "$f"; done
  [[ $FAILED -eq 0 ]]
}

# ---------------------------------------------------------------------------------------------
# Cluster: plain k3d. Admission policies need no CNI features, so flannel stays.

create_cluster() {
  log "creating k3d cluster ${CLUSTER} (${K3S_IMAGE})"
  quiet "$K3D" cluster create "$CLUSTER" \
    --image "$K3S_IMAGE" \
    --agents 1 \
    --k3s-arg '--disable=traefik@server:*' \
    --wait
  quiet "$KUBECTL" -n kube-system rollout status deployment/coredns --timeout=120s
}

delete_cluster() {
  "$K3D" cluster delete "$CLUSTER" >/dev/null 2>&1 || true
}

# ---------------------------------------------------------------------------------------------
# Namespaces and the chart

NAMESPACES=()

namespace() { # namespace <name>: created fresh, with the fixtures' service account; removed after the scenario
  "$KUBECTL" create namespace "$1" >/dev/null
  NAMESPACES+=("$1")
  fixture_service_account "$1"
}

# fixture_service_account <namespace>: ServiceAccount app, which every workload fixture runs as
# (disallow-default-service-account). The ServiceAccount admission plugin refuses a Pod whose
# service account doesn't exist, before any policy runs. Idempotent.
fixture_service_account() {
  "$KUBECTL" create serviceaccount app -n "$1" --dry-run=client -o yaml | quiet "$KUBECTL" apply -f -
}

RELEASE=${RELEASE:-policy}
RELEASE_NAMESPACE=${RELEASE_NAMESPACE:-policy}
CRD=policyexceptions.policy.posture.dev

# install_chart <example file under examples/> [helm args...]
# Installs the chart cluster-wide (release "policy" in namespace "policy"). Extra arguments go
# to helm install after the example, e.g. --set-json 'policies.x={}' or
# -f "$ROOT/test/e2e/values/<file>.yaml".
install_chart() {
  local example=$1
  shift
  quiet "$HELM" install "$RELEASE" "$ROOT/charts/policy" -n "$RELEASE_NAMESPACE" --create-namespace \
    -f "$ROOT/examples/${example}" "$@" --wait
  # Objects of the chart's own CRD (posture-exceptions) can only be created once it's served.
  quiet "$KUBECTL" wait --for=condition=Established "crd/$CRD" --timeout=60s
  info "${RELEASE} installed (examples/${example}${*:+ $*})"
}

cleanup_namespaces() {
  local ns
  # Uninstall first, so the policies can't block deleting anything.
  "$HELM" uninstall "$RELEASE" -n "$RELEASE_NAMESPACE" --wait >/dev/null 2>&1 || true
  for ns in "${NAMESPACES[@]}" "$RELEASE_NAMESPACE"; do
    "$KUBECTL" delete namespace "$ns" --wait=false >/dev/null 2>&1 || true
  done
  for ns in "${NAMESPACES[@]}" "$RELEASE_NAMESPACE"; do
    "$KUBECTL" wait --for=delete "namespace/$ns" --timeout=120s >/dev/null 2>&1 || true
  done
  # The CRD is kept on uninstall (helm.sh/resource-policy: keep); delete it so every scenario
  # starts from a cluster without it.
  "$KUBECTL" delete crd "$CRD" --ignore-not-found --wait=true >/dev/null 2>&1 || true
  NAMESPACES=()
}

# ---------------------------------------------------------------------------------------------
# Checks
#
# Scenarios declare checks with
#   expect admit <namespace> <fixture>             admitted, no policy warning
#   expect deny  <namespace> <fixture> [policy]    refused, and the message names the policy
#   expect warn  <namespace> <fixture> [policy]    admitted with a policy warning naming the policy
#   expect mutated <namespace> <fixture>           admitted, no policy warning, and every
#                                                  "# expect:" line in the fixture holds
#                                                  (mutations; see check_expectations)
# A policy warning is a "Warning:" line from a ValidatingAdmissionPolicy. Other warnings are the
# API server's own (deprecations such as spec.externalIPs on 1.37+) and don't count either way.
# <fixture> is relative to the repo root. [policy] defaults to the <policy> in
# fixtures/<policy>/<allow|deny>/<file>.yaml.
#
# run_checks then runs them:
#   baseline (before the chart is installed): every fixture, whatever it expects, must be
#     admitted with no policy warning, so a deny can't pass for the wrong reason (a malformed fixture,
#     a missing namespace, a typo'd field).
#   policy (after install): every deny and warn first, each retried until it fires (bindings
#     take a few seconds to become active), then every admit.

CHECKS=()

expect() { # expect <admit|deny|warn|mutated> <namespace> <fixture> [policy]
  local want=$1 ns=$2 fixture=$3 policy=${4:-}
  case $want in
    admit | mutated) ;;
    deny | warn)
      if [[ -z $policy ]]; then
        [[ $fixture =~ ^fixtures/([^/]+)/ ]] || die "expect $want $fixture: name the policy (not under fixtures/<policy>/)"
        policy=${BASH_REMATCH[1]}
      fi
      ;;
    *) die "expect: unknown expectation $want" ;;
  esac
  [[ -f $ROOT/$fixture ]] || die "expect: no such fixture: $fixture"
  CHECKS+=("$want $ns $fixture $policy")
}

DRY_OUT=""
DRY_RC=0

dry_run() { # dry_run <namespace> <fixture>: sets DRY_OUT (stdout+stderr) and DRY_RC
  DRY_RC=0
  DRY_OUT=$("$KUBECTL" apply --dry-run=server -n "$1" -f "$ROOT/$2" 2>&1) || DRY_RC=$?
}

# policy_warned [policy] < output: a ValidatingAdmissionPolicy warned (the named one, if given).
policy_warned() {
  grep -E '^Warning:' | grep -F 'ValidatingAdmissionPolicy' | grep -qF -- "${1:-Warning:}"
}

warned() { policy_warned "$@" <<<"$DRY_OUT"; } # warned [policy]: on DRY_OUT

check_once() { # check_once <admit|deny|warn> <namespace> <fixture> <policy>
  dry_run "$2" "$3"
  case $1 in
    admit) [[ $DRY_RC -eq 0 ]] && ! warned ;;
    mutated) [[ $DRY_RC -eq 0 ]] && ! warned && check_expectations "$2" "$3" ;;
    deny) [[ $DRY_RC -ne 0 ]] && grep -qF -- "$4" <<<"$DRY_OUT" ;;
    warn) [[ $DRY_RC -eq 0 ]] && warned "$4" ;;
  esac
}

# check_expectations <namespace> <fixture>: every "# expect: <jsonpath> <op> <value>" line in the
# fixture holds for the object the API server would store (a server-side dry-run, so after
# mutation). <op> is = (the jsonpath prints exactly <value>; an empty value means unset),
# ~ (contains <value>), or !~ (doesn't). Sets DRY_OUT to what failed.
check_expectations() {
  local ns=$1 fixture=$2 line jsonpath op value got
  while IFS= read -r line; do
    [[ $line =~ ^\#\ expect:\ (\{[^}]*\})\ (=|~|!~)\ ?(.*)$ ]] || continue
    jsonpath=${BASH_REMATCH[1]} op=${BASH_REMATCH[2]} value=${BASH_REMATCH[3]}
    got=$("$KUBECTL" apply --dry-run=server -n "$ns" -f "$ROOT/$fixture" -o "jsonpath=$jsonpath" 2>&1) || {
      DRY_OUT="$jsonpath: $got"; return 1; }
    case $op in
      =) [[ $got == "$value" ]] ;;
      '~') [[ $got == *"$value"* ]] ;;
      '!~') [[ $got != *"$value"* ]] ;;
    esac || { DRY_OUT="$jsonpath $op '$value', got '$got'"; return 1; }
  done <"$ROOT/$fixture"
}

check_retry() { # check_retry <want> <ns> <fixture> <policy>: retries while policies activate
  local _attempt
  for _attempt in 1 2 3 4 5 6 7 8 9 10; do
    check_once "$@" && return 0
    sleep 2
  done
  return 1
}

# verify <admit|deny|warn> <namespace> <fixture> [substring]: checks one object now (with the
# same retries) and records the result. For use in a scenario's extra, for objects that can't
# exist before the chart is installed (PolicyExceptions, whose CRD the chart installs), so the
# baseline doesn't apply. deny with a substring also covers schema rejections, e.g. the field.
verify() {
  local want=$1 ns=$2 fixture=$3 sub=${4:-}
  [[ -f $ROOT/$fixture ]] || die "verify: no such fixture: $fixture"
  if check_retry "$want" "$ns" "$fixture" "$sub"; then
    record PASS "[verify] $want $ns $fixture${sub:+ ($sub)}"
  else
    record FAIL "[verify] $want $ns $fixture${sub:+ ($sub)}" "$DRY_OUT"
  fi
}

# ---------------------------------------------------------------------------------------------
# The policy catalog's fixtures and exceptions

# fixture_policies: every policy with fixtures (fixtures/<policy>/), sorted.
fixture_policies() {
  local d
  for d in "$ROOT"/fixtures/*/; do basename "$d"; done | sort
}

DEFINITIONS_DIR=charts/policy/definitions/validating

# policy_exceptions_mode <policy>: labels, or none for a policy that takes no posture exceptions
# (resources: rbac, or exceptions: none), read from its definition.
policy_exceptions_mode() {
  local def="$ROOT/$DEFINITIONS_DIR/$1.yaml"
  if grep -qx 'resources: rbac' "$def" || grep -qx 'exceptions: none' "$def"; then
    echo none
  else
    echo labels
  fi
}

# exception_policies: every built-in policy that takes posture exceptions, sorted.
exception_policies() {
  local f p
  for f in "$ROOT/$DEFINITIONS_DIR"/*.yaml; do
    p=$(basename "$f" .yaml)
    [[ $(policy_exceptions_mode "$p") == labels ]] && echo "$p"
  done | sort
}

# optional_policy_flags [action]: helm flags turning on every optional policy at <action>
# (default enforce), read from the definitions, so a new optional policy is tested without
# editing any list.
optional_policy_flags() {
  local action=${1:-enforce} f
  for f in "$ROOT/$DEFINITIONS_DIR"/*.yaml; do
    if grep -qx 'tier: optional' "$f"; then
      printf -- '--set policies.%s.enabled=true --set policies.%s.action=%s\n' \
        "$(basename "$f" .yaml)" "$(basename "$f" .yaml)" "$action"
    fi
  done
}

# require_exempt_covers <posture-exceptions file>: the hand-written exempt object must except
# every policy that takes exceptions, or its admit checks would fail for the wrong reason.
require_exempt_covers() {
  local p missing=""
  for p in $(exception_policies); do
    grep -q "kind: ValidatingAdmissionPolicy, name: ${p} }" "$ROOT/$1" || missing+=" $p"
  done
  [[ -z $missing ]] || die "$1 doesn't except:$missing"
}

# exceptions_object <namespace> [policy...]: applies a posture-exceptions in exactly the shape
# posture renders (one entry per policy, sorted), excepting each listed policy for the fixtures
# (e2e.test/fixture=true). A policy is a ValidatingAdmissionPolicy's name, or Kind:name (e.g.
# MutatingAdmissionPolicy:add-default-resources). With no policies it is empty, as posture
# renders it for a namespace without exceptions.
exceptions_object() {
  local ns=$1 p entries=""
  shift
  local kind name
  for p in $(printf '%s\n' "$@" | sort); do
    if [[ $p == *:* ]]; then kind=${p%%:*} name=${p#*:}; else kind=ValidatingAdmissionPolicy name=$p; fi
    entries+="
    - policy: { kind: ${kind}, name: ${name} }
      workloads:
        - matchLabels: { e2e.test/fixture: \"true\" }
          reason: e2e fixture"
  done
  quiet "$KUBECTL" apply -n "$ns" -f - <<EOT
apiVersion: policy.posture.dev/v1alpha1
kind: PolicyExceptions
metadata:
  name: posture-exceptions
  annotations: { posture.dev/rule: exceptions }
spec:
  exceptions:${entries:- []}
EOT
}

# policy_test_namespace <policy>: where its deny fixtures are checked, with every other policy
# excepted: only-<policy>, or default for disallow-default-namespace (whose deny fixtures are
# compliant objects; the namespace is what it refuses).
policy_test_namespace() {
  if [[ $1 == disallow-default-namespace ]]; then echo default; else echo "only-$1"; fi
}

# policy_namespaces: one namespace per policy that takes exceptions, for that policy's deny
# fixtures (default already exists; it only gets the service account).
policy_namespaces() {
  local p ns
  for p in $(fixture_policies); do
    [[ $(policy_exceptions_mode "$p") == labels ]] || continue
    ns=$(policy_test_namespace "$p")
    if [[ $ns == default ]]; then fixture_service_account default; else namespace "$ns"; fi
  done
  return 0
}

# policy_exceptions: in each only-<policy>, every OTHER policy that takes exceptions is excepted
# for the fixtures, so a deny fixture there is refused by its own policy alone (some, like a
# HostProcess pod, can't help breaking two).
policy_exceptions() {
  local p
  local -a all
  mapfile -t all < <(exception_policies)
  for p in $(fixture_policies); do
    [[ $(policy_exceptions_mode "$p") == labels ]] || continue
    # shellcheck disable=SC2046 # word splitting of policy names is intended
    exceptions_object "$(policy_test_namespace "$p")" $(printf '%s\n' "${all[@]}" | grep -vxF "$p")
  done
}

# expect_policy_fixtures: declares every fixture's expectations (CLAUDE.md, "Testing"):
#   allow/*               admitted, with no policy warning, in apps (an empty posture-exceptions)
#   deny/* controllers    admitted with a warning naming the policy in only-<policy>; admitted
#                         with no policy warning in exempt
#   deny/* anything else  (Pods, Services, RBAC objects) denied by the policy in only-<policy>;
#                         admitted in exempt (every policy excepted), and in kube-system
#                         (never evaluated) unless it's cluster-scoped
# A policy without exceptions (rbac, exceptions: none) has no only-<policy> or exempt case: its
# deny fixtures are denied in apps, and nothing but its allowlist settings can admit them.
fixture_kind() { awk '/^kind:/ { print $2; exit }' "$ROOT/$1"; }

is_controller() { [[ $1 =~ ^(Deployment|StatefulSet|DaemonSet|ReplicaSet|Job|CronJob)$ ]]; }
is_cluster_scoped() { [[ $1 =~ ^(ClusterRole|ClusterRoleBinding)$ ]]; }

expect_policy_fixtures() {
  local p f rel kind ns
  for p in $(fixture_policies); do
    for f in "$ROOT/fixtures/$p"/allow/*.yaml; do
      expect admit apps "fixtures/$p/allow/$(basename "$f")"
    done
    if [[ $(policy_exceptions_mode "$p") == labels ]]; then ns=$(policy_test_namespace "$p"); else ns=apps; fi
    for f in "$ROOT/fixtures/$p"/deny/*.yaml; do
      rel="fixtures/$p/deny/$(basename "$f")"
      kind=$(fixture_kind "$rel")
      if is_controller "$kind"; then
        expect warn "$ns" "$rel" "$p"
      else
        expect deny "$ns" "$rel" "$p"
        is_cluster_scoped "$kind" || expect admit kube-system "$rel"
      fi
      if [[ $(policy_exceptions_mode "$p") == labels ]]; then expect admit exempt "$rel"; fi
    done
  done
}

# check_command <admit|deny|not-denied> <substring> <description> -- <command...>: runs a
# command that makes an admission request (e.g. a --dry-run=server patch) and records whether
# it was admitted with no policy warning, refused with a message containing <substring>, or (not-denied)
# not refused by <substring>, whether or not it fails afterwards for another reason (kubectl
# exec on a pod whose container never started). Retried like the other checks.
check_command() {
  local want=$1 sub=$2 desc=$3 out="" rc _attempt ok
  shift 4
  for _attempt in 1 2 3 4 5 6 7 8 9 10; do
    rc=0
    out=$("$@" 2>&1) || rc=$?
    ok=0
    case $want in
      admit) [[ $rc -eq 0 ]] && ! policy_warned <<<"$out" && ok=1 ;;
      deny) [[ $rc -ne 0 ]] && grep -qF -- "$sub" <<<"$out" && ok=1 ;;
      not-denied) ! grep -qF -- "$sub" <<<"$out" && ok=1 ;;
    esac
    [[ $ok == 1 ]] && break
    sleep 2
  done
  if [[ $ok == 1 ]]; then
    record PASS "[command] $want: $desc"
  else
    record FAIL "[command] $want: $desc" "$out"
  fi
}

# check_type_checking: every installed ValidatingAdmissionPolicy has been type-checked by the
# API server (status.observedGeneration caught up) with no expressionWarnings. The API server
# is the only real check of the policies' CEL against the Kubernetes types.
check_type_checking() {
  local vap vaps gen observed warnings _attempt
  vaps=$("$KUBECTL" get validatingadmissionpolicies -l app.kubernetes.io/name=policy -o name)
  if [[ -z $vaps ]]; then
    record FAIL "type checking: no ValidatingAdmissionPolicies from this chart are installed"
    return 0
  fi
  for vap in $vaps; do
    for _attempt in $(seq 1 30); do
      gen=$("$KUBECTL" get "$vap" -o jsonpath='{.metadata.generation}')
      observed=$("$KUBECTL" get "$vap" -o jsonpath='{.status.observedGeneration}')
      [[ $observed == "$gen" ]] && break
      sleep 2
    done
    if [[ $observed != "$gen" ]]; then
      record FAIL "$vap type-checked (status.observedGeneration ${observed:-unset}, generation $gen)"
      continue
    fi
    warnings=$("$KUBECTL" get "$vap" -o jsonpath='{range .status.typeChecking.expressionWarnings[*]}{.fieldRef}: {.warning}{"\n"}{end}')
    if [[ -z $warnings ]]; then
      record PASS "$vap type-checks with no warnings"
    else
      record FAIL "$vap type-checks with no warnings" "$warnings"
    fi
  done
}

# check_mutation_type_checking: like check_type_checking, for this chart's
# MutatingAdmissionPolicies. If the API server reports no type checking for them (no
# status.observedGeneration), that's noted, not failed: the mutation fixtures exercise every
# expression anyway.
check_mutation_type_checking() {
  local map maps gen observed warnings _attempt
  maps=$("$KUBECTL" get mutatingadmissionpolicies -l app.kubernetes.io/name=policy -o name)
  if [[ -z $maps ]]; then
    record FAIL "type checking: no MutatingAdmissionPolicies from this chart are installed"
    return 0
  fi
  for map in $maps; do
    for _attempt in $(seq 1 10); do
      gen=$("$KUBECTL" get "$map" -o jsonpath='{.metadata.generation}')
      observed=$("$KUBECTL" get "$map" -o jsonpath='{.status.observedGeneration}')
      [[ $observed == "$gen" ]] && break
      sleep 2
    done
    if [[ $observed != "$gen" ]]; then
      info "$map: the API server reports no type checking (status.observedGeneration unset)"
      continue
    fi
    warnings=$("$KUBECTL" get "$map" -o jsonpath='{range .status.typeChecking.expressionWarnings[*]}{.fieldRef}: {.warning}{"\n"}{end}')
    if [[ -z $warnings ]]; then
      record PASS "$map type-checks with no warnings"
    else
      record FAIL "$map type-checks with no warnings" "$warnings"
    fi
  done
}

run_checks() { # run_checks <baseline|policy>
  local phase=$1 check want w ns fixture policy
  if [[ $phase == baseline ]]; then
    for check in "${CHECKS[@]}"; do
      read -r want ns fixture policy <<<"$check"
      if check_once admit "$ns" "$fixture" ""; then
        record PASS "[baseline] admitted before install: $ns $fixture"
      else
        record FAIL "[baseline] admitted before install: $ns $fixture (the $want check below would prove nothing)" "$DRY_OUT"
      fi
    done
    return 0
  fi
  for want in deny warn admit mutated; do
    for check in "${CHECKS[@]}"; do
      read -r w ns fixture policy <<<"$check"
      [[ $w == "$want" ]] || continue
      case $want in
        # Admits run last, once every policy is active, so they aren't retried.
        admit) check_once admit "$ns" "$fixture" "" ;;
        # Mutations are retried like denies: until a mutating binding is active, the Pod is
        # admitted but not mutated.
        mutated) check_retry mutated "$ns" "$fixture" "" ;;
        *) check_retry "$want" "$ns" "$fixture" "$policy" ;;
      esac
      if [[ $? -eq 0 ]]; then
        record PASS "[policy] $want $ns $fixture${policy:+ ($policy)}"
      else
        record FAIL "[policy] $want $ns $fixture${policy:+ ($policy)}" "$DRY_OUT"
      fi
    done
  done
}

# run_scenario <name>: sources scenarios/<name>.sh, which defines setup, checks, and install
# (and optionally extra, for checks that aren't admission requests).
run_scenario() {
  local name=$1 before=$FAILED
  log "scenario ${name}"
  unset -f setup install checks extra
  # shellcheck source=/dev/null
  source "${HERE}/scenarios/${name}.sh"
  CHECKS=()
  setup
  checks
  run_checks baseline
  install
  run_checks policy
  if declare -F extra >/dev/null; then extra; fi
  if [[ $FAILED -gt $before ]]; then
    dump_state
    if [[ ${E2E_KEEP:-0} == 1 ]]; then
      # Keep this scenario's namespaces to inspect; later scenarios may reuse their names, so stop.
      KEPT_SCENARIO=$name
      info "keeping namespaces ${NAMESPACES[*]} and the release (E2E_KEEP=1); skipping the remaining scenarios"
      return 0
    fi
  fi
  cleanup_namespaces
}

# shellcheck disable=SC2034 # read by run.sh
KEPT_SCENARIO=""

# dump_state: a short overview after a failed scenario. For details, rerun with E2E_KEEP=1 and
# inspect what it keeps (kubectl get validatingadmissionpolicies -o yaml, and so on).
dump_state() {
  local ns
  printf '\n--- admission policies\n'
  "$KUBECTL" get validatingadmissionpolicies,validatingadmissionpolicybindings 2>&1 || true
  printf '\n--- type checking (the API server compiling each policy CEL)\n'
  "$KUBECTL" get validatingadmissionpolicies \
    -o jsonpath='{range .items[*]}{.metadata.name}: {.status.typeChecking}{"\n"}{end}' 2>&1 || true
  for ns in "${NAMESPACES[@]}"; do
    printf '\n--- namespace %s\n' "$ns"
    "$KUBECTL" -n "$ns" get policyexceptions 2>&1 || true
  done
  if [[ ${E2E_KEEP:-0} != 1 ]]; then
    printf '\n(rerun with E2E_KEEP=1 E2E_ARGS=<scenario> to keep these namespaces for inspection)\n'
  fi
}
