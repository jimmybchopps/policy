#!/usr/bin/env bash
# build-dist.sh <tag> [out-dir]: builds a release's assets into out-dir (default dist/), the same
# way for .github/workflows/release.yml and `make release-check TAG=...`:
#
#   policy-<version>.tgz                          the chart (helm package)
#   policy.posture.dev_policyexceptions.yaml      the PolicyExceptions CRD posture pins to
#   admission-policies.json                       the Grafana dashboard, for importing by hand
#                                                 (every policy; the chart's ConfigMap lists
#                                                 the release's own)
#   SHA256SUMS                                    of the three above
#   RELEASE_NOTES.md                              CHANGELOG.md's section for this version
#
# Expects HELM (the helm binary) in the environment; run from the repo root.
set -euo pipefail

tag=${1:?usage: build-dist.sh <tag> [out-dir]}
out=${2:-dist}
here=$(cd "$(dirname "$0")" && pwd)
chart=charts/policy
: "${HELM:?set HELM to the helm binary}"

"$here/check-tag.sh" "$tag" "$chart" CHANGELOG.md
version=${tag#v}

mkdir -p "$out"
"$HELM" package "$chart" -d "$out" >/dev/null
cp "$chart/crd/policy.posture.dev_policyexceptions.yaml" "$out/"
sed 's/__POLICIES__/.*/g' "$chart/dashboards/admission-policies.json" >"$out/admission-policies.json"
(
  cd "$out"
  sha256sum "policy-${version}.tgz" policy.posture.dev_policyexceptions.yaml admission-policies.json >SHA256SUMS
)
"$here/release-notes.sh" "$version" CHANGELOG.md >"$out/RELEASE_NOTES.md"
echo "==> built $tag into $out/: policy-${version}.tgz, the CRD, the dashboard, SHA256SUMS, RELEASE_NOTES.md"
