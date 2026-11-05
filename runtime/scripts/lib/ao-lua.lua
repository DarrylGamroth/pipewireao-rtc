-- SPDX-License-Identifier: MIT
-- RTC bindings for public libwp operations absent from its stock Lua API.
local api = assert (Plugin.find ("ao-lua"), "RTC ao-lua component is required")
local lua = {}

function lua.copy (pod)
  local copy = api:call ("pod-copy", pod)
  assert (api:call ("pod-valid", copy), "Invalid POD")
  return copy
end
function lua.equals (a, b) return api:call ("pod-equals", a, b) end
function lua.size (pod) return api:call ("pod-size", pod) end
function lua.object_id (pod) return assert (api:call ("pod-object-id", pod), "Expected Object") end
function lua.fields (pod)
  local iterator = api:call ("pod-fields", pod)
  assert (api:call ("iterator-valid", iterator), "Malformed Struct")
  return iterator:iterate ()
end
function lua.properties (pod)
  local iterator = api:call ("pod-properties", pod)
  assert (api:call ("iterator-valid", iterator), "Malformed Object")
  local next_property, state = iterator:iterate ()
  return function ()
    local property = next_property (state)
    if property then return property.key, property.value, property.flags, property.id end
  end
end
local function array_info (pod)
  local info = api:call ("pod-array-info", pod):parse ()
  assert (info.type, "Malformed Array or Choice")
  return info
end
function lua.array_info (pod)
  local info = array_info (pod)
  assert (not info.choice, "Expected Array")
  return info.type, info.width, info.count
end
function lua.choice_type (pod)
  return assert (array_info (pod).choice, "Expected Choice")
end
function lua.choice_child (pod)
  local info = array_info (pod)
  assert (info.choice, "Expected Choice")
  local child = api:call ("pod-choice-child", pod)
  assert (api:call ("pod-valid", child), "Malformed Choice")
  return child, info.count
end
function lua.object_manager (interests, features)
  assert (math.type (features) == "integer" and features >= 0 and features <= 0xffffffff,
      "Invalid ObjectManager features")
  local manager = api:call ("object-manager", features)
  for _, interest in ipairs (interests) do api:call ("add-interest", manager, interest) end
  return manager
end
function lua.push_event (event)
  assert (type (event.type) == "string" and math.type (event.priority) == "integer",
      "Invalid event type or priority")
  return api:call ("push-event", event.type, event.priority,
      event.properties or {}, event.source, event.subject)
end
return lua
