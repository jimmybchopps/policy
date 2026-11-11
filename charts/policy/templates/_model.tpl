{{/*
The model: definitions, the policies values, and custom policies merged once into one
normalized list that every renderer reads. Renderers call:

  {{- $model := include "policy.modelFor" . | fromJson -}}

Shape:

  excludedNamespaces: [kube-system]
  policies:                               # sorted by name; disabled policies are kept
    - name: disallow-host-path
      source: definitions/validating/disallow-host-path.yaml   # or custom.<name>
      tier: baked-in | optional | custom
      kind: ValidatingAdmissionPolicy
      description, controls: { pss?, nist? }
      resources: workloads | services | rbac | { matchConstraints }
      operations: [CREATE, UPDATE]
      scope: namespaced | cluster         # cluster (rbac): no namespace to read exceptions from
      enabled: true
      action: enforce | audit             # resolved; never inherit
      actions: { pods: [Deny, Audit], controllers: [Warn] }
      settings: { <name>: value }         # resolved, defaults applied
      variables: [{ name, expression }]   # shared (workloads), setting_*, the definition's own
      validations: [{ expression, message | messageExpression, reason? }]

policy.model is a pure function of its input (dict "Values" ... "definitions" ...), so the
probe chart (test/model-probe) can feed it test definitions and values the public schema
doesn't accept yet. policy.modelFor loads the real definitions and passes the real values.

Every fail message has the form "policy: <path>: <problem>".
*/}}

{{/*
The definition files, parsed, each with source: <path>.
Usage: include "policy.definitions" . | fromJsonArray     (needs the chart root, for .Files)
*/}}
{{- define "policy.definitions" -}}
{{- $defs := list -}}
{{- range $path, $_ := .Files.Glob "definitions/validating/*.yaml" -}}
  {{- $def := $.Files.Get $path | fromYaml -}}
  {{- if hasKey $def "Error" -}}
    {{- fail (printf "policy: %s: not valid YAML: %s" $path $def.Error) -}}
  {{- end -}}
  {{- $defs = append $defs (set $def "source" $path) -}}
{{- end -}}
{{- toJson $defs -}}
{{- end -}}

{{/*
The model for this release: the real definitions and values.
Usage: include "policy.modelFor" . | fromJson
*/}}
{{- define "policy.modelFor" -}}
{{- include "policy.model" (dict "Values" .Values "definitions" (include "policy.definitions" . | fromJsonArray)) -}}
{{- end -}}

{{- define "policy.model" -}}
{{- $values := .Values | default dict -}}
{{- $policyValues := $values.policies | default dict -}}
{{- $custom := $values.custom | default dict -}}
{{- $enforcement := $values.enforcement | default "enforce" -}}
{{- if not (has $enforcement (list "enforce" "audit")) -}}
  {{- fail (printf "policy: enforcement: must be enforce or audit, not %q" $enforcement) -}}
{{- end -}}

{{- $byName := dict -}}
{{- range $def := .definitions -}}
  {{- if hasKey $byName $def.name -}}
    {{- fail (printf "policy: %s: the policy name %q is already defined in %s" $def.source $def.name (get $byName $def.name).source) -}}
  {{- end -}}
  {{- $out := dict -}}
  {{- $_ := include "policy.normalize" (dict "def" $def "tier" $def.tier "path" (printf "policies.%s" $def.name) "values" (get $policyValues $def.name) "enforcement" $enforcement "out" $out) -}}
  {{- $_ := set $byName $def.name $out -}}
{{- end -}}

{{- range $name := keys $policyValues | sortAlpha -}}
  {{- if not (hasKey $byName $name) -}}
    {{- fail (printf "policy: policies.%s: no such policy; known: %s" $name (keys $byName | sortAlpha | join ", ")) -}}
  {{- end -}}
{{- end -}}

{{- range $name := keys $custom | sortAlpha -}}
  {{- if hasKey $byName $name -}}
    {{- fail (printf "policy: custom.%s: %q is the name of a built-in policy (%s); choose another name" $name $name (get $byName $name).source) -}}
  {{- end -}}
  {{- $def := merge (dict "name" $name "source" (printf "custom.%s" $name)) (get $custom $name | default dict) -}}
  {{- $out := dict -}}
  {{- $_ := include "policy.normalize" (dict "def" $def "tier" "custom" "path" (printf "custom.%s" $name) "values" dict "enforcement" $enforcement "out" $out) -}}
  {{- $_ := set $byName $name $out -}}
{{- end -}}

{{- $policies := list -}}
{{- range $name := keys $byName | sortAlpha -}}
  {{- $policies = append $policies (get $byName $name) -}}
{{- end -}}
{{- dict "policies" $policies "excludedNamespaces" (include "policy.excludedNamespaces" . | fromJsonArray) | toJson -}}
{{- end -}}

{{/*
Normalize one policy into out.
Input: dict "def" <definition> "tier" <baked-in|optional|custom> "path" <values path>
            "values" <policies.<name>, or nil> "enforcement" <enforce|audit> "out" <dict>
*/}}
{{- define "policy.normalize" -}}
{{- $def := .def -}}
{{- $tier := .tier -}}
{{- $path := .path -}}
{{- $name := $def.name -}}
{{- $src := $def.source -}}
{{- $userValues := .values | default dict -}}
{{- $settingsSpec := $def.settings | default dict -}}

{{- if not (has $tier (list "baked-in" "optional" "custom")) -}}
  {{- fail (printf "policy: %s: tier must be baked-in or optional, not %q" $src $tier) -}}
{{- end -}}
{{- if hasSuffix ".yaml" $src -}}
  {{- if ne (base $src | trimSuffix ".yaml") $name -}}
    {{- fail (printf "policy: %s: name is %q; it must match the file name" $src $name) -}}
  {{- end -}}
{{- end -}}

{{- /* Definitions stay portable CEL: no params (exceptions are injected), no authorizer. */ -}}
{{- $exprs := list -}}
{{- range $def.variables -}}{{- $exprs = append $exprs (dict "where" (printf "variables.%s" .name) "cel" .expression) -}}{{- end -}}
{{- range $i, $v := $def.validations -}}
  {{- $exprs = append $exprs (dict "where" (printf "validations[%d].expression" $i) "cel" ($v.expression | default "")) -}}
  {{- if $v.messageExpression -}}{{- $exprs = append $exprs (dict "where" (printf "validations[%d].messageExpression" $i) "cel" $v.messageExpression) -}}{{- end -}}
{{- end -}}
{{- range $exprs -}}
  {{- $hit := regexFind "(^|[^A-Za-z0-9_.])(params|authorizer)([^A-Za-z0-9_]|$)" .cel -}}
  {{- if $hit -}}
    {{- fail (printf "policy: %s: %s uses %s; definitions are portable CEL and may not use params (exceptions are injected by the renderer) or authorizer" $src .where (regexFind "params|authorizer" $hit)) -}}
  {{- end -}}
{{- end -}}

{{- $reserved := include "policy.reservedVariables" . | fromJsonArray -}}
{{- range $def.variables -}}
  {{- if or (has .name $reserved) (hasPrefix "setting_" .name) -}}
    {{- fail (printf "policy: %s: variables.%s: the name is reserved (shared variables %s, exempt, and setting_*)" $src .name (join ", " (without $reserved "exempt"))) -}}
  {{- end -}}
{{- end -}}

{{- if and (eq $tier "baked-in") $settingsSpec (ne $name "restrict-image-registries") -}}
  {{- fail (printf "policy: %s: baked-in policies take no settings (only restrict-image-registries takes its registries); write fixed values into the definition" $src) -}}
{{- end -}}

{{- /* Every key the user set must be a setting the definition declares (or enabled/action on an optional policy). */ -}}
{{- $allowed := keys $settingsSpec -}}
{{- if eq $tier "optional" -}}{{- $allowed = concat $allowed (list "enabled" "action") -}}{{- end -}}
{{- range $key := keys $userValues | sortAlpha -}}
  {{- if not (has $key $allowed) -}}
    {{- if eq $tier "baked-in" -}}
      {{- fail (printf "policy: %s.%s: %s is baked-in: always on, always enforced, and takes %s. If a workload needs more, add a posture exception for %s" $path $key $name (ternary (printf "only %s" (keys $settingsSpec | sortAlpha | join ", ")) "no settings" (gt (len $settingsSpec) 0)) $name) -}}
    {{- else -}}
      {{- fail (printf "policy: %s.%s: unknown setting; %s accepts: %s" $path $key $name (sortAlpha $allowed | join ", ")) -}}
    {{- end -}}
  {{- end -}}
{{- end -}}

{{- $settings := dict -}}
{{- range $s := keys $settingsSpec | sortAlpha -}}
  {{- $spec := get $settingsSpec $s -}}
  {{- $zero := get (dict "list" list "string" "" "bool" false) $spec.type -}}
  {{- $value := $zero -}}
  {{- if hasKey $spec "default" -}}{{- $value = get $spec "default" -}}{{- end -}}
  {{- if hasKey $userValues $s -}}{{- $value = get $userValues $s -}}{{- end -}}
  {{- $kind := get (dict "list" "slice" "string" "string" "bool" "bool") $spec.type -}}
  {{- if not $kind -}}
    {{- fail (printf "policy: %s: settings.%s: type must be list, string, or bool, not %q" $src $s $spec.type) -}}
  {{- end -}}
  {{- if not (kindIs $kind $value) -}}
    {{- fail (printf "policy: %s.%s: must be a %s" $path $s $spec.type) -}}
  {{- end -}}
  {{- if and $spec.required (ne $spec.type "bool") (eq (len $value) 0) -}}
    {{- fail (printf "policy: %s.%s is required%s" $path $s (ternary (printf ": %s" $spec.description) "" (not (empty $spec.description)))) -}}
  {{- end -}}
  {{- $_ := set $settings $s $value -}}
{{- end -}}

{{- /* enabled and action. */ -}}
{{- $enabled := true -}}
{{- $action := "inherit" -}}
{{- if eq $tier "baked-in" -}}
  {{- $action = "enforce" -}}
{{- else if eq $tier "optional" -}}
  {{- $dflt := get $def "default" | default dict -}}
  {{- if not (and (hasKey $dflt "enabled") (hasKey $dflt "action")) -}}
    {{- fail (printf "policy: %s: an optional policy needs default.enabled and default.action" $src) -}}
  {{- end -}}
  {{- $enabled = get $dflt "enabled" -}}
  {{- $action = get $dflt "action" -}}
  {{- if hasKey $userValues "enabled" -}}{{- $enabled = get $userValues "enabled" -}}{{- end -}}
  {{- if hasKey $userValues "action" -}}{{- $action = get $userValues "action" -}}{{- end -}}
  {{- if not (kindIs "bool" $enabled) -}}
    {{- fail (printf "policy: %s.enabled: must be true or false" $path) -}}
  {{- end -}}
{{- end -}}
{{- if not (has $action (list "inherit" "enforce" "audit")) -}}
  {{- fail (printf "policy: %s.action: must be inherit, enforce, or audit, not %q" $path $action) -}}
{{- end -}}
{{- if eq $action "inherit" -}}{{- $action = .enforcement -}}{{- end -}}

{{- /* Variables: shared (workloads), then settings, then the definition's own. */ -}}
{{- $resources := $def.resources | default "workloads" -}}
{{- $variables := list -}}
{{- if eq (toString $resources) "workloads" -}}
  {{- $variables = include "policy.workloadVariables" . | fromJsonArray -}}
{{- end -}}
{{- $variables = concat $variables (include "policy.settingVariables" $settings | fromJsonArray) ($def.variables | default list) -}}

{{- $out := .out -}}
{{- $_ := set $out "name" $name -}}
{{- $_ := set $out "source" $src -}}
{{- $_ := set $out "tier" $tier -}}
{{- $_ := set $out "kind" "ValidatingAdmissionPolicy" -}}
{{- $_ := set $out "description" ($def.description | default "") -}}
{{- $_ := set $out "controls" ($def.controls | default dict) -}}
{{- $_ := set $out "resources" $resources -}}
{{- $_ := set $out "operations" ($def.operations | default (list "CREATE" "UPDATE")) -}}
{{- $_ := set $out "scope" (ternary "cluster" "namespaced" (eq (toString $resources) "rbac")) -}}
{{- $_ := set $out "enabled" $enabled -}}
{{- $_ := set $out "action" $action -}}
{{- $_ := set $out "actions" (include "policy.actions" $action | fromJson) -}}
{{- $_ := set $out "settings" $settings -}}
{{- $_ := set $out "variables" (default list $variables) -}}
{{- $_ := set $out "validations" ($def.validations | default list) -}}
{{- end -}}
