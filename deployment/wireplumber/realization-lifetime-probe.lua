-- Isolated public-interface experiment, not the production connection policy.
local args = (...):parse()
local scopes = {}

local function inspect(scope)
  if scope.removed or scope.withdrawing then return end
  for pod in scope.object:iterate_params("Props") do
    local fields = pod:parse().properties.params
    assert(type(fields) == "table" and #fields == 6, "Unexpected probe Props")
    assert(fields[1] == "version" and fields[2] == 1)
    assert(fields[3] == "generation" and type(fields[4]) == "number")
    assert(fields[5] == "phase" and type(fields[6]) == "number")
    local generation, phase = fields[4], fields[6]
    assert(phase >= 0 and phase <= 2 and phase % 1 == 0)
    assert(not scope.generation or scope.generation == generation)
    assert(not scope.phase or phase >= scope.phase, "Phase regressed")
    scope.generation, scope.phase = generation, phase
    print("PROBE_PHASE " .. generation .. " " .. phase)
    if phase == 2 then
      scope.withdrawing = true
      -- The production policy must additionally drain every pending link
      -- activation. This probe has no links and qualifies only the primitive.
      Core.sync(function(error)
        assert(not error, tostring(error))
        if scope.removed then return end
        scope.object:request_destroy()
        print("PROBE_DESTROY_REQUESTED " .. generation)
      end)
    end
  end
end

realization_probe_om = ObjectManager {
  Interest { type = "node",
    Constraint { "node.name", "=", args["node.name"], type = "pw-global" } },
}
realization_probe_om:connect("object-added", function(_, object)
  local id = object["bound-id"]
  local scope = { object = object, id = id,
    serial = object["global-properties"]["object.serial"] }
  scopes[id] = scope
  object:connect("params-changed", function(_, name)
    if name == "Props" then inspect(scope) end
  end)
  print("PROBE_BOUND " .. id .. " " .. tostring(scope.serial))
  inspect(scope)
end)
realization_probe_om:connect("object-removed", function(_, object)
  local scope = scopes[object["bound-id"]]
  if not scope then return end
  scope.removed = true
  print("PROBE_REMOVED " .. tostring(scope.generation))
end)
realization_probe_om:activate()
