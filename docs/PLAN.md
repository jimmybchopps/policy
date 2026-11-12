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
| `disallow-default-namespace` | enforce | workloads | nothing runs in `default` (Services there are already refused: `default` has no `posture-exceptions`, so every Services policy fails closed) | CM-7 |
| `disallow-mesh-opt-out` | enforce | workloads | none of the policy's `markers` present | SC-7, SC-8 |
| `disallow-nodeport-services` | enforce | services | no `type: NodePort` | SC-7 |
| `restrict-loadbalancer-services` | enforce | services | `type: LoadBalancer` only in the policy's `namespaces` (none by default) | SC-7 |
| `restrict-externalname-services` | enforce | services | no `type: ExternalName` | SC-7 |
| `restrict-wildcard-rbac` | enforce | rbac | Roles and ClusterRoles don't use `*` in verbs, resources, or apiGroups (allowlist: `allowedRoles`) | AC-6 |
| `restrict-cluster-admin-binding` | enforce | rbac | bindings to `cluster-admin` only for the policy's `allowedSubjects` (`{kind, name}`, plus `namespace` for a ServiceAccount); Group `system:masters` always allowed (the API server's own binding) | AC-2, AC-6 |
| `disallow-rbac-escalation-verbs` | audit | rbac | no `escalate`, `bind`, or `impersonate` verbs outside `allowedRoles`; `cluster-admin`, `admin`, and `edit` always allowed (built in, rewritten by the API server); `*` is left to `restrict-wildcard-rbac` | AC-6 |
| `disallow-automount-service-account-token` | audit | workloads | `automountServiceAccountToken: false` unless excepted | AC-6 |
| `disallow-default-service-account` | audit | workloads | pods don't run as the `default` service account | AC-6 |
| `disallow-secrets-in-env` | audit | workloads | no `secretKeyRef` in env; mount secrets as files instead | SC-28 |
| `disallow-shared-process-namespace` | audit | workloads | `shareProcessNamespace` unset or false | SC-39 |
| `require-probes` | audit | workloads | readiness and liveness probes on long-running containers (regular containers unless the pod runs to completion, as a Job's do; sidecar init containers always) | — |
| `disallow-ephemeral-containers` | off | pods/ephemeralcontainers (UPDATE) | no `kubectl debug` ephemeral containers | AC-6, CM-7 |
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
| `add-default-security-context` | on | pod `runAsNonRoot: true` and seccomp `RuntimeDefault`; each container's and init container's `allowPrivilegeEscalation: false` and `capabilities.drop: [ALL]` |
| `disable-service-account-token-automount` | off | pod `automountServiceAccountToken: false`; also removes the token volume (`kube-api-access-*`) and mounts the ServiceAccount admission plugin already added, which runs before any mutating policy |
| `add-default-resources` | off | each container's and init container's `requests.cpu`, `requests.memory`, `limits.memory` from its settings (`cpuRequest` 100m, `memoryRequest` 128Mi, `memoryLimit` 128Mi); a memory limit is never set below the container's request |

There's no `set-image-pull-policy`: the API server's defaulting, which runs before any mutating
policy, already sets `IfNotPresent` on a digest-pinned image without a tag, and a mutation may
not overwrite the `Always` it sets for `:latest`, so it could never do anything.

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
- [x] e2e smoke: a Pod in a namespace without `posture-exceptions` is denied, and
      `kube-system` is not evaluated. A controller there is denied too, not warned: a missing
      param is a binding error, which denies whatever the binding's actions are (recorded in
      CLAUDE.md's "Fail closed").

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
- [x] The same accept/reject checks in a k3d API server (smoke scenario).
- [x] Publish the CRD file with each release so `posture` can pin to it: the raw file at a tag
      (URL in CLAUDE.md), and as a release asset (3c).
- [x] `templates/crd.yaml` renders it with `helm.sh/resource-policy: keep`.
- [x] e2e (moved from 1c, needs the CRD): every installed policy has no
      `status.typeChecking.expressionWarnings` (the API server is the only real check of the
      shared variables' CEL), and a compliant Pod in a namespace with an empty
      `posture-exceptions` is admitted.
      In the smoke scenario, with a keep-on-uninstall check.

### 1e. First policies, fixtures, e2e

- [x] Definitions: `disallow-privileged-containers`, `disallow-host-namespaces`,
      `disallow-host-path`, `require-run-as-non-root` (plus `restrict-image-registries`, whose
      definition landed in 1b). Every built-in message must name its exception (checked when
      the definitions load).
- [x] Fixtures: allow and deny cases for each, as a Pod, a Deployment, and a CronJob
      (`fixtures/<policy>/`, 38 files; `make check-fixtures` enforces the coverage).
- [x] `test/e2e/run.sh`: k3d on Kubernetes 1.36, install the chart, create a test namespace
      with an empty `posture-exceptions`, then `kubectl apply --dry-run=server` every fixture.
      Deny fixtures: Pods refused; controllers admitted with a `Warning:` naming the policy.
      In `scenarios/catalog.sh`: allow fixtures in `apps`; deny fixtures in
      `only-<policy>` (every other policy excepted, so each is refused by its own policy alone).
      Also `kubectl debug` (`pods/ephemeralcontainers`) is evaluated, and a label change on a
      pre-existing non-compliant pod is admitted (`pod-spec-changed`).
- [x] Exception e2e, using hand-written `PolicyExceptions` objects shaped exactly as posture
      renders them:
      (`examples/objects/posture-exceptions.yaml` is one; `verify` in `test/e2e/lib.sh` checks
      objects that can only exist after install)
      - an exempt Pod is admitted, and an exempt Deployment produces no warning;
      - a non-exempt Pod is denied;
      - a namespace with no `posture-exceptions` object is denied;
      - `kube-system` is never evaluated.
      Covered by: every deny fixture admitted in `exempt`; an unlabeled pod, a pod
      matching only a MutatingAdmissionPolicy entry, and a pod with one of two required labels
      are denied there; `bare` (smoke) has no object; every deny Pod admitted in `kube-system`.
- [x] Unit tests: model rules, both actions tables, the exclusion list, the exemption rewrite
      (`test/model-probe/tests/`, `charts/policy/tests/validating/`, including `catalog_test`).

**Done when** the five policies pass their fixtures in k3d and every exception case behaves as
listed.

---

## Phase 2: full catalog and custom policies

Split like Phase 1; each subphase ends with a green `make e2e`.

### 2a. Every shape, optional and custom policies, the values schema

- [x] `resources: services` and `resources: rbac` match rules, with a single binding each
      (`policy.posture.dev/binding: services | rbac`), and custom `matchConstraints` blocks
      (`custom`): `resourceRules`, `excludeResourceRules`, `matchPolicy`, never a
      `namespaceSelector` or `objectSelector`. Single bindings act `[Deny, Audit]` (enforce) or
      `[Audit, Warn]` (audit).
- [x] `exceptions: labels | none` in the definition format. RBAC policies (cluster-scoped
      objects, no namespace to read exceptions from) and `disallow-pod-exec` (the request has
      no pod labels) are `none`: no `paramKind`/`paramRef`, no exempt rewrite; they use their
      own allowlist settings, and RBAC policies always skip names starting with `system:`.
      Services take exceptions by the Service's own labels.
- [x] `enforcement` and `policies.<name>.enabled` / `.action` for optional policies, defaults
      from each definition; unit tests for every combination (`test/model-probe/tests/`).
- [x] `custom.<name>` in the definition format, with its own `enabled` and `action`, rendered
      the same way (exceptions, bindings, and enforcement apply automatically).
- [x] `values.schema.json` generated from the definitions (`make values-schema`,
      `test/values-schema/`); `make check-values-schema` (in `make test` and CI) fails if it's
      stale.
- [x] Definitions: `restrict-external-ips` (baked-in, services),
      `require-read-only-root-filesystem` (optional, workloads), `restrict-wildcard-rbac`
      (optional, rbac; `cluster-admin` always allowed), `disallow-pod-exec` (optional, off;
      CONNECT on `pods/exec` and `pods/attach`; `namespaces` setting), with fixtures.
      `make check-fixtures` requires the kinds each `resources` covers.
- [x] e2e: catalog with every optional policy on at enforce (Services and RBAC fixtures, the
      allowlists, kubectl exec), and the `settings` scenario (`enforcement: audit`, custom
      `require-team-label`). Green.

### 2b. Remaining baked-in workload policies

- [x] `disallow-host-ports`, `disallow-privilege-escalation`, `require-drop-all-capabilities`,
      `restrict-seccomp`, `restrict-apparmor`, `restrict-selinux`, `restrict-proc-mount`,
      `restrict-sysctls`, `restrict-volume-types`, each with allow and deny fixtures. No
      Windows carve-out: a Windows pod can't set the Linux-only fields, so it needs posture
      exceptions.
- [x] The exception-path e2e fixtures use `hostPID` instead of `hostPath` (which
      restrict-volume-types now also refuses), so each breaks exactly one policy.
- [x] e2e: green.

### 2c. Optional workload policies

- [x] `require-image-digest`, `disallow-latest-tag`, `require-resource-limits`,
      `require-standard-labels`, `disallow-default-namespace`, `disallow-mesh-opt-out`,
      `disallow-automount-service-account-token`, `disallow-default-service-account`,
      `disallow-secrets-in-env`, `disallow-shared-process-namespace`, `require-probes`, each
      with allow and deny fixtures; `disallow-ephemeral-containers` (a `matchConstraints`
      policy on `pods/ephemeralcontainers`: a Pod can't be created with ephemeral containers,
      so it's covered by kubectl debug checks instead).
- [x] The fixture base gains ServiceAccount `app` (created in every e2e namespace and
      kube-system), probes on long-running containers, and digest-pinned images everywhere;
      the kubectl debug checks move to `debug-allowed`, which excepts
      `disallow-ephemeral-containers`. disallow-default-namespace's deny fixtures are checked
      in `default`.
- [x] e2e: green.

### 2d. Optional Services and RBAC policies

- [x] `disallow-nodeport-services`, `restrict-loadbalancer-services`,
      `restrict-externalname-services`, `restrict-cluster-admin-binding`,
      `disallow-rbac-escalation-verbs`, each with allow and deny fixtures; e2e checks for
      each allowlist (`lb-allowed`, `allowedSubjects`, `system:masters`, `allowedRoles`).
- [x] `make check-fixtures` takes a binding as an RBAC policy's fixture: one cluster-scoped
      (ClusterRole or ClusterRoleBinding) and one namespaced (Role or RoleBinding).
- [x] e2e: green.

### 2e. Upgrade safety

- [x] Definitions may carry `since: "0.N"`, the chart minor version that introduced them
      (absent: the original catalog). While the chart's minor equals `since`, an optional
      policy's default action is `audit` unless the user sets `action`, so an upgrade can't
      suddenly deny workloads already running; NOTES.txt lists them, and the policy carries
      `policy.posture.dev/since`. Baked-in policies can't be audit: `make check-release`
      (`test/release/`, in `make test` and CI) fails unless every baked-in policy whose
      `since` is the chart's minor is named in `CHANGELOG.md` under the previous minor.
      Unit tests for both (`test/model-probe/tests/since_test.yaml`, `notes_test.yaml`;
      `test/release/cases/`).
- [x] `CHANGELOG.md`, starting with 0.1.0.
- [ ] e2e: a regression run (nothing sets `since` yet, so nothing should change).

**Done when** every policy in the catalog passes its fixtures in k3d.

---

## Phase 3: mutations, reporting, release

### 3a. Mutations

- [x] `definitions/mutating/` for the three mutations (`set-image-pull-policy` dropped; see
      the table), using ApplyConfiguration where it can express "only when unset" (one
      mutation per field, returning `Object{}` when it's set) and JSONPatch where it can't
      (removing the service account token volume; `capabilities.drop`, an atomic list an
      apply configuration may not set). Their own schema, `test/mutation-schema/`.
- [x] `MutatingAdmissionPolicy` and binding per mutation (`mutations.apiVersion`), Pods on
      CREATE only, `reinvocationPolicy: IfNeeded`, the same exclusion list, exceptions via
      `paramRef` (`parameterNotFoundAction: Deny`). The exemption check is a variable, and each
      mutation is wrapped to do nothing for an excepted Pod, so match conditions never need
      `params`. `mutations.*` in the values schema, generated from the definitions.
- [x] Fixtures (`fixtures/mutations/<name>/{mutated,kept,exempt}/`, with `# expect:` lines)
      show the mutated Pod passes the validators, an already-set value is left alone, and an
      excepted workload isn't mutated; the `mutations` e2e scenario also checks kube-system, a
      Deployment's template, and a namespace without `posture-exceptions`.
- [x] e2e: green.

### 3b. Reporting

- [x] An optional Grafana dashboard (`reporting.grafanaDashboard`: a ConfigMap the Grafana
      sidecar loads) built on the API server's admission-policy metrics: denials, warnings,
      audits, and errors per policy and binding, evaluation latency, and the mutations. Every
      query is limited to this release's enabled policies and mutations. The ConfigMap is
      always in the release namespace (this chart installs first, so Grafana's may not exist
      yet); Grafana's sidecar is pointed at it (`searchNamespace`). The metric names
      are confirmed against the Kubernetes version under test by e2e (`check_metrics`):

      | Metric | Labels used |
      |---|---|
      | `apiserver_validating_admission_policy_check_total` | `policy`, `policy_binding`, `enforcement_action`, `error_type` |
      | `apiserver_validating_admission_policy_check_duration_seconds` | `policy`, `policy_binding` |
      | `apiserver_mutating_admission_policy_check_total` | `policy`, `error_type` |
      | `apiserver_mutating_admission_policy_check_duration_seconds` | `policy` |
- [x] NOTES.txt lists enforcement, the baked-in count, optional policies by action and the
      ones off, custom policies, mutations, the excluded namespaces, and the dashboard.
- [ ] e2e: written, not yet run.

### 3c. Documentation and release

- [x] `make docs` generates `docs/policies.md` from the definitions (name, tier, default, rule,
      PSS, NIST, settings, what each checks; the mutations too) through `test/docs/`;
      `make check-docs` (in `make test` and CI) fails if it's out of date.
- [x] Examples: `default.yaml` (the recommended setup: the security-context mutation and the
      dashboard on) and `strict.yaml` (every optional policy at enforce, every mutation on;
      `notes_test` fails if a new one is missing).
- [x] The chart README (`charts/policy/README.md`): install order, values, exceptions,
      upgrades, the CRD contract.
- [x] Releases: `.github/workflows/release.yml` on a `v*` tag checks the tag against
      `Chart.yaml` and `CHANGELOG.md` (no longer `(unreleased)`), runs `make test`, and creates
      the GitHub release with the chart package, the CRD, the dashboard JSON, and `SHA256SUMS`
      (`test/release/build-dist.sh`, rehearsed locally with `make release-check TAG=...`).
- [ ] Chart version 1.0.0 once the CRD contract with `posture` is at `v1beta1` or later
      (depends on `posture`; 0.1.0 is the first release).
- [ ] e2e: a regression run (3c changes nothing deployed).

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
