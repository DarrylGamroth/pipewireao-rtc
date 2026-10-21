-- SPDX-License-Identifier: MIT
-- Use stock constructors/parser and RTC-owned copies across the public bridge.
local lua = require ("ao-lua")
local values = { Pod.None (), Pod.Id (0xf0000001), Pod.Int (-2147483648),
  Pod.Long (9007199254740993), Pod.Long (-9007199254740993),
  Pod.Long (math.maxinteger), Pod.Long (math.mininteger), Pod.Float (-0.0),
  Pod.Double (-0.0), Pod.Boolean (false), Pod.String ("science") }
local parent = Pod.Struct (values)
local retained = {}
for child in lua.fields (parent) do retained [#retained + 1] = child end
assert (#retained == #values)
parent = nil
for index, value in ipairs (values) do
  local child = retained [index]
  assert (lua.equals (child, value) and child:get_type_name () == value:get_type_name ())
  local parsed = child:parse ()
  if index >= 4 and index <= 7 then
    assert (math.type (parsed) == "integer" and parsed == value:parse (), "Int64 lost bits")
  elseif index == 8 or index == 9 then
    local format = index == 8 and "<f" or "<d"
    assert (string.pack (format, parsed) == string.pack (format, -0.0), "Signed zero lost")
  end
end
assert (not lua.equals (Pod.Float (1), Pod.Double (1)), "Scalar type erased")
assert (not lua.equals (Pod.Long (9007199254740993), Pod.Long (9007199254740992)))
local object = Pod.Object { "Spa:Pod:Object:Param:Props", "Props",
  ["id-f0000001"] = Pod.Long (9007199254740993), params = Pod.Struct { "retained" } }
local rows = {}
for key, value, flags, id in lua.properties (object) do
  assert (flags == 0 and not rows [id])
  rows [id] = { key = key, value = value }
end
object = nil
assert (rows [0xf0000001].key == "id-f0000001")
assert (rows [0xf0000001].value:parse () == 9007199254740993)
assert (lua.object_id (Pod.Object { "Spa:Pod:Object:Param:Props", "Props" }) == "Props")
assert (GLib.get_monotonic_time () > 0)

local array = Pod.Array { "Spa:Int", 4, 8 }
local kind, width, count = lua.array_info (array)
assert (kind == "Spa:Int" and width == 4 and count == 2)
local choice = Pod.Choice.None { "Spa:Int", 42, 7, 9 }
local before = lua.copy (choice)
assert (lua.choice_type (choice) == "None")
local default, alternatives = lua.choice_child (choice)
assert (default:parse () == 42 and alternatives == 3)
assert (lua.equals (choice, before), "Choice metadata inspection changed alternatives")
assert (not pcall (lua.fields, Pod.Int (1)))
assert (not pcall (lua.properties, Pod.Int (1)))
assert (not pcall (lua.array_info, choice))
assert (not pcall (lua.choice_child, array))
assert (not pcall (lua.copy, nil))
assert (not pcall (lua.array_info, Pod.Int (1)))
