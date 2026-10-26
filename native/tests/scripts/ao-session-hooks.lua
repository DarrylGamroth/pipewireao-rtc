-- Run the production policy through native WpEventDispatcher/AsyncEventHook.
-- Only native control/discovery boundaries are gated; there is no Lua event or
-- transition substitute. Fake monotonic time makes deadline races deterministic.
local lua = require ("ao-lua")
local selector = ...
Script.async_activation = true
local control = require ("ao-control")
local function upvalue (fn, wanted)
  for index = 1, 64 do
    local name, value = debug.getupvalue (fn, index)
    if not name then break end
    if name == wanted then return value end
  end
  error ("Missing production upvalue " .. wanted)
end

local function session (options)
  options = options or {}
  local test = { now = 1000000, effects = {}, hooks = {}, timers = {}, completions = {},
    pending = {}, warnings = {}, options = options }
  local fault, request, api
  local function record (name, callback, ...)
    test.effects [#test.effects + 1] = name
    local values = { ... }
    local function finish () callback (table.unpack (values)) end
    if options.throw == name then error ("Injected I/O throw: " .. name) end
    if test.pause == name then
      assert (not test.pending [name], "Repeated held effect")
      test.pending [name] = finish
    elseif options.delayed then Core.idle_add (function () finish (); return false end)
    else finish () end
    return function ()
      test.cancelled = (test.cancelled or 0) + 1
      if options.reentrant_cancel then finish () end
    end
  end
  local endpoint = { call = function (_, action)
    if action == "get-node-id" then return 1 end
    assert (action == "disconnect"); test.disconnected = true
  end, deactivate = function () test.effects [#test.effects + 1] = "remove-controls" end }
  local nodes = { source = { name = "source" }, alpha = { name = "alpha" },
    beta = { name = "beta" }, bootstrap = { name = "bootstrap", properties = { ["client.id"] = "7" } },
    parameters = { name = "parameters" } }
  if options.properties then
    local declarations = { ["controller:closed"] = Pod.Boolean (false),
      ["controller:gain"] = Pod.Float (0.2) }
    local correction_prefix = "pipewireao.correction-control."
    for name, value in pairs (options.properties) do
      if name:sub (1, #correction_prefix) == correction_prefix then declarations [name] = value end
    end
    test.property_info = declarations
    local function iterator (rows)
      return { iterate = function ()
        local index = 0
        return function () index = index + 1; return rows [index] end
      end }
    end
    nodes.alpha.enum_params = function (_, kind, callback)
      local rows = {}
      if kind == "PropInfo" then
        for name, value in pairs (declarations) do
          rows [#rows + 1] = Pod.Object { "Spa:Pod:Object:Param:PropInfo", "PropInfo",
            -- SPA_PROP_INFO_type is a generic Pod; use its public numeric key
            -- to bypass the stock Lua constructor's exact-type restriction.
            name = Pod.String (name), ["id-00000003"] = value }
        end
      else
        assert (kind == "Props")
        local fields = {}
        for name, value in pairs (options.properties) do
          fields [#fields + 1], fields [#fields + 2] = Pod.String (name), value
        end
        rows [1] = Pod.Object { "Spa:Pod:Object:Param:Props", "Props", params = Pod.Struct (fields) }
      end
      callback (iterator (rows))
    end
    nodes.alpha.set_param = function (_, kind, pod)
      assert (kind == "Props")
      test.effects [#test.effects + 1] = "property-write"
      for name, value in pairs (control.named_params (pod)) do options.properties [name] = value end
      local generation = control.scalar (options.properties ["controller:requested-generation"], "Long") + 1
      options.properties ["controller:requested-generation"] = Pod.Long (generation)
      options.properties ["controller:active-generation"] = Pod.Long (generation)
    end
  end
  local catalog = { nodes = { [1] = { name = "controller" } }, clients = { [7] = {} } }
  local mocks = { ["ao-lua"] = lua,
    ["ao-correction"] = require ("ao-correction"),
    ["ao-control"] = setmetatable ({ identity = function () return { global_id = 1,
      serial = 2, instance = 3, pid = 4 } end }, { __index = control }),
    ["ao-owner"] = {
      new = function (node) return { node = node } end,
      wait_prepared = function (_, _, callback) return record ("owner-ready", callback, true) end,
      request = function (_, opcode, _, _, callback)
        assert (opcode == 2)
        return record ("connect-owner", callback, true, Pod.Struct { Pod.Id (3), Pod.Struct {} })
      end,
      node_operation = function (node, operation, value, _, callback)
        return record (operation .. ":" .. node.name .. ":" .. tostring (value), callback, true)
      end,
      shutdown_order = function (owners) return owners end,
      shutdown = function (_, _, callback) return record ("shutdown-owner", callback, true) end,
    },
    ["ao-acquisition"] = {
      new = function () return {} end,
      prepare = function (_, _, callback) return record ("prepare-source", callback, true) end,
      operation = function (_, operation, value, _, callback)
        local snapshot = { running = operation == "run" and value == 2,
          completed = operation == "query" and options.source_completed or false,
          sequence = 0, generation = operation == "reset" and 2 or 1 }
        if options.bad_reset and operation == "reset" then snapshot.generation = 1 end
        if options.bad_initial then snapshot.sequence = 1 end
        return record (operation .. ":source:" .. tostring (value), callback, snapshot)
      end,
      shutdown = function (_, _, callback) return record ("shutdown-source", callback, true) end,
    },
    ["ao-connections"] = {
      new = function (_, _, callback) fault = callback; return catalog end,
      check_core = function () end,
      node = function (_, name) return nodes [name] end,
      capture_control = function () end,
      await_node = function (_, name, _, _, callback)
        return record ("capture:" .. name, callback, nodes [name])
      end,
      discover = function (_, _, callback) return record ("discover", callback, {}) end,
      realize = function (_, _, _, _, callback) return record ("connect-links", callback, true) end,
      withdraw = function (_, _, callback) return record ("withdraw-links", callback, true) end,
      wait_clients_removed = function (_, _, _, callback) return record ("clients-absent", callback, true) end,
    },
    ["ao-session-control"] = {
      new = function (_, _, callback, failure)
        assert (failure == fault); request = callback; api = {}; return api
      end,
      publish = function () end,
      check_ticket = function () return { global_id = 1, serial = 2, instance = 3, pid = 4 } end,
      complete = function (_, ticket, outcome, _, reason, unknown)
        test.completions [#test.completions + 1] = { ticket = ticket, outcome = outcome,
          reason = reason, unknown = unknown }
        if api.pending == ticket then api.pending = nil end
      end,
      complete_admin = function () test.admin = (test.admin or 0) + 1; api.pending = nil end,
    },
  }
  local environment = setmetatable ({
    require = function (name) return assert (mocks [name], name) end,
    Plugin = { find = function () return endpoint end },
    Log = { warning = function (message) test.warnings [#test.warnings + 1] = message end },
    GLib = { get_monotonic_time = function () return test.now end },
    Core = {
      timeout_add = function (_, callback)
        local timer = { callback = callback, destroy = function (self) self.destroyed = true end }
        test.timers [#test.timers + 1] = timer
        return timer
      end,
      sync = function (callback) callback (options.sync_error) end,
      update_properties = function (properties)
        assert (properties ["pipewireao.rtc.quit-complete"] == "true")
        test.quit_complete = true
      end },
    AsyncEventHook = function (declaration)
      if options.native_throw and declaration.name == "ao/session-start" then
        declaration.steps.start.execute = function () error ("Injected native step throw") end
      end
      local native = AsyncEventHook (declaration)
      test.hooks [#test.hooks + 1] = native
      return native
    end,
  }, { __index = _ENV })
  -- The normal package searcher returns the production chunk before sandboxing.
  local _, chunk = package.searchers [2] ("../ao/session")
  assert (type (chunk) == "function", "Production session script was not found")
  debug.setupvalue (chunk, 1, environment)
  local args = { instance = 1, ["controller.instance"] = "3", ["admission.controller-instance"] = "3",
    ["node.pids"] = { source = 1, alpha = 1, beta = 1 },
    source = { ["control-node"] = "source", pid = 1, role = "source" },
    owners = {}, session = { authority = "none", profile = "development",
      sources = { { ["node.name"] = "source" } },
      graphs = { { ["node.name"] = "alpha" }, { ["node.name"] = "beta" } }, sinks = {},
      links = { { output = "source:out", input = "alpha:in", passive = true },
        { output = "alpha:out", input = "beta:in" } },
      ["execution-groups"] = { { name = "science", nodes = { "alpha", "beta" } } } } }
  if options.bootstrap then args.owners = { { ["bootstrap-node"] = "bootstrap",
    ["bootstrap-instance"] = "8", pid = 1, role = "graph" } } end
  if options.publisher then args.owners [#args.owners + 1] = {
    ["control-node"] = "parameters", ["control-instance"] = "9", pid = 1,
    ["control-protocol"] = "pipewireao.rtc.parameter-source/1" } end
  if options.no_controller then catalog.nodes [1] = nil end
  test.pause = options.pause
  chunk ({ parse = function () return args end })
  test.state, test.api, test.fault = upvalue (fault, "state"), api, fault
  function test:request (opcode, payload)
    local ticket = { header = { operation = opcode, instance = 3 }, payload = payload or Pod.Struct {},
      deadline = self.now + 10000000 }
    if not api.pending then api.pending = ticket end
    request (ticket)
    return ticket
  end
  function test:release (name)
    local callback = assert (self.pending [name], "No paused effect: " .. name)
    self.pending [name] = nil
    callback ()
  end
  function test:close ()
    assert (not self.state.operation, "Case left operation in flight")
    for _, native in ipairs (self.hooks) do native:remove () end
  end
  return test
end

local co
local function tick () coroutine.yield () end
local function wait_for (predicate)
  for _ = 1, 500 do if predicate () then return end; tick () end
  error ("Native hook did not reach expected checkpoint")
end
local function prepared (test)
  wait_for (function () return test.state.warmed or test.state.faulted end)
  assert (test.state.warmed and not test.state.faulted, table.concat (test.warnings, ";"))
  test:request (15); test:request (16)
  assert (test.state.lifecycle == 3 and test.admin == 2)
  test.effects, test.completions = {}, {}
end
local function done (test)
  wait_for (function () return not test.state.operation end)
end
local function order (test, expected)
  assert (table.concat (test.effects, ",") == expected,
      "Effect order: " .. table.concat (test.effects, ","))
end
local function normal ()
  for _, delayed in ipairs ({ false, true }) do
    local test = session { delayed = delayed, bootstrap = true, publisher = true }
    prepared (test)
    test:request (10); done (test)
    order (test, "run:beta:2,run:alpha:2,run:source:2")
    assert (test.state.lifecycle == 4 and #test.completions == 1)
    test.effects = {}
    -- Source-end Stop first proves the source cursor is complete. A negative
    -- query is a known no-effect failure and leaves the running session intact.
    test:request (11); done (test)
    assert (test.state.lifecycle == 4 and test.completions [2].outcome == 0)
    order (test, "query:source:nil")
    test.effects = {}
    test.options.source_completed = true
    test:request (11); done (test)
    order (test, "query:source:nil,run:source:1,run:alpha:1,run:beta:1")
    assert (test.state.lifecycle == 3)
    test.effects = {}
    test:request (12); done (test)
    order (test, "run:source:1,run:alpha:1,run:beta:1,reset:source:nil,reset:alpha:nil,reset:beta:nil")
    assert (test.state.source.snapshot.generation == 2)
    test.effects = {}
    test:request (1); done (test)
    order (test, "run:source:1,run:alpha:1,run:beta:1,withdraw-links,shutdown-source,shutdown-owner,remove-controls,clients-absent")
    assert (test.disconnected and test.quit_complete and test.state.lifecycle == 1 and #test.completions == 5)
    test:close ()
  end
end

local function startup_queries ()
  local test = session { no_controller = true }
  wait_for (function () return test.state.operation.transition end)
  assert (not test.state.warmed)
  test:request (2); test:request (3); test:request (15)
  assert (#test.completions == 2 and test.admin == 1)
  local original = test.state.operation
  test:request (10)
  assert (test.state.operation == original and #test.effects == 0)
  local transition = original.transition
  test.fault ("Required controller lost during discovery")
  assert (transition.completed)
  tick ()
  test:close ()
end

local function deadline (reentrant, queued)
  local test = session { reentrant_cancel = reentrant }
  prepared (test)
  test.pause = "run:beta:2"
  local ticket = test:request (10)
  local operation = test.state.operation
  if not queued then wait_for (function () return test.pending ["run:beta:2"] end) end
  local transition = operation.transition
  test.now = operation.deadline
  operation.expiry.callback ()
  assert (operation.retired and (not transition or transition.completed))
  -- Fault compensation is independent of the retired native transition.
  assert (test.state.faulted or queued)
  if not queued then
    assert (#test.completions == 1 and test.completions [1].ticket == ticket and
        test.completions [1].unknown == true)
    test:release ("run:beta:2")
  else assert (#test.completions == 1 and not test.completions [1].unknown) end
  local before = #test.effects
  if not queued then
    test:request (10)
    assert (#test.effects == before, "Second normal operation issued effects")
  end
  tick ()
  assert (not test.pending ["run:alpha:2"] and not test.pending ["run:source:2"])
  test:close ()
end

local function loss (phase)
  local test = session ()
  prepared (test)
  test.pause = phase
  test:request (10)
  wait_for (function () return test.pending [phase] end)
  local operation = test.state.operation
  test.fault ("Required exact cohort member disappeared")
  assert (operation.retired and operation.transition.completed)
  local before = #test.effects
  test:release (phase)
  assert (#test.effects == before and #test.completions == 1 and test.completions [1].unknown)
  assert (test.state.lifecycle == 5)
  tick ()
  test:close ()
end

-- Required loss bypasses the normal event queue at every scientific I/O seam.
-- Keep cleanup parked to prove that terminal hook settlement does not publish
-- the pending command before source-first compensation finishes.
local function interrupted (opcode, phase, startup)
  local test = session (startup and { pause = phase, bootstrap = true, publisher = true } or {})
  local ticket
  if not startup then
    prepared (test)
    test.pause = phase
    ticket = test:request (opcode)
  end
  wait_for (function () return test.pending [phase] end)
  local operation = test.state.operation
  local before = #test.effects
  if not startup then
    test:request (opcode)
    assert (test.state.operation == operation and #test.effects == before,
        "Second operation escaped single-owner admission")
    assert (#test.completions == 1 and test.completions [1].ticket ~= ticket)
  end
  test.pause = "withdraw-links"
  test.fault ("Required object lost in " .. phase)
  assert (operation.retired and operation.transition.completed and not test.state.operation)
  assert (test.pending ["withdraw-links"] and (not ticket or test.api.pending == ticket))
  assert (#test.completions == (startup and 0 or 1), "Fault completed before compensation")
  local cancelled = test.cancelled
  before = #test.effects
  -- A stale effect, even returning an error, must not advance or fault twice.
  local late = test.pending [phase]
  test.pending [phase] = nil
  late ()
  late ()
  assert (#test.effects == before and test.cancelled == cancelled)
  test:release ("withdraw-links")
  assert (#test.completions == (startup and 0 or 2))
  if ticket then
    assert (test.completions [2].ticket == ticket and
        test.completions [2].unknown == operation.effects_issued)
  end
  -- A queued sentinel at the same priority proves the native dispatcher is no
  -- longer blocked by the original hook while the old operation is retired.
  local seen = false
  local sentinel = SimpleEventHook {
    name = "ao-test-sentinel", interests = { EventInterest {
      Constraint { "event.type", "=", "ao-test-sentinel" } } },
    execute = function () seen = true end,
  }
  sentinel:register ()
  lua.push_event { type = "ao-test-sentinel", priority = 0 }
  wait_for (function () return seen end)
  sentinel:remove ()
  test:close ()
end

local function quit_fence_failure ()
  local test = session { sync_error = "publication fence failed" }
  prepared (test)
  test:request (1); done (test)
  assert (test.disconnected and not test.quit_complete)
  assert (#test.warnings == 1)
  test:close ()
end

local function errors ()
  for _, options in ipairs ({ { native_throw = true }, { throw = "run:beta:2" },
      { bad_reset = true }, { bad_initial = true } }) do
    local test = session (options)
    if options.bad_initial then
      wait_for (function () return test.state.faulted end)
      assert (not test.state.warmed)
    else
      prepared (test)
      test:request (options.bad_reset and 12 or 10)
      wait_for (function () return test.state.faulted end)
      assert (#test.completions == 1)
    end
    assert (test.state.lifecycle == 5)
    tick ()
    test:close ()
  end
end

local function correction_admission ()
  local prefix = "pipewireao.correction-control."
  local key = prefix .. "controller:closed"
  local cases = {
    { "close", nil, true },
    { "open", function (_, values)
        values [key .. ".state"], values [key .. ".requested"] = Pod.String ("Closed"), Pod.Boolean (true)
        values ["controller:closed"] = Pod.Boolean (true)
      end, true, false },
    { "ready", function (state) state.lifecycle = 3 end },
    { "group stopped", function (state) state.groups.science.running = false end },
    { "owner stopped", function (_, values)
        values ["pipewireao.run-control.actual-state"] = Pod.String ("stopped") end },
    { "unknown", function (_, values) values [key .. ".state"] = Pod.String ("Unknown") end },
    { "fault", function (_, values) values [key .. ".fault"] = Pod.String ("observation_timeout") end },
    { "version", function (_, values) values [prefix .. "version"] = Pod.Int (2) end },
    { "incarnation", function (_, values) values [prefix .. "owner-instance"] = Pod.Long (9) end },
    { "pending", function (_, values) values ["controller:requested-generation"] = Pod.Long (1) end },
    { "mismatch", function (_, values) values [key .. ".requested"] = Pod.Boolean (true) end },
    { "partial state", function (_, values) values [key .. ".state"] = nil end },
    { "partial version", function (_, values)
        values [prefix .. "version"], values [key .. ".state"] = nil, nil end },
    { "missing declared status", function (_, values)
        for _, suffix in ipairs ({ ".state", ".fault", ".requested" }) do values [key .. suffix] = nil end
      end },
    { "legacy", function (_, values, declarations)
        for name in pairs (values) do
          if name:sub (1, #prefix) == prefix then values [name], declarations [name] = nil, nil end
        end
      end, true },
    { "ordinary property", nil, true, nil, true },
    { "future ordinary property", function (_, values) values [prefix .. "version"] = Pod.Int (2) end,
      false, nil, true },
  }
  for _, case in ipairs (cases) do
    local values = { [prefix .. "version"] = Pod.Int (1), [prefix .. "owner-instance"] = Pod.Long (8),
      [key .. ".state"] = Pod.String ("Open"), [key .. ".fault"] = Pod.String (""),
      [key .. ".requested"] = Pod.Boolean (false), ["controller:closed"] = Pod.Boolean (false),
      ["controller:gain"] = Pod.Float (0.2), ["controller:requested-generation"] = Pod.Long (0),
      ["controller:active-generation"] = Pod.Long (0),
      ["pipewireao.run-control.actual-state"] = Pod.String ("running") }
    local test = session { bootstrap = true, properties = values }
    prepared (test)
    test:request (10); done (test)
    test.effects, test.completions = {}, {}
    if case [2] then case [2] (test.state, values, test.property_info) end
    local active = control.scalar (values ["controller:closed"], "Bool")
    local requested = control.scalar (values ["controller:requested-generation"], "Long")
    local rows = { Pod.Struct { "controller:gain", Pod.Float (0.4) } }
    if not case [5] then rows [#rows + 1] = Pod.Struct {
      "controller:closed", Pod.Boolean (case [4] ~= false) } end
    test:request (13, Pod.Struct { "alpha", Pod.Struct (rows) }); done (test)
    assert (#test.completions == 1 and not test.completions [1].unknown, case [1])
    if case [3] then
      assert (test.completions [1].outcome == 5, case [1] .. ": " .. tostring (test.completions [1].reason))
      order (test, "property-write")
      assert (control.scalar (values ["controller:requested-generation"], "Long") == requested + 1)
    else
      order (test, "")
      assert (test.completions [1].outcome == 0 and test.completions [1].reason, case [1])
      assert (not test.state.faulted, "Rejected correction faulted the session: " .. case [1])
      assert (control.scalar (values ["controller:closed"], "Bool") == active)
      assert (control.scalar (values ["controller:gain"], "Float") == Pod.Float (0.2):parse ())
      assert (control.scalar (values ["controller:requested-generation"], "Long") == requested)
      assert (control.scalar (values ["controller:active-generation"], "Long") == 0)
    end
    test:close ()
  end
end

co = coroutine.create (function ()
  if selector == "correction" then correction_admission (); return end
  normal ()
  startup_queries ()
  quit_fence_failure ()
  deadline (false, false)
  deadline (true, false)
  deadline (false, true)
  for _, name in ipairs ({ "run:beta:2", "run:alpha:2", "run:source:2" }) do loss (name) end
  for _, name in ipairs ({ "owner-ready", "connect-owner", "capture:parameters", "capture:source", "prepare-source",
      "discover", "run:source:1", "connect-links", "run:alpha:1", "run:beta:1" }) do
    interrupted (nil, name, true)
  end
  for _, row in ipairs ({
      { 9, "run:source:1" }, { 9, "run:alpha:1" }, { 9, "run:beta:1" },
      { 12, "run:source:1" }, { 12, "run:alpha:1" }, { 12, "reset:source:nil" },
      { 12, "reset:alpha:nil" }, { 12, "reset:beta:nil" },
      { 1, "run:source:1" }, { 1, "run:alpha:1" }, { 1, "shutdown-source" },
      { 1, "clients-absent" } }) do interrupted (row [1], row [2], false) end
  errors ()
end)
Core.timeout_add (1, function ()
  local ok, error = coroutine.resume (co)
  if not ok then Script:finish_activation_with_error (tostring (error)); return false end
  if coroutine.status (co) == "dead" then Script:finish_activation (); return false end
  return true
end)
