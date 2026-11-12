#!/usr/bin/env bash
# Runs check-release.sh against every case in cases/<name>/: a Chart.yaml, definitions, a
# CHANGELOG.md, and expect (pass, or a substring of the expected failure).
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd)
fail=0
for c in "$here"/cases/*/; do
  name=$(basename "$c")
  want=$(cat "$c/expect")
  out=$("$here/check-release.sh" "$c" "$c/CHANGELOG.md" 2>&1); rc=$?
  if [[ $want == pass ]]; then
    [[ $rc -eq 0 ]] && ok=1 || ok=0
  else
    [[ $rc -ne 0 ]] && grep -qF -- "$want" <<<"$out" && ok=1 || ok=0
  fi
  if [[ $ok == 1 ]]; then
    echo "==> check-release case $name: $want"
  else
    echo "FAIL: check-release case $name: expected $want, got (exit $rc): $out"; fail=1
  fi
done
exit $fail
