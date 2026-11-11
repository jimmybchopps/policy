# policy: development plan

Three phases. Phase 1 proves the whole pipeline (definition format, renderer, the exceptions
contract with `posture`, fixtures, e2e) on a handful of policies. Phase 2 fills in the full
catalog and custom policies. Phase 3 adds mutations, reporting, and release polish. The
values contract and definition format are in `CLAUDE.md`.

Version floors:

- Validation: Kubernetes 1.30+ (ValidatingAdmissionPolicy is GA there).
- Mutation: Kubernetes 1.36+, where MutatingAdmissionPolicy is GA (`v1`, on by default). On
  1.34 and 1.35 it's `v1beta1` and needs the `MutatingAdmissionPolicy` feature gate plus
  `--runtime-config=admissionregistration.k8s.io/v1beta1=true`.

Not in scope now: a Kyverno renderer. Definitions are written in portable CEL and kept
separate from rendering so one can be added later without rewriting any policy (see "Later").

---

## Policy catalog

**Baked-in** policies are always installed and always enforced, and their rules are fixed.
Only `restrict-image-registries` takes configuration (the site's registries); nothing else
about the baseline can be changed through values. Workloads that need more get a `posture`
exception. **Optional** policies have a default (enforce, audit, or
off) that values can change. Every policy except the RBAC ones can be excepted per workload
through `posture`.

NIST SP 800-53 references are a suggested starting point for an RMF package, not an
authoritative mapping; confirm them with your ISSM before citing them.

### Baked-in (15)

| Policy | Rule | PSS | NIST |
|---|---|---|---|
| `disallow-privileged-containers` | no `privileged: true`; no Windows `hostProcess` | baseline | AC-6, CM-7 |
| `disallow-host-namespaces` | no `hostNetwork`, `hostPID`, `hostIPC` | baseline | AC-6, SC-39 |
| `disallow-host-path` | no `hostPath` volumes | baseline | AC-6, SC-39 |
| `disallow-host-ports` | no `hostPort` (other than 0) | baseline | CM-7, SC-7 |
| `disallow-privilege-escalation` | `allowPrivilegeEscalation: false` on every container | restricted | AC-6 |
| `require-run-as-non-root` | `runAsNonRoot: true` (pod or every container); `runAsUser` never 0 | restricted | AC-6 |
| `require-drop-all-capabilities` | `capabilities.drop` includes `ALL`; `add` contains nothing but `NET_BIND_SERVICE` | restricted | AC-6, CM-7 |
| `restrict-seccomp` | seccomp `RuntimeDefault` or `Localhost`, set at pod or container level | restricted | CM-7, SC-39 |
| `restrict-apparmor` | if set, `RuntimeDefault` or `Localhost` (field or legacy annotation) | baseline | CM-7, SC-39 |
| `restrict-selinux` | `type` unset or one of `container_t`, `container_init_t`, `container_kvm_t`, `container_engine_t`; `user` and `role` unset | baseline | AC-3, SC-39 |
| `restrict-proc-mount` | `procMount` is `Default` or unset | baseline | SC-39 |
| `restrict-sysctls` | only the Pod Security Standards' "safe" sysctls | baseline | CM-7, SC-39 |
| `restrict-volume-types` | volumes only of the Pod Security restricted types: configMap, csi, downwardAPI, emptyDir, ephemeral, persistentVolumeClaim, projected, secret | restricted | CM-7 |
| `restrict-image-registries` | every image starts with a prefix in `policies.restrict-image-registries.registries` (the only configurable baked-in policy; render fails if empty) | — | CM-7, SR-3 |
| `restrict-external-ips` | Services have no `spec.externalIPs` (CVE-2020-8554) | — | SC-7 |

### Optional (20)

| Policy | Default | Applies to | Rule | NIST |
|---|---|---|---|---|
| `require-image-digest` | enforce | workloads | every image pinned by `@sha256:` digest | CM-2, SI-7 |
| `disallow-latest-tag` | enforce | workloads | no `:latest` and no untagged images (for sites that turn off digests) | CM-2 |
| `require-read-only-root-filesystem` | enforce | workloads | `readOnlyRootFilesystem: true` on every container | CM-7, SI-7 |
| `require-resource-limits` | enforce | workloads | memory limit, plus CPU and memory requests, on every container | SC-5 |
| `require-standard-labels` | enforce | workloads | pod template has `app.kubernetes.io/name` (what `posture` selects on) | CM-8 |
| `disallow-default-namespace` | enforce | workloads, services | nothing runs in `default` | CM-7 |
| `disallow-mesh-opt-out` | enforce | workloads | none of the policy's `markers` present | SC-7, SC-8 |
| `disallow-nodeport-services` | enforce | services | no `type: NodePort` | SC-7 |
| `restrict-loadbalancer-services` | enforce | services | `type: LoadBalancer` only in the policy's `namespaces` | SC-7 |
| `restrict-externalname-services` | enforce | services | no `type: ExternalName` | SC-7 |
| `restrict-wildcard-rbac` | enforce | rbac | Roles and ClusterRoles don't use `*` in verbs, resources, or apiGroups (allowlist: `allowedRoles`) | AC-6 |
| `restrict-cluster-admin-binding` | enforce | rbac | bindings to `cluster-admin` only for the policy's `allowedSubjects` | AC-2, AC-6 |
| `disallow-rbac-escalation-verbs` | audit | rbac | no `escalate`, `bind`, or `impersonate` verbs outside `allowedRoles` | AC-6 |
| `disallow-automount-service-account-token` | audit | workloads | `automountServiceAccountToken: false` unless excepted | AC-6 |
| `disallow-default-service-account` | audit | workloads | pods don't run as the `default` service account | AC-6 |
| `disallow-secrets-in-env` | audit | workloads | no `secretKeyRef` in env; mount secrets as files instead | SC-28 |
| `disallow-shared-process-namespace` | audit | workloads | `shareProcessNamespace` unset or false | SC-39 |
| `require-probes` | audit | workloads | readiness and liveness probes on long-running containers | — |
| `disallow-ephemeral-containers` | off | workloads | no `kubectl debug` ephemeral containers | AC-6, CM-7 |
| `disallow-pod-exec` | off | pods/exec, pods/attach (CONNECT) | no interactive exec or attach | AC-6 |

Services and RBAC objects have no controller in front of them, so those policies use a single
binding with the policy's own actions.

### Mutations (phase 3; off unless `mutations.enabled`)

Mutations run before validation, so they let workloads that leave fields unset pass the
validators. They apply to **Pods only**: changing a Deployment's template would make the stored
object differ from what Helm or Flux applied, and they'd keep fighting over it. They **never
overwrite a value that's already set**, and they're idempotent. Their main use is pods created
by operators at runtime, which render-time hardening can't reach.

| Mutation | Default | Sets, only when unset |
|---|---|---|
| `add-default-security-context` | on | `runAsNonRoot: true`, seccomp `RuntimeDefault`, `allowPrivilegeEscalation: false`, `capabilities.drop: [ALL]` |
| `set-image-pull-policy` | on | `imagePullPolicy: IfNotPresent` for digest-pinned images |
| `disable-service-account-token-automount` | off | pod `automountServiceAccountToken: false` |
| `add-default-resources` | off | requests and limits from values |

Because controllers get only warnings, a Deployment that relies on a mutation to pass (for
example, it leaves `allowPrivilegeEscalation` unset) is admitted with a warning and its Pods
are admitted after mutation. The warning still tells the author to set the field explicitly.

---

## Phase 1: foundations

Goal: the full path from definition file to an enforced, excepted policy, proven in a real
cluster, on five baked-in policies.

### 1a. Repository and tooling

- [x] `charts/policy/` with `Chart.yaml`, `values.yaml` (every key documented),
      `values.schema.json`, `_helpers.tpl`.
- [x] Tooling pinned in a `Makefile` or `.tool-versions`: helm (3.14+ and 4), helm-unittest,
      kubeconform, k3d, kubectl.
- [ ] CI: lint, unit tests, kubeconform (with this chart's CRD schema), and the e2e job
      (1e).
      Workflow is in place (Helm matrix + k3d smoke e2e), and kubeconform checks PolicyExceptions
      objects against the CRD's own schema (1d). Still to do: a green run on GitHub.

### 1b. Definition format and model

- [x] `definitions/validating/` files in the format from CLAUDE.md, loaded with `.Files.Glob`
      and checked in CI against a small JSON schema for definitions.
- [x] `_model.tpl`: merge definitions, `policies` values, and `custom` into one normalized list
      with resolved `enabled` and actions per policy.
- [x] Rules enforced in the model, each a render failure naming the policy:
      - any key on a baked-in policy other than `restrict-image-registries.registries`
        (including `enabled` and `action`);
      - a setting a policy's definition doesn't declare;
      - a custom policy whose name matches a built-in one;
      - a required setting left empty (`restrict-image-registries.registries`);
      - a definition that uses `params` or `authorizer` (keeps definitions portable).
- [x] `_lib.tpl`: the shared variables (`podSpec`, `podMeta`, `workloadLabels`,
      `allContainers`), the Pod and controller resource rules (Pods include
      `pods/ephemeralcontainers`), policy settings as CEL literals via `toJson`, the action
      table, and the exclusion list (`kube-system`).
      Done: `restrict-image-registries` is the first definition; the schema lives in
      `test/definition-schema/` (`make check-definitions`); the model is tested through
      `test/model-probe/`. `custom`, `enforcement`, and optional-policy keys are handled by the
      model but still rejected by the values schema until phase 2.

### 1c. Renderer

- [x] One `ValidatingAdmissionPolicy` per enabled policy: `failurePolicy: Fail`, match
      constraints covering Pods and controllers, shared variables, the definition's variables,
      `exempt`, then validations rewritten as `variables.exempt || (E)`.
- [x] Two `ValidatingAdmissionPolicyBinding`s per workload policy, each with
      `matchResources` narrowing to its half and a `namespaceSelector` excluding the chart's
      list by `kubernetes.io/metadata.name`:
      - `<name>`: Pods, actions from the table in CLAUDE.md;
      - `<name>-controllers`: controllers, `[Warn]`.
- [x] Both bindings: `paramRef` with `name: posture-exceptions`,
      `parameterNotFoundAction: Deny`.
- [x] Annotations from CLAUDE.md on every policy.
- [x] `restrict-image-registries` (added in 1b) renders here too.
- [x] Pod UPDATEs that leave the spec unchanged are skipped (matchCondition `pod-spec-changed`,
      as Pod Security Admission does), so finalizer removal and GC patches on a non-compliant
      pod are never denied.
- [x] Renderer is `policy.renderValidating` in `_render.tpl`, so the probe chart renders test
      definitions too. `services`, `rbac` and custom `matchConstraints` fail until phase 2.
- [ ] e2e smoke (no CRD yet): a Pod in a namespace without `posture-exceptions` is denied, a
      controller there is admitted with a warning, and `kube-system` is not evaluated.
      Written but not yet run. If the controller is admitted with no warning, switch that
      check to `admit` and record the behaviour in CLAUDE.md's "Exceptions".

### 1d. The PolicyExceptions CRD

This chart owns the CRD (see CLAUDE.md). Nothing here waits on `posture`.

- [x] `crd/policy.posture.dev_policyexceptions.yaml`: group `policy.posture.dev`, version
      `v1alpha1`, kind `PolicyExceptions`, namespaced, with an OpenAPI schema for the object
      shape `posture` renders (`spec.exceptions[].policy.{kind,name}` with `kind` limited to
      `ValidatingAdmissionPolicy` and `MutatingAdmissionPolicy`;
      `spec.exceptions[].workloads[].{matchLabels,reason,expires}`).
- [x] Schema tests: `examples/objects/posture-exceptions.yaml` (shaped like posture's output)
      is accepted by kubeconform; the files in `test/e2e/fixtures/crd/invalid/` (missing
      `policy`, unknown `kind`, empty `matchLabels` or `workloads`, bad `expires`) are rejected.
      kubeconform uses a schema generated from the CRD (`make crd-schema`). The CRD object
      itself is skipped by kubeconform (no public schema exists for CustomResourceDefinition)
      and covered by `tests/crd_test.yaml` and the API server.
- [ ] The same accept/reject checks in a k3d API server (smoke scenario): written, not yet run.
- [x] Publish the CRD file with each release so `posture` can pin to it: the raw file at a tag
      (URL in CLAUDE.md); release assets come with 3c.
- [x] `templates/crd.yaml` renders it with `helm.sh/resource-policy: keep`.
- [ ] e2e (moved from 1c, needs the CRD): every installed policy has no
      `status.typeChecking.expressionWarnings` (the API server is the only real check of the
      shared variables' CEL), and a compliant Pod in a namespace with an empty
      `posture-exceptions` is admitted.
      Written, not yet run (smoke scenario, with a keep-on-uninstall check).

### 1e. First policies, fixtures, e2e

- [x] Definitions: `disallow-privileged-containers`, `disallow-host-namespaces`,
      `disallow-host-path`, `require-run-as-non-root` (plus `restrict-image-registries`, whose
      definition landed in 1b). Every built-in message must name its exception (checked when
      the definitions load).
- [x] Fixtures: allow and deny cases for each, as a Pod, a Deployment, and a CronJob
      (`fixtures/<policy>/`, 38 files; `make check-fixtures` enforces the coverage).
- [ ] `test/e2e/run.sh`: k3d on Kubernetes 1.36, install the chart, create a test namespace
      with an empty `posture-exceptions`, then `kubectl apply --dry-run=server` every fixture.
      Deny fixtures: Pods refused; controllers admitted with a `Warning:` naming the policy.
      Written (`scenarios/catalog.sh`), not yet run: allow fixtures in `apps`; deny fixtures in
      `only-<policy>` (every other policy excepted, so each is refused by its own policy alone).
      Also `kubectl debug` (`pods/ephemeralcontainers`) is evaluated, and a label change on a
      pre-existing non-compliant pod is admitted (`pod-spec-changed`).
- [ ] Exception e2e, using hand-written `PolicyExceptions` objects shaped exactly as posture
      renders them:
      (`examples/objects/posture-exceptions.yaml` is one; `verify` in `test/e2e/lib.sh` checks
      objects that can only exist after install)
      - an exempt Pod is admitted, and an exempt Deployment produces no warning;
      - a non-exempt Pod is denied;
      - a namespace with no `posture-exceptions` object is denied;
      - `kube-system` is never evaluated.
      Written, not yet run: every deny fixture admitted in `exempt`; an unlabeled pod, a pod
      matching only a MutatingAdmissionPolicy entry, and a pod with one of two required labels
      are denied there; `bare` (smoke) has no object; every deny Pod admitted in `kube-system`.
- [x] Unit tests: model rules, both actions tables, the exclusion list, the exemption rewrite
      (`test/model-probe/tests/`, `charts/policy/tests/validating/`, including `catalog_test`).

**Done when** the five policies pass their fixtures in k3d and every exception case behaves as
listed.

---

## Phase 2: full catalog and custom policies

- [ ] Remaining baked-in definitions (11) and all 20 optional ones, each with allow and deny
      fixtures.
- [ ] `resources: services` and `resources: rbac` match rules, with a single binding each.
- [ ] RBAC policies: cluster-scoped objects have no namespace to read exceptions from, so they
      render without `paramKind`/`paramRef`, use their own allowlist settings, and always skip
      names starting with `system:`.
- [ ] `disallow-pod-exec`: matches `CONNECT` on `pods/exec` and `pods/attach`.
- [ ] `enforcement` and `policies.<name>.enabled` / `.action` for optional policies, defaults
      from the table; unit tests for every combination.
- [ ] `custom.<name>` in the definition format, validated by the values schema and rendered the
      same way (exceptions, the two bindings, and enforcement apply automatically). Custom
      policies may set `resources` to a full `matchConstraints` block for kinds the shortcuts
      don't cover.
- [ ] One e2e custom policy (`require-team-label`).
- [ ] Upgrade safety: a policy added in a release ships as `audit` for one minor version before
      `enforce`, so an upgrade can't suddenly deny workloads already running. Baked-in
      additions follow the same rule: they appear in the release notes one version before they
      become part of the baseline.

**Done when** every policy in the catalog passes its fixtures in k3d.

---

## Phase 3: mutations, reporting, release

### 3a. Mutations

- [ ] `definitions/mutating/` for the four mutations, using ApplyConfiguration where it can
      express "only when unset" and JSONPatch where it can't.
- [ ] `MutatingAdmissionPolicy` and binding per mutation (`mutations.apiVersion`), Pods only,
      `reinvocationPolicy: IfNeeded`, the same exclusion list, exceptions via `paramRef`.
      Verify which parts of a mutating policy can read `params`; if match conditions can't,
      put the exemption check in the mutation expressions themselves.
- [ ] Fixtures show the mutated Pod passes the validators, an already-set value is left alone,
      and an excepted workload isn't mutated.

### 3b. Reporting

- [ ] An optional Grafana dashboard (ConfigMap) built on the API server's admission-policy
      metrics (evaluations and denials per policy and binding). Confirm the metric names
      against Kubernetes 1.36 before building panels.
- [ ] NOTES.txt lists enforcement, enabled optional policies, mutations, and the excluded
      namespaces.

### 3c. Documentation and release

- [ ] `make docs` generates `docs/policies.md` from the definitions (name, tier, default, rule,
      PSS, NIST, settings); CI fails if it's out of date.
- [ ] Examples: `default.yaml` and `strict.yaml` (every optional policy at enforce).
- [ ] Chart version 1.0.0 once the CRD contract with `posture` is at `v1beta1` or later.

**Done when** mutations pass their fixtures and the docs and examples are generated and
current.

---

## Settled

- No Kyverno mode for now. Definitions stay portable so it can be added later.
- Baked-in policies are always enforced and fixed; only `restrict-image-registries` takes
  configuration. Per-workload needs go through `posture` exceptions.
- Settings live under each policy in `policies.<name>`; there's no global settings block.
- This chart owns the `PolicyExceptions` CRD (defines and deploys it); `posture` creates the
  objects and pins to a released version of the CRD.
- `kube-system` is the only excluded namespace, and exclusions aren't configurable through
  values. `posture` always deploys first in every other namespace, so failing closed when its
  exceptions object is missing is safe.
- Enforcement happens on Pods; controllers get warnings only, matching Pod Security
  Admission's model. Audit records come from Pods, warnings from controllers, so neither is
  duplicated.

## Later

- **Distribution-specific exclusions.** Managed services and distributions run their own
  system components in their own namespaces. When those need excluding, add maintained lists
  to the chart, selected by a value such as `distribution: eks`, never free-form namespaces.
- **Kyverno renderer.** Render the same definitions as Kyverno `ValidatingPolicy` and
  `MutatingPolicy`, with exceptions rendered by `posture` as Kyverno `PolicyException`
  objects. The fixture suite should then run in both modes with identical results.
