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
      resources: workloads | services | rbac | { resourceRules, ... }   # as defined
      shape: workloads | services | rbac | custom   # what resources is; picks rules and bindings
      operations: [CREATE, UPDATE]
      exceptions: labels | none           # none: no paramKind, no exempt (rbac always)
      since: "0.N"                        # when the definition sets it: the chart minor that introduced it
      introducing: true                   # since is this chart's minor (its first release)
      newAudit: true                      # an optional policy auditing only because it's introducing
      enabled: true
      action: enforce | audit             # resolved; never inherit
      actions: { pods: [Deny, Audit], controllers: [Warn] }   # workloads
               { single: [Deny, Audit] }                      # every other shape
      settings: { <name>: value }         # resolved, defaults applied
      variables: [{ name, expression }]   # shared (workloads), setting_*, the definition's own
      validations: [{ expression, message | messageExpression, reason? }]

The model also carries release: the chart's MAJOR.MINOR ("0.1"), against which since is read,
and the mutations (definitions/mutating/), each normalized the same way:

  mutationApiVersion: admissionregistration.k8s.io/v1 | v1beta1   # mutations.apiVersion
  mutations:                              # sorted by name; disabled ones are kept
    - name: add-default-security-context
      source: definitions/mutating/add-default-security-context.yaml
      kind: MutatingAdmissionPolicy
      description, controls
      enabled: true                       # mutations.enabled and the mutation's own enabled
      settings: { <name>: value }         # resolved, defaults applied
      variables: [{ name, expression }]   # workloadLabels, setting_*, the definition's own
      mutations: [{ patchType, expression }]

policy.model is a pure function of its input (dict "Values" ... "definitions" ...
"chartVersion" ...), so the
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
  {{- /* Messages tell people what to do (CLAUDE.md): every built-in message names its exception,
         or, for a policy without exceptions, the setting that allows it. Checked here, on the
         real files only, so the probe's test definitions stay minimal. */ -}}
  {{- $none := or (eq (toString $def.exceptions) "none") (eq (toString $def.resources) "rbac") -}}
  {{- $want := ternary (printf "policies.%s." $def.name) (printf "posture exception for %s" $def.name) $none -}}
  {{- range $i, $v := $def.validations -}}
    {{- if and $v.message (not (contains $want $v.message)) -}}
      {{- if $none -}}
        {{- fail (printf "policy: %s: validations[%d].message must name the setting that allows it (%s<setting>)" $path $i $want) -}}
      {{- else -}}
        {{- fail (printf "policy: %s: validations[%d].message must say how to get an exception: \"... add a posture exception for %s.\"" $path $i $def.name) -}}
      {{- end -}}
    {{- end -}}
  {{- end -}}
  {{- $defs = append $defs (set $def "source" $path) -}}
{{- end -}}
{{- toJson $defs -}}
{{- end -}}

{{/*
The mutation definition files (definitions/mutating/), parsed, each with source: <path>.
Usage: include "policy.mutationDefinitions" . | fromJsonArray     (needs the chart root)
*/}}
{{- define "policy.mutationDefinitions" -}}
{{- $defs := list -}}
{{- range $path, $_ := .Files.Glob "definitions/mutating/*.yaml" -}}
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
{{- include "policy.model" (dict "Values" .Values "definitions" (include "policy.definitions" . | fromJsonArray) "mutationDefinitions" (include "policy.mutationDefinitions" . | fromJsonArray) "chartVersion" .Chart.Version) -}}
{{- end -}}

{{- define "policy.model" -}}
{{- $values := .Values | default dict -}}
{{- $policyValues := $values.policies | default dict -}}
{{- $custom := $values.custom | default dict -}}
{{- $enforcement := $values.enforcement | default "enforce" -}}
{{- if not (has $enforcement (list "enforce" "audit")) -}}
  {{- fail (printf "policy: enforcement: must be enforce or audit, not %q" $enforcement) -}}
{{- end -}}
{{- $chartVersion := .chartVersion | default "0.0.0" | toString -}}
{{- $release := regexFind "^[0-9]+\\.[0-9]+" $chartVersion -}}
{{- if not $release -}}
  {{- fail (printf "policy: Chart.yaml version %q: not a semantic version" $chartVersion) -}}
{{- end -}}
{{- $rel := dict "release" $release "chartVersion" $chartVersion -}}

{{- $byName := dict -}}
{{- range $def := .definitions -}}
  {{- if hasKey $byName $def.name -}}
    {{- fail (printf "policy: %s: the policy name %q is already defined in %s" $def.source $def.name (get $byName $def.name).source) -}}
  {{- end -}}
  {{- $out := dict -}}
  {{- $_ := include "policy.normalize" (dict "def" $def "tier" $def.tier "path" (printf "policies.%s" $def.name) "values" (get $policyValues $def.name) "enforcement" $enforcement "rel" $rel "out" $out) -}}
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
  {{- $entry := get $custom $name | default dict -}}
  {{- $def := merge (dict "name" $name "source" (printf "custom.%s" $name)) (omit $entry "enabled" "action") -}}
  {{- $out := dict -}}
  {{- $_ := include "policy.normalize" (dict "def" $def "tier" "custom" "path" (printf "custom.%s" $name) "values" (pick $entry "enabled" "action") "enforcement" $enforcement "rel" $rel "out" $out) -}}
  {{- $_ := set $byName $name $out -}}
{{- end -}}

{{- $policies := list -}}
{{- range $name := keys $byName | sortAlpha -}}
  {{- $policies = append $policies (get $byName $name) -}}
{{- end -}}

{{- /* Mutations: off unless mutations.enabled; each also has its own enabled. */ -}}
{{- $mutationValues := $values.mutations | default dict -}}
{{- range $key := keys $mutationValues | sortAlpha -}}
  {{- if not (has $key (list "enabled" "apiVersion" "policies")) -}}
    {{- fail (printf "policy: mutations.%s: unknown key; mutations takes enabled, apiVersion, policies" $key) -}}
  {{- end -}}
{{- end -}}
{{- $mutationsOn := $mutationValues.enabled | default false -}}
{{- if not (kindIs "bool" $mutationsOn) -}}
  {{- fail "policy: mutations.enabled: must be true or false" -}}
{{- end -}}
{{- $mutationApiVersion := $mutationValues.apiVersion | default "admissionregistration.k8s.io/v1" -}}
{{- if not (has $mutationApiVersion (list "admissionregistration.k8s.io/v1" "admissionregistration.k8s.io/v1beta1")) -}}
  {{- fail (printf "policy: mutations.apiVersion: must be admissionregistration.k8s.io/v1 (Kubernetes 1.36+) or admissionregistration.k8s.io/v1beta1 (1.34-1.35), not %q" $mutationApiVersion) -}}
{{- end -}}
{{- $perMutation := $mutationValues.policies | default dict -}}
{{- $mutationsByName := dict -}}
{{- range $def := .mutationDefinitions -}}
  {{- if hasKey $mutationsByName $def.name -}}
    {{- fail (printf "policy: %s: the mutation name %q is already defined in %s" $def.source $def.name (get $mutationsByName $def.name).source) -}}
  {{- end -}}
  {{- if hasKey $byName $def.name -}}
    {{- fail (printf "policy: %s: %q is already the name of a validating policy (%s); posture exceptions name policies, so mutations need names of their own" $def.source $def.name (get $byName $def.name).source) -}}
  {{- end -}}
  {{- $out := dict -}}
  {{- $_ := include "policy.normalizeMutation" (dict "def" $def "values" (get $perMutation $def.name) "on" $mutationsOn "out" $out) -}}
  {{- $_ := set $mutationsByName $def.name $out -}}
{{- end -}}
{{- range $name := keys $perMutation | sortAlpha -}}
  {{- if not (hasKey $mutationsByName $name) -}}
    {{- fail (printf "policy: mutations.policies.%s: no such mutation; known: %s" $name (keys $mutationsByName | sortAlpha | join ", ")) -}}
  {{- end -}}
{{- end -}}
{{- $mutations := list -}}
{{- range $name := keys $mutationsByName | sortAlpha -}}
  {{- $mutations = append $mutations (get $mutationsByName $name) -}}
{{- end -}}

{{- dict "policies" $policies "mutations" $mutations "mutationApiVersion" $mutationApiVersion "release" $release "excludedNamespaces" (include "policy.excludedNamespaces" . | fromJsonArray) | toJson -}}
{{- end -}}

{{/*
Normalize one policy into out.
Input: dict "def" <definition> "tier" <baked-in|optional|custom> "path" <values path>
            "values" <policies.<name> (custom: the entry's enabled and action), or nil>
            "enforcement" <enforce|audit> "rel" <dict "release" "0.N" "chartVersion" ...> "out" <dict>
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

{{- /* since: the chart minor that introduced the policy (absent: the original catalog). An
       optional policy audits by default in that minor; see "enabled and action" below. */ -}}
{{- $since := "" -}}
{{- $introducing := false -}}
{{- if hasKey $def "since" -}}
  {{- if eq $tier "custom" -}}
    {{- fail (printf "policy: %s: since: only built-in policies have since (it marks the chart release that introduced them)" $src) -}}
  {{- end -}}
  {{- if not (and (kindIs "string" $def.since) (regexMatch "^[0-9]+\\.[0-9]+$" $def.since)) -}}
    {{- fail (printf "policy: %s: since: must be \"MAJOR.MINOR\" (the chart version that introduced it), not %v" $src $def.since) -}}
  {{- end -}}
  {{- $since = $def.since -}}
  {{- $s := splitList "." $since -}}
  {{- $r := splitList "." .rel.release -}}
  {{- $later := or (gt (atoi (index $s 0)) (atoi (index $r 0))) (and (eq (atoi (index $s 0)) (atoi (index $r 0))) (gt (atoi (index $s 1)) (atoi (index $r 1)))) -}}
  {{- if $later -}}
    {{- fail (printf "policy: %s: since %s is later than this chart (%s); bump Chart.yaml's version in the same change" $src $since .rel.chartVersion) -}}
  {{- end -}}
  {{- $introducing = eq $since .rel.release -}}
{{- end -}}

{{- /* What resources is (its shape), and whether the policy takes exceptions. */ -}}
{{- $resources := $def.resources | default "workloads" -}}
{{- $shape := "" -}}
{{- if kindIs "map" $resources -}}
  {{- $shape = "custom" -}}
  {{- range $key := list "namespaceSelector" "objectSelector" -}}
    {{- if hasKey $resources $key -}}
      {{- fail (printf "policy: %s: resources.%s: not allowed; which namespaces are never evaluated is the chart's decision (kube-system only). Use posture exceptions for individual workloads" $src $key) -}}
    {{- end -}}
  {{- end -}}
  {{- range $key := keys $resources | sortAlpha -}}
    {{- if not (has $key (list "resourceRules" "excludeResourceRules" "matchPolicy")) -}}
      {{- fail (printf "policy: %s: resources.%s: unknown key; a matchConstraints block takes resourceRules, excludeResourceRules, matchPolicy" $src $key) -}}
    {{- end -}}
  {{- end -}}
  {{- if not $resources.resourceRules -}}
    {{- fail (printf "policy: %s: resources.resourceRules: required (at least one rule)" $src) -}}
  {{- end -}}
{{- else if has (toString $resources) (list "workloads" "services" "rbac") -}}
  {{- $shape = toString $resources -}}
{{- else -}}
  {{- fail (printf "policy: %s: resources must be workloads, services, rbac, or a matchConstraints block, not %q" $src (toString $resources)) -}}
{{- end -}}
{{- $exceptions := $def.exceptions | default (ternary "none" "labels" (eq $shape "rbac")) -}}
{{- if not (has $exceptions (list "labels" "none")) -}}
  {{- fail (printf "policy: %s: exceptions must be labels or none, not %q" $src $exceptions) -}}
{{- end -}}
{{- if and (eq $shape "rbac") (ne $exceptions "none") -}}
  {{- fail (printf "policy: %s: exceptions: rbac objects are cluster-scoped or have no labels to match, so rbac policies take exceptions: none (allowlist settings instead)" $src) -}}
{{- end -}}

{{- /* Definitions stay portable CEL: no params (exceptions are injected), no authorizer. */ -}}
{{- $exprs := list -}}
{{- range $def.variables -}}{{- $exprs = append $exprs (dict "where" (printf "variables.%s" .name) "cel" .expression) -}}{{- end -}}
{{- range $i, $v := $def.validations -}}
  {{- $exprs = append $exprs (dict "where" (printf "validations[%d].expression" $i) "cel" ($v.expression | default "")) -}}
  {{- if $v.messageExpression -}}{{- $exprs = append $exprs (dict "where" (printf "validations[%d].messageExpression" $i) "cel" $v.messageExpression) -}}{{- end -}}
{{- end -}}
{{- $_ := include "policy.checkPortable" (dict "src" $src "exprs" $exprs) -}}

{{- $_ := include "policy.checkReserved" (dict "src" $src "variables" $def.variables) -}}

{{- if and (eq $tier "baked-in") $settingsSpec (ne $name "restrict-image-registries") -}}
  {{- fail (printf "policy: %s: baked-in policies take no settings (only restrict-image-registries takes its registries); write fixed values into the definition" $src) -}}
{{- end -}}

{{- /* Every key the user set must be a setting the definition declares (or enabled/action on an optional policy). */ -}}
{{- $allowed := keys $settingsSpec -}}
{{- if has $tier (list "optional" "custom") -}}{{- $allowed = concat $allowed (list "enabled" "action") -}}{{- end -}}
{{- range $key := keys $userValues | sortAlpha -}}
  {{- if not (has $key $allowed) -}}
    {{- if eq $tier "baked-in" -}}
      {{- fail (printf "policy: %s.%s: %s is baked-in: always on, always enforced, and takes %s. If a workload needs more, add a posture exception for %s" $path $key $name (ternary (printf "only %s" (keys $settingsSpec | sortAlpha | join ", ")) "no settings" (gt (len $settingsSpec) 0)) $name) -}}
    {{- else -}}
      {{- fail (printf "policy: %s.%s: unknown setting; %s accepts: %s" $path $key $name (sortAlpha $allowed | join ", ")) -}}
    {{- end -}}
  {{- end -}}
{{- end -}}
{{- $settings := include "policy.resolveSettings" (dict "spec" $settingsSpec "values" $userValues "path" $path "src" $src) | fromJson -}}

{{- /* enabled and action. */ -}}
{{- $enabled := true -}}
{{- $action := "inherit" -}}
{{- $newAudit := false -}}
{{- if eq $tier "baked-in" -}}
  {{- $action = "enforce" -}}
{{- else -}}
  {{- if eq $tier "optional" -}}
    {{- $dflt := get $def "default" | default dict -}}
    {{- if not (and (hasKey $dflt "enabled") (hasKey $dflt "action")) -}}
      {{- fail (printf "policy: %s: an optional policy needs default.enabled and default.action" $src) -}}
    {{- end -}}
    {{- $enabled = get $dflt "enabled" -}}
    {{- $action = get $dflt "action" -}}
    {{- /* New in this minor: audit first, so an upgrade never starts denying what already runs. */ -}}
    {{- if and $introducing (ne $action "audit") (not (hasKey $userValues "action")) -}}
      {{- $action = "audit" -}}
      {{- $newAudit = true -}}
    {{- end -}}
  {{- end -}}
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

{{- /* Variables: shared (workloads; workloadLabels alone for other objects that take
       exceptions), then settings, then the definition's own. */ -}}
{{- $variables := list -}}
{{- if eq $shape "workloads" -}}
  {{- $variables = include "policy.workloadVariables" . | fromJsonArray -}}
{{- else if eq $exceptions "labels" -}}
  {{- $variables = include "policy.objectVariables" . | fromJsonArray -}}
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
{{- $_ := set $out "shape" $shape -}}
{{- $_ := set $out "operations" ($def.operations | default (list "CREATE" "UPDATE")) -}}
{{- $_ := set $out "exceptions" $exceptions -}}
{{- if $since -}}{{- $_ := set $out "since" $since -}}{{- end -}}
{{- if $introducing -}}{{- $_ := set $out "introducing" true -}}{{- end -}}
{{- if $newAudit -}}{{- $_ := set $out "newAudit" true -}}{{- end -}}
{{- $_ := set $out "enabled" $enabled -}}
{{- $_ := set $out "action" $action -}}
{{- $_ := set $out "actions" (include "policy.actions" (dict "action" $action "workloads" (eq $shape "workloads")) | fromJson) -}}
{{- $_ := set $out "settings" $settings -}}
{{- $_ := set $out "variables" (default list $variables) -}}
{{- $_ := set $out "validations" ($def.validations | default list) -}}
{{- end -}}

{{/*
Fails if any expression uses params or authorizer: definitions are portable CEL (exceptions are
injected by the renderer).
Input: dict "src" <source> "exprs" (list (dict "where" <field> "cel" <expression>))
*/}}
{{- define "policy.checkPortable" -}}
{{- $src := .src -}}
{{- range .exprs -}}
  {{- $hit := regexFind "(^|[^A-Za-z0-9_.])(params|authorizer)([^A-Za-z0-9_]|$)" .cel -}}
  {{- if $hit -}}
    {{- fail (printf "policy: %s: %s uses %s; definitions are portable CEL and may not use params (exceptions are injected by the renderer) or authorizer" $src .where (regexFind "params|authorizer" $hit)) -}}
  {{- end -}}
{{- end -}}
{{- end -}}

{{/*
Fails if a definition declares a variable whose name the renderer reserves.
Input: dict "src" <source> "variables" <the definition's variables>
*/}}
{{- define "policy.checkReserved" -}}
{{- $src := .src -}}
{{- $reserved := include "policy.reservedVariables" . | fromJsonArray -}}
{{- range .variables -}}
  {{- if or (has .name $reserved) (hasPrefix "setting_" .name) -}}
    {{- fail (printf "policy: %s: variables.%s: the name is reserved (shared variables %s, exempt, and setting_*)" $src .name (join ", " (without $reserved "exempt"))) -}}
  {{- end -}}
{{- end -}}
{{- end -}}

{{/*
A definition's settings, resolved: each declared setting's default, overridden by the user's
value, type-checked, and required ones present. The caller checks for undeclared keys.
Input: dict "spec" <settings> "values" <the user's values> "path" <values path> "src" <source>
Output: JSON object { <name>: value }
*/}}
{{- define "policy.resolveSettings" -}}
{{- $settingsSpec := .spec | default dict -}}
{{- $userValues := .values | default dict -}}
{{- $path := .path -}}
{{- $src := .src -}}
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
  {{- if and $spec.pattern (eq $spec.type "string") (not (regexMatch $spec.pattern $value)) -}}
    {{- fail (printf "policy: %s.%s: %q doesn't match %s" $path $s $value $spec.pattern) -}}
  {{- end -}}
  {{- $_ := set $settings $s $value -}}
{{- end -}}
{{- toJson $settings -}}
{{- end -}}

{{/*
Normalize one mutation into out (see the model's shape above).
Input: dict "def" <mutation definition> "values" <mutations.policies.<name>, or nil>
            "on" <mutations.enabled> "out" <dict>
*/}}
{{- define "policy.normalizeMutation" -}}
{{- $def := .def -}}
{{- $name := $def.name -}}
{{- $src := $def.source -}}
{{- $path := printf "mutations.policies.%s" $name -}}
{{- $userValues := .values | default dict -}}
{{- $settingsSpec := $def.settings | default dict -}}
{{- if hasSuffix ".yaml" $src -}}
  {{- if ne (base $src | trimSuffix ".yaml") $name -}}
    {{- fail (printf "policy: %s: name is %q; it must match the file name" $src $name) -}}
  {{- end -}}
{{- end -}}
{{- if not $def.mutations -}}
  {{- fail (printf "policy: %s: mutations: required (at least one)" $src) -}}
{{- end -}}

{{- $exprs := list -}}
{{- range $def.variables -}}{{- $exprs = append $exprs (dict "where" (printf "variables.%s" .name) "cel" .expression) -}}{{- end -}}
{{- range $i, $m := $def.mutations -}}
  {{- if not (has $m.patchType (list "ApplyConfiguration" "JSONPatch")) -}}
    {{- fail (printf "policy: %s: mutations[%d].patchType: must be ApplyConfiguration or JSONPatch, not %q" $src $i (toString $m.patchType)) -}}
  {{- end -}}
  {{- $exprs = append $exprs (dict "where" (printf "mutations[%d].expression" $i) "cel" ($m.expression | default "")) -}}
{{- end -}}
{{- $_ := include "policy.checkPortable" (dict "src" $src "exprs" $exprs) -}}
{{- $_ := include "policy.checkReserved" (dict "src" $src "variables" $def.variables) -}}

{{- $allowed := concat (keys $settingsSpec) (list "enabled") -}}
{{- range $key := keys $userValues | sortAlpha -}}
  {{- if not (has $key $allowed) -}}
    {{- fail (printf "policy: %s.%s: unknown setting; %s accepts: %s" $path $key $name (sortAlpha $allowed | join ", ")) -}}
  {{- end -}}
{{- end -}}
{{- $settings := include "policy.resolveSettings" (dict "spec" $settingsSpec "values" $userValues "path" $path "src" $src) | fromJson -}}

{{- $dflt := $def.default | default dict -}}
{{- if not (hasKey $dflt "enabled") -}}
  {{- fail (printf "policy: %s: a mutation needs default.enabled" $src) -}}
{{- end -}}
{{- $enabled := get $dflt "enabled" -}}
{{- if hasKey $userValues "enabled" -}}{{- $enabled = get $userValues "enabled" -}}{{- end -}}
{{- if not (kindIs "bool" $enabled) -}}
  {{- fail (printf "policy: %s.enabled: must be true or false" $path) -}}
{{- end -}}

{{- /* Pods only: workloadLabels is the Pod's own labels (the workload variables would read
       controller fields a Pod doesn't have). */ -}}
{{- $variables := concat (include "policy.objectVariables" . | fromJsonArray) (include "policy.settingVariables" $settings | fromJsonArray) ($def.variables | default list) -}}

{{- $out := .out -}}
{{- $_ := set $out "name" $name -}}
{{- $_ := set $out "source" $src -}}
{{- $_ := set $out "kind" "MutatingAdmissionPolicy" -}}
{{- $_ := set $out "description" ($def.description | default "") -}}
{{- $_ := set $out "controls" ($def.controls | default dict) -}}
{{- $_ := set $out "enabled" (and .on $enabled) -}}
{{- $_ := set $out "settings" $settings -}}
{{- $_ := set $out "variables" $variables -}}
{{- $_ := set $out "mutations" $def.mutations -}}
{{- end -}}
