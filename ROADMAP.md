# ArgoCD health checks for kgateway — roadmap

Programme-level view of the work tracked by
[kgateway-dev/kgateway#13871](https://github.com/kgateway-dev/kgateway/issues/13871).
Each phase gets its own design spec and implementation plan under
[`docs/superpowers/`](docs/superpowers/); this page says what the phases are,
what ships to whom, and in what order.

**Last updated:** 2026-10-05

## The problem

ArgoCD has no built-in health checks for kgateway's CRDs, so resources managed
by an ArgoCD Application show `(none)` for health even when the controller has
written a clear status. Worse, an Application full of broken kgateway resources
reports **Healthy**, because ArgoCD has no opinion about resources it cannot
assess. Standard `gateway.networking.k8s.io` resources do have checks; the
`gateway.kgateway.dev` ones do not.

## Delivery model

Two vehicles for the same Lua, and the order matters:

1. **`argocd-cm` ConfigMap — ships first.** Works on any ArgoCD version with no
   upstream dependency, which makes it both the development loop (edit, apply,
   watch the badge change in ~10s) and the first thing users and customers get.
2. **Bundled upstream in `argoproj/argo-cd` — ships after.** Gets the checks in
   front of everyone by default, on ArgoCD's release cadence.

`argocd-cm` entries **override** bundled checks (`util/lua/lua.go`,
`GetHealthScript`: configmap exact → configmap wildcard → embedded exact →
embedded wildcard). So the ConfigMap is not merely a stopgap — it stays valid
after the upstream PR merges, and remains the escape hatch for anyone who needs
different semantics. Customer-facing docs must say when it is safe to remove.

## Status

| Phase | Scope | State |
|---|---|---|
| 1 | `gateway.kgateway.dev`: `Backend`, `TrafficPolicy` | **Complete.** 11 cluster-captured fixtures, passing argo-cd's own harness, proven on a live cluster |
| 2 | `gateway.kgateway.dev`: `ListenerPolicy`, `BackendConfigPolicy`, `DirectResponse`, `GatewayExtension` | Design started — scope agreed, Sections 2-4 outstanding |
| 3 | `enterprisekgateway.solo.io`, `enterprise.solo.io`, `waf.solo.io` | Not designed |
| 4 | `portal.solo.io` | Not designed |

### Currently supported

```
resource.customizations.health.gateway.kgateway.dev_Backend
resource.customizations.health.gateway.kgateway.dev_TrafficPolicy
```

### Excluded, with reasons

| Kind | Why |
|---|---|
| `GatewayParameters` | No status implemented — the CRD schema says so outright. Any check would be a constant. Revisit if kgateway implements status. |
| `HTTPListenerPolicy` | Deprecated in 2.4.x in favour of `ListenerPolicy.spec.httpSettings`, and already absent from `main`. A check would ship for a kind that disappears next minor. |
| `ratelimit.solo.io/RateLimitConfig` | Empty status — same case as `GatewayParameters`. Confirm against a live SEFK cluster during phase 3. |
| `extauth.solo.io/AuthConfig` | Empty status — as above. |

## Phases

### Phase 2 — remaining kgateway OSS CRDs

Brings `gateway.kgateway.dev` coverage to six kinds and **closes #13871**.

Agreed so far: two byte-identical Lua scripts (one per status shape) using
`obj.kind` for messages, copied per kind with a drift test — argo-cd's Lua VM
has no module system, so this is the only way to avoid four hand-maintained
copies; a third ArgoCD Application `kgw-coverage` holds the new kinds so the
demo narrative stays minimal; eight new fixtures (healthy + degraded per kind),
19 total.

Also in scope: refactoring phase 1's two scripts onto the shared form. That
change is behaviour-preserving — the rendered messages are identical — so the
existing 11 fixtures are its regression test.

**Ships:** OSS ConfigMap package, then the upstream PR.

### Phase 3 — Solo Enterprise for kgateway

`enterprisekgateway.solo.io` (TrafficPolicy, Parameters, DestinationSelector),
`enterprise.solo.io` (EnterpriseListenerSet), `waf.solo.io` (WAFPolicy). Same
two status shapes, so the Lua transfers nearly unchanged.

Two things make this unlike phases 1-2. It needs a **licensed SEFK cluster** to
capture fixtures, since the method is probe-first rather than written from
source. And whether these checks go upstream at all is a genuine question:
being commercial is no barrier (upstream already carries checks for
`datadoghq.com`, `coralogix.com`, `astra.netapp.io`, and Solo's own
`gateway.solo.io`/`gloo.solo.io`), but the ConfigMap may simply be the better
vehicle for a product with its own release cadence.

**Ships:** the customer package.

### Phase 4 — Portal

`portal.solo.io`: `Portal`, `ApiProduct`, `ApiDoc`, and possibly
`PortalConfig`, `PortalParameters`, `VisibilityPolicy` (several have no status
— confirm live).

The interesting one is `ApiProduct`, which nests `status.versions[].conditions[]`.
A per-version failure must surface rather than hide behind top-level
conditions, so this needs real aggregation design rather than a copy of what
exists.

## Documentation deliverables

Not yet written, and not yet in any phase's plan. The repo's current docs
(`README.md`, `DEMO.md`, `SCENARIOS.md`) are written for us, not for consumers.

| Deliverable | Audience | When |
|---|---|---|
| OSS ConfigMap package — install, what each status means, how to remove once upstream ships | kgateway OSS users | end of phase 2 |
| Customer package — as above plus SEFK-specific kinds and supported version matrix | SEFK customers | end of phase 3 |
| Upstream PR body + `#13871` closing comment | argo-cd maintainers, kgateway community | with the PR |
| Product docs entry | docs.solo.io / kgateway.dev | after phase 3 — owner TBD |

## Method

Worth stating because it constrains scheduling, and because departing from it
caused every significant defect found so far:

- **Probe first.** Scenario behaviour is predicted from source, then verified on
  a live cluster before fixtures are built. Phase 1's probe caught two API
  errors that would otherwise have shipped.
- **Capture, don't author.** Fixtures are `kubectl get -o yaml` from a real
  cluster. Where a state cannot be produced, say so in the PR rather than
  fabricating it. Derived fixtures carry a header disclosing exactly what was
  substituted.
- **Verify shipped CRDs, not Go types.** The two differ. kgateway v2.4.5 ships
  8 CRDs where `main` ships 7; SEFK ships 14 across six groups where the Go
  types suggested three in one.

## Open decisions

- Exact timing of the upstream PR relative to the OSS ConfigMap release — the
  PR is held at a local commit and folds in phase 2 before opening.
- Whether phase 3's SEFK checks go upstream or stay ConfigMap-only.
- Owner and location for the product-docs entry.
