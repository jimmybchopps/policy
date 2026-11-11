{{/*
Shared building blocks for the model and the renderers: the namespaces never evaluated, the
variables every workload policy gets, the resource rules, settings as CEL literals, and the
action table. Each helper returns JSON; callers use fromJson / fromJsonArray.
*/}}

{{/*
The only namespaces never evaluated. This list is the chart's decision, not the user's: there
is no values key for it (CLAUDE.md, "Exclusions are the chart's decision").
*/}}
{{- define "policy.excludedNamespaces" -}}
{{- list "kube-system" | toJson -}}
{{- end -}}

{{/*
Names reserved for the renderer: the shared variables, the exemption check, and settings
(setting_<name>). Definitions can't declare variables with these names.
*/}}
{{- define "policy.reservedVariables" -}}
{{- list "podSpec" "podMeta" "workloadLabels" "allContainers" "exempt" | toJson -}}
{{- end -}}

{{/*
Variables injected first into every policy with resources: workloads, in this order (later
variables read earlier ones).

  podSpec         object.spec (Pod), spec.jobTemplate.spec.template.spec (CronJob),
                  spec.template.spec (every other controller)
  podMeta         the matching metadata; {} when a template has none
  workloadLabels  podMeta.labels, or {} when absent
  allContainers   containers + initContainers + ephemeralContainers

ephemeralContainers has its own type (EphemeralContainer), so that part is wrapped in dyn()
for the API server's type checker; so are the {} fallbacks for ObjectMeta.
*/}}
{{- define "policy.workloadVariables" -}}
{{- list
  (dict "name" "podSpec" "expression" "object.kind == 'Pod' ? object.spec : (object.kind == 'CronJob' ? object.spec.jobTemplate.spec.template.spec : object.spec.template.spec)")
  (dict "name" "podMeta" "expression" "object.kind == 'Pod' ? dyn(object.metadata) : (object.kind == 'CronJob' ? (has(object.spec.jobTemplate.spec.template.metadata) ? dyn(object.spec.jobTemplate.spec.template.metadata) : dyn({})) : (has(object.spec.template.metadata) ? dyn(object.spec.template.metadata) : dyn({})))")
  (dict "name" "workloadLabels" "expression" "has(variables.podMeta.labels) ? variables.podMeta.labels : {}")
  (dict "name" "allContainers" "expression" "variables.podSpec.containers + (has(variables.podSpec.initContainers) ? variables.podSpec.initContainers : []) + dyn(has(variables.podSpec.ephemeralContainers) ? variables.podSpec.ephemeralContainers : [])")
  | toJson -}}
{{- end -}}

{{/*
Resource rules for the Pod half of a workload policy (the subresource covers kubectl debug).
Usage: include "policy.podRules" (list "CREATE" "UPDATE") | fromJsonArray
*/}}
{{- define "policy.podRules" -}}
{{- list (dict "apiGroups" (list "") "apiVersions" (list "v1") "resources" (list "pods" "pods/ephemeralcontainers") "operations" .) | toJson -}}
{{- end -}}

{{/*
Resource rules for the controller half of a workload policy.
Usage: include "policy.controllerRules" (list "CREATE" "UPDATE") | fromJsonArray
*/}}
{{- define "policy.controllerRules" -}}
{{- list
  (dict "apiGroups" (list "apps") "apiVersions" (list "v1") "resources" (list "deployments" "statefulsets" "daemonsets" "replicasets") "operations" .)
  (dict "apiGroups" (list "batch") "apiVersions" (list "v1") "resources" (list "jobs" "cronjobs") "operations" .)
  | toJson -}}
{{- end -}}

{{/*
Resource rules for resources: services.
Usage: include "policy.serviceRules" (list "CREATE" "UPDATE") | fromJsonArray
*/}}
{{- define "policy.serviceRules" -}}
{{- list (dict "apiGroups" (list "") "apiVersions" (list "v1") "resources" (list "services") "operations" .) | toJson -}}
{{- end -}}

{{/*
Resource rules for resources: rbac. Roles and bindings, namespaced and cluster-scoped.
Usage: include "policy.rbacRules" (list "CREATE" "UPDATE") | fromJsonArray
*/}}
{{- define "policy.rbacRules" -}}
{{- list (dict "apiGroups" (list "rbac.authorization.k8s.io") "apiVersions" (list "v1") "resources" (list "roles" "clusterroles" "rolebindings" "clusterrolebindings") "operations" .) | toJson -}}
{{- end -}}

{{/*
Resource rules for a custom matchConstraints block: its resourceRules (and
excludeResourceRules), each rule without operations given the policy's.
Usage: include "policy.customRules" (dict "rules" $rules "operations" $ops) | fromJsonArray
*/}}
{{- define "policy.customRules" -}}
{{- $out := list -}}
{{- range $r := .rules | default list -}}
  {{- $rule := deepCopy $r -}}
  {{- if not (hasKey $rule "operations") -}}{{- $_ := set $rule "operations" $.operations -}}{{- end -}}
  {{- $out = append $out $rule -}}
{{- end -}}
{{- toJson $out -}}
{{- end -}}

{{/*
The one shared variable for policies that aren't workloads but take exceptions (services,
custom matchConstraints): workloadLabels, the object's own labels, so posture exceptions
select a Service (or any object) by its labels the way they select a workload by its pod
template's.
*/}}
{{- define "policy.objectVariables" -}}
{{- list (dict "name" "workloadLabels" "expression" "has(object.metadata.labels) ? object.metadata.labels : {}") | toJson -}}
{{- end -}}

{{/*
The match condition every rbac policy gets: names starting with system: belong to Kubernetes
(and the distribution) and are reconciled by the API server, so they're never evaluated.
*/}}
{{- define "policy.rbacMatchConditions" -}}
{{- list (dict "name" "not-system" "expression" "!object.metadata.name.startsWith('system:')") | toJson -}}
{{- end -}}

{{/*
A policy's resolved settings as variables, sorted by name: setting_<name> = the value as a CEL
literal. JSON is valid CEL for strings, lists, maps, and bools, including the
\u003c-style escapes toJson produces for <, > and &.
Usage: include "policy.settingVariables" $settings | fromJsonArray
*/}}
{{- define "policy.settingVariables" -}}
{{- $vars := list -}}
{{- range $name := keys . | sortAlpha -}}
{{- $vars = append $vars (dict "name" (printf "setting_%s" $name) "expression" (get $ $name | toJson)) -}}
{{- end -}}
{{- toJson $vars -}}
{{- end -}}

{{/*
The action table (CLAUDE.md, "Actions"). Workload policies have two bindings: audit records
come from Pods only and warnings from controllers only, so neither is duplicated. Every other
policy (services, rbac, custom matchConstraints) has a single binding; under audit it also
warns, so whoever applies the object still sees the problem (the API server doesn't allow Deny
and Warn together).
Usage: include "policy.actions" (dict "action" "enforce" "workloads" true) | fromJson
*/}}
{{- define "policy.actions" -}}
{{- if not (has .action (list "enforce" "audit")) -}}
{{- fail (printf "policy: internal: unknown action %q" .action) -}}
{{- end -}}
{{- if .workloads -}}
{{- if eq .action "enforce" -}}
{{- dict "pods" (list "Deny" "Audit") "controllers" (list "Warn") | toJson -}}
{{- else -}}
{{- dict "pods" (list "Audit") "controllers" (list "Warn") | toJson -}}
{{- end -}}
{{- else -}}
{{- if eq .action "enforce" -}}
{{- dict "single" (list "Deny" "Audit") | toJson -}}
{{- else -}}
{{- dict "single" (list "Audit" "Warn") | toJson -}}
{{- end -}}
{{- end -}}
{{- end -}}

{{/*
Match conditions every workload policy gets. A Pod UPDATE that leaves the spec unchanged
(labels, annotations, finalizers, ownerReferences) isn't evaluated, the same as Pod Security
Admission: otherwise finalizer removal and garbage-collector patches on a pod that predates a
policy (or an expired exception) would be denied, leaving it stuck. kubectl debug
(pods/ephemeralcontainers) and controller updates are always evaluated.
*/}}
{{- define "policy.workloadMatchConditions" -}}
{{- list (dict "name" "pod-spec-changed" "expression" "!(request.operation == 'UPDATE' && object.kind == 'Pod' && !(has(request.subResource) && request.subResource == 'ephemeralcontainers') && object.spec == oldObject.spec)") | toJson -}}
{{- end -}}

{{/*
The exempt variable: true when the namespace's posture-exceptions object (the binding's
params) lists this policy for a workload whose matchLabels all match the pod template's (or
the Pod's) labels. Guarded for an empty object. An entry with empty matchLabels never matches:
it would otherwise exempt every workload in the namespace.
Usage: include "policy.exemptExpression" (dict "kind" "ValidatingAdmissionPolicy" "name" "x")
*/}}
{{- define "policy.exemptExpression" -}}
{{- printf "has(params.spec) && has(params.spec.exceptions) && params.spec.exceptions.exists(e, e.policy.kind == '%s' && e.policy.name == '%s' && has(e.workloads) && e.workloads.exists(w, has(w.matchLabels) && size(w.matchLabels) > 0 && w.matchLabels.all(k, k in variables.workloadLabels && variables.workloadLabels[k] == w.matchLabels[k])))" .kind .name -}}
{{- end -}}
