#!/usr/bin/env bash
# Installs everything ArgoCD is NOT responsible for: Gateway API CRDs,
# kgateway, and ArgoCD itself. ArgoCD then manages only the demo resources,
# which keeps its resource tree limited to the objects whose health we care
# about.
set -euo pipefail

cd "$(dirname "$0")"
source ./env.sh

echo "==> Gateway API ${GWAPI_VERSION} CRDs"
# MUST come first: no kgateway chart bundles these, so a Gateway or HTTPRoute
# would fail discovery on a clean cluster.
kubectl apply -f "${GWAPI_MANIFEST}"
kubectl wait --for=condition=Established --timeout=60s \
  crd/gateways.gateway.networking.k8s.io \
  crd/httproutes.gateway.networking.k8s.io

echo "==> kgateway ${KGATEWAY_VERSION}"
helm upgrade --install kgateway-crds "${KGATEWAY_CRDS_CHART}" \
  --version "${KGATEWAY_VERSION}" \
  --namespace "${KGATEWAY_NS}" --create-namespace --wait
helm upgrade --install kgateway "${KGATEWAY_CHART}" \
  --version "${KGATEWAY_VERSION}" \
  --namespace "${KGATEWAY_NS}" --wait
kubectl -n "${KGATEWAY_NS}" rollout status deploy/kgateway --timeout=180s

echo "==> Argo CD (chart ${ARGOCD_CHART_VERSION})"
helm upgrade --install argo-cd argo-cd \
  --repo "${ARGOCD_CHART_REPO}" \
  --version "${ARGOCD_CHART_VERSION}" \
  --namespace "${ARGOCD_NS}" --create-namespace --wait \
  -f - <<EOF
configs:
  params:
    server.insecure: true
  cm:
    # Short reconciliation so health-check edits surface in seconds while
    # iterating on the Lua.
    timeout.reconciliation: 10s
EOF
kubectl -n "${ARGOCD_NS}" rollout status deploy/argo-cd-argocd-server --timeout=300s

echo
echo "Setup complete."
echo "  GatewayClass:   $(kubectl get gatewayclass kgateway -o jsonpath='{.metadata.name}' 2>/dev/null || echo MISSING)"
echo "  ArgoCD admin:   kubectl -n ${ARGOCD_NS} get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d"
echo "  ArgoCD UI:      kubectl -n ${ARGOCD_NS} port-forward svc/argo-cd-argocd-server 8080:80"
