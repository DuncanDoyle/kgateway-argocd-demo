# What these scripts are for

Nothing in this directory ships to a user. Delete it and the health checks still work — `hack/` is the Kubernetes-ecosystem convention for scripts that build, generate or check a project rather than being part of it. (`argo-cd` and `kgateway` both have one.)

## The one-paragraph version

The source of truth is **two** Lua files — `healthchecks/lua/ancestors/health.lua` and `healthchecks/lua/conditions/health.lua` — one per status shape. But ArgoCD needs **five** scripts, one per CRD kind, and its Lua sandbox has no `require`, so the copies genuinely cannot share code. Everything here exists to generate those copies from the two originals, prove they are faithful, and keep them from drifting.

## Who runs these, and when

**If you only want to use the health checks, you never run any of them.** Follow [docs/INSTALL.md](../docs/INSTALL.md); it needs nothing from this directory.

These are maintainer scripts, and they are **trigger-based, not scheduled**. There is nothing to run periodically — a quiet repo needs none of this.

| Trigger | Run |
|---|---|
| You edited a `health.lua` | `render-argocd-cm.sh`, then `extract-testdata.sh`, then `install-to-argocd.sh`, then `go test` in the argo-cd clone |
| You added a CRD kind | add it to `kind-shapes.sh` first, then the same chain |
| You bumped the kgateway version | See [Revalidating against a new kgateway](#revalidating-against-a-new-kgateway) below — it needs a rebuilt cluster, not just the script. |
| Before sharing the ConfigMap package with anyone | `check-generated.sh`, then `capture-evidence.sh` |
| Before proposing upstream | all of the above, against a current `upstream/master` |
| Someone reports a resource showing the wrong health | `extract-testdata.sh` to capture the real status, then compare against the fixture you have |

The ordering within the first row matters: `render-argocd-cm.sh` and `extract-testdata.sh` both read the Lua, and `install-to-argocd.sh` copies what `extract-testdata.sh` assembled, so running the installer first copies the previous run's output.

### Revalidating against a new kgateway

The one task that genuinely needs a cluster. A new kgateway release can change the status it writes, and that status is the input every health check is built on.

1. **Bump the pins together** in `env.sh`. `KGATEWAY_VERSION` and `GWAPI_VERSION` are coupled — each kgateway OSS line is built against a specific Gateway API minor, noted in that file.
2. **Rebuild the cluster**: `./teardown.sh`, `./setup.sh`, then [DEMO.md](../DEMO.md) steps 1, 3 and 4 so all three Applications are synced. `extract-testdata.sh` runs under `set -e` and dies on the first resource it cannot find, so a partial deploy just fails.
3. **`./hack/check-generated.sh`** — with no `SKIP_REFRESH`, so it captures from the live cluster. It is the right tool here: it refuses a dirty `healthchecks/` so the diff is attributable, runs the refresh, and re-renders the patch.

**Exit 0** is the normal outcome: kgateway did not change its status output. Bump committed, done.

**Exit 1 with a diff is the finding**, not a failure — the refreshed fixtures are left in your working tree, so `git diff healthchecks/` shows exactly what moved. kgateway changed what it writes; the question is whether the Lua still reaches the right verdict from the new shape:

4. `./hack/install-to-argocd.sh`, then `go test ./util/lua/ -run 'TestLuaHealthScript/gateway.kgateway.dev'` in the argo-cd clone. A failing `health_test.yaml` expectation here *is* the bug report — kgateway moved and the health check did not follow.
5. Update whatever the change invalidated: the Lua if a verdict is now wrong; `health_test.yaml` if an expected message changed; [COVERAGE.md](../COVERAGE.md), which records observed behaviour against a named kgateway version; `kind-shapes.sh` and new fixtures if kgateway added a kind.

`render-argocd-cm.sh` is only needed if step 5 changed the Lua — and CI catches a forgotten re-render on the next push.

### What CI covers, and what it cannot

[`.github/workflows/ci.yml`](../.github/workflows/ci.yml) runs on every push and pull request, **with no cluster**:

- `SKIP_REFRESH=1 ./hack/check-generated.sh` — does `argocd-cm-patch.yaml` still match the Lua it was rendered from? This is the phase-1 failure, caught automatically now.
- The argo-cd Lua harness against the 21 committed fixtures, with an assertion that all 21 subtests actually passed.

`SKIP_REFRESH=1` is what makes this possible: the cluster dependency in `extract-testdata.sh` is confined to the `extract()` function, so skipping the 12 captures leaves pure file assembly. Nothing else in the repo calls `kubectl`.

**What CI cannot check is whether the fixtures still match reality.** Refreshing them answers "has kgateway changed the status it writes?" — a question no commit here can affect, and one only a live cluster can answer. That stays manual, triggered by a kgateway version bump rather than by a schedule.

A timer would be worse than nothing, for two reasons. The demo cluster is minikube with a `teardown.sh`; it does not exist most of the time, and `extract-testdata.sh` dies under `set -e` on the first missing resource — so a nightly run is a nightly red check that means nothing, which is exactly what teaches people to scroll past it. And a fixture diff carries no cause: on a version bump you know why it changed, because you just changed the version; on a timer every diff is an investigation from zero, and most resolve to something you did to the cluster yourself.

## The scripts

| Script | What it does |
|---|---|
| `kind-shapes.sh` | **A library, not a command.** Eight lines mapping each CRD kind to its status shape. `source`d by the three scripts below that need to fan out. |
| `render-argocd-cm.sh` | Lua → the two installable artefacts: `argocd-cm-patch.yaml` (kubectl) and `argocd-helm-values.yaml` (argo-helm). Same scripts, different wrapper. |
| `extract-testdata.sh` | Live cluster → test fixtures, then assembles `out/resource_customizations/`. |
| `install-to-argocd.sh` | Copies that tree into a local `argoproj/argo-cd` clone. |
| `check-generated.sh` | Fails if any committed generated file no longer matches its source. |
| `capture-evidence.sh` | Regenerates `docs/evidence/{before,after}.txt` against a live ArgoCD. |

## The two that look alike: `extract-testdata` vs `capture-evidence`

Both read the live cluster, which makes them easy to confuse. They capture **opposite ends of the same function**: a health check is `status → verdict`, and one captures the input while the other captures the output.

```bash
# extract-testdata.sh reads the kgateway CR's own status subresource
kubectl -n httpbin get trafficpolicy/add-demo-header -o json
#   → healthchecks/lua/TrafficPolicy/testdata/healthy.yaml     (the Lua's INPUT)

# capture-evidence.sh reads ArgoCD's verdict about that same resource
kubectl -n argocd get application kgw-demo -o jsonpath='…{.health.status}…'
#   → docs/evidence/after.txt                                  (the Lua's OUTPUT)
```

Neither looks at what the other looks at. `extract-testdata.sh` never reads an ArgoCD Application and would work on a cluster with no ArgoCD installed at all. `capture-evidence.sh` never reads a TrafficPolicy.

| | `extract-testdata.sh` | `capture-evidence.sh` |
|---|---|---|
| Reads | kgateway CRs' `status` | `Application.status.resources[].health` |
| Writes | 12 YAML fixtures, plus the `out/` tree | Two text transcripts |
| Consumed by | `go test` — machine-read | A human reading a PR or issue |
| Needs ArgoCD? | No | Yes — ArgoCD *is* the thing under test |
| Mutates the cluster? | No, pure read | **Yes** — strips keys from `argocd-cm` |

## The other pair: `check-generated` vs `capture-evidence`

Also easy to confuse, since both end in an assertion against a live cluster. They have different subjects:

- **`check-generated.sh` examines this repo's files.** *Are the committed artefacts stale?* It re-runs both generators and fails on any `git diff` under `healthchecks/`. It never asks whether the Lua is correct — only whether what is committed is what the scripts currently produce.
- **`capture-evidence.sh` examines a running ArgoCD.** *Do these checks actually make health appear in the UI?*

## Three verification layers

They are independent, and each catches what the others cannot:

1. **`go test ./util/lua/`** in an argo-cd clone — does the Lua compute the right verdict from a given status? This is the real correctness gate.
2. **`check-generated.sh`** — do the shipped files still match the scripts those tests exercised? Cheap; catches "fixed the Lua, forgot to regenerate the patch".
3. **`capture-evidence.sh`** — does it survive contact with a real ArgoCD? The first two can both pass on a patch that ArgoCD rejects at load time.

## Before you run them

**`capture-evidence.sh` deliberately breaks the demo for about a minute.** Its first step removes all five health keys so it can prove the before-state is genuinely empty; every badge goes blank until step 5 re-applies the patch. Do not run it with an audience watching. It is self-restoring only if it completes — kill it halfway and the cluster is left with no health checks at all. Budget ~70s for the two 30s refresh waits.

**`check-generated.sh` refuses to start with uncommitted changes under `healthchecks/`**, otherwise your own edits read as drift. It also needs the cluster in the states the fixtures expect, i.e. all three Applications synced.

**`extract-testdata.sh` and `check-generated.sh` need all three Applications**, not just `kgw-demo` — seven of the twelve refreshed fixtures come from the coverage resources. See [../DEMO.md](../DEMO.md).

## Design decisions worth knowing before editing

**`extract-testdata.sh` enumerates what it may overwrite.** Twelve of the 21 fixtures are refreshable from a live cluster; the other nine are derived, hand-captured, or synthetic — states the cluster cannot be made to produce on demand. The script lists those twelve explicitly rather than globbing, so a re-run cannot silently destroy the nine irreplaceable ones.

**It masks `lastTransitionTime` when deciding whether to rewrite a fixture.** A controller re-transition bumps only that field, which would otherwise dirty every tracked fixture on every run and make `check-generated.sh` report drift constantly — the fastest way to teach yourself to ignore it.

**It preserves a fixture's leading comment block.** Annotating a fixture with its provenance does not make it un-refreshable.

**The completeness check iterates the authored directories, not the generated ones.** A kind missing from `kind-shapes.sh` produces no output directory, so checking the output cannot see the omission — and argo-cd's harness reports a cheerful `ok` for a directory with no `health.lua`. Without this check, a forgotten kind looks exactly like a pass.

**`install-to-argocd.sh` refuses a source containing no `health.lua`.** It uses `rsync --delete`, so an empty `out/` after a half-failed generator run would not merely be useless — it would wipe the destination, including uncommitted work in your argo-cd clone.

**`capture-evidence.sh` asserts its capture count as a literal (`EXPECTED_RESOURCES=14`).** Repo-wide convention: every assertion over a collection first asserts the collection is non-empty. "All statuses are empty" is trivially true of zero statuses.
