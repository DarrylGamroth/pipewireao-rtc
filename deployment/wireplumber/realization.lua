-- Exact declared session links. No source release or scientific lifecycle here.
local args = (...):parse()
assert(type(args["node.name"]) == "string", "Realization marker name missing")
local scopes, ports, clients = {}, {}, {}
local MAX_SCOPES, MAX_LINKS = 32, 32
local ADMISSION_TIMEOUT_MS = 5000
local PREPARED, REALIZE, WITHDRAW = 0, 1, 2

local function key(object)
  return tostring(object["bound-id"]) .. ":" .. tostring(object["global-properties"]["object.serial"])
end

local function integer(value)
  return type(value) == "number" and math.type(value) == "integer"
end

local function identity(value)
  assert(type(value) == "table" and #value == 2, "Invalid identity arity")
  assert(integer(value[1]) and value[1] > 0 and value[1] < 0xffffffff, "Invalid global ID")
  assert(integer(value[2]) and value[2] ~= 0, "Invalid object serial")
  return Pod.Struct { Pod.Id(value[1]), Pod.Long(value[2]) }
end

local function endpoint(value)
  assert(type(value) == "table" and #value == 3, "Invalid endpoint arity")
  return Pod.Struct { identity(value[1]), identity(value[2]), identity(value[3]) }
end

local function decode(pod)
  assert(pod:get_type_name() == "Spa:Pod:Object:Param:Props", "Expected native Props")
  local parsed = pod:parse()
  assert(parsed.object_id == "Props", "Incorrect Props object ID")
  for name in pairs(parsed.properties) do assert(name == "params", "Unexpected Props property") end
  local fields = parsed.properties.params
  local names = { "version", "generation", "phase", "runtime", "manager", "links" }
  assert(type(fields) == "table" and #fields == 12, "Invalid intent arity")
  for index, name in ipairs(names) do assert(fields[index * 2 - 1] == name, "Invalid intent field") end
  local version, generation, phase = fields[2], fields[4], fields[6]
  assert(version == 1 and integer(generation) and generation > 0, "Invalid intent version/generation")
  assert(integer(phase) and phase >= PREPARED and phase <= WITHDRAW, "Invalid phase")
  local rows, canonical = fields[12], {}
  assert(type(rows) == "table" and #rows > 0 and #rows <= MAX_LINKS, "Invalid link count")
  local indices, endpoints = {}, {}
  for _, row in ipairs(rows) do
    assert(type(row) == "table" and #row == 4, "Invalid link arity")
    assert(integer(row[1]) and row[1] >= 0 and row[1] <= 0x7fffffff, "Invalid declaration index")
    assert(type(row[4]) == "boolean" and not indices[row[1]], "Invalid passive/duplicate index")
    indices[row[1]] = true
    local output, input = endpoint(row[2]), endpoint(row[3])
    local path = row[2][1][1] .. ":" .. row[2][2][1] .. ":" .. row[3][1][1] .. ":" .. row[3][2][1]
    assert(not endpoints[path], "Duplicate link endpoints")
    endpoints[path] = true
    table.insert(canonical, Pod.Struct { Pod.Int(row[1]), output, input, Pod.Boolean(row[4]) })
  end
  -- parse() erases primitive types. Native filtering against an explicit typed
  -- reconstruction rejects Int/Long/Id substitutions without Lua coercion.
  local expected = Pod.Object { "Spa:Pod:Object:Param:Props", "Props",
    params = Pod.Struct { "version", Pod.Int(version), "generation", Pod.Long(generation),
      "phase", Pod.Id(phase), "runtime", identity(fields[8]), "manager", identity(fields[10]),
      "links", Pod.Struct(canonical) } }
  assert(pod:filter(expected), "Incorrect native intent field types")
  return { generation = generation, phase = phase, runtime = fields[8], manager = fields[10], links = rows }
end

local function same(a, b)
  if type(a) ~= type(b) then return false end
  if type(a) ~= "table" then return a == b end
  if #a ~= #b then return false end
  for index = 1, #a do if not same(a[index], b[index]) then return false end end
  return true
end

local function find(identity_value, catalog)
  return catalog[tostring(identity_value[1]) .. ":" .. string.format("%u", identity_value[2])]
end

local function own_manager(intent)
  return intent.manager[1] == Core.get_own_bound_id() and find(intent.manager, clients) ~= nil
end

local function endpoint_present(value, direction)
  local port, owner = find(value[2], ports), find(value[3], clients)
  return port and owner and port:get_direction() == direction
      and tostring(port["global-properties"]["node.id"]) == tostring(value[1][1])
end

local function deactivate(scope)
  for _, link in ipairs(scope.links) do link:deactivate(Feature.Proxy.BOUND) end
end

local function finish_withdrawal(scope)
  if not scope.terminal or scope.pending ~= 0 or scope.syncing or scope.finished then return end
  scope.syncing = true
  deactivate(scope)
  Core.sync(function(error)
    scope.syncing = false
    if error then
      print("RTC_REALIZATION_CLEANUP_FAILED " .. scope.key .. " " .. tostring(error))
      return -- No acknowledgement after an unknown cleanup outcome.
    end
    scope.finished = true
    if not scope.removed then scope.object:request_destroy() end
    print("RTC_REALIZATION_WITHDRAWN " .. scope.key)
    if scope.removed then scopes[scope.key] = nil end
  end)
end

local function withdraw(scope, reason)
  if not scope.terminal then
    scope.terminal = true
    print("RTC_REALIZATION_WITHDRAW " .. scope.key .. " " .. reason)
  end
  deactivate(scope)
  finish_withdrawal(scope)
end

local advance
advance = function(scope)
  if scope.terminal or scope.creating or scope.pending > 0 or scope.ready then return end
  local intent = scope.intent
  if not intent or intent.phase ~= REALIZE then return end
  if not own_manager(intent) or not find(intent.runtime, clients) then
    withdraw(scope, "owner-lost"); return
  end
  if not scope.captured then
    -- ObjectManagers populate independently. Initial cache absence is not
    -- endpoint loss; wait within the admission deadline for the complete set.
    for _, declared in ipairs(intent.links) do
      if not endpoint_present(declared[2], "output") or not endpoint_present(declared[3], "input") then return end
    end
    scope.captured = true
  end
  local row = intent.links[scope.next]
  if not row then
    scope.ready = true
    print("RTC_REALIZATION_LINKS_READY " .. scope.key)
    return -- RTC still verifies the actual topology before admission.
  end
  if not endpoint_present(row[2], "output") or not endpoint_present(row[3], "input") then
    withdraw(scope, "endpoint-lost"); return
  end
  scope.creating = true
  local created, link = pcall(Link, "link-factory", {
    ["link.output.node"] = row[2][1][1], ["link.output.port"] = row[2][2][1],
    ["link.input.node"] = row[3][1][1], ["link.input.port"] = row[3][2][1],
    ["link.passive"] = row[4], ["object.linger"] = false,
    ["object.path"] = "pipewireao/rtc-realization/" .. scope.key .. "/" .. row[1],
  })
  if not created or not link then withdraw(scope, "link-factory-missing"); return end
  table.insert(scope.links, link)
  link:connect("bound", function(_, id) scope.link_ids[id] = true end)
  scope.pending = scope.pending + 1
  local usable, advanced = false, false
  local function progressed()
    if scope.terminal then finish_withdrawal(scope); return end
    if not advanced and scope.pending == 0 and usable then
      advanced = true
      scope.creating = false
      scope.next = scope.next + 1
      advance(scope)
    end
  end
  link:connect("pw-proxy-destroyed", function()
    if not scope.terminal then withdraw(scope, "link-removed") end
  end)
  link:connect("state-changed", function(_, _, state)
    if state == "error" or state == "unlinked" then withdraw(scope, "link-failed")
    elseif state == "active" or state == "paused" then usable = true; progressed() end
  end)
  local activation_ok = pcall(function()
    link:activate(Feature.Proxy.BOUND | Feature.PipewireObject.INFO, function(_, error)
    scope.pending = scope.pending - 1
    if scope.terminal then
      link:deactivate(Feature.Proxy.BOUND)
      finish_withdrawal(scope)
    elseif error then withdraw(scope, "link-activation-failed")
    else
      usable = usable or link["state"] == "paused" or link["state"] == "active"
      progressed()
    end
    end)
  end)
  if not activation_ok then
    -- An exception does not prove that no callback was queued. Preserve the
    -- pending count until a callback arrives; unknown completion cannot ACK.
    withdraw(scope, "link-activation-exception")
  end
end

local function inspect(scope)
  if scope.terminal or scope.removed then return end
  for pod in scope.object:iterate_params("Props") do
    local ok, intent = pcall(decode, pod)
    if not ok then
      -- An unrecognized marker carries no authority to destroy its owner.
      if scope.intent then withdraw(scope, "malformed-intent") end
      return
    end
    if scope.intent and (intent.generation ~= scope.intent.generation
        or intent.phase < scope.intent.phase or not same(intent.runtime, scope.intent.runtime)
        or not same(intent.manager, scope.intent.manager) or not same(intent.links, scope.intent.links)) then
      withdraw(scope, "intent-mutated"); return
    end
    if not scope.intent then
      if not own_manager(intent) or not find(intent.runtime, clients) then return end
      if scope.object.properties["pipewireao.rtc-realization.profile"] ~= "pipewireao.rtc.realization/1"
          or tostring(scope.object.properties["client.id"]) ~= tostring(intent.runtime[1]) then return end
      -- At most one admitted or draining cohort on this selected private core.
      -- A rejected new marker has no links and may be acknowledged independently.
      for _, other in pairs(scopes) do
        if other ~= scope and other.intent and not other.finished then
          scope.intent = intent
          withdraw(scope, "previous-generation-not-drained"); return
        end
      end
    end
    local first = scope.intent == nil
    scope.intent = intent
    if first and intent.phase == PREPARED then print("RTC_REALIZATION_PREPARED " .. scope.key) end
    if intent.phase == WITHDRAW then withdraw(scope, "requested")
    else
      if intent.phase == REALIZE and not scope.deadline then
        scope.deadline = Core.timeout_add(ADMISSION_TIMEOUT_MS, function()
          if not scope.ready and not scope.terminal then withdraw(scope, "admission-timeout") end
          return false
        end)
      end
      advance(scope)
    end
  end
end

local function added(kind, object)
  if kind == "port" then ports[key(object)] = object
  elseif kind == "client" then clients[key(object)] = object
  elseif kind == "marker" then
    local count = 0
    for _ in pairs(scopes) do count = count + 1 end
    if count >= MAX_SCOPES then return end -- Unknown excess markers never acquire authority.
    local scope = { key = key(object), object = object, pending = 0, next = 1, links = {}, link_ids = {} }
    scopes[scope.key] = scope
    object:connect("params-changed", function(_, name) if name == "Props" then inspect(scope) end end)
  end
  for _, scope in pairs(scopes) do inspect(scope) end
end

local function removed(kind, object)
  if kind == "port" then ports[key(object)] = nil
  elseif kind == "client" then clients[key(object)] = nil end
  local removed_scope = kind == "marker" and scopes[key(object)]
  if removed_scope then
    removed_scope.removed = true
    if removed_scope.intent then withdraw(removed_scope, "runtime-removed")
    else scopes[removed_scope.key] = nil end
    if removed_scope.finished then scopes[removed_scope.key] = nil end
  end
  for _, scope in pairs(scopes) do
    if scope.intent and not scope.terminal then
      if kind == "link" and scope.link_ids[object["bound-id"]] then withdraw(scope, "link-removed")
      elseif not find(scope.intent.runtime, clients) or not own_manager(scope.intent) then withdraw(scope, "owner-removed")
      else
        for _, row in ipairs(scope.intent.links) do
          local function removed_endpoint(value)
            local expected = kind == "port" and value[2] or kind == "client" and value[3]
            return expected and key(object) == tostring(expected[1]) .. ":" .. string.format("%u", expected[2])
          end
          if removed_endpoint(row[2]) or removed_endpoint(row[3]) or (scope.captured
              and (not endpoint_present(row[2], "output") or not endpoint_present(row[3], "input"))) then
            withdraw(scope, "endpoint-removed"); break
          end
        end
      end
    end
  end
end

-- Separate managers retain the actual interface type. Never bind scientific
-- Nodes here: Lua ObjectManager activates all features, including their Props.
-- RTC validates node serial and node/client provenance before projection and
-- again before admission; this policy validates Ports and Clients directly.
realization_om = ObjectManager {
  Interest { type = "node",
    Constraint { "node.name", "=", args["node.name"], type = "pw-global" } },
}
realization_port_om = ObjectManager { Interest { type = "port" } }
realization_client_om = ObjectManager { Interest { type = "client" } }
realization_link_om = ObjectManager { Interest { type = "link" } }
for _, entry in ipairs {{"marker", realization_om}, {"port", realization_port_om}, {"client", realization_client_om}, {"link", realization_link_om}} do
  local kind, om = entry[1], entry[2]
  om:connect("object-added", function(_, object) added(kind, object) end)
  om:connect("object-removed", function(_, object) removed(kind, object) end)
  om:activate()
end
