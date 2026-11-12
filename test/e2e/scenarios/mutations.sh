# shellcheck shell=bash
# The mutations (examples/mutations.yaml: every mutation on), against a real API server. Every
# fixture under fixtures/mutations/<mutation>/ is checked with expect mutated: admitted with no
# policy warning, and each of its "# expect:" lines holds for the object the API server would
# store (CLAUDE.md, "Testing").
#
#   apps     empty posture-exceptions            mutated/ and kept/ fixtures: the mutated Pod
#                                                passes every policy; set values are kept
#   kept     the validators a kept fixture       fixtures whose header says "namespace: kept":
#            breaks on purpose, excepted         non-compliant values that are still never
#                                                overwritten
#   exempt   every mutation and every policy     exempt/ fixtures: not mutated
#            excepted for the fixtures
#   kube-system  none                            never mutated
#   bare     no posture-exceptions at all        the Pod is denied: the mutating bindings fail
#                                                closed too
#
# A Deployment is checked too: mutations never touch a template (the policies still warn).

MUT=fixtures/mutations
HELPERS=test/e2e/fixtures/mutations

# fixture_namespace <fixture>: the namespace its header names (# namespace: <ns>), else exempt
# for exempt/ fixtures and apps for the rest.
fixture_namespace() {
  local ns
  ns=$(sed -n 's/^# namespace: \([a-z0-9-]*\).*/\1/p' "$ROOT/$1" | head -1)
  if [[ -n $ns ]]; then echo "$ns"; elif [[ $1 == */exempt/* ]]; then echo exempt; else echo apps; fi
}

setup() {
  namespace apps
  namespace kept
  namespace exempt
  namespace bare
}

checks() {
  local f rel
  for f in "$ROOT/$MUT"/*/mutated/*.yaml "$ROOT/$MUT"/*/kept/*.yaml "$ROOT/$MUT"/*/exempt/*.yaml; do
    rel=${f#"$ROOT/"}
    expect mutated "$(fixture_namespace "$rel")" "$rel"
  done
  # Checked after the fixtures above, which prove the mutating bindings are active by then: a
  # Pod in kube-system is never mutated.
  expect mutated kube-system "$HELPERS/pod-unset.yaml"
  # The mutating binding reads posture-exceptions like every policy and fails closed without it.
  expect deny bare "$HELPERS/pod-unset.yaml" "no params found"
  # A Deployment's template isn't mutated, so the policies warn about it (its expectations are
  # checked in extra).
  expect warn apps "$HELPERS/deployment-unset.yaml" restrict-seccomp
}

install() {
  local m mutations=()
  install_chart mutations.yaml
  for m in "$ROOT"/charts/policy/definitions/mutating/*.yaml; do
    mutations+=("MutatingAdmissionPolicy:$(basename "$m" .yaml)")
  done
  exceptions_object apps
  exceptions_object kept require-run-as-non-root disallow-privilege-escalation
  # shellcheck disable=SC2046 # one policy per word
  exceptions_object exempt "${mutations[@]}" $(exception_policies)
  info "posture-exceptions applied in apps (empty), kept, and exempt (every mutation and policy); none in bare"
}

extra() {
  if check_expectations apps "$HELPERS/deployment-unset.yaml"; then
    record PASS "[command] a Deployment's template isn't mutated"
  else
    record FAIL "[command] a Deployment's template isn't mutated" "$DRY_OUT"
  fi
  check_type_checking
  check_mutation_type_checking
  # The dashboard's mutating-policy metrics exist (the fixtures above were mutated).
  check_metrics apiserver_mutating_admission_policy
}
