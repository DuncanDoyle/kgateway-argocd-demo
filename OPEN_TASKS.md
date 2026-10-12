# Open tasks

Deferred work, in rough priority order. See [ROADMAP.md](ROADMAP.md) for the
programme view and what each phase covers.

**Last updated:** 2026-10-07

## Current approach: ConfigMap first, upstream later

The health checks ship as an `argocd-cm` ConfigMap patch
([docs/INSTALL.md](docs/INSTALL.md)). That works on any ArgoCD version with no
upstream dependency, and it is deliberately the only delivery route for now.

**Contributing these checks to `argoproj/argo-cd` is deferred until the
ConfigMap package has been used in anger.** The reasoning: the Lua is correct
against a test cluster and argo-cd's own harness, but nobody has yet run it
against a real deployment with real resources and real failure modes. Early
users are far better placed to find the gaps than another review pass is, and
anything they turn up is much cheaper to fix in a ConfigMap than in a merged
upstream script that ships on someone else's release cadence.

Upstream is still the destination — it is how everyone gets the checks by
default — just not the next step.

## Before proposing upstream

Only relevant once the ConfigMap package has been validated in real use.

- [ ] **Add a DCO sign-off to the contribution commit.** `argoproj/argo-cd`
      runs a `dco` check on pull requests and will not merge without it:
      `git commit --amend -s`. The sign-off certifies you have the right to
      submit the contribution under the project's licence — see
      [developercertificate.org](https://developercertificate.org/). It is an
      attestation, so it has to be made deliberately rather than added as a
      formatting step.
- [ ] **Replace the PR-link placeholder** in the issue comment draft once a PR
      exists. The draft carries a pre-post checklist.
- [ ] **Re-run the full `./util/lua/` suite** against whatever `upstream/master`
      is at the time. The branch is rebased onto a specific base, and that will
      be stale by then.
- [ ] **Re-read both drafts for accuracy.** They quote fixture counts, a base
      SHA and test results that will all have moved.

## Before the ConfigMap package is handed to anyone

- [ ] **Verify `setup.sh` on a clean machine.** It has only ever run where the
      minikube node image and the Helm charts were already cached locally, so
      the `registry.k8s.io` pull path is untested — and that is the path anyone
      reproducing from the README takes. Needs a full teardown and rebuild, so
      do it when the cluster is no longer needed as a fixture source.
- [ ] **Follow [docs/INSTALL.md](docs/INSTALL.md) end to end on a cluster you
      did not build**, to catch anything that only works here.
- [ ] **Bump the pin in `docs/INSTALL.md`.** The patch file changed (header
      note) and `healthchecks/argocd-helm-values.yaml` is new, so the pinned
      commit `d034785` predates both — route B's file does not exist there.
      Must be updated in or immediately after the commit that lands these.
- [ ] **Run a live `helm upgrade` with `argocd-helm-values.yaml`.** The values
      shape is verified by `helm template` against chart 10.9.2 (all five keys
      land in `argocd-cm`, Lua byte-identical to the patch), but no actual
      upgrade has been performed.
- [ ] Note the untested paths that document already declares:
      `controller.resource.health.persist` unset, and the `curl` alternative.

## Documentation gaps

Resolved 2026-10-12 in the README/DEMO readability pass: the three-Application
structure is now introduced before the names are used, `kgw-scenarios` is named
as a prerequisite of the capture scripts, the wait-for-Healthy gate is explicit,
and the sync step no longer assumes a logged-in `argocd` CLI.

- [ ] `docs/evidence/{before,after}.txt` can go stale without anything
      noticing: `hack/check-generated.sh` only diffs `healthchecks/`. If the
      demo or coverage manifests gain or lose a resource, the committed
      evidence keeps showing the old capture until someone re-runs
      `hack/capture-evidence.sh` by hand. Note that `EXPECTED_RESOURCES=14` in
      that script would catch a count change *when run*, but nothing prompts
      the run.
- [ ] `docs/INSTALL.md` does not state its `jq` prerequisite, used by the key
      removal loop.
- [ ] `docs/INSTALL.md`'s `kubectl rollout restart` line names a
      release-specific StatefulSet; the "name varies" note is easy to miss.
- [ ] `README.md` says `hack/check-generated.sh` needs "the live cluster"; it
      actually needs the cluster **in the states the fixtures expect**.
- [ ] `COVERAGE.md`'s fixtures table says "none reachable" for
      `DirectResponse`'s degraded cell. The evidence supports "none obtained;
      one mechanism tried" — the surrounding prose is correctly hedged, this is
      one cell.

## Tooling

- [ ] **The pin in `docs/INSTALL.md` can go stale silently.** It points at a
      specific commit of `healthchecks/argocd-cm-patch.yaml` so readers get
      reviewed code rather than whatever `main` holds. If the patch changes and
      the pin is not bumped, readers quietly get superseded Lua.
      Enforce it in `hack/check-generated.sh` — but compare **blob content**
      (`git rev-parse <pin>:healthchecks/argocd-cm-patch.yaml` against
      `HEAD:…`), not commit SHAs: a SHA check can never pass on the very commit
      that changes the patch and updates the pin together, because that
      commit's own SHA is not knowable when writing it.
- [x] ~~Nothing runs `check-generated.sh` automatically.~~ Resolved
      2026-10-12: `SKIP_REFRESH=1` makes `extract-testdata.sh` cluster-free, so
      `.github/workflows/ci.yml` now runs both the generated-file check and the
      argo-cd Lua harness on every push. Refreshing fixtures from a live
      cluster remains manual and is triggered by a kgateway version bump, not a
      schedule — see `hack/README.md`.
- [ ] `hack/install-to-argocd.sh` tests `-d "$ARGOCD_DIR/.git"`, which rejects
      a git worktree or submodule checkout where `.git` is a file. Use `-e`.
      Fails safe today.
- [ ] `hack/install-to-argocd.sh`'s trailing `git status` can make the script
      exit non-zero after a successful sync, under `set -e`.
- [ ] `hack/install-to-argocd.sh`'s content guard requires only **one**
      `health.lua` in the source, so a half-generated tree could still let
      `rsync --delete` drop the rest from the destination.
- [ ] `hack/capture-evidence.sh`'s "key absent" check treats a `kubectl get`
      failure as absence. Not exploitable — a later step fails under
      `pipefail` — but it is the wrong signal.

## Fixtures and naming

- [ ] `manifests/coverage/listenerpolicy.yaml`'s `lp-degraded-ca` is named and
      commented as a degraded attempt but reports **Healthy**, because kgateway
      accepts a `caCertificateRefs` pointing at a missing ConfigMap. The
      behaviour is real and documented in `COVERAGE.md`; the name misleads in
      the evidence table. Rename it, or change the comment.
- [ ] `docs/evidence/after.txt` ships that `Healthy` row with no in-file note
      explaining it.
- [ ] `COVERAGE.md`'s `bcp-healthy` row still describes a superseded first run
      that targeted the demo's Backend.

## Known kgateway gaps

- [ ] [kgateway#14792](https://github.com/kgateway-dev/kgateway/issues/14792) —
      `GatewayExtension` declares a status subresource but never populates it.
      Filed 2026-10-06. Until it is implemented, `GatewayExtension` cannot have
      a meaningful health check and stays excluded.
