# Changelog

Newest first, one `## X.Y.Z` section per release. A baked-in policy is enforced from its
first release, so it's announced here one minor ahead: `make check-release` fails unless every
baked-in policy whose `since:` is the chart's minor is named under the previous minor. New
optional policies audit for their first minor instead (CLAUDE.md, "New policies arrive in
audit"). A version's section stays marked `(unreleased)` until the release commit; the release
workflow refuses a tag whose section still is.

## 0.1.0

First release.

- The PolicyExceptions CRD (`policyexceptions.policy.posture.dev`, `v1alpha1`) that `posture`
  fills in each namespace.
- 15 baked-in policies, always enforced: the Pod Security Standards' baseline and restricted
  rules, `restrict-image-registries`, and `restrict-external-ips`.
- 20 optional policies (workloads, Services, RBAC, `kubectl exec` and `debug`), each with its
  own default and `enabled` / `action`; the `enforcement` setting; custom policies in the
  definition format.
- Enforcement on Pods, warnings on controllers; posture exceptions by workload labels, failing
  closed in a namespace without `posture-exceptions`; `kube-system` never evaluated.
- 3 mutations, off unless `mutations.enabled`: `add-default-security-context` (on once
  enabled), `disable-service-account-token-automount`, and `add-default-resources`. Pods only,
  on creation; never overwrite a set value.
- Upgrade safety: a policy introduced later carries `since:`, and an optional one audits for
  its first minor version.
- An optional Grafana dashboard (`reporting.grafanaDashboard`) on the API server's
  admission-policy metrics.
- The policy catalog, `docs/policies.md`, generated from the definitions.
- Release assets: the chart package, the PolicyExceptions CRD, the dashboard JSON, and
  `SHA256SUMS`.
