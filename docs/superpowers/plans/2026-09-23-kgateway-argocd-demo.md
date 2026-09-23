# kgateway + ArgoCD Health-Check Demo Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a minimal, self-contained kgateway + ArgoCD demo that produces cluster-extracted test fixtures for ArgoCD health checks covering `gateway.kgateway.dev/TrafficPolicy` and `Backend`, verified by argo-cd's own `go test ./util/lua/`.

**Architecture:** A setup script installs Gateway API CRDs, kgateway and ArgoCD out-of-band. ArgoCD then manages two Applications over one public GitHub repo — a always-green demo app and an on-demand scenarios app holding deliberately-broken resources. Health-check Lua is developed against the live cluster via `argocd-cm` (which overrides bundled checks), then emitted in `resource_customizations/` layout for an upstream PR.

**Tech Stack:** bash, kubectl, Helm, Kubernetes Gateway API v1.6.1, kgateway v2.4.5, Argo CD (chart 10.9.2 / appVersion v3.5.3), Lua 5.1 (gopher-lua, as embedded by argo-cd), Go (for running argo-cd's test harness).

**Spec:** `docs/superpowers/specs/2026-09-22-kgateway-argocd-demo-design.md`

## Global Constraints

- **Repo:** `DuncanDoyle/kgateway-argocd-demo` — already created and public. Local path `~/Development/github/kgateway-argocd-demo`.
  - **Push remote (SSH):** `git@github.com:DuncanDoyle/kgateway-argocd-demo.git`
  - **`REPO_URL` for ArgoCD (HTTPS):** `https://github.com/DuncanDoyle/kgateway-argocd-demo.git` — ArgoCD pulls anonymously and cannot use an SSH URL without a key Secret, which this demo deliberately avoids. These two are NOT interchangeable.
- **Gateway API:** `v1.6.1`, Standard channel. Must be installed **before** kgateway — no kgateway chart bundles these CRDs.
- **kgateway:** `v2.4.5`, charts `oci://cr.kgateway.dev/kgateway-dev/charts/kgateway-crds` and `oci://cr.kgateway.dev/kgateway-dev/charts/kgateway`, namespace `kgateway-system`. (OCI path and version verified 2026-09-23.)
- **Argo CD:** chart `argo-cd` version `10.9.2` from `https://argoproj.github.io/argo-helm`, namespace `argocd`, installed with `timeout.reconciliation: 10s`.
- **Workload image:** `docker.io/mccutchen/go-httpbin:v2.9.2@sha256:8b27c0fcea0d386992f26d33c0eaadf1709e759f9d3e8b6622d276d10d0569fe` (digest verified 2026-09-23). go-httpbin listens on **8080**; the Service exposes **8000**.
- **argo-cd clone** for the test harness: `~/Development/github/argo-cd`, SHA `a770f6f6019205ca66dcf2eaea6a6c244fb16bad`. Record the SHA in the README next to the test run.
- **Cluster:** minikube primary, but no minikube-only assumptions. Gateway reached via `kubectl port-forward`.
- **Never hand-author a fixture and present it as cluster-extracted.** Fixtures come from `kubectl get -o yaml`. The single possible exception is `backend-stale`, and only after capture is attempted and fails (Task 5).
- **Scope is a partial contribution.** kgateway#13871 stays open. Do not write checks for `HTTPListenerPolicy` (deprecated in v2.4.5, absent from `main`) or `GatewayParameters` (no status).
- **Size note:** this plan creates well over 5 files and 400 lines, exceeding the AGENTS.md change-size guardrail. Approving this plan is the approval for that.

---

### Task 1: Repository skeleton and pinned configuration

**Files:**
- Create: `~/Development/github/kgateway-argocd-demo/env.sh`
- Create: `~/Development/github/kgateway-argocd-demo/.gitignore`
- Create: `~/Development/github/kgateway-argocd-demo/README.md`
- Move: `docs/superpowers/specs/2026-09-22-kgateway-argocd-demo-design.md` and `docs/superpowers/plans/2026-09-23-kgateway-argocd-demo.md` into the new repo, preserving paths

**Interfaces:**
- Consumes: nothing
- Produces: `env.sh` exporting `REPO_URL`, `REPO_REVISION`, `GWAPI_VERSION`, `KGATEWAY_VERSION`, `ARGOCD_CHART_VERSION`, `HTTPBIN_IMAGE`, `DEMO_NS`, `SCENARIOS_NS`, `KGATEWAY_NS`, `ARGOCD_NS`. Every later script sources this file and uses no other source of versions.

- [ ] **Step 1: Create the repo directory and initialise git**

```bash
mkdir -p ~/Development/github/kgateway-argocd-demo
cd ~/Development/github/kgateway-argocd-demo
git init -b main
```

- [ ] **Step 2: Write `env.sh`**

```bash
#!/usr/bin/env bash
# Single source of truth for every external version and identifier.
# Swapping the git source (e.g. to an in-cluster Gitea) means changing
# REPO_URL/REPO_REVISION here and nothing else.

# --- git source ArgoCD pulls manifests from -------------------------------
# HTTPS, not SSH: ArgoCD pulls anonymously and has no key. The SSH form is
# only for our own pushes (git remote origin).
export REPO_URL="https://github.com/DuncanDoyle/kgateway-argocd-demo.git"
export REPO_REVISION="HEAD"

# --- pinned external artifacts --------------------------------------------
# Gateway API CRDs. kgateway 2.4.x is built against v1.6.1; no kgateway
# chart bundles these, so they must be applied first.
export GWAPI_VERSION="v1.6.1"
export GWAPI_MANIFEST="https://github.com/kubernetes-sigs/gateway-api/releases/download/${GWAPI_VERSION}/standard-install.yaml"

export KGATEWAY_VERSION="v2.4.5"
export KGATEWAY_CRDS_CHART="oci://cr.kgateway.dev/kgateway-dev/charts/kgateway-crds"
export KGATEWAY_CHART="oci://cr.kgateway.dev/kgateway-dev/charts/kgateway"

export ARGOCD_CHART_REPO="https://argoproj.github.io/argo-helm"
export ARGOCD_CHART_VERSION="10.9.2"

# Pinned by digest: fixtures must be reproducible byte-for-byte.
export HTTPBIN_IMAGE="docker.io/mccutchen/go-httpbin:v2.9.2@sha256:8b27c0fcea0d386992f26d33c0eaadf1709e759f9d3e8b6622d276d10d0569fe"

# --- namespaces ------------------------------------------------------------
export KGATEWAY_NS="kgateway-system"
export ARGOCD_NS="argocd"
export DEMO_NS="httpbin"
export SCENARIOS_NS="scenarios"
```

- [ ] **Step 3: Write `.gitignore`**

```gitignore
# Extraction output — regenerated from a live cluster, never committed as
# the source of truth. Copied into the argo-cd clone for the upstream PR.
out/
```

- [ ] **Step 4: Write `README.md`**

````markdown
# kgateway + ArgoCD health-check demo

A minimal kgateway demo deployed through ArgoCD, built to produce test
fixtures for ArgoCD health checks covering `gateway.kgateway.dev` CRDs.

Tracks [kgateway#13871](https://github.com/kgateway-dev/kgateway/issues/13871).

## What this is for

ArgoCD has no health checks for `gateway.kgateway.dev/*` resources, so they
show `(none)` in the resource tree. This repo deploys kgateway resources via
ArgoCD, captures their real status in every reachable health state, and turns
that into `resource_customizations/` fixtures for an upstream PR.

## Requirements

- A Kubernetes cluster (developed on minikube; no minikube-specific assumptions)
- `kubectl`, `helm`, `curl`
- For running the upstream test harness: Go and a clone of `argoproj/argo-cd`

## Quick start

```bash
./setup.sh
```

Then follow [DEMO.md](DEMO.md).

## Teardown

```bash
./teardown.sh
```

## Versions

All pins live in [`env.sh`](env.sh). See that file for the authoritative list.
````

- [ ] **Step 5: Move the spec and plan into the repo**

```bash
mkdir -p ~/Development/github/kgateway-argocd-demo/docs/superpowers/specs
mkdir -p ~/Development/github/kgateway-argocd-demo/docs/superpowers/plans
cp /Users/ddoyle/Development/claude/gh_kgw-13871-argocd-claude/docs/superpowers/specs/2026-09-22-kgateway-argocd-demo-design.md \
   ~/Development/github/kgateway-argocd-demo/docs/superpowers/specs/
cp /Users/ddoyle/Development/claude/gh_kgw-13871-argocd-claude/docs/superpowers/plans/2026-09-23-kgateway-argocd-demo.md \
   ~/Development/github/kgateway-argocd-demo/docs/superpowers/plans/
```

- [ ] **Step 6: Verify `env.sh` sources cleanly and exports what later scripts need**

```bash
cd ~/Development/github/kgateway-argocd-demo
bash -c 'source ./env.sh && for v in REPO_URL GWAPI_MANIFEST KGATEWAY_CHART ARGOCD_CHART_VERSION HTTPBIN_IMAGE DEMO_NS SCENARIOS_NS; do
  [ -n "${!v}" ] || { echo "MISSING: $v"; exit 1; }
  echo "$v=${!v}"
done'
```

Expected: every variable printed with a non-empty value, exit 0.

- [ ] **Step 7: Commit and push to the existing public repo**

The repo already exists and is public — do NOT run `gh repo create`. Add the
SSH remote and push.

```bash
cd ~/Development/github/kgateway-argocd-demo
git add .
git commit -m "feat: repo skeleton with pinned versions"   # skip if already committed
git remote add origin git@github.com:DuncanDoyle/kgateway-argocd-demo.git
git push -u origin main
```

- [ ] **Step 8: Verify the repo is reachable anonymously**

ArgoCD pulls without credentials, so an unauthenticated fetch must work.

```bash
# The HTTPS form, unauthenticated — this is exactly what ArgoCD will do.
GIT_TERMINAL_PROMPT=0 git ls-remote \
  https://github.com/DuncanDoyle/kgateway-argocd-demo.git HEAD
```

Expected: a SHA printed, no credential prompt.

---

### Task 2: Cluster bootstrap script

**Files:**
- Create: `~/Development/github/kgateway-argocd-demo/setup.sh`
- Create: `~/Development/github/kgateway-argocd-demo/teardown.sh`

**Interfaces:**
- Consumes: every variable from `env.sh` (Task 1)
- Produces: a cluster with Gateway API v1.6.1 CRDs, kgateway v2.4.5 running in `kgateway-system` with GatewayClass `kgateway`, and ArgoCD in `argocd`. Task 3 assumes all three exist.

- [ ] **Step 1: Write `setup.sh`**

```bash
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
```

- [ ] **Step 2: Write `teardown.sh`**

```bash
#!/usr/bin/env bash
# Removes everything setup.sh created, in reverse order. CRDs last, because
# deleting them first strands finalizers on the CRs.
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
```

- [ ] **Step 3: Make both scripts executable**

```bash
chmod +x setup.sh teardown.sh
```

- [ ] **Step 4: Run setup against a clean cluster**

```bash
minikube delete --profile kgw-argocd || true
minikube start --profile kgw-argocd
kubectl config use-context kgw-argocd
./setup.sh
```

Expected: completes without error; the final banner prints `GatewayClass: kgateway`.

- [ ] **Step 5: Verify the three layers independently**

```bash
kubectl get crd | grep -c 'gateway.networking.k8s.io'   # expect >= 4
kubectl get crd | grep -c 'gateway.kgateway.dev'        # expect 8 (v2.4.5)
kubectl get gatewayclass kgateway \
  -o jsonpath='{.status.conditions[?(@.type=="Accepted")].status}'  # expect True
kubectl -n argocd get deploy argo-cd-argocd-server \
  -o jsonpath='{.status.readyReplicas}'                 # expect 1
```

Expected: 8 kgateway CRDs confirms the v2.4.5 inventory from the spec, including the deprecated `httplistenerpolicies`.

- [ ] **Step 6: Commit**

```bash
git add setup.sh teardown.sh
git commit -m "feat: cluster bootstrap for Gateway API, kgateway and ArgoCD"
```

---

### Task 3: Demo manifests and the always-green Application

**Files:**
- Create: `manifests/demo/namespace.yaml`
- Create: `manifests/demo/httpbin.yaml`
- Create: `manifests/demo/gateway.yaml`
- Create: `manifests/demo/httproute-via-service.yaml`
- Create: `manifests/demo/backend-static.yaml`
- Create: `manifests/demo/httproute-via-backend.yaml`
- Create: `manifests/demo/trafficpolicy-add-header.yaml`
- Create: `argocd/app-demo.yaml`
- Create: `DEMO.md`

**Interfaces:**
- Consumes: cluster from Task 2; `REPO_URL`, `REPO_REVISION`, `DEMO_NS`, `HTTPBIN_IMAGE` from `env.sh`
- Produces: namespace `httpbin` containing `Gateway/demo-gateway`, `HTTPRoute/httpbin-via-service`, `HTTPRoute/httpbin-via-backend`, `Backend/httpbin-static`, `TrafficPolicy/add-demo-header`, all Healthy. Task 5 extracts `Backend/httpbin-static` and `TrafficPolicy/add-demo-header` as the `healthy` fixtures.

- [ ] **Step 1: Write `manifests/demo/namespace.yaml`**

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: httpbin
```

- [ ] **Step 2: Write `manifests/demo/httpbin.yaml`**

Sync wave -1: the workload exists before anything routing to it, so no route
is transiently unresolvable. This is the ordering answer from the spec —
transient unresolvable references are prevented by declaring order, not by
health-check cleverness.

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: httpbin
  namespace: httpbin
  annotations:
    argocd.argoproj.io/sync-wave: "-1"
spec:
  replicas: 1
  selector:
    matchLabels: { app: httpbin }
  template:
    metadata:
      labels: { app: httpbin }
    spec:
      containers:
      - name: httpbin
        # Pinned by digest so extracted fixtures are reproducible.
        image: docker.io/mccutchen/go-httpbin:v2.9.2@sha256:8b27c0fcea0d386992f26d33c0eaadf1709e759f9d3e8b6622d276d10d0569fe
        ports:
        - containerPort: 8080
        readinessProbe:
          httpGet: { path: /status/200, port: 8080 }
---
apiVersion: v1
kind: Service
metadata:
  name: httpbin
  namespace: httpbin
  annotations:
    argocd.argoproj.io/sync-wave: "-1"
spec:
  selector: { app: httpbin }
  ports:
  - name: http
    port: 8000          # what routes and the Backend target
    targetPort: 8080    # what go-httpbin actually listens on
```

- [ ] **Step 3: Write `manifests/demo/gateway.yaml`**

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: demo-gateway
  namespace: httpbin
spec:
  gatewayClassName: kgateway
  listeners:
  - name: http
    port: 8080
    protocol: HTTP
    allowedRoutes:
      namespaces: { from: Same }
```

- [ ] **Step 4: Write `manifests/demo/httproute-via-service.yaml`**

```yaml
# Route A — ordinary Service backendRef. The TrafficPolicy attaches here,
# and only here, which is what makes the two paths visibly differ.
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: httpbin-via-service
  namespace: httpbin
spec:
  parentRefs:
  - name: demo-gateway
  rules:
  - matches:
    - path: { type: PathPrefix, value: /headers }
    backendRefs:
    - name: httpbin
      port: 8000
```

- [ ] **Step 5: Write `manifests/demo/backend-static.yaml`**

```yaml
# Static Backend pointing at httpbin's own in-cluster DNS name. Contrived on
# purpose: it exercises the Backend CRD's status without an off-cluster
# endpoint, keeping the demo offline-capable.
apiVersion: gateway.kgateway.dev/v1alpha1
kind: Backend
metadata:
  name: httpbin-static
  namespace: httpbin
  annotations:
    argocd.argoproj.io/sync-wave: "-1"
spec:
  static:
    hosts:
    - host: httpbin.httpbin.svc.cluster.local
      port: 8000
```

- [ ] **Step 6: Write `manifests/demo/httproute-via-backend.yaml`**

```yaml
# Route B — same workload, reached through the Backend CR instead of the
# Service. URLRewrite so /via-backend lands on httpbin's /headers and returns
# a real response rather than a 404.
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: httpbin-via-backend
  namespace: httpbin
spec:
  parentRefs:
  - name: demo-gateway
  rules:
  - matches:
    - path: { type: PathPrefix, value: /via-backend }
    filters:
    - type: URLRewrite
      urlRewrite:
        path: { type: ReplacePrefixMatch, replacePrefixMatch: /headers }
    backendRefs:
    - group: gateway.kgateway.dev
      kind: Backend
      name: httpbin-static
```

- [ ] **Step 7: Write `manifests/demo/trafficpolicy-add-header.yaml`**

```yaml
# Simplest visible effect: add a request header that httpbin echoes straight
# back in its /headers response body. headerModifiers rather than
# transformation — declarative, no templating DSL to explain.
apiVersion: gateway.kgateway.dev/v1alpha1
kind: TrafficPolicy
metadata:
  name: add-demo-header
  namespace: httpbin
spec:
  targetRefs:
  - group: gateway.networking.k8s.io
    kind: HTTPRoute
    name: httpbin-via-service
  headerModifiers:
    request:
      set:
      - name: X-Kgateway-Demo
        value: hello-from-trafficpolicy
```

- [ ] **Step 8: Write `argocd/app-demo.yaml`**

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: kgw-demo
  namespace: argocd
  finalizers:
  - resources-finalizer.argocd.argoproj.io
spec:
  project: default
  source:
    # Tokens substituted by sed at apply time from env.sh, so REPO_URL stays
    # the single place to change when swapping the git source (e.g. Gitea).
    repoURL: ${REPO_URL}
    targetRevision: ${REPO_REVISION}
    path: manifests/demo
  destination:
    server: https://kubernetes.default.svc
    namespace: httpbin
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
    - CreateNamespace=true
```

- [ ] **Step 9: Commit and push (ArgoCD can only sync what is on the remote)**

```bash
git add manifests/demo argocd/app-demo.yaml
git commit -m "feat: demo manifests and always-green ArgoCD Application"
git push
```

- [ ] **Step 10: Apply the Application and wait for it to go green**

```bash
source ./env.sh
sed -e "s|\${REPO_URL}|${REPO_URL}|g" -e "s|\${REPO_REVISION}|${REPO_REVISION}|g" \
  argocd/app-demo.yaml | kubectl apply -f -
kubectl -n argocd wait --for=jsonpath='{.status.sync.status}'=Synced \
  application/kgw-demo --timeout=180s
kubectl -n argocd wait --for=jsonpath='{.status.health.status}'=Healthy \
  application/kgw-demo --timeout=180s
```

Expected: both waits succeed.

- [ ] **Step 11: Verify the data path proves both CRDs**

```bash
kubectl -n httpbin port-forward svc/demo-gateway 8080:8080 &
PF=$!
sleep 3
echo "--- via Service (TrafficPolicy attached) ---"
curl -s localhost:8080/headers | grep -i 'X-Kgateway-Demo' \
  && echo "OK: header injected"
echo "--- via Backend (no policy attached) ---"
curl -s localhost:8080/via-backend | grep -i 'X-Kgateway-Demo' \
  && echo "UNEXPECTED: header should not be here" || echo "OK: header absent"
kill $PF
```

Expected: header present on `/headers`, absent on `/via-backend`. Both return
a JSON body — a 404 or connection refused means routing is broken, not that
the policy is misapplied.

- [ ] **Step 12: Confirm the CRs actually carry status**

```bash
kubectl -n httpbin get backend httpbin-static -o jsonpath='{.status}' | head -c 400; echo
kubectl -n httpbin get trafficpolicy add-demo-header -o jsonpath='{.status}' | head -c 400; echo
```

Expected: `Backend` shows `conditions` with `Accepted`; `TrafficPolicy` shows
`ancestors` with at least one entry carrying `controllerName`. If either is
empty, stop — every later task depends on real status existing.

- [ ] **Step 13: Write `DEMO.md`**

````markdown
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
````

- [ ] **Step 14: Commit**

```bash
git add DEMO.md
git commit -m "docs: demo walkthrough"
git push
```

---

### Task 4: Scenario manifests and the status probe

This is the task that can invalidate design assumptions. The scenario
mechanisms are traced from kgateway source but **not yet observed**. Record
what actually happens; do not bend observations to match the spec.

**Files:**
- Create: `manifests/scenarios/namespace.yaml`
- Create: `manifests/scenarios/trafficpolicy-progressing.yaml`
- Create: `manifests/scenarios/trafficpolicy-degraded.yaml`
- Create: `manifests/scenarios/backend-degraded.yaml`
- Create: `argocd/app-scenarios.yaml`
- Create: `SCENARIOS.md`

**Interfaces:**
- Consumes: cluster and demo app from Task 3
- Produces: namespace `scenarios` containing `TrafficPolicy/tp-progressing`, `TrafficPolicy/tp-degraded`, `Backend/backend-degraded`; and an observed-status table in `SCENARIOS.md` that Task 5 uses to decide which fixtures exist.

- [ ] **Step 1: Write `manifests/scenarios/namespace.yaml`**

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: scenarios
```

- [ ] **Step 2: Write `manifests/scenarios/trafficpolicy-progressing.yaml`**

```yaml
# Targets an HTTPRoute that does not exist. Translation never encounters the
# ancestor, so no ancestor entry is written and status.ancestors stays empty.
# Expected: Progressing (a health check must not read "no ancestors" as
# healthy).
apiVersion: gateway.kgateway.dev/v1alpha1
kind: TrafficPolicy
metadata:
  name: tp-progressing
  namespace: scenarios
spec:
  targetRefs:
  - group: gateway.networking.k8s.io
    kind: HTTPRoute
    name: no-such-route
  headerModifiers:
    request:
      set:
      - name: X-Never-Applied
        value: "true"
```

- [ ] **Step 3: Write `manifests/scenarios/trafficpolicy-degraded.yaml`**

```yaml
# Attached to a real route, but references a GatewayExtension that does not
# exist. Schema-valid, so it passes admission; fails at translation.
# Expected: Accepted=False / Reason=Invalid -> Degraded.
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: scenarios-route
  namespace: scenarios
  annotations:
    argocd.argoproj.io/sync-wave: "-1"
spec:
  parentRefs:
  - name: demo-gateway
    namespace: httpbin
  rules:
  - matches:
    - path: { type: PathPrefix, value: /scenarios }
    backendRefs:
    - name: httpbin
      namespace: httpbin
      port: 8000
---
apiVersion: gateway.kgateway.dev/v1alpha1
kind: TrafficPolicy
metadata:
  name: tp-degraded
  namespace: scenarios
spec:
  targetRefs:
  - group: gateway.networking.k8s.io
    kind: HTTPRoute
    name: scenarios-route
  extAuth:
    extensionRef:
      name: no-such-gateway-extension
```

> Note: this route crosses namespaces to reach `demo-gateway`, which needs
> the Gateway to allow it. If the demo Gateway's `allowedRoutes.namespaces.from: Same`
> blocks it, the route will not attach and this becomes a second Progressing
> case rather than Degraded. If that happens, move the broken TrafficPolicy
> to target `httpbin-via-service` in the `httpbin` namespace instead, and
> record the change in SCENARIOS.md.

- [ ] **Step 4: Write `manifests/scenarios/backend-degraded.yaml`**

```yaml
# Priority group referencing a Backend that does not exist. Schema-valid (the
# ref is just a name), so it passes admission; fails at translation with
#   priority group 0: backend "no-such-backend" not found in namespace "scenarios"
# Expected: Accepted=False / Reason=Invalid -> Degraded.
apiVersion: gateway.kgateway.dev/v1alpha1
kind: Backend
metadata:
  name: backend-degraded
  namespace: scenarios
spec:
  priorityGroups:
  - backends:
    - name: no-such-backend
```

- [ ] **Step 5: Write `argocd/app-scenarios.yaml`**

```yaml
# Manual sync only: the demo starts all-green and failure states are summoned
# on demand. With both apps synced, Task 5 captures every state in one pass.
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: kgw-scenarios
  namespace: argocd
  finalizers:
  - resources-finalizer.argocd.argoproj.io
spec:
  project: default
  source:
    repoURL: ${REPO_URL}
    targetRevision: ${REPO_REVISION}
    path: manifests/scenarios
  destination:
    server: https://kubernetes.default.svc
    namespace: scenarios
  syncPolicy:
    syncOptions:
    - CreateNamespace=true
```

- [ ] **Step 6: Commit, push, apply and sync**

```bash
git add manifests/scenarios argocd/app-scenarios.yaml
git commit -m "feat: failure scenarios and on-demand ArgoCD Application"
git push
source ./env.sh
sed -e "s|\${REPO_URL}|${REPO_URL}|g" -e "s|\${REPO_REVISION}|${REPO_REVISION}|g" \
  argocd/app-scenarios.yaml | kubectl apply -f -
kubectl -n argocd patch application kgw-scenarios --type merge \
  -p '{"operation":{"sync":{"revision":"HEAD"}}}'
sleep 30
```

- [ ] **Step 7: Confirm the resources exist — admission did not reject them**

```bash
kubectl -n scenarios get trafficpolicy,backend
```

Expected: all three present. A resource **missing** here means admission
rejected it, which is the wrong failure mode — the manifest must be made
semantically wrong rather than structurally wrong. Fix the manifest before
continuing.

- [ ] **Step 8: Run the probe and capture observed status**

```bash
mkdir -p out/probe
for r in trafficpolicy/tp-progressing trafficpolicy/tp-degraded backend/backend-degraded; do
  name=$(echo "$r" | tr '/' '-')
  kubectl -n scenarios get "$r" -o yaml > "out/probe/${name}.yaml"
  echo "=== $r ==="
  kubectl -n scenarios get "$r" -o jsonpath='{.status}' | python3 -m json.tool 2>/dev/null || echo "(no status)"
done
```

- [ ] **Step 9: Probe for the `Pending` reason**

The spec leaves open whether `Accepted=False/Reason=Pending` is ever
observable. Watch while forcing re-reconciliation.

```bash
timeout 60 kubectl -n scenarios get trafficpolicy -o yaml --watch \
  > out/probe/tp-watch.yaml 2>&1 &
sleep 2
for i in 1 2 3 4 5; do
  kubectl -n scenarios patch trafficpolicy tp-degraded --type merge \
    -p "{\"spec\":{\"headerModifiers\":{\"request\":{\"set\":[{\"name\":\"X-Probe\",\"value\":\"$i\"}]}}}}"
  sleep 1
done
wait
grep -c 'reason: Pending' out/probe/tp-watch.yaml || echo "0 — Pending never observed"
```

Record the count. Non-zero means the Lua's Pending branch is load-bearing and
needs a fixture; zero means it is defensive only and **no fixture may be
fabricated for it**.

- [ ] **Step 10: Write `SCENARIOS.md` with the observed results**

Fill the Observed column from Steps 8-9 — not from the spec's predictions.

````markdown
# Failure scenarios

Each resource here is semantically wrong but structurally valid, so it passes
CRD admission and fails at translation. A manifest that admission rejects
produces no resource and therefore no status, which is the wrong failure mode.

| Resource | Mechanism | Predicted | Observed |
|---|---|---|---|
| `TrafficPolicy/tp-progressing` | targets a non-existent HTTPRoute | no ancestors → Progressing | *fill in* |
| `TrafficPolicy/tp-degraded` | `extAuth.extensionRef` → non-existent GatewayExtension | `Accepted=False/Invalid` → Degraded | *fill in* |
| `Backend/backend-degraded` | priority group → non-existent Backend | `Accepted=False/Invalid` → Degraded | *fill in* |

`Accepted=False/Reason=Pending` observed in the watch probe: *fill in count*.

## If a prediction did not hold

Record what actually happened rather than adjusting the observation. A state
that turns out to be unreachable is a finding — but check whether unreachable
is simply *correct* for that CRD before calling it a kgateway bug.
````

- [ ] **Step 11: Commit**

```bash
git add SCENARIOS.md
git commit -m "docs: record observed status for each failure scenario"
git push
```

---

### Task 5: Fixture extraction

**Files:**
- Create: `hack/extract-testdata.sh`

**Interfaces:**
- Consumes: both Applications synced (Tasks 3, 4)
- Produces: `out/resource_customizations/gateway.kgateway.dev/{Backend,TrafficPolicy}/testdata/*.yaml` — full manifests, `status` intact, cluster noise stripped. Tasks 6 and 7 write `health.lua` and `health_test.yaml` beside them.

- [ ] **Step 1: Write `hack/extract-testdata.sh`**

```bash
#!/usr/bin/env bash
# Dumps live resources into argo-cd's resource_customizations layout.
#
# Strips managedFields/uid/resourceVersion/creationTimestamp/selfLink — noise
# that upstream's existing fixtures do not carry — but keeps the status
# subresource completely intact, which is the entire point of the fixture.
set -euo pipefail

cd "$(dirname "$0")/.."
source ./env.sh

OUT="out/resource_customizations/gateway.kgateway.dev"

# extract <namespace> <resource/name> <Kind> <state>
extract() {
  local ns="$1" res="$2" kind="$3" state="$4"
  local dir="${OUT}/${kind}/testdata"
  mkdir -p "$dir"
  kubectl -n "$ns" get "$res" -o yaml \
    | python3 -c '
import sys, yaml
d = yaml.safe_load(sys.stdin)
d["metadata"].pop("managedFields", None)
for k in ("uid", "resourceVersion", "creationTimestamp", "selfLink"):
    d["metadata"].pop(k, None)
d["metadata"].pop("annotations", None)
# An EMPTY status is legitimate for the progressing fixture: a policy that
# attaches to nothing writes no ancestors at all. Warn rather than fail, but
# make the absence loud so it is never silently mistaken for a dump error.
if not d.get("status"):
    print("WARNING: no status on " + d["metadata"]["name"], file=sys.stderr)
yaml.safe_dump(d, sys.stdout, default_flow_style=False, sort_keys=False)
' > "${dir}/${state}.yaml"
  echo "wrote ${dir}/${state}.yaml"
}

extract "${DEMO_NS}"      backend/httpbin-static        Backend       healthy
extract "${SCENARIOS_NS}" backend/backend-degraded      Backend       degraded
extract "${DEMO_NS}"      trafficpolicy/add-demo-header TrafficPolicy healthy
extract "${SCENARIOS_NS}" trafficpolicy/tp-degraded     TrafficPolicy degraded
extract "${SCENARIOS_NS}" trafficpolicy/tp-progressing  TrafficPolicy progressing

# Copy authored content (health.lua, health_test.yaml) in beside the captured
# fixtures, so out/ is a complete resource_customizations tree ready to drop
# into an argo-cd clone. Authored files live under healthchecks/; out/ is
# generated and gitignored.
for kind in Backend TrafficPolicy; do
  for f in health.lua health_test.yaml; do
    if [ -f "healthchecks/lua/${kind}/${f}" ]; then
      cp "healthchecks/lua/${kind}/${f}" "${OUT}/${kind}/${f}"
    fi
  done
done

echo
echo "Extraction complete. Review each file before use:"
find "${OUT}" -type f | sort
```

- [ ] **Step 2: Make executable and run**

```bash
chmod +x hack/extract-testdata.sh
./hack/extract-testdata.sh
```

Expected: five files written. A `WARNING: no status` line is expected for
`tp-progressing` — a policy attached to nothing writes no ancestors, which is
the state that fixture exists to capture. A warning on any *other* resource
means status is genuinely missing; stop and investigate.

- [ ] **Step 3: Attempt to capture the stale-generation state**

A generation mismatch is a real state in the API server (spec edited,
controller has not yet written status), so it is capturable — just
short-lived. Try before hand-authoring.

```bash
timeout 90 kubectl -n httpbin get backend httpbin-static -o yaml --watch \
  > out/probe/backend-watch.yaml 2>&1 &
sleep 2
for i in 1 2 3 4 5 6 7 8 9 10; do
  kubectl -n httpbin patch backend httpbin-static --type merge \
    -p "{\"metadata\":{\"labels\":{\"probe\":\"$i\"}}}" >/dev/null
  kubectl -n httpbin patch backend httpbin-static --type merge \
    -p "{\"spec\":{\"static\":{\"hosts\":[{\"host\":\"httpbin.httpbin.svc.cluster.local\",\"port\":8000}]}}}" >/dev/null
done
wait
python3 - <<'EOF'
import yaml
docs = [d for d in yaml.safe_load_all(open('out/probe/backend-watch.yaml')) if d]
for d in docs:
    gen = d.get('metadata', {}).get('generation')
    for c in d.get('status', {}).get('conditions', []) or []:
        og = c.get('observedGeneration')
        if gen is not None and og is not None and og != gen:
            print("CAPTURED stale:", "generation", gen, "observedGeneration", og)
            yaml.safe_dump(d, open('out/probe/backend-stale-captured.yaml', 'w'), sort_keys=False)
            raise SystemExit(0)
print("not captured — hand-author required")
EOF
```

- [ ] **Step 4: Produce the stale fixture**

If Step 3 captured it, clean `out/probe/backend-stale-captured.yaml` with the
same stripping as `extract()` and save as
`out/resource_customizations/gateway.kgateway.dev/Backend/testdata/stale.yaml`.

If it did not, copy `Backend/testdata/healthy.yaml` to `stale.yaml` and
decrement `observedGeneration` on every condition by 1, leaving
`metadata.generation` unchanged. Add a comment at the top of the file:

```yaml
# Hand-authored: a generation mismatch closes too quickly to capture reliably.
# Derived from a real cluster dump with observedGeneration decremented.
```

Say which route was taken in the upstream PR description.

- [ ] **Step 5: Commit the extraction script**

```bash
git add hack/extract-testdata.sh
git commit -m "feat: extract fixtures into argo-cd resource_customizations layout"
git push
```

---

### Task 6: Backend health check (TDD against argo-cd's harness)

**Files:**
- Create: `healthchecks/lua/Backend/health.lua`
- Create: `healthchecks/lua/Backend/health_test.yaml`
- Test: `~/Development/github/argo-cd/util/lua/health_test.go` (existing harness, not modified)

**Interfaces:**
- Consumes: fixtures from Task 5
- Produces: `healthchecks/lua/Backend/health.lua` — copied into the argo-cd
  clone by Step 5 of this task, into `out/` by extract-testdata.sh, and
  compiled into `argocd-cm` form by Task 8's render script.

- [ ] **Step 1: Read the real messages from the fixtures**

The expected messages in `health_test.yaml` must be what the controller
actually wrote, not what we assume.

```bash
cd ~/Development/github/kgateway-argocd-demo
for f in out/resource_customizations/gateway.kgateway.dev/Backend/testdata/*.yaml; do
  echo "=== $f ==="
  python3 -c "
import yaml,sys
d=yaml.safe_load(open('$f'))
for c in d.get('status',{}).get('conditions',[]) or []:
    print(c.get('type'), c.get('status'), c.get('reason'), '|', c.get('message'))
"
done
```

- [ ] **Step 2: Write the failing test**

Write `healthchecks/lua/Backend/health_test.yaml`, substituting the messages
printed in Step 1. It lives beside the Lua because it is authored content;
`out/` holds only generated files and is gitignored.

```yaml
tests:
- healthStatus:
    status: Healthy
    message: "<message from healthy.yaml Accepted condition>"
  inputPath: testdata/healthy.yaml
- healthStatus:
    status: Degraded
    message: "<message from degraded.yaml Accepted condition>"
  inputPath: testdata/degraded.yaml
- healthStatus:
    status: Progressing
    message: "Waiting for Backend status"
  inputPath: testdata/stale.yaml
```

- [ ] **Step 3: Copy into the argo-cd clone and run the test to see it fail**

```bash
cp -r out/resource_customizations/gateway.kgateway.dev \
      ~/Development/github/argo-cd/resource_customizations/
cd ~/Development/github/argo-cd
go test -v ./util/lua/ -run 'TestLuaHealthScript/gateway.kgateway.dev'
```

Expected: FAIL — there is no `health.lua` yet, so the health status comes back
empty and does not match.

- [ ] **Step 4: Write the implementation**

`healthchecks/lua/Backend/health.lua`:

```lua
-- Health check for gateway.kgateway.dev/Backend.
--
-- Status shape: status.conditions[] (standard metav1.Condition list).
-- Two condition types, both owned by kgateway
-- (api/v1alpha1/kgateway/backend_types.go):
--   Accepted            True/Accepted | False/Invalid
--   EndpointsDiscovered True/Discovered
--                     | False/{NoMatchingInstances,CredentialError,
--                              AuthorizationError,DiscoveryError,Degraded}
--
-- EndpointsDiscovered is a RUNTIME condition: a Backend can be Accepted=True
-- and still be failing endpoint discovery. We therefore aggregate over every
-- recognised condition rather than returning on the first True — returning
-- early on Accepted=True would report a broken backend as Healthy.
local hs = {}

local RECOGNISED = { Accepted = true, EndpointsDiscovered = true }

-- Stale status describes the previous spec, so treat it as "not yet known"
-- rather than reporting a verdict about configuration that no longer exists.
local function isStale(obj, condition)
  if obj.metadata == nil or obj.metadata.generation == nil then
    return false
  end
  if condition.observedGeneration == nil then
    return false
  end
  return condition.observedGeneration ~= obj.metadata.generation
end

if obj.status ~= nil and obj.status.conditions ~= nil then
  local degradedMsg = nil
  local healthyMsg = nil
  local sawStale = false

  for _, condition in ipairs(obj.status.conditions) do
    if RECOGNISED[condition.type] then
      if isStale(obj, condition) then
        sawStale = true
      elseif condition.status == "False" then
        -- First failure wins the message; any failing condition is Degraded.
        if degradedMsg == nil then
          degradedMsg = condition.message or (condition.type .. " is False")
        end
      elseif condition.status == "True" then
        if healthyMsg == nil then
          healthyMsg = condition.message or (condition.type .. " is True")
        end
      end
    end
  end

  -- Precedence: Degraded > Progressing > Healthy.
  if degradedMsg ~= nil then
    hs.status = "Degraded"
    hs.message = degradedMsg
    return hs
  end
  if sawStale then
    hs.status = "Progressing"
    hs.message = "Waiting for Backend status"
    return hs
  end
  if healthyMsg ~= nil then
    hs.status = "Healthy"
    hs.message = healthyMsg
    return hs
  end
end

hs.status = "Progressing"
hs.message = "Waiting for Backend status"
return hs
```

- [ ] **Step 5: Copy the script in and run the test to see it pass**

```bash
cd ~/Development/github/kgateway-argocd-demo
cp healthchecks/lua/Backend/health.lua \
   ~/Development/github/argo-cd/resource_customizations/gateway.kgateway.dev/Backend/health.lua
cd ~/Development/github/argo-cd
go test -v ./util/lua/ -run 'TestLuaHealthScript/gateway.kgateway.dev/Backend'
```

Expected: PASS for all three fixtures. If the Healthy message does not match,
correct `health_test.yaml` to the controller's actual message — do not change
the Lua to produce a message the controller never wrote.

- [ ] **Step 6: Commit**

```bash
cd ~/Development/github/kgateway-argocd-demo
git add healthchecks/lua/Backend/health.lua healthchecks/lua/Backend/health_test.yaml
git commit -m "feat: Backend health check with condition aggregation"
git push
```

---

### Task 7: TrafficPolicy health check (TDD against argo-cd's harness)

**Files:**
- Create: `healthchecks/lua/TrafficPolicy/health.lua`
- Create: `healthchecks/lua/TrafficPolicy/health_test.yaml`
- Create: `out/resource_customizations/gateway.kgateway.dev/TrafficPolicy/testdata/foreign_controller.yaml`

**Interfaces:**
- Consumes: fixtures from Task 5; the same stripping conventions as Task 6
- Produces: `healthchecks/lua/TrafficPolicy/health.lua`

- [ ] **Step 1: Read the real messages and controllerName from the fixtures**

```bash
cd ~/Development/github/kgateway-argocd-demo
for f in out/resource_customizations/gateway.kgateway.dev/TrafficPolicy/testdata/*.yaml; do
  echo "=== $f ==="
  python3 -c "
import yaml
d=yaml.safe_load(open('$f'))
for a in d.get('status',{}).get('ancestors',[]) or []:
    print('controllerName:', a.get('controllerName'))
    for c in a.get('conditions',[]) or []:
        print(' ', c.get('type'), c.get('status'), c.get('reason'), '|', c.get('message'))
"
done
```

Record the exact `controllerName` string — the Lua filters on it.

- [ ] **Step 2: Build the foreign-controller fixture**

kgateway preserves ancestors written by other controllers
(`pkg/pluginsdk/statussync/writer.go:267`), so the check must ignore them.
Derive this fixture from the real `healthy.yaml` by appending a second
ancestor owned by someone else.

```bash
python3 - <<'EOF'
import yaml, copy
src = 'out/resource_customizations/gateway.kgateway.dev/TrafficPolicy/testdata/healthy.yaml'
d = yaml.safe_load(open(src))
ancestors = d['status']['ancestors']
foreign = copy.deepcopy(ancestors[0])
foreign['controllerName'] = 'example.com/some-other-controller'
for c in foreign.get('conditions', []):
    c['status'] = 'False'
    c['reason'] = 'Invalid'
    c['message'] = 'Rejected by a controller that does not own this resource'
d['status']['ancestors'] = ancestors + [foreign]
out = 'out/resource_customizations/gateway.kgateway.dev/TrafficPolicy/testdata/foreign_controller.yaml'
with open(out, 'w') as f:
    f.write('# Derived from healthy.yaml with a second ancestor owned by an\n')
    f.write('# unrelated controller appended, to prove the check ignores it.\n')
    yaml.safe_dump(d, f, sort_keys=False)
print('wrote', out)
EOF
```

- [ ] **Step 2b: Build the remaining derived fixtures**

The spec requires the check to be pinned against each `Attached` reason,
`PartiallyValid`, and a resource with no status. These states cannot be
produced by this demo — `Overridden` needs two competing policies and
`PartiallyValid` needs a partially-rejected spec — so they are **derived**
from the real `healthy.yaml` with the reason swapped, each carrying a header
comment saying so. This is the same technique as `foreign_controller.yaml`,
and it is not the same as inventing status the controller never writes: the
structure is real, only the reason string is substituted.

```bash
python3 - <<'EOF'
import yaml, copy
base = 'out/resource_customizations/gateway.kgateway.dev/TrafficPolicy/testdata/'
src = yaml.safe_load(open(base + 'healthy.yaml'))

def derive(name, note, mutate):
    d = copy.deepcopy(src)
    mutate(d)
    with open(base + name, 'w') as f:
        f.write('# Derived from healthy.yaml: ' + note + '\n')
        yaml.safe_dump(d, f, sort_keys=False)
    print('wrote', base + name)

def set_condition(d, ctype, status, reason, message):
    for a in d['status']['ancestors']:
        found = False
        for c in a.get('conditions', []):
            if c['type'] == ctype:
                c.update(status=status, reason=reason, message=message)
                found = True
        if not found:
            first = a['conditions'][0]
            a['conditions'].append({
                'type': ctype, 'status': status, 'reason': reason,
                'message': message,
                'lastTransitionTime': first.get('lastTransitionTime'),
                'observedGeneration': first.get('observedGeneration'),
            })

derive('overridden.yaml',
       'Attached=False/Overridden — policy exists but is not in effect.',
       lambda d: set_condition(d, 'Attached', 'False', 'Overridden',
                               'Policy is overridden by a more specific policy'))

derive('partially_valid.yaml',
       'Accepted=False/PartiallyValid — part of the policy was rejected.',
       lambda d: set_condition(d, 'Accepted', 'False', 'PartiallyValid',
                               'Policy was partially accepted'))

derive('no_status.yaml',
       'status removed entirely — the resource exists but has not been reconciled.',
       lambda d: d.pop('status', None))
EOF
```

- [ ] **Step 3: Write the failing test**

`healthchecks/lua/TrafficPolicy/health_test.yaml`, with messages substituted
from Step 1:

```yaml
tests:
- healthStatus:
    status: Healthy
    message: "<message from healthy.yaml Accepted condition>"
  inputPath: testdata/healthy.yaml
- healthStatus:
    status: Degraded
    message: "<message from degraded.yaml Accepted condition>"
  inputPath: testdata/degraded.yaml
- healthStatus:
    status: Progressing
    message: "Waiting for TrafficPolicy status"
  inputPath: testdata/progressing.yaml
# The foreign ancestor is Invalid but owned by another controller, so the
# result must be identical to healthy.yaml.
- healthStatus:
    status: Healthy
    message: "<same message as healthy.yaml>"
  inputPath: testdata/foreign_controller.yaml
- healthStatus:
    status: Degraded
    message: "Policy is overridden by a more specific policy"
  inputPath: testdata/overridden.yaml
- healthStatus:
    status: Degraded
    message: "Policy was partially accepted"
  inputPath: testdata/partially_valid.yaml
- healthStatus:
    status: Progressing
    message: "Waiting for TrafficPolicy status"
  inputPath: testdata/no_status.yaml
```

- [ ] **Step 4: Copy in and run the test to see it fail**

```bash
cp -r out/resource_customizations/gateway.kgateway.dev \
      ~/Development/github/argo-cd/resource_customizations/
cd ~/Development/github/argo-cd
go test -v ./util/lua/ -run 'TestLuaHealthScript/gateway.kgateway.dev/TrafficPolicy'
```

Expected: FAIL — no `health.lua` for TrafficPolicy yet.

- [ ] **Step 5: Write the implementation**

`healthchecks/lua/TrafficPolicy/health.lua`:

```lua
-- Health check for gateway.kgateway.dev/TrafficPolicy.
--
-- Status shape: status.ancestors[].conditions[] (Gateway API policy
-- attachment). Structured after
-- resource_customizations/gateway.envoyproxy.io/BackendTrafficPolicy/health.lua,
-- which solves the same shape, with two deliberate divergences:
--
--  1. We branch on REASON, not on status alone. kgateway defaults both the
--     Accepted and Attached conditions to False/Pending when translation has
--     set no condition (pkg/reports/policy.go). Pending means "seen, not yet
--     decided" and is Progressing; only Invalid is Degraded. Envoy Gateway
--     has no Pending reason, so its script checks status == "False" alone.
--
--  2. We filter ancestors by controllerName. kgateway preserves ancestors
--     written by other controllers in the status it writes
--     (pkg/pluginsdk/statussync/writer.go MergePolicyAncestorStatuses), so
--     an unfiltered check would report another controller's verdict as ours.
--     Same bug class as argo-cd#29823 for BackendTLSPolicy.
--
-- Reasons (api/v1alpha1/shared/policy_types.go):
--   Accepted: Valid | PartiallyValid | Invalid | Pending
--   Attached: Attached | Merged | Overridden | Invalid | Pending
local hs = {}

local CONTROLLER = "kgateway.dev/kgateway"

-- Reasons that mean "degraded" on either condition type.
local DEGRADED_REASON = {
  Invalid = true,          -- rejected outright
  PartiallyValid = true,   -- part of the policy was rejected
  Overridden = true,       -- exists but is not in effect
}

local function isStale(obj, condition)
  if obj.metadata == nil or obj.metadata.generation == nil then
    return false
  end
  if condition.observedGeneration == nil then
    return false
  end
  return condition.observedGeneration ~= obj.metadata.generation
end

if obj.status ~= nil and obj.status.ancestors ~= nil then
  local degradedMsg = nil
  local progressing = false
  local healthyMsg = nil

  for _, ancestor in ipairs(obj.status.ancestors) do
    -- Ignore ancestors we do not own.
    if ancestor.controllerName == CONTROLLER and ancestor.conditions ~= nil then
      for _, condition in ipairs(ancestor.conditions) do
        if condition.type == "Accepted" or condition.type == "Attached" then
          if isStale(obj, condition) then
            progressing = true
          elseif condition.reason == "Pending" then
            progressing = true
          elseif DEGRADED_REASON[condition.reason] then
            if degradedMsg == nil then
              degradedMsg = condition.message
                or (condition.type .. ": " .. condition.reason)
            end
          elseif condition.status == "True" then
            if healthyMsg == nil then
              healthyMsg = condition.message
                or (condition.type .. " is True")
            end
          elseif condition.status == "False" then
            -- False with an unrecognised reason: treat as degraded rather
            -- than silently healthy.
            if degradedMsg == nil then
              degradedMsg = condition.message
                or (condition.type .. " is False")
            end
          end
        end
      end
    end
  end

  -- Precedence: Degraded > Progressing > Healthy.
  if degradedMsg ~= nil then
    hs.status = "Degraded"
    hs.message = degradedMsg
    return hs
  end
  if progressing then
    hs.status = "Progressing"
    hs.message = "Waiting for TrafficPolicy status"
    return hs
  end
  if healthyMsg ~= nil then
    hs.status = "Healthy"
    hs.message = healthyMsg
    return hs
  end
end

-- No ancestors we own means the policy has not attached to anything. That is
-- not healthy — it must not fall through to Healthy.
hs.status = "Progressing"
hs.message = "Waiting for TrafficPolicy status"
return hs
```

- [ ] **Step 6: Copy in and run the test to see it pass**

```bash
cd ~/Development/github/kgateway-argocd-demo
cp healthchecks/lua/TrafficPolicy/health.lua \
   ~/Development/github/argo-cd/resource_customizations/gateway.kgateway.dev/TrafficPolicy/health.lua
cd ~/Development/github/argo-cd
go test -v ./util/lua/ -run 'TestLuaHealthScript/gateway.kgateway.dev'
```

Expected: PASS for every fixture in both kinds.

- [ ] **Step 7: Commit**

```bash
cd ~/Development/github/kgateway-argocd-demo
git add healthchecks/lua/TrafficPolicy/health.lua healthchecks/lua/TrafficPolicy/health_test.yaml
git commit -m "feat: TrafficPolicy health check with reason branching and controller scoping"
git push
```

---

### Task 8: argocd-cm delivery and live verification

**Files:**
- Create: `hack/render-argocd-cm.sh`
- Create: `healthchecks/argocd-cm-patch.yaml` (generated, committed)

**Interfaces:**
- Consumes: `healthchecks/lua/{Backend,TrafficPolicy}/health.lua` (Tasks 6, 7)
- Produces: a ConfigMap patch users apply on any ArgoCD version; this is the delivery vehicle for customers on older ArgoCD and the escape hatch after the upstream PR merges.

- [ ] **Step 1: Write `hack/render-argocd-cm.sh`**

```bash
#!/usr/bin/env bash
# Compiles healthchecks/lua/<Kind>/health.lua into the argocd-cm form.
#
# argocd-cm entries OVERRIDE bundled checks (util/lua/lua.go GetHealthScript:
# configmap exact -> configmap wildcard -> embedded exact -> embedded
# wildcard), so this works before the upstream PR merges AND remains a valid
# escape hatch afterwards.
set -euo pipefail

cd "$(dirname "$0")/.."
OUT="healthchecks/argocd-cm-patch.yaml"

{
  cat <<'HEADER'
# GENERATED by hack/render-argocd-cm.sh — do not edit by hand.
# Apply with:
#   kubectl -n argocd patch configmap argocd-cm --patch-file healthchecks/argocd-cm-patch.yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: argocd-cm
  namespace: argocd
data:
HEADER
  for kind in Backend TrafficPolicy; do
    echo "  resource.customizations.health.gateway.kgateway.dev_${kind}: |"
    sed 's/^/    /' "healthchecks/lua/${kind}/health.lua"
  done
} > "${OUT}"

echo "wrote ${OUT}"
```

- [ ] **Step 2: Render and apply**

```bash
chmod +x hack/render-argocd-cm.sh
./hack/render-argocd-cm.sh
kubectl -n argocd patch configmap argocd-cm --patch-file healthchecks/argocd-cm-patch.yaml
```

- [ ] **Step 3: Verify the YAML is well-formed before trusting the badges**

A malformed block scalar silently yields no health check rather than an error.

```bash
python3 -c "
import yaml
d = yaml.safe_load(open('healthchecks/argocd-cm-patch.yaml'))
for k, v in d['data'].items():
    assert v.strip().endswith('return hs'), k + ' does not end with return hs'
    print(k, '->', len(v.splitlines()), 'lines')
"
```

Expected: both keys listed, each ending in `return hs`.

- [ ] **Step 4: Verify health in the live cluster**

ArgoCD re-evaluates within `timeout.reconciliation` (10s).

```bash
sleep 20
kubectl -n argocd get application kgw-demo \
  -o jsonpath='{range .status.resources[?(@.group=="gateway.kgateway.dev")]}{.kind}{"/"}{.name}{" -> "}{.health.status}{"\n"}{end}'
kubectl -n argocd get application kgw-scenarios \
  -o jsonpath='{range .status.resources[?(@.group=="gateway.kgateway.dev")]}{.kind}{"/"}{.name}{" -> "}{.health.status}{"\n"}{end}'
```

Expected: `kgw-demo` resources `Healthy`; `kgw-scenarios` showing `Degraded`
and `Progressing` per the observed table in SCENARIOS.md. Anything reporting
empty means the ConfigMap key name does not match the group/kind.

- [ ] **Step 5: Capture the before/after evidence for the PR**

Take two screenshots of the ArgoCD UI resource tree — one before the
ConfigMap patch showing `(none)`, one after showing real badges. Save to
`docs/images/`. (Re-create the "before" by removing the two keys from
`argocd-cm` and waiting 20s, if the patch is already applied.)

- [ ] **Step 6: Commit**

```bash
git add hack/render-argocd-cm.sh healthchecks/argocd-cm-patch.yaml docs/images
git commit -m "feat: argocd-cm delivery for the health checks"
git push
```

---

### Task 9: Upstream contribution and issue update

**Files:**
- Modify: `README.md` (add verification + upstream sections)
- Create: files under `~/Development/github/argo-cd/resource_customizations/gateway.kgateway.dev/` (in a branch of that clone)
- Modify: `~/Development/github/argo-cd/docs/operator-manual/upgrading/overview.md`

**Interfaces:**
- Consumes: everything from Tasks 5-8
- Produces: an upstream PR against `argoproj/argo-cd`, and an updated kgateway#13871.

- [ ] **Step 1: Confirm the local argo-cd clone is current before citing it**

```bash
cd ~/Development/github/argo-cd
git log -1 --format='%H %cd' HEAD
gh api repos/argoproj/argo-cd/commits/master --jq '.sha'
```

If HEAD is behind, `git pull` and re-run the tests before opening a PR —
a fixture that passes on a stale clone proves nothing about current master.

- [ ] **Step 2: Run the full harness, not just our subtests**

```bash
cd ~/Development/github/argo-cd
go test -v ./util/lua/
```

Expected: PASS overall. A failure elsewhere means the copied directory broke
something — investigate before proceeding.

- [ ] **Step 3: Add the upgrade-notes entry**

Append under *Custom Healthchecks Added* in
`docs/operator-manual/upgrading/overview.md`:

```markdown
- `gateway.kgateway.dev/Backend`
- `gateway.kgateway.dev/TrafficPolicy`
```

- [ ] **Step 4: Open the upstream PR**

```bash
cd ~/Development/github/argo-cd
git checkout -b feat/kgateway-health-checks
git add resource_customizations/gateway.kgateway.dev docs/operator-manual/upgrading/overview.md
git commit -m "feat(health): add health checks for gateway.kgateway.dev Backend and TrafficPolicy"
git push -u origin feat/kgateway-health-checks
```

The PR description must state, explicitly:
- that `Pending` reasons map to Progressing, diverging from the
  `gateway.envoyproxy.io` model, and why kgateway needs it
- that ancestors are scoped by `controllerName` **deliberately** (same bug
  class as #29823), not overlooked
- which fixtures were captured from a cluster and which — if any — were
  hand-authored, and why
- that `EndpointsDiscovered` failure modes are handled by the Lua but have no
  fixtures, because producing them needs real AWS credentials
- that this covers 2 of the group's CRDs, with the rest tracked in
  kgateway#13871

- [ ] **Step 5: Update kgateway#13871**

Post a comment that corrects the status table and records scope. Keep it
short — dense over exhaustive. It must contain:
- the corrected shape table, noting 8 CRDs at v2.4.5 vs 7 on `main`
- that `DirectResponse` now has `PolicyStatus` and `GatewayParameters` has no
  status, contradicting the original issue body
- a link to the upstream PR
- the remaining kinds as named follow-ups, so the issue stays open with a
  clear remainder

**Sanitisation:** this is a public OSS repo. Before posting, run the
`sanitize-kgateway-oss-resources` skill over the comment and the PR body — no
customer names, no `solo-io/gloo-gateway` links, no internal tracker IDs, no
local filesystem paths. Reference the demo by its GitHub URL only.

- [ ] **Step 6: Add the verification section to `README.md`**

````markdown
## Verifying the health checks

The real gate is argo-cd's own test harness, not the badges in the UI.

```bash
./hack/extract-testdata.sh
cp -r out/resource_customizations/gateway.kgateway.dev \
      <path-to-argo-cd-clone>/resource_customizations/
cd <path-to-argo-cd-clone>
go test -v ./util/lua/ -run 'TestLuaHealthScript/gateway.kgateway.dev'
```

Verified against argo-cd `a770f6f6019205ca66dcf2eaea6a6c244fb16bad`.

## Using the checks before they ship upstream

`argocd-cm` entries override bundled checks, so this works on any ArgoCD
version — and remains a valid override afterwards:

```bash
kubectl -n argocd patch configmap argocd-cm \
  --patch-file healthchecks/argocd-cm-patch.yaml
```
````

- [ ] **Step 7: Commit**

```bash
cd ~/Development/github/kgateway-argocd-demo
git add README.md
git commit -m "docs: verification and argocd-cm usage"
git push
```

---

## Notes for the executor

**The probe in Task 4 is allowed to invalidate this plan.** Tasks 5-7 assume
`tp-degraded` and `backend-degraded` reach `Degraded` and `tp-progressing`
reaches `Progressing`. If the observed status differs, stop and report rather
than adjusting fixtures to fit — the fixture set is derived from observation,
which is the entire reason the harness exists.

**Captured vs derived vs fabricated.** Three distinct things, and the PR must
say which is which:
- *Captured* — `kubectl get -o yaml` from a live cluster. The default, and
  what the harness exists to produce.
- *Derived* — a captured dump with one documented field substituted
  (`foreign_controller.yaml`, `overridden.yaml`, `partially_valid.yaml`,
  `no_status.yaml`). Legitimate: the structure is real. Each carries a header
  comment saying what was changed.
- *Fabricated* — invented wholesale. Never do this. If a state cannot be
  produced or credibly derived, say so in SCENARIOS.md and in the PR instead.

`backend-stale` is the one fixture that may need hand-authoring, and only
after Task 5 Step 3's capture attempt fails.

**Messages come from the controller.** Where `health_test.yaml` says
`<message from ...>`, read the actual value out of the fixture. If a test
fails on a message mismatch, the test is wrong, not the controller.
