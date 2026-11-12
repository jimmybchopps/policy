# Changelog

Newest first, one `## X.Y.Z` section per release. A baked-in policy is enforced from its
first release, so it's announced here one minor ahead: `make check-release` fails unless every
baked-in policy whose `since:` is the chart's minor is named under the previous minor. New
optional policies audit for their first minor instead (CLAUDE.md, "New policies arrive in
audit").

## 0.1.0 (unreleased)

First release.

- The PolicyExceptions CRD (`policyexceptions.policy.posture.dev`, `v1alpha1`) that `posture`
  fills in each namespace.
- 15 baked-in policies, always enforced: the Pod Security Standards' baseline and restricted
  rules, `restrict-image-registries`, and `restrict-external-ips`.
- 20 optional policies (workloads, Services, RBAC, `kubectl exec` and `debug`), each with its
  own default and `enabled` / `action`; the `enforcement` setting; custom policies.
