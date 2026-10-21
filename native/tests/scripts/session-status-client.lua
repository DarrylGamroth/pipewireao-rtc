-- A native public-protocol client, with no scientific owner substitutes.
Script.async_activation = true
local control, owner = require ("ao-control"), require ("ao-owner")
local args = (...):parse ()
local own = assert (Plugin.find ("test-status-controller"))
local manager = ObjectManager ({ Interest { type = "node" } },
    Feature.Proxy.BOUND | Feature.PipewireObject.INFO)
local running = false
local function fail (reason)
  Script:finish_activation_with_error (tostring (reason))
end
local function checked (action)
  return function (...)
    local ok, reason = pcall (action, ...)
    if not ok then fail (reason) end
  end
end
local function discover ()
  if running then return end
  local endpoint, controller
  for node in manager:iterate () do
    if node.properties ["node.name"] == "test-public-session" then endpoint = node end
    if node ["bound-id"] == own:call ("get-node-id") then controller = node end
  end
  if not endpoint or not controller then return end
  running = true
  assert (endpoint:get_n_input_ports () == 0 and endpoint:get_n_output_ports () == 0,
      "Public session endpoint unexpectedly has data ports")
  local identity = control.identity (controller)
  identity.instance = 303
  local client = owner.new (endpoint, "pipewireao.rtc.session", 101, identity, args ["server-pid"])
  local query
  local function retry ()
    Core.timeout_add (5, function () query (); return false end)
  end
  query = function () endpoint:enum_params ("Props", checked (function (iterator, reason)
    if reason or not iterator then retry (); return end
    local capability
    for pod in iterator:iterate () do
      local values = control.named_params (pod)
      if values ["pipewireao.rtc.session.version"] then capability = values end
    end
    if not capability then retry (); return end
    assert (control.scalar (capability ["pipewireao.rtc.session.owner-pid"], "Id") == args ["server-pid"])
    assert (control.scalar (capability ["pipewireao.rtc.session.lifecycle"], "Id") == 2,
        "Owner-absent production session must remain Configuring")
    owner.request (client, 2, Pod.Struct {}, Core.get_monotonic_time () + 3000000,
        checked (function (header, payload, reason)
      assert (not reason, reason)
      assert (header.operation == 2 and header.result == 0 and header.instance == 303)
      local fields = control.fields (payload, 3)
      assert (control.scalar (fields [1], "Id") == 2, "Status lifecycle differs from Configuring")
      assert (control.scalar (fields [2], "Id") == 2, "Status outcome is not Observed")
      assert (#control.fields (control.fields (fields [3], 1) [1]) == 0,
          "Absent scientific owners unexpectedly admitted an execution group")
      Script:finish_activation ()
      Core.update_properties ({ ["pipewireao.rtc.quit-complete"] = "true" })
      Core.quit ()
    end))
  end)) end
  query ()
end
manager:connect ("object-added", checked (discover))
manager:activate ()
