-- Health check for gateway.kgateway.dev/TrafficPolicy.
--
-- Status shape: status.ancestors[].conditions[] (Gateway API policy
-- attachment, one entry per Gateway/xRoute the policy targets or reaches).
-- Structured after
-- resource_customizations/gateway.envoyproxy.io/BackendTrafficPolicy/health.lua,
-- which solves the same shape, with two deliberate divergences:
--
--  1. We branch on REASON, not on status alone. kgateway defaults both the
--     Accepted and Attached conditions to False/Pending when translation has
--     not yet reconciled them. Pending means "seen, not yet decided" and is
--     Progressing; only Invalid/PartiallyValid/Overridden are Degraded.
--     Envoy Gateway has no Pending reason, so its script checks
--     status == "False" alone.
--
--  2. We filter ancestors by controllerName. kgateway preserves ancestors
--     written by other controllers in the status it writes
--     (pkg/pluginsdk/statussync/writer.go MergePolicyAncestorStatuses), so
--     an unfiltered check would report another controller's verdict as ours.
--
-- Reasons observed on real clusters (see testdata/):
--   Accepted: Valid | PartiallyValid | Invalid | Pending
--   Attached: Attached | Merged | Overridden | Invalid | Pending
--
-- Attached=False/Pending is deliberately Progressing, not Degraded: it is
-- the steady companion of Accepted=False/Invalid (see testdata/degraded.yaml),
-- but also the shape of a policy that is genuinely mid-attachment. Precedence
-- below (Degraded > Progressing > Healthy) means a resource with both
-- Accepted=False/Invalid and Attached=False/Pending still comes out Degraded,
-- via the Accepted condition.
local hs = {}

local CONTROLLER = "kgateway.dev/kgateway"

-- Reasons that mean "degraded" on either condition type.
local DEGRADED_REASON = {
  Invalid = true,          -- rejected outright
  PartiallyValid = true,   -- part of the policy was rejected
  Overridden = true,       -- exists but is not in effect (Attached only)
}

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

-- kgateway has been observed writing message: "" on some conditions (see
-- testdata/degraded.yaml's Attached/Pending condition). In Lua the empty
-- string is truthy, so `condition.message or fallback` would still pick ""
-- and the health badge would render blank. Skip empty messages explicitly
-- and fall back to a synthesized description instead. The guard itself is
-- exercised by testdata/overridden_empty_message.yaml, which relocates that
-- same real empty message onto a DEGRADED_REASON branch where it is
-- actually read (degraded.yaml's own empty message sits on a Pending
-- condition, which short-circuits before condition.message is ever
-- consulted). Same approach as Backend's health.lua.
local function messageOrFallback(condition, fallback)
  if condition.message ~= nil and condition.message ~= "" then
    return condition.message
  end
  return fallback
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
              degradedMsg = messageOrFallback(condition, condition.type .. ": " .. condition.reason)
            end
          elseif condition.status == "True" then
            if healthyMsg == nil then
              healthyMsg = messageOrFallback(condition, condition.type .. " is True")
            end
          elseif condition.status == "False" then
            -- False with an unrecognised reason: treat as degraded rather
            -- than silently healthy.
            if degradedMsg == nil then
              degradedMsg = messageOrFallback(condition, condition.type .. " is False")
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

-- No ancestors we own means the policy has not attached to anything yet
-- (or status is entirely absent). That is not healthy — it must not fall
-- through to Healthy.
hs.status = "Progressing"
hs.message = "Waiting for TrafficPolicy status"
return hs
