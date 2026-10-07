#!/usr/bin/env bash
# Regenerates docs/evidence/{before,after}.txt end to end against the live
# cluster, and asserts that each capture is what it claims to be:
#   before: every kgateway resource has an EMPTY health status
#   after:  every kgateway resource has a NON-EMPTY health status
# Without those assertions a stale or half-removed state looks like evidence.
set -euo pipefail
cd "$(dirname "$0")/.."
source ./hack/kind-shapes.sh

NS=argocd
APPS="kgw-demo kgw-scenarios kgw-coverage"
PREFIX="resource.customizations.health.gateway.kgateway.dev_"

# Applications cache per-resource health and do not re-evaluate it when
# argocd-cm changes, so a plain sleep yields stale (plausible-looking)
# statuses. A hard refresh forces re-evaluation with the current ConfigMap.
hard_refresh_and_wait() {
  for a in $APPS; do
    kubectl -n "$NS" annotate application "$a" argocd.argoproj.io/refresh=hard --overwrite >/dev/null
  done
  sleep 30
}

capture() {
  for app in $APPS; do
    echo "### $app"
    kubectl -n "$NS" get application "$app" -o jsonpath='{range .status.resources[?(@.group=="gateway.kgateway.dev")]}{.kind}{"/"}{.name}{" ("}{.namespace}{") -> "}{.health.status}{"\n"}{end}'
  done
}

# 1. Remove every mapped key. "Absent" is fine; any other error is fatal
#    (swallowing errors once left a key behind and faked the before-state).
for k in ${ANCESTORS_KINDS} ${CONDITIONS_KINDS}; do
  if kubectl -n "$NS" get cm argocd-cm -o json | jq -e --arg key "${PREFIX}${k}" '.data|has($key)' >/dev/null; then
    kubectl -n "$NS" patch cm argocd-cm --type=json \
      -p "[{\"op\":\"remove\",\"path\":\"/data/${PREFIX}${k}\"}]" >/dev/null \
      || { echo "ERROR: failed to remove ${PREFIX}${k}" >&2; exit 1; }
  fi
  if kubectl -n "$NS" get cm argocd-cm -o json | jq -e --arg key "${PREFIX}${k}" '.data|has($key)' >/dev/null; then
    echo "ERROR: ${PREFIX}${k} still present after removal" >&2; exit 1
  fi
done

# 2-4. Before capture, asserted empty.
hard_refresh_and_wait
capture | tee docs/evidence/before.txt
if grep -E -- '-> .+$' docs/evidence/before.txt; then
  echo "ERROR: a resource still reports health in the before-state (lines above)" >&2; exit 1
fi
echo "before-state is genuine"

# 5-6. Apply, after capture, asserted non-empty.
kubectl -n "$NS" patch configmap argocd-cm --patch-file healthchecks/argocd-cm-patch.yaml >/dev/null
hard_refresh_and_wait
capture | tee docs/evidence/after.txt
if grep -E -- '-> *$' docs/evidence/after.txt; then
  echo "ERROR: a resource has no health status in the after-state (lines above)" >&2; exit 1
fi
echo "after-state is complete"
