-- Exercise the production session fault callback with controlled asynchronous
-- boundaries. Discovery and native transport require separate live tests.
local function upvalue(fn, wanted)
  for index = 1, math.huge do
    local name, value = debug.getupvalue(fn, index)
    assert(name, "Production callback no longer captures " .. wanted)
    if name == wanted then return value end
  end
end

local function session()
  local observed = { effects = {}, warnings = {}, pending = {}, completions = {} }
  local function effect(name) observed.effects[#observed.effects + 1] = name end
  local endpoint = { call = function(_, operation)
    assert(operation == "disconnect")
    effect("disconnect")
  end }
  local fault, api
  local mocks = {
    ["ao-control"] = {},
    ["ao-owner"] = { node_operation = function(node, operation, value, _, callback)
      assert(operation == "run" and value == 1, "Fault must hold graph processing")
      effect("hold:" .. node.name)
      observed.pending.graph = callback
    end },
    ["ao-acquisition"] = { operation = function(_, operation, value, _, callback)
      assert(operation == "run" and value == 1, "Fault must hold source acquisition")
      effect("hold:source")
      assert(not observed.pending.source, "Fault retried source hold")
      observed.pending.source = callback
    end },
    ["ao-connections"] = {
      new = function(_, _, callback) fault = callback; return {} end,
      withdraw = function(_, _, callback)
        effect("withdraw")
        observed.pending.withdraw = callback
      end,
    },
    ["ao-session-control"] = {
      new = function(_, _, _, callback)
        assert(callback == fault)
        api = {}
        return api
      end,
      publish = function() effect("publish:fault") end,
      complete = function(_, ticket, outcome, _, reason)
        observed.completions[#observed.completions + 1] = {
          ticket = ticket, outcome = outcome, reason = reason }
      end,
    },
  }
  local environment = setmetatable({
    require = function(name) return assert(mocks[name], "Unexpected dependency: " .. name) end,
    Plugin = { find = function() return endpoint end },
    -- This harness extracts only the compensation callback; native hooks are
    -- exercised by WirePlumber's ao-session-hooks test instead.
    AsyncEventHook = function() return { register = function() end } end,
    EventInterest = function(value) return value end,
    Constraint = function(value) return value end,
    EventDispatcher = { push_event = function()
      return { stop_processing = function() end }
    end },
    Log = { warning = function(message)
      observed.warnings[#observed.warnings + 1] = message
    end },
    Core = {
      get_monotonic_time = function() return 1000 end,
      timeout_add = function()
        return { destroy = function() effect("cancel:timer") end }
      end,
    },
  }, { __index = _G })
  local arguments = { parse = function() return {
    instance = 1, session = { authority = "none", profile = "development", links = {{}} },
    ["node.pids"] = {},
  } end }
  assert(loadfile(POLICY_PATH, "t", environment))(arguments)
  observed.state = upvalue(fault, "state")
  observed.state.lifecycle = 4
  observed.state.source = {}
  observed.state.graphs = { alpha = { name = "alpha" }, beta = { name = "beta" } }
  observed.effects = {}
  observed.fault, observed.api = fault, api
  return observed
end

local function sequence(observed, expected)
  assert(table.concat(observed.effects, ",") == expected,
    "Unexpected effect sequence: " .. table.concat(observed.effects, ","))
end

local function acknowledge_source(observed)
  observed.pending.source({}, nil)
end

local function acknowledge_graphs(observed, first_error)
  observed.pending.graph(nil, first_error)
  observed.pending.graph(nil, nil)
end

local cases = {}

function cases.source_first()
  local value = session()
  value.fault("required sink entered error")
  assert(value.state.faulted and value.state.lifecycle == 5)
  sequence(value, "cancel:timer,publish:fault,hold:source")
  assert(not value.pending.graph and not value.pending.withdraw,
    "Consumers or links changed before source hold acknowledgement")
  acknowledge_source(value)
  sequence(value, "cancel:timer,publish:fault,hold:source,hold:alpha")
  assert(not value.pending.withdraw, "Links withdrawn before graph hold acknowledgement")
  value.pending.graph(nil, nil)
  sequence(value, "cancel:timer,publish:fault,hold:source,hold:alpha,hold:beta")
  assert(not value.pending.withdraw, "Links withdrawn before all graph holds")
  value.pending.graph(nil, nil)
  sequence(value, "cancel:timer,publish:fault,hold:source,hold:alpha,hold:beta,withdraw")
end

function cases.first_fault()
  local value = session()
  local ticket = {}
  local cancelled = 0
  value.state.operation.ticket = ticket
  value.state.operation.cancels = { function() cancelled = cancelled + 1 end }
  value.api.pending = ticket
  local epoch = value.state.epoch
  value.fault("first sink fault")
  value.fault("second endpoint loss")
  assert(cancelled == 1 and value.state.epoch == epoch + 1)
  assert(value.state.operation == nil)
  acknowledge_source(value)
  acknowledge_graphs(value)
  value.pending.withdraw(true, nil)
  assert(#value.completions == 1 and value.completions[1].ticket == ticket)
  assert(value.completions[1].outcome == 0 and value.completions[1].reason == "first sink fault")
  value.fault("late owner exit")
  assert(#value.completions == 1 and cancelled == 1)
end

function cases.hold_unknown()
  local value = session()
  value.fault("sink removed")
  value.pending.source(nil, "outcome unknown")
  sequence(value, "cancel:timer,publish:fault,hold:source,disconnect")
  assert(not value.pending.graph and not value.pending.withdraw)
  assert(#value.warnings == 2)
  value.fault("another removal")
  sequence(value, "cancel:timer,publish:fault,hold:source,disconnect")
end

function cases.graph_hold_failed()
  local value = session()
  value.fault("controller exited")
  acknowledge_source(value)
  acknowledge_graphs(value, "owner disappeared")
  sequence(value, "cancel:timer,publish:fault,hold:source,hold:alpha,hold:beta,withdraw")
  assert(value.state.lifecycle == 5 and #value.warnings == 2)
end

function cases.withdraw_failed()
  local value = session()
  value.fault("sink fault")
  acknowledge_source(value)
  acknowledge_graphs(value)
  value.pending.withdraw(nil, "withdrawal uncertain")
  assert(value.state.lifecycle == 5 and value.state.faulted)
  assert(#value.warnings == 2 and value.warnings[2]:find("cleanup uncertain", 1, true))
  value.fault("replacement appeared")
  sequence(value, "cancel:timer,publish:fault,hold:source,hold:alpha,hold:beta,withdraw")
end

function cases.before_source_capture()
  local value = session()
  value.state.source = nil
  value.fault("preparation failed")
  sequence(value, "cancel:timer,publish:fault,withdraw")
  assert(not value.pending.source and not value.pending.graph)
end

function cases.no_automatic_readmission()
  local value = session()
  value.state.operation = nil
  value.fault("sink disappeared")
  acknowledge_source(value)
  acknowledge_graphs(value)
  value.pending.withdraw(true, nil)
  sequence(value, "publish:fault,hold:source,hold:alpha,hold:beta,withdraw")
  assert(value.state.lifecycle == 5 and value.state.generation == 0)
  assert(#value.completions == 0)
end

assert(cases[CASE], "Unknown fault case: " .. tostring(CASE))()
