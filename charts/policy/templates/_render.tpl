{{/*
Renders the model's validating policies: per enabled policy, one ValidatingAdmissionPolicy and
two bindings (CLAUDE.md, "Actions" and "Exceptions"):

  <name>              Pods (pods, pods/ephemeralcontainers), actions.pods
  <name>-controllers  Deployment, StatefulSet, DaemonSet, ReplicaSet, Job, CronJob, [Warn]

Each binding is annotated policy.posture.dev/binding: pods | controllers (which half it is;
the Pod binding shares its name with the policy).

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
{{- $resources := toString $p.resources -}}
{{- if ne $resources "workloads" -}}
  {{- fail (printf "policy: %s: resources %s is rendered from phase 2" $p.source $resources) -}}
{{- end -}}

{{- $annotations := dict "policy.posture.dev/tier" $p.tier "policy.posture.dev/description" $p.description -}}
{{- with $p.controls.pss -}}{{- $_ := set $annotations "policy.posture.dev/pss" . -}}{{- end -}}
{{- with $p.controls.nist -}}{{- $_ := set $annotations "policy.posture.dev/nist" (join ", " .) -}}{{- end -}}

{{- $variables := concat $p.variables (list (dict "name" "exempt" "expression" (include "policy.exemptExpression" (dict "kind" $p.kind "name" $p.name)))) -}}
{{- $validations := list -}}
{{- range $v := $p.validations -}}
  {{- $out := dict "expression" (printf "variables.exempt || (%s)" $v.expression) -}}
  {{- range $k := list "message" "messageExpression" "reason" -}}
    {{- if hasKey $v $k -}}{{- $_ := set $out $k (get $v $k) -}}{{- end -}}
  {{- end -}}
  {{- $validations = append $validations $out -}}
{{- end -}}

{{- $podRules := include "policy.podRules" $p.operations | fromJsonArray -}}
{{- $controllerRules := include "policy.controllerRules" $p.operations | fromJsonArray -}}
{{- $spec := dict
  "failurePolicy" "Fail"
  "matchConstraints" (dict "resourceRules" (concat $podRules $controllerRules))
  "matchConditions" (include "policy.workloadMatchConditions" . | fromJsonArray)
  "variables" $variables
  "validations" $validations -}}
{{- if eq $p.scope "namespaced" -}}
  {{- $_ := set $spec "paramKind" (dict "apiVersion" "policy.posture.dev/v1alpha1" "kind" "PolicyExceptions") -}}
{{- end }}
---
{{ dict "apiVersion" "admissionregistration.k8s.io/v1" "kind" "ValidatingAdmissionPolicy" "metadata" (dict "name" $p.name "labels" $labels "annotations" $annotations) "spec" $spec | toYaml }}
{{- $namespaceSelector := dict "matchExpressions" (list (dict "key" "kubernetes.io/metadata.name" "operator" "NotIn" "values" $excluded)) -}}
{{- range $half := list (dict "half" "pods" "suffix" "" "actions" $p.actions.pods "rules" $podRules) (dict "half" "controllers" "suffix" "-controllers" "actions" $p.actions.controllers "rules" $controllerRules) -}}
{{- $bindingSpec := dict
  "policyName" $p.name
  "validationActions" $half.actions
  "matchResources" (dict "namespaceSelector" $namespaceSelector "resourceRules" $half.rules) -}}
{{- if eq $p.scope "namespaced" -}}
  {{- $_ := set $bindingSpec "paramRef" (dict "name" "posture-exceptions" "parameterNotFoundAction" "Deny") -}}
{{- end }}
---
{{ dict "apiVersion" "admissionregistration.k8s.io/v1" "kind" "ValidatingAdmissionPolicyBinding" "metadata" (dict "name" (printf "%s%s" $p.name $half.suffix) "labels" $labels "annotations" (dict "policy.posture.dev/tier" $p.tier "policy.posture.dev/binding" $half.half)) "spec" $bindingSpec | toYaml }}
{{- end -}}
{{- end -}}
{{- end -}}
{{- end -}}
