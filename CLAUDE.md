# policy: context for Claude Code

`policy` is a Helm chart that installs a cluster's admission policies: strict validation
rules suitable for DoD or comparable civilian environments, plus optional mutations that fill
in safe defaults. It uses Kubernetes' built-in ValidatingAdmissionPolicy and
MutatingAdmissionPolicy, evaluated by the API server with no webhook, and installs the
`PolicyExceptions` CRD that the `posture` chart fills in each namespace.

It is **foundational**: it installs before anything else, so every workload the cluster ever
runs is checked at admission, including the platform's own.

The `posture` chart (per-namespace network, mesh, and exception settings; always the first
release in any namespace) is a separate companion. This chart never references it; the only
contract between them is the `PolicyExceptions` CRD, which this chart owns (see below).

The build order is in `docs/PLAN.md`. Work through it phase by phase.

## Principles (don't break these)

- **The baked-in baseline is fixed.** Baked-in policies are always on, always enforced, and
  ignore the global `enforcement` setting. Their rules are fixed in the chart (for example,
  `require-drop-all-capabilities` always means drop `ALL`, add nothing but
  `NET_BIND_SERVICE`). The single exception is `restrict-image-registries`, which can't work
  without the site's registry list, so it takes exactly that and nothing else. Any other key
  on a baked-in policy fails the render. A workload that genuinely needs more gets a
  per-workload exception through `posture`, which is reviewed and visible, instead of a
  cluster-wide loosening.
- **Settings live with their policy.** A policy that takes configuration declares it in its
  definition, and users set it under `policies.<name>`. There's no separate global settings
  block, so it's always clear which policy a value affects.
- **Enforce on Pods, warn on controllers.** Every pod is checked no matter what created it
  (Deployment, operator, Job, `kubectl run`), so the Pod is where policies deny. Deployments,
  StatefulSets, DaemonSets, ReplicaSets, Jobs, and CronJobs get a warning only, so whoever
  applies one sees the problem immediately, without the same violation being denied twice.
  This is the model Kubernetes' own Pod Security Admission uses.
- **Definitions are separate from rendering, in portable CEL.** Each policy is a data file
  under `definitions/`; templates turn it into Kubernetes objects. Definitions may use
  `object`, `oldObject`, `request`, `variables`, and `namespaceObject`, plus the standard
  Kubernetes CEL libraries: no `params` (exceptions are injected by the renderer), no
  `authorizer`. That keeps every definition reusable by a future Kyverno renderer (Kyverno's
  ValidatingPolicy and MutatingPolicy accept the same CEL), which isn't being built now.
- **Fail closed.** `failurePolicy: Fail` everywhere. Bindings use
  `parameterNotFoundAction: Deny`, so a namespace without its `posture-exceptions` object is
  denied rather than skipped. That covers controllers too: a missing param is a binding
  error, which denies whatever the binding's actions are, so even a `[Warn]` binding refuses
  a Deployment there. That's safe because `posture` always deploys first.
- **Exclusions are the chart's decision, not the user's.** The only namespace never evaluated
  is `kube-system`. There is no values key for excluding namespaces, because one would get
  used to exclude whole namespaces instead of requesting exceptions. Maintainers can extend
  the list in the chart (for example per distribution, later).
- **Values decide, not the cluster.** No `lookup`, no `.Capabilities` checks to choose what to
  render. `helm template` must produce exactly what `helm install` applies.
- **Policy names are a contract.** `posture` exceptions refer to policies by name and kind. A
  rename is a breaking change: keep the old name working for one minor version (or longer)
  and document it.
- **No workloads.** This chart renders policies, bindings, the CRD, and configuration only. It
  never runs a pod, so it can install before anything else exists and is never blocked by its
  own policies.
- **Messages tell people what to do.** Every validation message names the field, the required
  value, and how to get an exception, for example: "containers[*].securityContext.privileged
  must be false or unset. If this workload needs it, add a posture exception for
  disallow-privileged-containers."

## Values contract

```yaml
enforcement: enforce             # enforce | audit; optional and custom policies only

policies:
  # Baked-in: the only setting any baked-in policy accepts.
  restrict-image-registries:
    registries: []               # required: image prefixes, e.g. ["registry.site.mil/", "127.0.0.1:31999/"]

  # Optional: enabled, action (inherit | enforce | audit), and the policy's own settings.
  require-read-only-root-filesystem: { enabled: true, action: inherit }
  disallow-pod-exec: { enabled: false }
  disallow-mesh-opt-out:
    markers:                     # labels/annotations that take a pod out of the mesh
      - { kind: label, key: istio.io/dataplane-mode, value: none }
      - { kind: label, key: sidecar.istio.io/inject, value: "false" }
      - { kind: annotation, key: linkerd.io/inject, value: disabled }
  restrict-loadbalancer-services:
    namespaces: [ingress-gateway]   # only the ingress gateway needs an external address
  restrict-wildcard-rbac:        # RBAC is cluster-scoped, so it can't use namespace exceptions
    allowedRoles: []             # Role/ClusterRole names allowed to use "*"
  restrict-cluster-admin-binding:
    allowedSubjects: []          # subjects allowed to be bound to cluster-admin
  disallow-rbac-escalation-verbs:
    allowedRoles: []

custom:                          # user-defined policies, same format as definitions/ (see below)
  require-team-label:
    description: Every workload carries a team label.
    resources: workloads
    validations:
      - expression: "'team' in variables.workloadLabels"
        message: "Add a 'team' label to the pod template."

mutations:
  enabled: false
  apiVersion: admissionregistration.k8s.io/v1   # v1 on Kubernetes 1.36+; v1beta1 on 1.34-1.35
  policies:
    add-default-security-context: { enabled: true }
    set-image-pull-policy: { enabled: true }
```

### Actions

| Policy | Pods | Controllers |
|---|---|---|
| baked-in | `[Deny, Audit]`, always | `[Warn]` |
| optional or custom, `enforce` | `[Deny, Audit]` | `[Warn]` |
| optional or custom, `audit` | `[Audit]` | `[Warn]` |

Audit records come from Pods only, so the audit log has one entry per offending pod and no
duplicates from controllers. Warnings come from controllers only, so the person applying a
Deployment sees one warning per violation rather than one per replica.

Services, RBAC objects, and custom `matchConstraints` have no controller in front of them, so
they get a single binding: `[Deny, Audit]` at `enforce`, `[Audit, Warn]` at `audit` (the API
server doesn't allow `Deny` and `Warn` together, and under audit the person applying the
object should still see the problem).

## Definition format (`definitions/validating/<name>.yaml`, `definitions/mutating/<name>.yaml`)

```yaml
name: disallow-privileged-containers
tier: baked-in                   # baked-in | optional (custom policies are tier custom automatically)
default: { enabled: true, action: inherit }   # optional tier only
description: Containers may not run privileged or as Windows HostProcess.
controls:                        # shown as annotations and in docs/policies.md
  pss: baseline                  # Pod Security Standard level, if any
  nist: [AC-6, CM-7]             # suggested NIST SP 800-53 mapping; confirm with your ISSM
resources: workloads             # workloads | services | rbac | { resourceRules, excludeResourceRules?, matchPolicy? }
operations: [CREATE, UPDATE]     # also filled into any resourceRules entry without operations
exceptions: labels               # labels (default) | none; rbac is always none
settings: {}                     # settings this policy accepts under policies.<name>, e.g.
                                 #   registries: { type: list | string | bool, required: true,
                                 #                 default: ..., description: "shown when missing",
                                 #                 items: { JSON schema for list items } }
                                 # baked-in policies declare none, except restrict-image-registries
variables:
  - name: privileged
    expression: "variables.allContainers.exists(c, has(c.securityContext) && has(c.securityContext.privileged) && c.securityContext.privileged)"
validations:
  - expression: "!variables.privileged"
    message: "..."
```

`resources: workloads` means Pods (including the `pods/ephemeralcontainers` subresource) and
the controllers that create them: Deployment, StatefulSet, DaemonSet, ReplicaSet, Job,
CronJob. The renderer splits those across the two bindings described in "Actions".
`resources: services` is core `services`; `resources: rbac` is Roles, ClusterRoles, and their
bindings, and always skips names starting with `system:` (match condition `not-system`). A
`matchConstraints` block takes `resourceRules`, `excludeResourceRules`, and `matchPolicy`, never
a `namespaceSelector` or `objectSelector` (exclusions are the chart's decision); it's how
`disallow-pod-exec` matches CONNECT on `pods/exec`, and how custom policies cover other kinds.

`values.schema.json` is generated from the definitions (`make values-schema`, from
`test/values-schema/`), so every policy's settings, `enabled`, and `action` are checked and
documented; `make check-values-schema` fails if it's stale. Regenerate it after changing any
definition.

### Shared variables (injected for `resources: workloads`)

| Variable | Meaning |
|---|---|
| `podSpec` | `object.spec` for Pods, `spec.template.spec` for controllers, `spec.jobTemplate.spec.template.spec` for CronJobs |
| `podMeta` | the matching metadata (Pod metadata or the template's) |
| `workloadLabels` | `podMeta.labels`, or `{}` when absent |
| `allContainers` | containers, initContainers, and ephemeralContainers together |

Other policies that take exceptions (services, custom `matchConstraints`) get only
`workloadLabels`: the object's own `metadata.labels`, so a posture exception selects a Service
by its labels. Policies with `exceptions: none` get no shared variables.

A policy's settings are rendered into its expressions as CEL literals via `toJson`
(`["registry.site.mil/"]`), and its definition reads them as `variables.setting_<name>`. Fixed
values in baked-in policies (the safe sysctls, allowed SELinux types, allowed volume types,
`NET_BIND_SERVICE`) are written directly in the definition, not as settings.

### Exceptions

Each policy gets `paramKind` `policy.posture.dev/v1alpha1` `PolicyExceptions`, and both of its
bindings get `paramRef: { name: posture-exceptions, parameterNotFoundAction: Deny }` with no
namespace, so the object is read from the admitted object's namespace. The renderer adds an
`exempt` variable and rewrites every validation `E` as `variables.exempt || (E)`:

```
params.spec.exceptions.exists(e,
  e.policy.kind == 'ValidatingAdmissionPolicy' && e.policy.name == '<policy name>' &&
  e.workloads.exists(w, w.matchLabels.all(k,
    k in variables.workloadLabels && variables.workloadLabels[k] == w.matchLabels[k])))
```

(guarded with `has()` for an empty object). Because `workloadLabels` is the pod template's
labels on a controller and the pod's own labels on a Pod, an exception covers a Deployment's
warning and its Pods' admission alike. Mutating policies use the same check with
`MutatingAdmissionPolicy` as the kind.

An entry with empty `matchLabels` never matches (it would otherwise exempt every workload in
the namespace). Every workload policy also gets one match condition, `pod-spec-changed`: a Pod
UPDATE that leaves the spec unchanged (labels, annotations, finalizers, ownerReferences) isn't
evaluated, as in Pod Security Admission, so a pod that predates a policy or an expired
exception can still be cleaned up. `kubectl debug` (`pods/ephemeralcontainers`) is always
evaluated.

Policies with `exceptions: none` get no `paramKind`, no `paramRef`, and no `exempt` rewrite;
their allowlists come from their own settings instead, and their messages name that setting
(`policies.<name>.<setting>`) rather than a posture exception. That's every RBAC policy
(cluster-scoped objects have no namespace to read exceptions from:
`policies.restrict-wildcard-rbac.allowedRoles` and so on) and `disallow-pod-exec` (a CONNECT
request carries exec options, not the Pod, so there are no labels to match:
`policies.disallow-pod-exec.namespaces`).

### The PolicyExceptions CRD

**This chart owns the CRD: it defines it and deploys it.** The policies read it as their
parameters, so its schema and their CEL change together, in one repo. `posture` is a
producer: it creates `posture-exceptions` objects and pins to a released version of this CRD
for its own validation and e2e tests. (Kyverno works the same way: Kyverno owns its
PolicyException CRD, tenants just create the objects.)

- **Source file:** `crd/policy.posture.dev_policyexceptions.yaml`, plain YAML, the single source.
  Group `policy.posture.dev` (the CRD is `policyexceptions.policy.posture.dev`), so the group
  itself says this chart owns it.
  `templates/crd.yaml` renders it with `.Files.Get` and adds the chart's labels and
  `helm.sh/resource-policy: keep`, so uninstalling this chart never deletes every namespace's
  exceptions. It lives under `templates/`, not Helm's `crds/` folder, so Helm upgrades it.
- **Consumers fetch the same file** at a release tag and pin to it:
  `https://raw.githubusercontent.com/jimmybchopps/policy/<tag>/charts/policy/crd/policy.posture.dev_policyexceptions.yaml`
  (release assets come with phase 3c). `posture` pins to that tag.
- **Compatibility rule:** within an API version (`v1alpha1`, `v1beta1`, ...) changes are
  additive only (new optional fields). Anything else means a new API version, served alongside
  the old one until `posture` moves over.
- **Tests here:** schema-level checks that the CRD accepts an object shaped exactly like
  `posture`'s output (`examples/objects/posture-exceptions.yaml`; a subfolder, because every
  `examples/*.yaml` is a values file) and rejects bad ones (`test/e2e/fixtures/crd/invalid/`:
  missing `policy`, unknown `policy.kind`, empty `matchLabels` or `workloads`, a malformed
  `expires`). kubeconform checks both against a JSON schema generated from the CRD
  (`make crd-schema`, `test/crd-schema/`), and the e2e smoke test checks both in a real API
  server. Deeper rendering tests stay in `posture`.

## Naming

- A policy's ValidatingAdmissionPolicy (or MutatingAdmissionPolicy) is named for the
  definition: `disallow-host-path`.
- Its bindings: `disallow-host-path` (Pods) and `disallow-host-path-controllers` (warnings)
  for workload policies; a single `restrict-external-ips` for every other shape.
- Annotations on every policy: `policy.posture.dev/tier`, `policy.posture.dev/description`,
  `policy.posture.dev/pss`, `policy.posture.dev/nist`.
- Annotations on every binding: `policy.posture.dev/tier` and `policy.posture.dev/binding`
  (`pods`, `controllers`, `services`, `rbac`, or `custom`; the first binding shares its name
  with the policy, so this tells them apart).
- Custom policy names must not collide with built-in ones; collisions fail the render.

## Layout

```
charts/policy/
  Chart.yaml  values.yaml  values.schema.json (generated: make values-schema)
  definitions/
    validating/<name>.yaml        one file per policy (read with .Files.Glob)
    mutating/<name>.yaml
  crd/policy.posture.dev_policyexceptions.yaml   the PolicyExceptions CRD (owned here)
  templates/
    _lib.tpl                       shared variables, policy settings as CEL literals, actions, exclusions
    _model.tpl                     definitions + values + custom -> one normalized list
    validate.yaml                  builds the model on every render, so bad values always fail
    _render.tpl                    the model -> policies and bindings (validating.yaml calls it)
    crd.yaml
    validating.yaml                policies and their bindings
    mutating.yaml
    NOTES.txt
  tests/                           helm-unittest suites
fixtures/<policy>/allow/*.yaml     objects each policy must admit
fixtures/<policy>/deny/*.yaml      objects each policy must refuse (Pods, Services, RBAC) or warn on (controllers)
test/e2e/run.sh                    k3d: server-side dry-run every fixture, compare to expected
test/e2e/scenarios/                smoke, catalog, settings (enforcement audit, a custom policy)
test/e2e/values/                   values files for scenarios (also checked by tests/schema_test)
test/model-probe/                  test-only chart that renders the model for helm-unittest
test/definition-schema/            JSON schema for definitions (make check-definitions)
test/crd-schema/                   CRD -> JSON schema for kubeconform (make crd-schema)
test/values-schema/                definitions -> charts/policy/values.schema.json (make values-schema)
examples/objects/                  example objects (not values files), e.g. posture-exceptions.yaml
docs/PLAN.md                       build order
docs/policies.md                   generated catalog (make docs); CI checks it's current
```

## Testing

    make test           # lint, check-definitions, check-fixtures, check-values-schema, unittest,
                        # validate (kubeconform)
    make test-all-helm  # the same under every supported Helm version
    make e2e            # k3d, Kubernetes 1.36+ (MutatingAdmissionPolicy is v1 there)

The API server is the source of truth for CEL: fixtures are checked with
`kubectl apply --dry-run=server`, which runs admission without persisting anything. For a deny
fixture, a Pod must be refused, and a controller must be admitted with a `Warning:` naming the
policy.

Every policy needs allow and deny fixtures covering the kinds it applies to: a Pod, a
Deployment, and a CronJob for workloads; a Service for services; a ClusterRole and a Role for
rbac (`make check-fixtures` enforces it). A `matchConstraints` policy is covered by e2e
commands instead (`check_command`). Every fixture is compliant with every other policy,
optional ones included: the catalog scenario installs with every optional policy on at
`enforce`. In e2e (`test/e2e/scenarios/catalog.sh`) a deny fixture is checked in
`only-<policy>`, a namespace whose `posture-exceptions` excepts every other policy, so it must
be refused by its own policy alone, and in `exempt`, where every policy is excepted, so it must
be admitted with no warning. Policies with `exceptions: none` skip both; their deny fixtures
are denied in `apps`, and their allowlist settings get their own checks. "No warning" means no
warning from a ValidatingAdmissionPolicy: the API server adds its own (deprecations such as
`spec.externalIPs` on 1.37+), and those don't count.
Every exception path needs an e2e case:
exempt workload admitted with no warning, non-exempt denied, namespace without
`posture-exceptions` denied, `kube-system` never evaluated.

## Status

| Phase | Area | Status |
|---|---|---|
| 1 | Foundations: format, renderer, CRD, exceptions, first policies | 1a–1e done, e2e green; green CI run pending |
| 2 | Full catalog, custom policies, enforcement controls | 2a built; e2e run pending |
| 3 | Mutations, reporting, docs, release | not started |
