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
