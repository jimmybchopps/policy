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
The action table (CLAUDE.md, "Actions"). Audit records come from Pods only and warnings from
controllers only, so neither is duplicated.
Usage: include "policy.actions" "enforce" | fromJson
*/}}
{{- define "policy.actions" -}}
{{- if eq . "enforce" -}}
{{- dict "pods" (list "Deny" "Audit") "controllers" (list "Warn") | toJson -}}
{{- else if eq . "audit" -}}
{{- dict "pods" (list "Audit") "controllers" (list "Warn") | toJson -}}
{{- else -}}
{{- fail (printf "policy: internal: unknown action %q" .) -}}
{{- end -}}
{{- end -}}
