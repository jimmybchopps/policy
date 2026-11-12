#!/usr/bin/env bash
# check-release.sh <chart-dir> <changelog>
#
# Upgrade safety for baked-in policies (CLAUDE.md, "New policies arrive in audit"). An optional
# policy new in this chart's minor audits by default, but a baked-in one is enforced at once,
# so it must be announced a minor ahead: every baked-in definition whose since: is this chart's
# MAJOR.MINOR must be named in CHANGELOG.md under the most recent earlier MAJOR.MINOR (any of
# its patch releases, "## X.Y.Z ..." headings).
set -euo pipefail

chart=${1:?usage: check-release.sh <chart-dir> <changelog>}
changelog=${2:?usage: check-release.sh <chart-dir> <changelog>}

version=$(sed -n 's/^version: *"\{0,1\}\([0-9][0-9.]*\).*/\1/p' "$chart/Chart.yaml" | head -1)
[[ $version =~ ^([0-9]+)\.([0-9]+) ]] || { echo "FAIL: $chart/Chart.yaml: no version"; exit 1; }
major=${BASH_REMATCH[1]} minor=${BASH_REMATCH[2]}
release="$major.$minor"

new=()
for def in "$chart"/definitions/validating/*.yaml; do
  [[ -e $def ]] || continue
  grep -qx 'tier: baked-in' "$def" || continue
  since=$(sed -n 's/^since: *"\{0,1\}\([0-9.]*\)"\{0,1\} *$/\1/p' "$def")
  [[ $since == "$release" ]] && new+=("$(basename "$def" .yaml)")
done

if [[ ${#new[@]} -eq 0 ]]; then
  echo "==> no baked-in policy is new in $release"
  exit 0
fi

# The sections of the most recent earlier MAJOR.MINOR: its version, then its text.
previous=$(awk -v M="$major" -v m="$minor" '
  /^## v?[0-9]+\.[0-9]+\.[0-9]+/ {
    v = $2; sub(/^v/, "", v); split(v, p, ".")
    a = p[1] + 0; b = p[2] + 0
    if ((a < M + 0 || (a == M + 0 && b < m + 0)) && (!found || a > ba || (a == ba && b > bb))) {
      found = 1; ba = a; bb = b
    }
  }
  END { if (found) print ba "." bb }' "$changelog")
if [[ -z $previous ]]; then
  echo "FAIL: baked-in policies new in $release: ${new[*]}; a baked-in policy can't be new in the first release (no earlier version in $changelog to announce it)"
  exit 1
fi
text=$(awk -v want="$previous" '
  /^## / {
    v = $2; sub(/^v/, "", v); split(v, p, ".")
    on = (p[1] "." p[2] == want)
    next
  }
  on' "$changelog")

missing=()
for p in "${new[@]}"; do
  # A whole policy name: policy names contain "-", so grep -w would find restrict-x in restrict-x-ray.
  grep -qE -- "(^|[^a-z0-9-])${p}([^a-z0-9-]|\$)" <<<"$text" || missing+=("$p")
done
if [[ ${#missing[@]} -gt 0 ]]; then
  echo "FAIL: baked-in policies new in $release aren't announced in $changelog under $previous: ${missing[*]} (a baked-in policy is enforced from its first release, so name it in the release before)"
  exit 1
fi
echo "==> baked-in policies new in $release are announced under $previous: ${new[*]}"
