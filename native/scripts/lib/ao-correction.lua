-- WirePlumber
-- SPDX-License-Identifier: MIT

-- Admission for explicitly published correction-loop controls. The session
-- remains the sole execution authority; no scientific state is changed here.
local control = require ("ao-control")
local correction = {}
local PREFIX = "pipewireao.correction-control."

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

function correction.check (state, args, name, values, updates, declarations)
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
      assert (scalar (values, PREFIX .. "owner-instance", "Long") == owner_instance (args, name),
          "Correction graph owner incarnation changed")
      assert (state.lifecycle == 4, "Correction control requires a running session")
      local running = false
      for _, group in pairs (state.groups) do
        for _, member in ipairs (group.nodes) do
          if member == name then
            assert (group.running, "Correction execution group is stopped")
            running = true
          end
        end
      end
      assert (running, "Correction graph has no running execution group")
      assert (scalar (values, "pipewireao.run-control.actual-state", "String") == "running",
          "Correction graph owner is stopped")
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
