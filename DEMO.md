# Running the demo

```bash
./setup.sh
kubectl apply -f argocd/app-demo.yaml
```

Open the ArgoCD UI:

```bash
kubectl -n argocd port-forward svc/argo-cd-argocd-server 8080:80
# user: admin
kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath='{.data.password}' | base64 -d; echo
```

The `kgw-demo` Application tree shows the Gateway, both HTTPRoutes, the
Backend and the TrafficPolicy. Note that `Backend` and `TrafficPolicy` show
**no health status** — that is the gap this repo exists to close.

## Prove the data path

```bash
kubectl -n httpbin port-forward svc/demo-gateway 8080:8080
curl -s localhost:8080/headers      | jq '.headers["X-Kgateway-Demo"]'
curl -s localhost:8080/via-backend  | jq '.headers["X-Kgateway-Demo"]'
```

`/headers` routes through the Service and has the TrafficPolicy attached, so
the injected header comes back. `/via-backend` routes through the `Backend`
CR with no policy attached, so it does not.

## Failure scenarios

```bash
source ./env.sh && sed -e "s|\${REPO_URL}|${REPO_URL}|g" \
  -e "s|\${REPO_REVISION}|${REPO_REVISION}|g" \
  argocd/app-scenarios.yaml | kubectl apply -f -
argocd app sync kgw-scenarios   # or press Sync in the UI
```

See [SCENARIOS.md](SCENARIOS.md) for what each resource is meant to show.
