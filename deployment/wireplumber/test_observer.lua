-- Cold callback plumbing only; live native SPA Format checks run separately.
local script = arg[1] or "deployment/wireplumber/hil-observer.lua"
local original_print = print
local output, timer
print = function(value) table.insert(output, value) end
Interest = function(value) return value end
ObjectManager = function(_)
  return {
    callbacks = {},
    connect = function(self, name, callback) self.callbacks[name] = callback end,
    activate = function() end,
  }
end
Core = { timeout_add = function(_, callback) timer = callback end }

local function setup()
  output = {}
  local contract = { role = "link-9", kind = "link", id = 9, serial = 19,
    passive = true, properties = { ["client.id"] = 2 } }
  local owner = { role = "client-2", id = 2, serial = 12, pid = 100 }
  assert(loadfile(script))({parse = function() return {objects = {contract}, owners = {owner}} end})
  local link = { ["bound-id"] = 9, ["global-properties"] = { ["object.serial"] = 19 },
    properties = { ["client.id"] = 2, ["link.passive"] = "true" }, state = "paused", callbacks = {} }
  local client = { ["bound-id"] = 2, ["global-properties"] = { ["object.serial"] = 12 },
    properties = { ["application.process.id"] = "100" }, callbacks = {} }
  for _, object in ipairs {link, client} do
    object.connect = function(self, name, callback) self.callbacks[name] = callback end
    hil_observer_om.callbacks["object-added"](hil_observer_om, object)
  end
  assert(output[#output] == "HIL_COHORT_READY")
  assert(timer() == true)
  return link, client
end

for _, state in ipairs { "active", "paused" } do
  local link = setup()
  link.state = state
  link.callbacks["state-changed"](link, "paused", state)
  assert(timer() == true)
  assert(output[#output] == "HIL_COHORT_READY")
end
for _, state in ipairs { "error", "unlinked" } do
  local link = setup()
  link.callbacks["state-changed"](link, "active", state)
  assert(output[#output] == "HIL_COHORT_LOST link-9 link-failed")
  assert(timer() == false)
end
local link = setup()
link.state = "error"
assert(timer() == false)
assert(output[#output] == "HIL_COHORT_LOST link-9 link-failed")
link = setup()
link.properties["link.passive"] = "false"
assert(timer() == false)
assert(output[#output] == "HIL_COHORT_LOST link-9 passive-changed")
local _, client = setup()
client.properties["application.process.id"] = "101"
client.callbacks["notify::properties"](client)
assert(output[#output] == "HIL_COHORT_LOST client-2 owner-changed")
link = setup()
hil_observer_om.callbacks["object-removed"](hil_observer_om, link)
local count = #output
hil_observer_om.callbacks["object-added"](hil_observer_om, link)
assert(#output == count) -- Withdrawal cannot silently repair a captured session.
assert(timer() == false)
original_print("observer callback checks passed")
