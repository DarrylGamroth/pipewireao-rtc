-- Loaded by the isolated session-items validation profile. The endpoint
-- clients are real PipeWireAO NdArraySource/NdArraySink streams created by the
-- Julia harness; this script exercises the production ao-connections module.
local log = Log.open_topic ("session-items-validation")
local connections = require ("ao-connections")

local prefix = "session-items-validation: "
local source = "fixture.session-items.ndarray-source"
local sink = "fixture.session-items.ndarray-sink"
local expected_pid = __EXPECTED_PIPEWIREAO_CLIENT_PID__
local deadline = Core.get_monotonic_time () + 30000000
local generation = "validation/1"
local specification = {
  links = {
    { output = source .. ":output_1", input = sink .. ":input_1", passive = false },
  },
  sources = {
    { ["node.name"] = source, ports = {
      { name = "output_1", direction = "output", ["element-type"] = "F32_LE",
        schema = "org.pipewireao.test.session-items/1", layout = "ROW_MAJOR",
        shape = { 2 }, rate = "100/1" },
    } },
  },
  graphs = {},
  sinks = {
    { ["node.name"] = sink, ports = {
      { name = "input_1", direction = "input", ["element-type"] = "F32_LE",
        schema = "org.pipewireao.test.session-items/1", layout = "ROW_MAJOR",
        shape = { 2 }, rate = "100/1" },
    } },
  },
}

local catalog = connections.new (specification,
  { [source] = expected_pid, [sink] = expected_pid },
  function (reason)
    log:warning (prefix .. "required object lost: " .. tostring (reason))
  end)

local function withdraw (reason)
  connections.withdraw (catalog, Core.get_monotonic_time () + 10000000,
    function (ok, error)
      if ok then
        log:warning (prefix .. "WITHDRAWN " .. tostring (reason or "complete"))
      else
        log:warning (prefix .. "WITHDRAW_FAILED " .. tostring (error))
      end
    end)
end

connections.discover (catalog, deadline, function (rows, error)
  if not rows then
    log:warning (prefix .. "DISCOVERY_FAILED " .. tostring (error))
    withdraw ("after-discovery-failure")
    return
  end
  connections.realize (catalog, rows, generation, deadline, function (cohort, realize_error)
    if not cohort then
      log:warning (prefix .. "REALIZATION_FAILED " .. tostring (realize_error))
      withdraw ("after-realization-failure")
      return
    end
    log:warning (prefix .. "REALIZED " .. generation)
    -- Leave the real link up long enough for the Julia harness to exchange
    -- several CPU arrays before testing production withdrawal.
    Core.timeout_add (30000, function ()
      withdraw (generation)
      return false
    end)
  end)
end)
