-- Development coexistence probe. The RTC owns admission and all links.
-- Do not watch nodes: Lua ObjectManager requests ALL features, including Props.
local args = (...):parse()
assert(type(args.objects) == "table" and #args.objects > 0, "Required cohort arguments missing")
print("HIL_OBSERVER_STARTED " .. tostring(#args.objects))
local seen = {}
local ready = false
local withdrawn = false
local current = {}

local function withdraw(role, reason)
  if withdrawn then return end
  withdrawn = true
  print("HIL_COHORT_LOST " .. role .. " " .. reason)
end

local function expected_format(contract)
  local shape = { "Spa:Int" }
  for _, value in ipairs(contract.shape) do table.insert(shape, value) end
  local declaration = {
    "Spa:Pod:Object:Param:Format", "Format",
    mediaType = contract.mediaType,
    mediaSubtype = contract.mediaSubtype,
    elementType = contract.elementType,
    schema = contract.schema,
    layout = contract.layout,
    shape = Pod.Array(shape),
  }
  if contract.rate then
    -- The generic Format table also has audio's integer "rate". Use the
    -- public NDArray ABI key to select its Fraction without that name clash.
    declaration["id-01000004"] = Pod.Fraction(contract.rate.num, contract.rate.denom)
  end
  return Pod.Object(declaration)
end

local function matches(object, expected)
  return tostring(object["bound-id"]) == tostring(expected.id)
      and tostring(object["global-properties"]["object.serial"]) == tostring(expected.serial)
end

local function check_ready()
  if ready or withdrawn then return end
  for _, expected in ipairs(args.objects) do
    if not seen[expected.role] then return end
  end
  for _, expected in ipairs(args.owners or {}) do
    if not seen[expected.role] then return end
  end
  ready = true
  print("HIL_COHORT_READY")
end

hil_observer_om = ObjectManager {
  Interest { type = "port" },
  Interest { type = "link" },
  Interest { type = "client" },
}
hil_observer_om:connect("object-added", function(_, object)
  if withdrawn then return end
  for _, expected in ipairs(args.objects) do
    if matches(object, expected) then
      local props = object["global-properties"]
      if expected.kind == "port" then
        assert(tostring(props["node.id"]) == tostring(expected.node), "Wrong parent node")
        assert(object:get_direction() == expected.direction, "Wrong port direction")
        local matched = false
        local contract = expected.format
        local filter = expected_format(contract)
        -- These runtime-owned links are already negotiated. Validate Format,
        -- not a sparse EnumFormat offer (parameter offers may omit a rate).
        for pod in object:iterate_params("Format") do
          local format = pod:parse().properties
          print("HIL_FORMAT " .. expected.role)
          Debug.dump_table(format)
          local complete = format.mediaType and format.mediaSubtype
              and format.elementType and format.schema and format.layout and format.shape
              and (not contract.rate or format.rate)
          -- Lua parse() does not preserve values for Choice.None of String,
          -- Array or Fraction. Native SPA filtering does; keep validation there.
          if complete and pod:filter(filter) then
            for _, key in ipairs { "schema", "shape", "elementType", "layout", "rate" } do
              if contract[key] then
                local wrong = {}
                for name, value in pairs(contract) do wrong[name] = value end
                if key == "schema" then wrong.schema = contract.schema .. ".incompatible"
                elseif key == "shape" then
                  wrong.shape = { table.unpack(contract.shape) }
                  wrong.shape[1] = wrong.shape[1] + 1
                elseif key == "elementType" then
                  wrong.elementType = contract.elementType == "F32_LE" and "U16_LE" or "F32_LE"
                elseif key == "layout" then
                  wrong.layout = contract.layout == "ROW_MAJOR" and "COLUMN_MAJOR" or "ROW_MAJOR"
                else
                  wrong.rate = { num = contract.rate.num + 1, denom = contract.rate.denom }
                end
                assert(not pod:filter(expected_format(wrong)), "Native format filter accepted wrong " .. key)
                print("HIL_REJECTED " .. expected.role .. " " .. key)
              end
            end
            matched = true
            break
          end
        end
        assert(matched, "Expected NDArray port contract missing")
      else
        -- Passive policy belongs to Link Info, not the registry property subset.
        props = object.properties
        for key, value in pairs(expected.properties) do
          assert(tostring(props[key]) == tostring(value), "Wrong link endpoint or owner")
        end
        assert((tostring(props["link.passive"]) == "true") == expected.passive, "Wrong passive policy")
      end
      seen[expected.role] = true
      current[expected.role] = object
      if expected.kind == "link" then
        object:connect("state-changed", function(_, _, state)
          if state < 0 then withdraw(expected.role, "link-failed") end
        end)
      end
      print("HIL_OBJECT " .. expected.role .. " " .. tostring(expected.id)
          .. " " .. tostring(expected.serial))
      check_ready()
      return
    end
  end
  for _, expected in ipairs(args.owners or {}) do
    if matches(object, expected) then
      assert(tostring(object.properties["application.process.id"]) == tostring(expected.pid), "Wrong role owner PID")
      seen[expected.role] = true
      current[expected.role] = object
      object:connect("notify::properties", function()
        if tostring(object.properties["application.process.id"]) ~= tostring(expected.pid) then
          withdraw(expected.role, "owner-changed")
        end
      end)
      print("HIL_OWNER " .. expected.role .. " " .. tostring(expected.pid))
      check_ready()
      return
    end
  end
end)
hil_observer_om:connect("object-removed", function(_, object)
  for _, expected in ipairs(args.objects) do
    if matches(object, expected) then
      withdraw(expected.role, "object-removed")
      return
    end
  end
  for _, expected in ipairs(args.owners or {}) do
    if matches(object, expected) then
      withdraw(expected.role, "owner-removed")
      return
    end
  end
end)
hil_observer_om:activate()

-- Recheck the observed declared contracts. This optional policy neither repairs
-- links nor authorizes ingress; RTC's native monitor retains those decisions.
Core.timeout_add(100, function()
  if withdrawn then return false end
  if not ready then return true end
  for _, expected in ipairs(args.objects) do
    local object = current[expected.role]
    if not object or not matches(object, expected) then
      withdraw(expected.role, "incarnation-changed")
      return false
    end
    if expected.kind == "port" then
      local matched = false
      for pod in object:iterate_params("Format") do
        local format = pod:parse().properties
        local complete = format.mediaType and format.mediaSubtype and format.elementType
            and format.schema and format.layout and format.shape
            and (not expected.format.rate or format.rate)
        if complete and pod:filter(expected_format(expected.format)) then matched = true; break end
      end
      if not matched then
        withdraw(expected.role, "format-changed")
        return false
      end
    else
      if object["state"] < 0 then
        withdraw(expected.role, "link-failed")
        return false
      end
      if (tostring(object.properties["link.passive"]) == "true") ~= expected.passive then
        withdraw(expected.role, "passive-changed")
        return false
      end
      for key, value in pairs(expected.properties) do
        if tostring(object.properties[key]) ~= tostring(value) then
          withdraw(expected.role, "link-changed")
          return false
        end
      end
    end
  end
  return true
end)
