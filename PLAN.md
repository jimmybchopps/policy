# posture: development plan

Build order: network policies, then authorization policies generated from the same rules, then
mTLS, then policy exceptions, then the Linkerd and Cilium renderers. Istio ambient (L4) is the
first mesh for phases 2 and 3. The values contract is in `CLAUDE.md`; this file says what to
build and how to know it's done.

Each phase ends with its acceptance criteria passing in CI.

---

## Phase 0: repository setup

- [ ] `charts/posture/` with `Chart.yaml` (apiVersion v2, type application, version 0.1.0),
      `values.yaml` documenting every key with comments, a `values.schema.json` skeleton, and
      `_helpers.tpl` with labels and `posture.name`, the naming convention from CLAUDE.md
      (tokens for `any`, optional `namePrefix`, length check).
- [ ] Tooling: helm-unittest plugin, kubeconform, k3d. Pin versions in a `Makefile` or
      `.tool-versions`.
- [ ] CI (GitLab or GitHub, wherever the repo lives): `helm lint --strict`, `helm unittest`,
      kubeconform over every file in `examples/`. The e2e job is added in phase 1.
- [ ] Support Helm 3 (3.14 or later) and Helm 4; run unit tests under both.

**Done when** an empty install lints, templates to the default objects only, and CI is green.

---

## Phase 1: network policies

### 1a. Presets and the model

- [ ] `_presets.tpl`: the predefined sources and destinations from CLAUDE.md.
- [ ] Preset merging: user entries merge field by field over presets; an in-cluster field
      (`namespace`, `workload`, `podSelector`) drops the preset's `cidrs`; `cidrs` together
      with an in-cluster field in user values is a `fail`. New names are allowed.
- [ ] `_model.tpl`: normalize `ingress` and `egress` into rules, each with its object name,
      direction, target `podSelector`, normalized peers, and normalized ports.
- [ ] Selector resolution with the precedence entry > rule > `name`, mapping the short names
      to labels.
- [ ] The reserved key `any`, for targets and for peers, with `namespace` omitted, set, or
      `any` (see the table in CLAUDE.md).
- [ ] Ports: required and non-empty everywhere they appear; numbers or port objects with a
      numeric `port`; `protocol` defaults to TCP. Port names are a schema error.
- [ ] Unknown preset references (`destinations: [postgress]`) `fail` with the list of known
      names.
- [ ] Schema: selector enum, port shape, `endPort >= port`, `any` not allowed as a
      `serviceAccount` or selector value, each `from`/`to` entry is either a workload entry
      or a `cidrs` entry.

### 1b. Rendered policies

- [ ] `deny-all-ingress`, `deny-all-egress`, `allow-same-namespace`,
      `allow-egress-from-all-to-dns`, and `allow-ingress-from-ambient-probes-to-all`
      (`mesh: istio` only).
- [ ] `mesh: istio`: add TCP 15008 to every ingress and egress rule whose peer is inside the
      cluster (not to `cidrs` rules), deduplicated. NetworkPolicies only.
- [ ] One NetworkPolicy per target and peer pair (each `from`/`to` entry and each
      `sources`/`destinations` reference), named `allow-<direction>-from-<source>-to-<destination>`.
- [ ] Collision check: two rules producing the same name fail the render, naming both.
- [ ] `posture.dev/rule` annotation on every object.
- [ ] NOTES.txt warning: `namespace: any` on a named workload without `serviceAccount`.

### 1c. Tests and examples

- [ ] Unit tests: every peer form in the translation list, every selector value and the
      precedence, every port form, preset overrides (cidrs only, ports only, switch to
      in-cluster, new name), the `fail` cases, every row of the naming tables in CLAUDE.md,
      the collision `fail`, and name stability when keys are added.
- [ ] `examples/`:
      - `minimal.yaml`: defaults only
      - `prometheus.yaml`: the `prometheus` namespace, egress to every namespace on listed
        metrics ports
      - `grafana.yaml`: `ingress-gateway` and `monitoring` sources in, `postgres` and `sso` out
      - `strict.yaml`: `allowSameNamespace: false`
      - `istio.yaml`: `grafana.yaml` with `mesh: istio`
- [ ] e2e on k3d with Calico (flannel disabled): deploy a server and client pods in two
      namespaces, apply each example, and check that allowed connections succeed and denied
      ones time out, including Prometheus scraping into another namespace. With
      `mesh: istio`, also check that meshed traffic on a listed port connects (15008 added),
      that a peer not in any rule can't get through over 15008, and that probes still pass.

**Done when** every example renders, validates with kubeconform, and passes e2e with
`mesh: none` and `mesh: istio`.

---

## Phase 2: authorization policies (Istio ambient first)

Generated from `ingress` (authorization is enforced at the destination, so `egress` stays
NetworkPolicy-only). Enforced by ztunnel at L4.

- [ ] When `mesh: istio` and `defaultDeny.ingress`: a namespace-wide allow-nothing
      AuthorizationPolicy (empty spec) named `deny-all-ingress`.
- [ ] `allowSameNamespace`: ALLOW from `namespaces: [<this namespace>]`, named
      `allow-same-namespace`.
- [ ] One ALLOW policy per target and peer pair, with the same name as the NetworkPolicy from
      that rule (no selector when the target is `any`). The peer maps to `from.source` as follows:

      | Peer | `from.source` |
      |---|---|
      | workload + `serviceAccount`, namespace X | `principals: [<trustDomain>/ns/X/sa/<sa>]` |
      | workload + `serviceAccount`, `namespace: any` | `principals: ["*/sa/<sa>"]` |
      | workload without `serviceAccount`, namespace X | `namespaces: [X]`, with a NOTES warning |
      | workload without `serviceAccount`, `namespace: any` | `principals: ["*"]` (any mesh identity), with a NOTES warning |
      | `any` + namespace X | `namespaces: [X]` |
      | `any` + `namespace: any` | `principals: ["*"]` |
      | `cidrs` | `ipBlocks` / `notIpBlocks` |

      `to.operation.ports` from the rule's ports, never including 15008 (ztunnel enforces
      authorization on the original destination port, after unwrapping HBONE).
- [ ] Presets as sources follow the same table (a preset can carry a `serviceAccount`).
- [ ] `authorization.enabled` (default true when `mesh` isn't `none`).
- [ ] Unit tests for every row and the `fail` cases. e2e: a pod with the right labels but the
      wrong service account is refused by the mesh even though the NetworkPolicy lets it
      through; test each layer with the other relaxed.

**Done when** e2e shows NetworkPolicy and AuthorizationPolicy each block traffic on their own.

---

## Phase 3: mTLS with per-port exclusions

```yaml
mtls:
  mode: STRICT              # STRICT | PERMISSIVE | inherit (render nothing)
  exclusions:               # workload (or any) -> ports that also accept plaintext
    grafana: [9090]
```

Confirmed for Istio ambient: with the namespace at STRICT, a workload can set individual ports
to PERMISSIVE; disabling mTLS (`DISABLE`) on a port isn't supported. The chart follows that
everywhere:

- [ ] Istio: a namespace PeerAuthentication `mtls-<mode>`; one workload PeerAuthentication per
      exclusion, `allow-plaintext-to-<workload>` (`allow-plaintext-to-all` for `any`), with
      `portLevelMtls` set to `PERMISSIVE` for the listed ports.
- [ ] Exclusions are only valid with `mode: STRICT`; with `PERMISSIVE` or `inherit` they `fail`
      (every port already accepts plaintext, or the chart isn't managing mTLS).
- [ ] There is no `DISABLE` anywhere: the schema rejects it as a mode, and exclusions always
      mean PERMISSIVE (mTLS still used when the client offers it).
- [ ] Unit tests; e2e: a client outside the mesh is refused on a strict port and connects on
      an excluded one, while a meshed client still connects with mTLS on the excluded port.

**Done when** the e2e matrix passes for strict, permissive, and excluded ports.

---

## Phase 4: policy exceptions

Exceptions to the cluster's admission policies, declared by the namespace that needs them.

The policies stay cluster-wide (in Neutron Star, the core `policy` bundle, installed before
anything else). Built-in admission policies and their bindings are cluster-scoped, so they
can't live in this chart, and keeping them central means a namespace without a `posture`
release still gets every policy. This chart renders the per-namespace exceptions object the
policies read as parameters, much like a Kyverno PolicyException.

### How it fits together

- **A namespaced CRD, defined in this repo, installed by whoever installs the policies.**
  `crd/policyexception.yaml` (group `posture.dev`, kind `PolicyException`) lives here because
  it's this chart's contract, but the chart never installs it. Neutron Star's `policy` bundle
  ships it.
- **One object per namespace,** named `posture-exceptions`, holding every exception for that
  namespace. Policies look it up by name in the namespace of the object being admitted. Never
  several: when a binding matches several parameter objects, the policy must pass against
  each of them, which is the opposite of how exceptions should work.
- **Two bindings per policy,** so a missing object can never mean "skip the policy":
  - with parameters, for namespaces labeled `posture.dev/exceptions: "true"`; if the object
    is missing there, the request is denied (fails closed);
  - without parameters, for every other namespace; the full policy applies.

  The label is set by whoever manages namespaces (Neutron Star's installer), not by this
  chart, and namespace users normally can't change namespace labels, so they can't opt
  themselves in.
- **RBAC decides who can write exceptions.** Only the account that deploys this chart (Flux's
  service account in Neutron Star) may create or change `PolicyException` objects; the kind
  must not be aggregated into the built-in `admin` or `edit` roles. A ConfigMap would let any
  namespace admin exempt themselves, which is why this is a CRD.

### Values and the rendered object

```yaml
exceptions:
  legacy-agent-root:                  # a name for the exception
    policy: require-non-root          # the admission policy's name
    workload: legacy-agent            # optional; omit for the whole namespace
    selector: name                    # optional
    kinds: [Deployment]               # optional; omit for every kind
    reason: "Vendor image runs as root; ticket OPS-123"
    expires: 2027-03-31               # required
```

```yaml
apiVersion: posture.dev/v1alpha1
kind: PolicyException
metadata:
  name: posture-exceptions
spec:
  exceptions:
    - name: legacy-agent-root
      policy: require-non-root
      match:
        label: app.kubernetes.io/name   # resolved from selector
        value: legacy-agent             # absent = whole namespace
        kinds: [Deployment]             # absent = every kind
      reason: "Vendor image runs as root; ticket OPS-123"
      expires: "2027-03-31"
```

### The matching contract (what policies implement)

An admitted object is exempt from policy `P` when some entry has `policy == P`, and either no
`match.value` or the object's labels have `match.label == match.value`, and either no
`match.kinds` or the object's kind is listed. "The object's labels" means
`spec.template.metadata.labels` for workload controllers (Deployment, StatefulSet, DaemonSet,
Job, CronJob's job template) and `metadata.labels` for everything else, so a Deployment and
the Pods it creates are matched the same way.

Admission rules can't read the clock, so `expires` is enforced by this chart, not the policy.

### Tasks

- [ ] `crd/policyexception.yaml` with an OpenAPI schema matching the object above; kubeconform
      validates rendered objects against it.
- [ ] `docs/exceptions.md`: the matching contract plus a reference CEL snippet (an `exempt`
      variable used as `variables.exempt || <rule>`) that policy authors copy.
- [ ] Render `posture-exceptions` only when `exceptions` is non-empty; NOTES.txt reminds that
      the namespace needs the `posture.dev/exceptions: "true"` label for them to apply.
- [ ] `reason` and `expires` are required (schema). Expired entries are listed in NOTES.txt and
      fail the render when `exceptionsFailOnExpired: true` (sprig `now`, `toDate`).
- [ ] Unknown `policy` names can't be checked by the chart (it can't see the cluster); a
      `knownPolicies` list in values, when set, turns typos into a `fail`.
- [ ] e2e with a sample policy written from the reference snippet and its two bindings:
      - an exempt Deployment and its Pods are admitted; a non-exempt one is denied;
      - an expired-but-rendered entry still works at admission (expiry is the chart's job),
        and the chart fails on it when `exceptionsFailOnExpired` is on;
      - an unlabeled namespace with an exceptions object gets the full policy;
      - a labeled namespace without the object denies everything the policy covers;
      - a namespace admin without the RBAC can't create a `PolicyException`.

**Done when** every e2e case above passes.

---

## Phase 5: Linkerd and Cilium

- [ ] Linkerd: a `Server` per target port; `AuthorizationPolicy` with `MeshTLSAuthentication`
      (identity `<sa>.<ns>.serviceaccount.identity.linkerd.<trustDomain>`) or
      `NetworkAuthentication` for `cidrs`; mTLS via `Server.spec.accessPolicy`
      (`all-authenticated`, or `all-unauthenticated` for excluded ports).
- [ ] Cilium: `networkPolicy: cilium` renders `CiliumNetworkPolicy` instead of NetworkPolicy;
      identity rules match `io.cilium.k8s.policy.serviceaccount`; strict mTLS requires Cilium
      mutual authentication, or `fail`s unless the values explicitly accept encryption-only.
- [ ] Cilium as the gateway: Cilium's Gateway API traffic arrives from its shared Envoy with
      the reserved `ingress` identity, not from pods in the `ingress-gateway` namespace. When the
      cluster uses Cilium's gateway, the `ingress-gateway` source renders as
      `fromEntities: [ingress]` (needs `networkPolicy: cilium`).
- [ ] Linkerd and Cilium `fail` on the `egress-gateway` destination with an explanation (it
      only exists for Istio's egress waypoint).
- [ ] Golden files: one example, three meshes, reviewed side by side.

---

## Open questions

1. **An escape hatch for custom resources (deferred, after phase 5).** The generated rules
   will eventually meet a case they can't express (an L7 rule on a waypoint, an unusual
   Cilium selector, a vendor-specific policy). Users need a way to add their own objects
   without forking the chart, but a fully open "any manifest" field would let this chart
   create cluster-scoped objects and anything else, breaking the namespace-scoped principle.
   Options:

   - **A. Fully open `extraObjects`:** a map of raw manifests rendered as given. Common in
     charts, simplest, but no guardrails.
   - **B. Restricted `extraObjects`** (leaning this way): the same map, but each object must
     be a kind on an allow list (NetworkPolicy, AuthorizationPolicy, PeerAuthentication,
     Linkerd Server and AuthorizationPolicy, CiliumNetworkPolicy, and so on), is forced into
     the release namespace, and can't be cluster-scoped. Anything else `fail`s with the list
     of allowed kinds.
   - **C. Per-rule overrides:** extra fields merged into a generated object
     (`ingress.grafana.from.prometheus.override: {...}`). Precise, but couples users to the
     generated shape, which then can't change freely.

   Whichever is chosen: keyed by name (a map, so overrides merge), annotated
   `posture.dev/rule: extraObjects.<key>` so it's clear these weren't generated, listed in
   NOTES.txt, and exempt from the "never silently weaker" check, since the chart can't
   judge hand-written objects.

### Settled

- Policy exceptions (phase 4): policies stay cluster-wide; each namespace has one
  `PolicyException` object (a CRD defined here, installed with the policies); two bindings per
  policy so a missing object never skips a policy; only the deploying account may write
  exceptions; expiry is enforced by the chart.
- Ports are always required and always numeric. There is no "all ports" form and no named
  ports.
- Under Istio ambient, TCP 15008 is added to every in-cluster NetworkPolicy rule alongside
  its ports; authorization policies list only the user's ports.
- Istio ambient supports port-level PERMISSIVE under a STRICT namespace, and not DISABLE
  (phase 3 reflects this).
- Gateway presets use mesh-neutral namespaces named after them: the `ingress-gateway` source
  (namespace `ingress-gateway`) and the `egress-gateway` destination (namespace
  `egress-gateway`, Istio only).
- The `monitoring` source defaults to namespace `prometheus`, workload `prometheus`. Presets
  assume one namespace per application, named after it.
