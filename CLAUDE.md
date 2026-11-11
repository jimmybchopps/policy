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
  denied rather than skipped. That's safe because `posture` always deploys first.
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

## Definition format (`definitions/validating/<name>.yaml`, `definitions/mutating/<name>.yaml`)

```yaml
name: disallow-privileged-containers
tier: baked-in                   # baked-in | optional (custom policies are tier custom automatically)
default: { enabled: true, action: inherit }   # optional tier only
description: Containers may not run privileged or as Windows HostProcess.
controls:                        # shown as annotations and in docs/policies.md
  pss: baseline                  # Pod Security Standard level, if any
  nist: [AC-6, CM-7]             # suggested NIST SP 800-53 mapping; confirm with your ISSM
resources: workloads             # workloads | services | rbac | { custom matchConstraints }
operations: [CREATE, UPDATE]
settings: {}                     # settings this policy accepts under policies.<name>, e.g.
                                 #   registries: { type: list, required: true }
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

### Shared variables (injected for `resources: workloads`)

| Variable | Meaning |
|---|---|
| `podSpec` | `object.spec` for Pods, `spec.template.spec` for controllers, `spec.jobTemplate.spec.template.spec` for CronJobs |
| `podMeta` | the matching metadata (Pod metadata or the template's) |
| `workloadLabels` | `podMeta.labels`, or `{}` when absent |
| `allContainers` | containers, initContainers, and ephemeralContainers together |

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

Policies on **cluster-scoped** resources (RBAC) have no namespace to read exceptions from, so
they get no `paramKind`; their allowlists come from their own settings
(`policies.restrict-wildcard-rbac.allowedRoles` and so on) instead.

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
- **Consumers fetch the same file** at a release tag (for example from the repo or a release
  asset); `posture` pins to that tag.
- **Compatibility rule:** within an API version (`v1alpha1`, `v1beta1`, ...) changes are
  additive only (new optional fields). Anything else means a new API version, served alongside
  the old one until `posture` moves over.
- **Tests here:** schema-level checks that the CRD accepts an object shaped exactly like
  `posture`'s output (`examples/posture-exceptions.yaml`) and rejects bad ones (missing
  required fields, an unknown `policy.kind`). Deeper rendering tests stay in `posture`.

## Naming

- A policy's ValidatingAdmissionPolicy (or MutatingAdmissionPolicy) is named for the
  definition: `disallow-host-path`.
- Its bindings: `disallow-host-path` (Pods) and `disallow-host-path-controllers` (warnings).
- Annotations on every policy: `policy.posture.dev/tier`, `policy.posture.dev/description`,
  `policy.posture.dev/pss`, `policy.posture.dev/nist`.
- Custom policy names must not collide with built-in ones; collisions fail the render.

## Layout

```
charts/policy/
  Chart.yaml  values.yaml  values.schema.json
  definitions/
    validating/<name>.yaml        one file per policy (read with .Files.Glob)
    mutating/<name>.yaml
  crd/policy.posture.dev_policyexceptions.yaml   the PolicyExceptions CRD (owned here)
  templates/
    _lib.tpl                       shared variables, policy settings as CEL literals, actions, exclusions
    _model.tpl                     definitions + values + custom -> one normalized list
    crd.yaml
    validating.yaml                policies and their two bindings
    mutating.yaml
    NOTES.txt
  tests/                           helm-unittest suites
fixtures/<policy>/allow/*.yaml     objects each policy must admit
fixtures/<policy>/deny/*.yaml      objects each policy must refuse (Pods) or warn on (controllers)
test/e2e/run.sh                    k3d: server-side dry-run every fixture, compare to expected
docs/PLAN.md                       build order
docs/policies.md                   generated catalog (make docs); CI checks it's current
```

## Testing

    helm lint --strict charts/policy
    helm unittest charts/policy
    helm template t charts/policy -f examples/<x>.yaml | kubeconform -strict ...
    test/e2e/run.sh               # k3d, Kubernetes 1.36+ (MutatingAdmissionPolicy is v1 there)

The API server is the source of truth for CEL: fixtures are checked with
`kubectl apply --dry-run=server`, which runs admission without persisting anything. For a deny
fixture, a Pod must be refused, and a controller must be admitted with a `Warning:` naming the
policy.

Every policy needs at least one allow and one deny fixture, covering a Pod and a Deployment
(and a CronJob where the pod spec path differs). Every exception path needs an e2e case:
exempt workload admitted with no warning, non-exempt denied, namespace without
`posture-exceptions` denied, `kube-system` never evaluated.

## Status

| Phase | Area | Status |
|---|---|---|
| 1 | Foundations: format, renderer, CRD, exceptions, first policies | in progress (1a done) |
| 2 | Full catalog, custom policies, enforcement controls | not started |
| 3 | Mutations, reporting, docs, release | not started |
