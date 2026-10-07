-- Cold callback ordering checks; native identity/type/link checks run separately.
local policy = arg[1] or "deployment/wireplumber/realization.lua"
local original_print = print
local links, syncs, timers, output
print = function(value) table.insert(output, value) end
Interest = function(value) return value end
Constraint = function(value) return value end
Feature = { Proxy = { BOUND = 1 }, PipewireObject = { INFO = 2 } }
Pod = { Struct = function(v) return v end, Object = function(v) return v end }
for _, name in ipairs {"Id", "Int", "Long", "Boolean"} do Pod[name] = function(v) return v end end
ObjectManager = function()
  return { callbacks = {}, connect = function(self, name, fn) self.callbacks[name] = fn end,
    activate = function() end }
end
Core = {
  get_own_bound_id = function() return 2 end,
  sync = function(fn) table.insert(syncs, fn) end,
  timeout_add = function(_, fn) table.insert(timers, fn); return fn end,
}
Link = function(_, properties)
  local link = { properties = properties, callbacks = {}, deactivations = 0, state = "init" }
  function link:connect(name, fn) self.callbacks[name] = fn end
  function link:activate(_, fn)
    self.activation = fn
    self["bound-id"] = 1000 + #links
    self.callbacks["bound"](self, self["bound-id"])
  end
  function link:deactivate(_) self.deactivations = self.deactivations + 1 end
  table.insert(links, link)
  return link
end
local function identity(id) return {id, id + 100} end
local function endpoint(node, port) return {identity(node), identity(port), identity(1)} end
local function snapshot(phase)
  local rows = { {0, endpoint(10,11), endpoint(20,21), true},
    {1, endpoint(20,22), endpoint(30,31), false} }
  local fields = {"version", 1, "generation", 1, "phase", phase,
    "runtime", identity(1), "manager", identity(2), "links", rows}
  return { get_type_name = function() return "Spa:Pod:Object:Param:Props" end,
    parse = function() return {object_id = "Props", properties = {params = fields}} end,
    filter = function() return true end, fields = fields }
end
local function object(id, properties)
  properties = properties or {}
  properties["object.serial"] = id + 100
  local obj = { ["bound-id"] = id, ["global-properties"] = properties,
    properties = properties, callbacks = {}, destroys = 0 }
  function obj:connect(name, fn) self.callbacks[name] = fn end
  function obj:get_direction() return self.direction end
  function obj:request_destroy() self.destroys = self.destroys + 1 end
  function obj:iterate_params()
    local supplied = false
    return function() if not supplied then supplied = true; return self.pod end end
  end
  return obj
end
local function manager(obj)
  if obj["global-properties"]["node.name"] then return realization_om end
  if obj.direction then return realization_port_om end
  if obj.kind == "link" then return realization_link_om end
  return realization_client_om
end
local function add(obj) local om = manager(obj); om.callbacks["object-added"](om, obj) end
local function remove(obj) local om = manager(obj); om.callbacks["object-removed"](om, obj) end
local function update(marker, pod)
  marker.pod = pod
  marker.callbacks["params-changed"](marker, "Props")
end
local function state(link, new)
  link.state = new; link.callbacks["state-changed"](link, "init", new)
end
local function complete(link, error) link.activation(link, error) end
local function setup(phase, change)
  links, syncs, timers, output = {}, {}, {}, {}
  assert(loadfile(policy))({ parse = function() return {["node.name"] = "marker"} end })
  local runtime = object(1); add(runtime); add(object(2))
  for _, spec in ipairs {{11,10,"output"},{21,20,"input"},{22,20,"output"},{31,30,"input"}} do
    local port = object(spec[1], {["node.id"] = spec[2]}); port.direction = spec[3]; add(port)
  end
  local marker = object(50, {["node.name"] = "marker", ["client.id"] = 1,
    ["pipewireao.rtc-realization.profile"] = "pipewireao.rtc.realization/1"})
  marker.pod = snapshot(phase)
  if change then change(marker) end
  add(marker)
  return marker, runtime
end

-- Prepared is inert; unrelated events and repeated link state cannot advance twice.
local marker = setup(0)
assert(#links == 0 and #syncs == 0)
update(marker, snapshot(1)); assert(#links == 1)
add(object(99)); assert(#links == 1)
state(links[1], "paused"); assert(#links == 1)
complete(links[1]); assert(#links == 2)
state(links[1], "active"); assert(#links == 2)
state(links[2], "paused"); complete(links[2]); assert(#links == 2)
state(links[1], "paused"); state(links[2], "active"); assert(#links == 2)
assert(output[#output]:find("LINKS_READY", 1, true))
update(marker, snapshot(2)); assert(#syncs == 1 and marker.destroys == 0)
syncs[1](); assert(marker.destroys == 1)
update(marker, snapshot(1)); assert(#links == 2)

-- Withdrawal during activation cannot ACK until the captured callback and fence.
marker = setup(1)
update(marker, snapshot(2)); assert(#syncs == 0 and marker.destroys == 0)
state(links[1], "paused"); assert(#links == 1 and #syncs == 0)
complete(links[1]); assert(#syncs == 1 and links[1].deactivations >= 2)
assert(marker.destroys == 0); syncs[1](); assert(marker.destroys == 1 and #links == 1)

-- A coalesced initial Withdraw still receives a fenced acknowledgement.
marker = setup(2); assert(#links == 0 and #syncs == 1 and marker.destroys == 0)
syncs[1](); assert(marker.destroys == 1)

-- Unknown sync outcome and activation exception must not falsely acknowledge.
marker = setup(2); syncs[1]("disconnected"); assert(marker.destroys == 0)
local original_link = Link
Link = function(...)
  local link = original_link(...)
  link.activate = function() error("unknown submission outcome") end
  return link
end
marker = setup(1); assert(#syncs == 0 and marker.destroys == 0)
Link = original_link

-- Manager mismatch, wrong creator and unknown malformed snapshots carry no authority.
for _, change in ipairs {
  function(m) m.pod.fields[10] = identity(3) end,
  function(m) m.properties["client.id"] = 3 end,
  function(m) m.pod.fields[1] = "bad" end,
} do
  marker = setup(1, change); assert(#links == 0 and #syncs == 0 and marker.destroys == 0)
end

-- Mutation, failure and admission timeout are terminal, with pending work drained.
for _, trigger in ipairs {
  function(m) local pod = snapshot(1); pod.fields[4] = 2; update(m, pod) end,
  function(m) update(m, snapshot(0)) end,
  function(_) state(links[1], "error") end,
  function(_) links[1].callbacks["pw-proxy-destroyed"]() end,
  function(_) local obj = object(links[1]["bound-id"]); obj.kind = "link"; remove(obj) end,
  function(_) assert(timers[1]() == false) end,
} do
  marker = setup(1); trigger(marker)
  assert(#links == 1 and #syncs == 0)
  complete(links[1]); assert(#links == 1 and #syncs == 1)
  syncs[1](); assert(marker.destroys == 1)
end
marker = setup(1); complete(links[1], "activation failed")
assert(#links == 1 and #syncs == 1 and marker.destroys == 0)
syncs[1](); assert(marker.destroys == 1)

-- Owner loss drains old links; a replacement does not repair the old generation.
local runtime
marker, runtime = setup(1)
remove(runtime); add(object(1)); assert(#links == 1 and #syncs == 0)
complete(links[1]); assert(#syncs == 1); syncs[1](); assert(marker.destroys == 1)

-- Runtime-marker disappearance still drains a pending creator activation.
marker = setup(1); remove(marker); assert(#syncs == 0)
complete(links[1]); assert(#syncs == 1); syncs[1](); assert(marker.destroys == 0)
-- Independent discovery ordering may expose the marker before required ports.
marker = setup(0)
local late = object(31, {["node.id"] = 30}); late.direction = "input"
remove(late) -- Prepared already captured this declared removal: terminal fence.
assert(#syncs == 1)
marker = setup(1, function(m)
  local last = object(31, {["node.id"] = 30}); last.direction = "input"
  remove(last) -- Before marker acceptance, this is initial cache absence.
end)
assert(#links == 0 and #syncs == 0)
add(object(98)); assert(#links == 0 and #syncs == 0)
add(late); assert(#links == 1)
original_print("realization callback ordering checks passed")
