# Running the demo

```bash
./setup.sh
source ./env.sh && sed -e "s|\${REPO_URL}|${REPO_URL}|g" \
  -e "s|\${REPO_REVISION}|${REPO_REVISION}|g" \
  argocd/app-demo.yaml | kubectl apply -f -
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

## Deploy the coverage resources

The `kgw-coverage` Application holds resources in several health states for
`ListenerPolicy`, `BackendConfigPolicy` and `DirectResponse`. It is not
part of the narrative; it generates the status that
`hack/extract-testdata.sh` captures, so `extract-testdata.sh`,
`check-generated.sh` and `capture-evidence.sh` all need it.

```bash
source ./env.sh && sed -e "s|\${REPO_URL}|${REPO_URL}|g" \
  -e "s|\${REPO_REVISION}|${REPO_REVISION}|g" \
  argocd/app-coverage.yaml | kubectl apply -f -
argocd app sync kgw-coverage   # or press Sync in the UI
```

Order matters: sync `kgw-demo` first. The coverage resources live in the
`httpbin` namespace, which `kgw-demo` creates, and attach to `demo-gateway`.
Applied earlier, they have no namespace to land in and nothing to attach to.
See [COVERAGE.md](COVERAGE.md) for what each resource is for and what was
observed.

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
