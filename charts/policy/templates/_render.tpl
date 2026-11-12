{{/*
Renders the model's validating policies: per enabled policy, one ValidatingAdmissionPolicy and
its bindings (CLAUDE.md, "Actions" and "Exceptions"). Workload policies get two bindings:

  <name>              Pods (pods, pods/ephemeralcontainers), actions.pods
  <name>-controllers  Deployment, StatefulSet, DaemonSet, ReplicaSet, Job, CronJob, [Warn]

Every other shape (services, rbac, custom matchConstraints) has no controller in front of it,
so it gets one binding, <name>, with actions.single.

Each binding is annotated policy.posture.dev/binding: pods | controllers | services | rbac |
custom (which part it is; the first binding shares its name with the policy).

Policies with exceptions: labels read the namespace's posture-exceptions as params and have
every validation rewritten as exempt || (E); exceptions: none have neither.

Objects are built as dicts and serialized with toYaml, so CEL strings never need YAML quoting.

Usage: include "policy.renderValidating" (dict "model" $model "root" .)
The root (Chart, Release) is only used for labels; the probe chart passes its own.
*/}}
{{- define "policy.renderValidating" -}}
{{- $root := .root -}}
{{- $model := .model -}}
{{- $labels := include "policy.labels" $root | fromYaml -}}
{{- $excluded := $model.excludedNamespaces -}}
{{- range $p := $model.policies -}}
{{- if $p.enabled -}}
{{- $withExceptions := eq $p.exceptions "labels" -}}

{{- $annotations := dict "policy.posture.dev/tier" $p.tier "policy.posture.dev/description" $p.description -}}
{{- with $p.controls.pss -}}{{- $_ := set $annotations "policy.posture.dev/pss" . -}}{{- end -}}
{{- with $p.controls.nist -}}{{- $_ := set $annotations "policy.posture.dev/nist" (join ", " .) -}}{{- end -}}
{{- with $p.since -}}{{- $_ := set $annotations "policy.posture.dev/since" . -}}{{- end -}}

{{- $variables := $p.variables -}}
{{- $validations := list -}}
{{- if $withExceptions -}}
  {{- $variables = concat $p.variables (list (dict "name" "exempt" "expression" (include "policy.exemptExpression" (dict "kind" $p.kind "name" $p.name)))) -}}
{{- end -}}
{{- range $v := $p.validations -}}
  {{- $out := dict "expression" (ternary (printf "variables.exempt || (%s)" $v.expression) $v.expression $withExceptions) -}}
  {{- range $k := list "message" "messageExpression" "reason" -}}
    {{- if hasKey $v $k -}}{{- $_ := set $out $k (get $v $k) -}}{{- end -}}
  {{- end -}}
  {{- $validations = append $validations $out -}}
{{- end -}}

{{- /* Rules, match conditions, and bindings, by shape. Each half: name suffix, annotation,
       actions, and the rules its binding matches. */ -}}
{{- $match := dict -}}
{{- $matchConditions := list -}}
{{- $halves := list -}}
{{- if eq $p.shape "workloads" -}}
  {{- $podRules := include "policy.podRules" $p.operations | fromJsonArray -}}
  {{- $controllerRules := include "policy.controllerRules" $p.operations | fromJsonArray -}}
  {{- $match = dict "resourceRules" (concat $podRules $controllerRules) -}}
  {{- $matchConditions = include "policy.workloadMatchConditions" . | fromJsonArray -}}
  {{- $halves = list
    (dict "half" "pods" "suffix" "" "actions" $p.actions.pods "match" (dict "resourceRules" $podRules))
    (dict "half" "controllers" "suffix" "-controllers" "actions" $p.actions.controllers "match" (dict "resourceRules" $controllerRules)) -}}
{{- else -}}
  {{- if eq $p.shape "services" -}}
    {{- $match = dict "resourceRules" (include "policy.serviceRules" $p.operations | fromJsonArray) -}}
  {{- else if eq $p.shape "rbac" -}}
    {{- $match = dict "resourceRules" (include "policy.rbacRules" $p.operations | fromJsonArray) -}}
    {{- $matchConditions = include "policy.rbacMatchConditions" . | fromJsonArray -}}
  {{- else if eq $p.shape "custom" -}}
    {{- $match = dict "resourceRules" (include "policy.customRules" (dict "rules" $p.resources.resourceRules "operations" $p.operations) | fromJsonArray) -}}
    {{- if $p.resources.excludeResourceRules -}}
      {{- $_ := set $match "excludeResourceRules" (include "policy.customRules" (dict "rules" $p.resources.excludeResourceRules "operations" $p.operations) | fromJsonArray) -}}
    {{- end -}}
    {{- with $p.resources.matchPolicy -}}{{- $_ := set $match "matchPolicy" . -}}{{- end -}}
  {{- else -}}
    {{- fail (printf "policy: internal: %s: unknown shape %q" $p.source $p.shape) -}}
  {{- end -}}
  {{- $halves = list (dict "half" $p.shape "suffix" "" "actions" $p.actions.single "match" $match) -}}
{{- end -}}

{{- $spec := dict
  "failurePolicy" "Fail"
  "matchConstraints" $match
  "variables" $variables
  "validations" $validations -}}
{{- if $matchConditions -}}{{- $_ := set $spec "matchConditions" $matchConditions -}}{{- end -}}
{{- if $withExceptions -}}
  {{- $_ := set $spec "paramKind" (dict "apiVersion" "policy.posture.dev/v1alpha1" "kind" "PolicyExceptions") -}}
{{- end }}
---
{{ dict "apiVersion" "admissionregistration.k8s.io/v1" "kind" "ValidatingAdmissionPolicy" "metadata" (dict "name" $p.name "labels" $labels "annotations" $annotations) "spec" $spec | toYaml }}
{{- $namespaceSelector := dict "matchExpressions" (list (dict "key" "kubernetes.io/metadata.name" "operator" "NotIn" "values" $excluded)) -}}
{{- range $half := $halves -}}
{{- $bindingSpec := dict
  "policyName" $p.name
  "validationActions" $half.actions
  "matchResources" (merge (dict "namespaceSelector" $namespaceSelector) $half.match) -}}
{{- if $withExceptions -}}
  {{- $_ := set $bindingSpec "paramRef" (dict "name" "posture-exceptions" "parameterNotFoundAction" "Deny") -}}
{{- end }}
---
{{ dict "apiVersion" "admissionregistration.k8s.io/v1" "kind" "ValidatingAdmissionPolicyBinding" "metadata" (dict "name" (printf "%s%s" $p.name $half.suffix) "labels" $labels "annotations" (dict "policy.posture.dev/tier" $p.tier "policy.posture.dev/binding" $half.half)) "spec" $bindingSpec | toYaml }}
{{- end -}}
{{- end -}}
{{- end -}}
{{- end -}}
