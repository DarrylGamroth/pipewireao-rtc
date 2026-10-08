local original_file_metatable = debug.getmetatable (io.tmpfile ())
local wrappers, proxies = {}, {}
local object_metatable = {
  __eq = function (a, b) return proxies [a] == proxies [b] end,
  __index = function (object, key)
    if key == "bound-id" then return proxies [object].bound end
  end,
}
local function wrap (proxy)
  local wrapper = assert (io.tmpfile ())
  wrappers [#wrappers + 1], proxies [wrapper] = wrapper, proxy
  debug.setmetatable (wrapper, object_metatable)
  return wrapper
end
local function catalog (path)
  local managers, losses = {}, {}
  local environment = setmetatable ({
    Feature = { Proxy = { BOUND = 1 }, PipewireObject = { INFO = 16 } },
    Interest = function (interest) return interest end,
    require = function (name) assert (name == "ao-control"); return {} end,
    ObjectManager = function (interests)
      local manager = { callbacks = {} }
      function manager:connect (signal, callback) self.callbacks [signal] = callback end
      function manager:activate () end
      managers [interests [1].type] = manager
      return manager
    end,
  }, { __index = _G })
  local connections = assert (loadfile (path, "t", environment)) ()
  local value = connections.new ({}, {}, function (reason) losses [#losses + 1] = reason end)
  return value, managers, losses
end
local function run (path, expect_fixed)
  local checks, missed = 0, 0
  for _, phase in ipairs ({ "configuring", "admitted" }) do
    for _, kind in ipairs ({ "node", "port", "client", "link" }) do
      local value, managers, losses = catalog (path)
      local map = value [kind == "node" and "nodes" or kind == "port" and "ports" or
          kind == "client" and "clients" or "links"]
      local proxy = { bound = 49 }
      local retained, captured, removed = wrap (proxy), wrap (proxy), wrap (proxy)
      managers [kind].callbacks ["object-added"] (managers [kind], retained)
      value.captured [retained], value.captured [captured] = true, true
      assert (retained == removed and rawget (value.captured, removed) == nil)
      proxy.bound = 0xffffffff -- Both wrappers now expose invalid live BOUND.
      managers [kind].callbacks ["object-removed"] (managers [kind], removed)
      local fixed = map [49] == nil and #losses == 1 and next (value.captured) == nil
      if not fixed then missed = missed + 1 end
      assert (fixed == expect_fixed, phase .. ": " .. kind .. " required loss")
      if expect_fixed then
        managers [kind].callbacks ["object-removed"] (managers [kind], wrap (proxy))
        assert (#losses == 1, "duplicate loss callback")
      end
      checks = checks + 1
    end
  end
  if expect_fixed then
    local value, managers, losses = catalog (path)
    local old, replacement = { bound = 50 }, { bound = 50 }
    local old_wrapper, new_wrapper = wrap (old), wrap (replacement)
    managers.node.callbacks ["object-added"] (managers.node, old_wrapper)
    value.captured [old_wrapper] = true
    managers.node.callbacks ["object-added"] (managers.node, new_wrapper)
    old.bound = 0xffffffff
    managers.node.callbacks ["object-removed"] (managers.node, wrap (old))
    assert (value.nodes [50] == new_wrapper and #losses == 1, "replacement ID reuse")
    managers.node.callbacks ["object-removed"] (managers.node, wrap ({ bound = 99 }))
    assert (value.nodes [50] == new_wrapper and #losses == 1, "unrelated removal")
    value.captured [new_wrapper], value.withdrawing = true, true
    replacement.bound = 0xffffffff
    managers.node.callbacks ["object-removed"] (managers.node, wrap (replacement))
    assert (value.nodes [50] == nil and next (value.captured) == nil and #losses == 1,
        "intentional withdrawal suppression")
    checks = checks + 3
  end
  return checks, missed
end
local before_checks, missed = run (arg [1], false)
local after_checks = run (arg [2], true)
for _, wrapper in ipairs (wrappers) do
  debug.setmetatable (wrapper, original_file_metatable)
  wrapper:close ()
end
print ("fail-before: " .. missed .. "/" .. before_checks .. " required removals missed")
print ("pass-after: " .. after_checks .. " checks, including duplicates, BOUND loss, ID reuse, unrelated removal and withdrawal")
