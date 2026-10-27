-- Native POD decoding and correction admission, without scientific effects.
local control = require ("ao-control")
local correction = require ("ao-correction")
local PREFIX = "pipewireao.correction-control."
local TARGET = "controller:closed"
local KEY = PREFIX .. TARGET

local function snapshot ()
  -- Use the same wire decoding as a fresh native owner Props enumeration.
  return control.named_params (Pod.Object { "Spa:Pod:Object:Param:Props", "Props",
    params = Pod.Struct {
      PREFIX .. "version", Pod.Int (1), PREFIX .. "owner-instance", Pod.Long (8),
      KEY .. ".state", "Open", KEY .. ".fault", "", KEY .. ".requested", Pod.Boolean (false),
      TARGET, Pod.Boolean (false), "controller:requested-generation", Pod.Long (3),
      "controller:active-generation", Pod.Long (3),
      "pipewireao.run-control.actual-state", "running" } })
end
local function context ()
  return { lifecycle = 4, groups = { science = { nodes = { "graph" }, running = true } } },
    { ["node.pids"] = { graph = 17 }, owners = {
      { ["bootstrap-node"] = "graph-owner", ["bootstrap-instance"] = "8", pid = 17 } } }
end

local function check (mutate, expected, ordinary)
  local state, args = context ()
  local values = snapshot ()
  local declarations = {}
  for name in pairs (values) do declarations [name] = true end
  local updates = ordinary and { ["controller:gain"] = Pod.Float (0.2) } or
      { [TARGET] = Pod.Boolean (true), ["controller:gain"] = Pod.Float (0.2) }
  if mutate then mutate (state, args, values, updates, declarations) end
  local ok, error = pcall (correction.check, state, args, "graph", values, updates, declarations)
  if expected then
    assert (not ok and tostring (error):find (expected, 1, true), tostring (error))
  else assert (ok, tostring (error)) end
end

check () -- Close from Open.
check (function (_, _, values, updates)
  values [KEY .. ".state"] = Pod.String ("Closed")
  values [KEY .. ".requested"], values [TARGET] = Pod.Boolean (true), Pod.Boolean (true)
  updates [TARGET] = Pod.Boolean (false)
end) -- Open from Closed.
check (nil, nil, true) -- Ordinary property on a versioned owner.
check (function (_, _, values, _, declarations)
  for name in pairs (values) do
    if name:sub (1, #PREFIX) == PREFIX then values [name], declarations [name] = nil, nil end
  end
end) -- No correction capability preserves legacy Boolean writes.
check (function (state, _, values, _, declarations)
  state.lifecycle = 3
  for name in pairs (values) do
    if name:sub (1, #PREFIX) == PREFIX then values [name], declarations [name] = nil, nil end
  end
end) -- Legacy stopped-property staging is unchanged.

for _, lifecycle in ipairs ({ 2, 3, 5 }) do
  check (function (state) state.lifecycle = lifecycle end, "requires a running session")
end
check (function (state) state.groups.science.running = false end, "execution group is stopped")
check (function (state) state.groups = {} end, "no running execution group")
check (function (_, _, values)
  values ["pipewireao.run-control.actual-state"] = Pod.String ("stopped")
end, "owner is stopped")
for _, state in ipairs ({ "Unknown", "Opening", "Closing", "Invalid" }) do
  check (function (_, _, values) values [KEY .. ".state"] = Pod.String (state) end, "state is not ready")
end
check (function (_, _, values) values [KEY .. ".fault"] = Pod.String ("observation_timeout") end,
    "fault is latched")
check (function (_, _, values) values [PREFIX .. "version"] = Pod.Int (2) end,
    "Unsupported correction-control version")
check (function (_, _, values) values [PREFIX .. "version"] = Pod.Int (2) end,
    "Unsupported correction-control version", true)
check (function (_, _, values) values [PREFIX .. "version"] = Pod.String ("1") end,
    "Incorrect control scalar type", true)
check (function (_, _, values) values [PREFIX .. "version"] = nil end,
    "Correction-control version missing")
check (function (_, _, values)
  values [PREFIX .. "version"], values [KEY .. ".state"] = nil, nil
end, "Correction-control version missing")
check (function (_, _, values)
  for _, suffix in ipairs ({ ".state", ".fault", ".requested" }) do values [KEY .. suffix] = nil end
end, "Missing correction status")
check (function (_, _, values) values [PREFIX .. "owner-instance"] = Pod.Long (9) end,
    "owner incarnation changed")
check (function (_, args) args.owners [1].pid = 18 end, "no declared bootstrap owner")
check (function (_, args) args.owners [2] = args.owners [1] end, "Ambiguous correction graph owner")
check (function (_, _, values) values ["controller:active-generation"] = Pod.Long (2) end,
    "adoption is pending")
check (function (_, _, values)
  values ["controller:requested-generation"], values ["controller:active-generation"] = Pod.Long (-1), Pod.Long (-1)
end, "adoption is pending")
check (function (_, _, values) values [KEY .. ".requested"] = Pod.Boolean (true) end,
    "Inconsistent correction state")
check (function (_, _, values) values [KEY .. ".state"] = Pod.String ("Closed") end,
    "Inconsistent correction state")
for _, name in ipairs ({ KEY .. ".state", KEY .. ".fault", KEY .. ".requested",
    PREFIX .. "owner-instance", TARGET, "controller:requested-generation",
    "controller:active-generation", "pipewireao.run-control.actual-state" }) do
  check (function (_, _, values) values [name] = Pod.Int (1) end, "Incorrect control scalar type")
end
for _, name in ipairs ({ KEY .. ".state", KEY .. ".fault", KEY .. ".requested", PREFIX .. "owner-instance",
    TARGET, "controller:requested-generation", "controller:active-generation",
    "pipewireao.run-control.actual-state" }) do
  check (function (_, _, values) values [name] = nil end, "Missing correction status")
end

-- A different explicitly published target is recognized without guessing names.
check (function (_, _, values, updates)
  updates [TARGET], updates ["arbitrary:enabled"] = nil, updates [TARGET]
  values ["arbitrary:enabled"] = values [TARGET]
  values ["arbitrary:requested-generation"], values ["arbitrary:active-generation"] = Pod.Long (0), Pod.Long (0)
  for _, suffix in ipairs ({ ".state", ".fault", ".requested" }) do
    values [PREFIX .. "arbitrary:enabled" .. suffix] = values [KEY .. suffix]
    values [KEY .. suffix] = nil
  end
end)

-- Protective operations use the same exact owner, running and generation fences.
local RECOVERY = "pipewireao-recovery:"
local function recovery_case (release, mutate, expected)
  check (function (state, args, values, updates, declarations)
    for key in pairs (updates) do updates [key] = nil end
    values [RECOVERY .. "version"] = Pod.Int (1)
    values [RECOVERY .. "controller"] = Pod.String ("controller")
    values [RECOVERY .. "close-guarded"] = Pod.Boolean (false)
    values [RECOVERY .. "requested-generation"] = Pod.Long (2)
    values [RECOVERY .. "active-generation"] = Pod.Long (2)
    values [RECOVERY .. "recovery-generation"] = Pod.Long (1)
    values [RECOVERY .. "request-token"] = Pod.Long (9)
    values [RECOVERY .. "closure-inhibited"] = Pod.Boolean (release)
    values [RECOVERY .. "reference-reached"] = Pod.Boolean (release)
    values [RECOVERY .. "observation-sequence"] = Pod.Long (release and 4 or 0)
    values [RECOVERY .. "observation-monotonic-nanoseconds"] = Pod.Long (GLib.get_monotonic_time () * 1000)
    values [RECOVERY .. "reference-timeout-ms"] = Pod.Int (5000)
    values [RECOVERY .. "state"] = Pod.String (release and "applied" or "released")
    updates [RECOVERY .. (release and "release-token" or "request-token")] = Pod.Long (release and 1 or 10)
    if mutate then mutate (state, args, values, updates, declarations) end
  end, expected)
end
recovery_case (false)
recovery_case (true)
recovery_case (false, function (state) state.lifecycle = 3 end,
    "Correction control requires a running session")
recovery_case (false, function (_, args) args.owners [1] ["bootstrap-instance"] = "9" end,
    "Correction graph owner incarnation changed")
recovery_case (false, function (_, _, values) values [RECOVERY .. "active-generation"] = Pod.Long (1) end,
    "Recovery adoption is pending")
recovery_case (false, function (_, _, _, updates) updates [RECOVERY .. "request-token"] = Pod.Long (9) end,
    "Recovery request token must advance")
recovery_case (false, function (_, _, _, updates) updates ["controller:gain"] = Pod.Float (0.2) end,
    "Recovery requires one unmixed control request")
recovery_case (false, function (_, _, values) values [KEY .. ".fault"] = Pod.String ("fault") end,
    "Correction fault is latched")
recovery_case (true, function (_, _, values) values [RECOVERY .. "reference-reached"] = Pod.Boolean (false) end,
    "Recovery command reference is not confirmed")
recovery_case (true, function (_, _, values) values [RECOVERY .. "observation-sequence"] = Pod.Long (0) end,
    "Recovery command reference is not confirmed")
recovery_case (true, function (_, _, _, updates) updates [RECOVERY .. "release-token"] = Pod.Long (2) end,
    "Recovery release generation mismatch")
recovery_case (true, function (_, _, values) values [TARGET] = Pod.Boolean (true); values [KEY .. ".state"] = Pod.String ("Closed"); values [KEY .. ".requested"] = Pod.Boolean (true) end,
    "Recovery release requires an inhibited open controller")
recovery_case (true, function (_, _, values) values [RECOVERY .. "state"] = Pod.String ("release_refused") end)
recovery_case (true, function (_, _, _, updates)
  updates [RECOVERY .. "release-token"] = nil
  updates ["controller:gain"] = Pod.Float (0.2)
end, "Protective recovery inhibits scientific updates")
local inhibited = { [RECOVERY .. "version"] = Pod.Int (1),
    [RECOVERY .. "closure-inhibited"] = Pod.Boolean (true) }
assert (not pcall (correction.check_parameter, inhibited))
inhibited [RECOVERY .. "closure-inhibited"] = Pod.Boolean (false)
assert (pcall (correction.check_parameter, inhibited))
assert (pcall (correction.check_parameter, {}))

local function guarded_close (_, _, values, updates)
  updates [RECOVERY .. "request-token"] = nil
  updates [TARGET] = Pod.Boolean (true)
  values [RECOVERY .. "close-guarded"] = Pod.Boolean (true)
  values [RECOVERY .. "reference-reached"] = Pod.Boolean (true)
  values [RECOVERY .. "observation-sequence"] = Pod.Long (4)
end
recovery_case (false, guarded_close)
recovery_case (false, function (...)
  guarded_close (...)
  local values = select (3, ...)
  values [RECOVERY .. "reference-reached"] = Pod.Boolean (false)
end, "Recovery command reference is not confirmed")
recovery_case (false, function (...)
  guarded_close (...)
  local values = select (3, ...)
  values [RECOVERY .. "active-generation"] = Pod.Long (1)
end, "Recovery command reference is not confirmed")

recovery_case (false, function (...)
  guarded_close (...)
  local updates = select (4, ...)
  updates ["controller:gain"] = Pod.Float (0.2)
end, "Recovery close requires one unmixed control request")

for _, mutate in ipairs ({
  function (values) values [RECOVERY .. "observation-monotonic-nanoseconds"] = Pod.Long ((GLib.get_monotonic_time () - 6000000) * 1000) end,
  function (values) values [RECOVERY .. "observation-monotonic-nanoseconds"] = Pod.Long ((GLib.get_monotonic_time () + 1000000) * 1000) end,
  function (values) values [RECOVERY .. "reference-timeout-ms"] = Pod.Int (0) end,
}) do
  recovery_case (true, function (_, _, values) mutate (values) end,
      "Recovery command reference is not confirmed")
  recovery_case (false, function (...)
    guarded_close (...)
    mutate (select (3, ...))
  end, "Recovery command reference is not confirmed")
end
