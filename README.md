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

The real gate is argo-cd's own test harness, not the badges in the UI. All 21
testdata fixtures are tracked in this repo under
`healthchecks/lua/<Kind>/testdata/`, across five kinds (`Backend`,
`TrafficPolicy`, `ListenerPolicy`, `BackendConfigPolicy`, `DirectResponse`).
13 are live captures, 7 are derived from a capture, and 1 is synthetic; each
file's header comment, and the header of `hack/extract-testdata.sh`, say which
is which.

`hack/extract-testdata.sh` refreshes 12 of the captured fixtures from the live
cluster, and 7 of those 12 come from the coverage resources. So the cluster must
have **all three** Applications deployed, not just the two the demo walks
through. Follow [DEMO.md](DEMO.md) first, including its "Deploy the coverage
resources" step: it must run **after** `kgw-demo` has synced, because the
coverage resources live in the `httpbin` namespace and attach to `demo-gateway`,
both created by `kgw-demo`. [COVERAGE.md](COVERAGE.md) records what each
coverage resource is for and the status it was observed to produce. Without
them `extract-testdata.sh` fails on the first missing resource, and so do
`check-generated.sh` and `capture-evidence.sh`.

```bash
./hack/extract-testdata.sh      # regenerates out/resource_customizations/gateway.kgateway.dev
./hack/install-to-argocd.sh     # mirrors that tree into your argo-cd clone
cd <path-to-argo-cd-clone>
go test -v ./util/lua/ -run 'TestLuaHealthScript/gateway.kgateway.dev'
```

`install-to-argocd.sh` reads the clone location from `ARGOCD_DIR` (the script
sets a default; override it for your clone), refuses an empty source, and syncs only the
`resource_customizations/gateway.kgateway.dev` directory, so uncommitted work
elsewhere in the clone is never touched. Prefer it over a manual `cp -r`, which
leaves stale files behind when a fixture is removed.

Verified against argo-cd `2f3711241` (base of the upstream branch): the command
above reports 21 passing fixtures.

### Regenerating the before/after evidence

`./hack/capture-evidence.sh` removes every health key from `argocd-cm`, captures `docs/evidence/before.txt` (asserting every health status is empty), applies the patch, and captures `after.txt` (asserting every status is non-empty). It hard-refreshes the Applications each time because they cache per-resource health and ignore an `argocd-cm` change until refreshed, so a plain sleep yields plausible but stale statuses.

### Reproducibility guard

**Convention: every assertion over a collection first asserts that the
collection is non-empty, with the expected count as a literal.** A predicate
quantified over an empty set is vacuously true, and "all statuses are empty" or
"all fixtures pass" then succeeds having checked nothing. When the set grows or
shrinks, the literal is updated in the same commit, which makes the change
visible in review.

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
