# policy

A cluster's admission policies: a strict, always-enforced security baseline suitable for DoD or
comparable civilian environments, optional policies with sensible defaults, and optional
mutations that fill in safe defaults. Everything runs as Kubernetes' built-in
ValidatingAdmissionPolicy and MutatingAdmissionPolicy, evaluated by the API server: no
webhook, no controller, no pods.

The chart also installs the `PolicyExceptions` CRD. Its companion chart, `posture`, creates
one `posture-exceptions` object in every namespace: the reviewed, per-workload exceptions.

- Every policy, its default, its settings, and what it checks: [docs/policies.md](../../docs/policies.md)
- What changed in each release: [CHANGELOG.md](../../CHANGELOG.md)

## Install order

1. **This chart, first**, before anything else, so every workload the cluster ever runs is
   checked, including the platform's own.
2. **`posture` in every namespace**, as that namespace's first release. Policies read the
   namespace's `posture-exceptions` and **fail closed** without it: until it exists, nothing
   is admitted there (Deployments included). `kube-system` is never evaluated.

## Install

From a release's `policy-<version>.tgz`:

```sh
helm install policy ./policy-0.1.0.tgz -n policy --create-namespace -f values.yaml
```

One value is required, the registries the cluster may pull from:

```yaml
policies:
  restrict-image-registries:
    registries: ["registry.site.mil/", "127.0.0.1:31999/"]
```

Every value is checked by the chart's JSON schema, so a typo fails the install instead of
being ignored. `helm template` renders exactly what `helm install` applies: nothing depends on
what's in the cluster. Example values files:

| File | What it is |
|---|---|
| `examples/minimal.yaml` | the registries, nothing else |
| `examples/default.yaml` | a recommended starting point: the security-context mutation and the Grafana dashboard on |
| `examples/strict.yaml` | every optional policy at enforce, every mutation on |

## Requirements

- Kubernetes 1.30+ for the validating policies.
- For mutations: 1.36+ (`mutations.apiVersion: admissionregistration.k8s.io/v1`, the default),
  or 1.34–1.35 with `admissionregistration.k8s.io/v1beta1` and the MutatingAdmissionPolicy
  feature gate and API turned on.
- Helm 3.14+ or Helm 4.

## Values

```yaml
# How optional and custom policies with action inherit act: enforce (deny and audit Pods,
# warn on controllers) or audit (audit Pods, warn on controllers). Baked-in policies always
# enforce.
enforcement: enforce

policies:
  # Baked-in policies take nothing but restrict-image-registries' registries.
  restrict-image-registries: { registries: [registry.site.mil/] }
  # Optional policies take enabled, action (inherit | enforce | audit), and their own settings.
  disallow-pod-exec: { enabled: true, namespaces: [debug] }
  restrict-loadbalancer-services: { namespaces: [ingress-gateway] }

# Your own policies, in the definition format (docs/policies.md describes the built-in ones).
custom:
  require-team-label:
    description: Every workload carries a team label.
    validations:
      - expression: "'team' in variables.workloadLabels"
        message: "Add a 'team' label to the pod template."

# Fill in safe defaults on Pods that leave them unset (off unless enabled).
mutations:
  enabled: true
  policies:
    add-default-resources: { enabled: true, memoryLimit: 256Mi }

# A Grafana dashboard ConfigMap, in this release's namespace (point Grafana's dashboard sidecar
# at it, e.g. kube-prometheus-stack's grafana.sidecar.dashboards.searchNamespace).
reporting:
  grafanaDashboard: { enabled: true }
```

**Baked-in policies are fixed.** They're always on and always enforced; a workload that
genuinely needs more gets a posture exception, which is reviewed and visible, never a
cluster-wide loosening.

**Enforcement happens on Pods.** Every Pod is checked, whatever created it. Deployments,
StatefulSets, DaemonSets, Jobs, and CronJobs get warnings, so whoever applies one sees the
problem at once, the way Pod Security Admission works.

## Exceptions

A `posture-exceptions` object (written by `posture`) excepts workloads, selected by their
labels, from named policies:

```yaml
apiVersion: policy.posture.dev/v1alpha1
kind: PolicyExceptions
metadata:
  name: posture-exceptions
  namespace: monitoring
spec:
  exceptions:
    - policy: { kind: ValidatingAdmissionPolicy, name: disallow-host-path }
      workloads:
        - matchLabels: { app.kubernetes.io/name: node-exporter }
          reason: reads /proc and /sys from the node
```

RBAC policies and `disallow-pod-exec` take no exceptions (cluster-scoped objects and exec
requests have no labels to match); their settings are the allowlist instead.

## Upgrades

A policy added after the first release carries the chart version that introduced it. An
optional one audits (never denies) for that whole minor version, unless you set its `action`,
and the install notes list it, so an upgrade never suddenly denies workloads that already run.
A new baked-in policy is announced in CHANGELOG.md a minor version ahead.

## The PolicyExceptions CRD

This chart owns the CRD (`policyexceptions.policy.posture.dev`) and keeps it on uninstall
(`helm.sh/resource-policy: keep`), so uninstalling never deletes every namespace's
exceptions. Consumers pin to a released version of it, either from the release assets
(`policy.posture.dev_policyexceptions.yaml`) or at the tag:
`https://raw.githubusercontent.com/jimmybchopps/policy/<tag>/charts/policy/crd/policy.posture.dev_policyexceptions.yaml`.
