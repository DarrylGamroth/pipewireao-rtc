-- Development compatibility fixture; does not authorize RTC acquisition.
-- Exact object IDs and serials come from the isolated core's current registry.
local args = ...
args = args:parse(1)
local link
local attempted = false
local withdrawn = false

local function matches(object, prefix)
  local props = object["global-properties"]
  return tostring(object["bound-id"]) == tostring(args[prefix .. ".id"])
      and tostring(props["object.serial"]) == tostring(args[prefix .. ".serial"])
end

local function find(prefix, kind)
  for object in ndarray_pilot_om:iterate { type = kind } do
    if matches(object, prefix) then return object end
  end
end

local function realize()
  if attempted then return end
  local source = find("source", "node")
  local sink = find("sink", "node")
  local output = find("output", "port")
  local input = find("input", "port")
  if not source or not sink or not output or not input then return end
  attempted = true
  assert(tostring(output["global-properties"]["node.id"]) == tostring(source["bound-id"]))
  assert(tostring(input["global-properties"]["node.id"]) == tostring(sink["bound-id"]))
  assert(output:get_direction() == "output" and input:get_direction() == "input")

  local compatible
  for offered in output:iterate_params("EnumFormat") do
    for accepted in input:iterate_params("EnumFormat") do
      compatible = offered:filter(accepted)
      if compatible then break end
    end
    if compatible then break end
  end
  assert(compatible, "NDArray endpoints have no format intersection")
  compatible:fixate()
  local format = compatible:parse().properties
  print("PILOT_FORMAT")
  Debug.dump_table(format)
  assert(format.mediaSubtype == "ndarray", "AO NDArray type is unavailable")
  assert(format.mediaType == "application", "Unexpected media type")
  assert(format.elementType == "U16_LE", "Unexpected element encoding")
  assert(format.schema == "org.pipewireao.test.wireplumber/1", "Unexpected schema")
  assert(format.shape[1] == 4 and format.shape[2] == 3 and #format.shape == 2,
      "Unexpected array shape")
  assert(format.layout == "COLUMN_MAJOR", "Unexpected layout")
  assert(format.rate.num == 100 and format.rate.denom == 1, "Unexpected rate")

  output:enum_params("Meta", function(iterator, error)
    if withdrawn then return end
    assert(not error, tostring(error))
    local header = false
    for pod in iterator:iterate() do
      local meta = pod:parse().properties
      if meta.type == "Header" and meta.size == 32 then header = true end
    end
    assert(header, "Expected frame Header metadata")
    print("PILOT_META Header 32")

    -- Keep the proxy alive and client-owned. There is no automatic name-based
    -- reconnection, lingering link, standard audio policy or source release here.
    link = Link("link-factory", {
      ["link.output.node"] = source["bound-id"],
      ["link.output.port"] = output["bound-id"],
      ["link.input.node"] = sink["bound-id"],
      ["link.input.port"] = input["bound-id"],
      ["link.passive"] = false,
      ["object.linger"] = false,
    })
    assert(link, "link-factory unavailable")
    link:connect("state-changed", function(_, _, state)
      print("PILOT_LINK_STATE " .. tostring(state))
    end)
    link:activate(Feature.Proxy.BOUND | Feature.PipewireObject.INFO, function(object, error)
      if withdrawn then return end
      assert(not error, tostring(error))
      print("PILOT_LINK_BOUND " .. tostring(object["bound-id"]))
    end)
  end)
end

ndarray_pilot_om = ObjectManager {
  Interest { type = "node" },
  Interest { type = "port" },
}
ndarray_pilot_om:connect("object-added", function(_, object)
  print("PILOT_OBJECT " .. tostring(object["bound-id"]) .. " " .. tostring(object["global-properties"]["object.serial"]))
  realize()
end)
ndarray_pilot_om:connect("object-removed", function(_, object)
  for _, prefix in ipairs { "source", "sink", "output", "input" } do
    if matches(object, prefix) then
      withdrawn = true
      if link then link:request_destroy(); link = nil end
      attempted = true
      print("PILOT_ENDPOINT_LOST " .. prefix)
      return
    end
  end
end)
ndarray_pilot_om:activate()

Core.timeout_add(5000, function()
  if not link then
    withdrawn = true
    attempted = true
    print("PILOT_NO_LINK")
  end
  return false
end)
