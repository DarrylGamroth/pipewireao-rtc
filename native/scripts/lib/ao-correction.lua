-- WirePlumber
-- SPDX-License-Identifier: MIT

-- Admission for explicitly published correction-loop controls. The session
-- remains the sole execution authority; no scientific state is changed here.
local control = require ("ao-control")
local correction = {}
local PREFIX = "pipewireao.correction-control."
local RECOVERY = "pipewireao-recovery:"

-- These read-only fields share the scientific Props record. They are not
-- run/reset acknowledgements; those retain their separate exact records.
function correction.is_status_field (name)
  if name:sub (1, #PREFIX) ~= PREFIX then return false end
  local suffix = name:sub (#PREFIX + 1)
  if suffix == "version" or suffix == "owner-instance" then return true end
  local property, field = suffix:match ("^([^:]+:[^:]+)%.([a-z]+)$")
  return property ~= nil and (field == "state" or field == "fault" or field == "requested")
end

local function scalar (values, name, kind)
  return control.scalar (assert (values [name], "Missing correction status: " .. name), kind)
end

local function owner_instance (args, name)
  local pid = args ["node.pids"] [name]
  assert (math.type (pid) == "integer" and pid > 0, "Correction graph owner PID missing")
  local instance
  for _, declaration in ipairs (args.owners) do
    if declaration ["bootstrap-node"] and declaration.pid == pid then
      assert (not instance, "Ambiguous correction graph owner")
      instance = tonumber (declaration ["bootstrap-instance"])
      assert (math.type (instance) == "integer" and instance > 0,
          "Correction graph owner incarnation missing")
    end
  end
  return assert (instance, "Correction graph has no declared bootstrap owner")
end

local function running (state, args, name, values)
  assert (scalar (values, PREFIX .. "owner-instance", "Long") == owner_instance (args, name),
      "Correction graph owner incarnation changed")
  assert (state.lifecycle == 4, "Correction control requires a running session")
  local admitted = false
  for _, group in pairs (state.groups) do
    for _, member in ipairs (group.nodes) do
      if member == name then
        assert (group.running, "Correction execution group is stopped")
        admitted = true
      end
    end
  end
  assert (admitted, "Correction graph has no running execution group")
  assert (scalar (values, "pipewireao.run-control.actual-state", "String") == "running",
      "Correction graph owner is stopped")
end

local function recovery_check (state, args, name, values, updates, declarations)
  local request = updates [RECOVERY .. "request-token"]
  local release = updates [RECOVERY .. "release-token"]
  local version = values [RECOVERY .. "version"]
  if not (version or declarations [RECOVERY .. "version"] or request or release) then return end
  assert (version and control.scalar (version, "Int") == 1, "Unsupported recovery-control version")
  local inhibited = scalar (values, RECOVERY .. "closure-inhibited", "Bool")
  if not request and not release then
    assert (not inhibited, "Protective recovery inhibits scientific updates")
    local controller = scalar (values, RECOVERY .. "controller", "String")
    local close = updates [controller .. ":closed"]
    if close and control.scalar (close, "Bool") and
        scalar (values, RECOVERY .. "close-guarded", "Bool") then
      assert (scalar (values, RECOVERY .. "state", "String") == "released" and
          scalar (values, RECOVERY .. "requested-generation", "Long") ==
          scalar (values, RECOVERY .. "active-generation", "Long") and
          scalar (values, RECOVERY .. "reference-reached", "Bool") and
          scalar (values, RECOVERY .. "observation-sequence", "Long") > 0,
          "Recovery command reference is not confirmed")
    end
    return
  end
  local count = 0
  for _ in pairs (updates) do count = count + 1 end
  assert (count == 1 and not (request and release), "Recovery requires one unmixed control request")
  running (state, args, name, values)
  assert (scalar (values, PREFIX .. "version", "Int") == 1, "Unsupported correction-control version")
  local controller = scalar (values, RECOVERY .. "controller", "String")
  assert (controller:match ("^[%w_.%-]+$"), "Invalid recovery controller")
  local target = controller .. ":closed"
  local key = PREFIX .. target
  local current = scalar (values, key .. ".state", "String")
  assert (current == "Open" or current == "Closed", "Correction state is not ready")
  assert (scalar (values, key .. ".fault", "String") == "", "Correction fault is latched")
  assert (scalar (values, RECOVERY .. "requested-generation", "Long") ==
      scalar (values, RECOVERY .. "active-generation", "Long"), "Recovery adoption is pending")
  assert (scalar (values, controller .. ":requested-generation", "Long") ==
      scalar (values, controller .. ":active-generation", "Long"), "Correction property adoption is pending")
  local active = scalar (values, target, "Bool")
  assert ((current == "Closed") == active and scalar (values, key .. ".requested", "Bool") == active,
      "Inconsistent correction state")
  if request then
    assert (not inhibited, "Protective recovery is already inhibited")
    local token = control.scalar (request, "Long")
    assert (token > 0 and token > scalar (values, RECOVERY .. "request-token", "Long"),
        "Recovery request token must advance")
  else
    assert (inhibited and not active, "Recovery release requires an inhibited open controller")
    local generation = scalar (values, RECOVERY .. "recovery-generation", "Long")
    assert (generation > 0 and control.scalar (release, "Long") == generation,
        "Recovery release generation mismatch")
    local recovery_state = scalar (values, RECOVERY .. "state", "String")
    assert ((recovery_state == "applied" or recovery_state == "release_refused") and
        scalar (values, RECOVERY .. "reference-reached", "Bool") and
        scalar (values, RECOVERY .. "observation-sequence", "Long") > 0,
        "Recovery command reference is not confirmed")
  end
end

function correction.check_parameter (values)
  if values [RECOVERY .. "version"] then
    assert (control.scalar (values [RECOVERY .. "version"], "Int") == 1,
        "Unsupported recovery-control version")
    assert (not scalar (values, RECOVERY .. "closure-inhibited", "Bool"),
        "Protective recovery inhibits scientific updates")
  end
end

function correction.check (state, args, name, values, updates, declarations)
  recovery_check (state, args, name, values, updates, declarations)
  local version = values [PREFIX .. "version"]
  if version or declarations [PREFIX .. "version"] then
    assert (version, "Correction-control version missing")
    assert (control.scalar (version, "Int") == 1, "Unsupported correction-control version")
  end
  for property, update in pairs (updates) do
    local key = PREFIX .. property
    if values [key .. ".state"] or values [key .. ".fault"] or values [key .. ".requested"] or
        declarations [key .. ".state"] or declarations [key .. ".fault"] or declarations [key .. ".requested"] then
      assert (version, "Correction-control version missing")
      running (state, args, name, values)
      local current = scalar (values, key .. ".state", "String")
      assert (current == "Open" or current == "Closed", "Correction state is not ready")
      assert (scalar (values, key .. ".fault", "String") == "", "Correction fault is latched")
      control.scalar (update, "Bool")
      local active = scalar (values, property, "Bool")
      assert (scalar (values, key .. ".requested", "Bool") == active and
          (current == "Closed") == active, "Inconsistent correction state")
      local node = assert (property:match ("^([^:]+):.+$"), "Invalid correction property")
      local requested = scalar (values, node .. ":requested-generation", "Long")
      local applied = scalar (values, node .. ":active-generation", "Long")
      assert (requested >= 0 and requested == applied, "Correction property adoption is pending")
    end
  end
end

return correction
