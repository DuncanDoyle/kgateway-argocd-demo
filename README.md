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

## Verifying health via CLI

`setup.sh` sets `controller.resource.health.persist: "true"` on the ArgoCD
Helm release. Without it, ArgoCD's default (`resourceHealthSource: appTree`)
never writes per-resource health onto `Application.status.resources[]` — the
UI still shows badges correctly, but `kubectl get application ... jsonpath
'...health.status...'` returns nothing whether or not the health checks
work. If you're pointing this demo at an ArgoCD install that predates this
setting, add it and re-run `helm upgrade` — the application-controller
restarts automatically since the chart checksums `argocd-cmd-params-cm`
into its pod template.

## Verifying the health checks

The real gate is argo-cd's own test harness, not the badges in the UI.

```bash
./hack/extract-testdata.sh
cp -r out/resource_customizations/gateway.kgateway.dev \
      <path-to-argo-cd-clone>/resource_customizations/
cd <path-to-argo-cd-clone>
go test -v ./util/lua/ -run 'TestLuaHealthScript/gateway.kgateway.dev'
```

Verified against argo-cd `1db740c1fa7854052c554742d4d6baaa2663c952`
(`upstream/master`, 2026-09-24). All 11 fixtures pass; the full
`go test -v ./util/lua/` suite also passes on this base, so the added
checks don't regress anything else in the harness.

## Using the checks before they ship upstream

`argocd-cm` entries override bundled checks, so this works on any ArgoCD
version — and remains a valid override afterwards:

```bash
kubectl -n argocd patch configmap argocd-cm \
  --patch-file healthchecks/argocd-cm-patch.yaml
```

## Teardown

```bash
./teardown.sh
```

## Versions

All pins live in [`env.sh`](env.sh). See that file for the authoritative list.
