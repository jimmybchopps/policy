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

namespace() { # namespace <name>: created fresh, removed after the scenario
  "$KUBECTL" create namespace "$1" >/dev/null
  NAMESPACES+=("$1")
}

RELEASE=${RELEASE:-policy}
RELEASE_NAMESPACE=${RELEASE_NAMESPACE:-policy}

# install_chart <example file under examples/> [helm args...]
# Installs the chart cluster-wide (release "policy" in namespace "policy"). Extra arguments go
# to helm install after the example, e.g. --set-json 'policies.x={}'.
install_chart() {
  local example=$1
  shift
  quiet "$HELM" install "$RELEASE" "$ROOT/charts/policy" -n "$RELEASE_NAMESPACE" --create-namespace \
    -f "$ROOT/examples/${example}" "$@" --wait
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
  NAMESPACES=()
}

# ---------------------------------------------------------------------------------------------
# Checks
#
# Scenarios declare checks with
#   expect admit <namespace> <fixture>             admitted, no warning
#   expect deny  <namespace> <fixture> [policy]    refused, and the message names the policy
#   expect warn  <namespace> <fixture> [policy]    admitted with a "Warning:" naming the policy
# <fixture> is relative to the repo root. [policy] defaults to the <policy> in
# fixtures/<policy>/<allow|deny>/<file>.yaml.
#
# run_checks then runs them:
#   baseline (before the chart is installed): every fixture, whatever it expects, must be
#     admitted with no warning, so a deny can't pass for the wrong reason (a malformed fixture,
#     a missing namespace, a typo'd field).
#   policy (after install): every deny and warn first, each retried until it fires (bindings
#     take a few seconds to become active), then every admit.

CHECKS=()

expect() { # expect <admit|deny|warn> <namespace> <fixture> [policy]
  local want=$1 ns=$2 fixture=$3 policy=${4:-}
  case $want in
    admit) ;;
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

warned() { # warned [policy]: DRY_OUT has a warning (naming the policy, if given)
  grep -E '^Warning:' <<<"$DRY_OUT" | grep -qF -- "${1:-Warning:}"
}

check_once() { # check_once <admit|deny|warn> <namespace> <fixture> <policy>
  dry_run "$2" "$3"
  case $1 in
    admit) [[ $DRY_RC -eq 0 ]] && ! warned ;;
    deny) [[ $DRY_RC -ne 0 ]] && grep -qF -- "$4" <<<"$DRY_OUT" ;;
    warn) [[ $DRY_RC -eq 0 ]] && warned "$4" ;;
  esac
}

check_retry() { # check_retry <want> <ns> <fixture> <policy>: retries while policies activate
  local _attempt
  for _attempt in 1 2 3 4 5 6 7 8 9 10; do
    check_once "$@" && return 0
    sleep 2
  done
  return 1
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
  for want in deny warn admit; do
    for check in "${CHECKS[@]}"; do
      read -r w ns fixture policy <<<"$check"
      [[ $w == "$want" ]] || continue
      if [[ $want == admit ]] && check_once admit "$ns" "$fixture" ""; then
        record PASS "[policy] admit $ns $fixture"
      elif [[ $want != admit ]] && check_retry "$want" "$ns" "$fixture" "$policy"; then
        record PASS "[policy] $want $ns $fixture ($policy)"
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
  for ns in "${NAMESPACES[@]}"; do
    printf '\n--- namespace %s\n' "$ns"
    "$KUBECTL" -n "$ns" get policyexceptions 2>&1 || true
  done
  if [[ ${E2E_KEEP:-0} != 1 ]]; then
    printf '\n(rerun with E2E_KEEP=1 E2E_ARGS=<scenario> to keep these namespaces for inspection)\n'
  fi
}
