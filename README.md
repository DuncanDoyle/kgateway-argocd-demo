# kgateway + ArgoCD health-check demo

A minimal kgateway demo deployed through ArgoCD, built to produce test
fixtures for ArgoCD health checks covering `gateway.kgateway.dev` CRDs.

Tracks [kgateway#13871](https://github.com/kgateway-dev/kgateway/issues/13871).

For the programme view — phases, what ships to whom, and what is
deliberately excluded — see [ROADMAP.md](ROADMAP.md).

**Using the health checks:** see [docs/INSTALL.md](docs/INSTALL.md).

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

The real gate is argo-cd's own test harness, not the badges in the UI. All
11 testdata fixtures are tracked in this repo under
`healthchecks/lua/{Backend,TrafficPolicy}/testdata/` — 5 are live captures,
6 are derived/asserted (see each file's header comment, and
`hack/extract-testdata.sh`'s own comments, for which is which).

```bash
./setup.sh                      # needed: extract-testdata.sh refreshes
                                 # the 5 captured fixtures from this cluster
./hack/extract-testdata.sh
cp -r out/resource_customizations/gateway.kgateway.dev \
      <path-to-argo-cd-clone>/resource_customizations/
cd <path-to-argo-cd-clone>
go test -v ./util/lua/ -run 'TestLuaHealthScript/gateway.kgateway.dev'
```

Verified against argo-cd `1db740c1fa7854052c554742d4d6baaa2663c952`
(`upstream/master`, 2026-09-24) — 11/11 fixtures pass; the full
`go test -v ./util/lua/` suite also passes on this base, so the added
checks don't regress anything else in the harness. Re-verified 2026-09-24
following the exact steps above from a fresh clone of this repo.

### Regenerating the before/after evidence

`./hack/capture-evidence.sh` removes every health key from `argocd-cm`, captures `docs/evidence/before.txt` (asserting every health status is empty), applies the patch, and captures `after.txt` (asserting every status is non-empty). It hard-refreshes the Applications each time because they cache per-resource health and ignore an `argocd-cm` change until refreshed, so a plain sleep yields plausible but stale statuses.

### Reproducibility guard

`healthchecks/` holds generated artefacts (captured fixtures and the
`argocd-cm` patch). To prove they still match what the scripts produce:

```bash
./hack/check-generated.sh   # needs the live cluster; fails if healthchecks/ drifts
```

It re-runs `extract-testdata.sh` and `render-argocd-cm.sh`, then fails on any
`git diff` under `healthchecks/`. Re-captures that differ only in
`lastTransitionTime` do not count as drift.

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
