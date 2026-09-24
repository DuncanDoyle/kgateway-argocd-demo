#!/usr/bin/env bash
# Removes everything setup.sh created, in reverse order. CRDs last, because
# deleting them first strands finalizers on the CRs.
#
# NOT fully true for ArgoCD's own CRDs (applications.argoproj.io and
# siblings): the argo-helm chart annotates them helm.sh/resource-policy:
# keep, so `helm uninstall argo-cd` intentionally leaves them installed.
# Verified live -- they survive this script. Delete them manually for a
# fully clean cluster: `kubectl delete crd -l app.kubernetes.io/part-of=argocd`.
set -euo pipefail

cd "$(dirname "$0")"
source ./env.sh

kubectl delete application --all -n "${ARGOCD_NS}" --ignore-not-found --timeout=120s || true
helm uninstall argo-cd -n "${ARGOCD_NS}" || true
kubectl delete ns "${DEMO_NS}" "${SCENARIOS_NS}" "${ARGOCD_NS}" --ignore-not-found --timeout=180s || true
helm uninstall kgateway -n "${KGATEWAY_NS}" || true
helm uninstall kgateway-crds -n "${KGATEWAY_NS}" || true
kubectl delete ns "${KGATEWAY_NS}" --ignore-not-found --timeout=120s || true
kubectl delete -f "${GWAPI_MANIFEST}" --ignore-not-found || true

echo "Teardown complete."
