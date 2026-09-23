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
