#!/usr/bin/env bash
# Kind -> status shape. One shared script serves every kind of a shape; the
# copies are assembled here rather than hand-maintained, so they cannot drift.
# A kind missing from these lists silently gets no health.lua, and argo-cd's
# harness then reports "no tests to run" rather than failing — so the
# completeness check in extract-testdata.sh exists to catch exactly that.
ANCESTORS_KINDS="TrafficPolicy ListenerPolicy BackendConfigPolicy DirectResponse"
CONDITIONS_KINDS="Backend"
