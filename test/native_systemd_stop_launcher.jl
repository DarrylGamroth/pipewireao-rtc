# Instrument only the cold integration helper, without production timing hooks.
# Evaluate the instrumented CLI in an isolated parent module so the package
# methods remain unchanged. Exact replacements fail if the measured code drifts.
source_path, evidence_root = ARGS[1:2]
stop_test_event(name) = write(joinpath(evidence_root, name), string(time_ns()))
stop_test_event("helper-launch")
using PipeWireAORTC
source_path = joinpath(PipeWireAORTC.package_root(), "src", "cli.jl")
source = read(source_path, String)
first_byte = findfirst("function stop!(args)", source)
last_byte = findnext("\n\"List local POD hints", source, last(first_byte))
body = source[first(first_byte):first(last_byte)-1]
function insert_once(body, before, after)
    length(findall(before, body)) == 1 || error("stop timing source changed: $before")
    return replace(body, before => after; count=1)
end
for (before, after) in [
    "    deadline = Client.monotonic() + 30" => "    Main.stop_test_event(\"helper-budget-start\")\n    deadline = Client.monotonic() + 30",
    "    client = Client.connect(" => "    Main.stop_test_event(\"connect-begin\")\n    client = Client.connect(",
    "    try\n        status = Client.request!" => "    Main.stop_test_event(\"connect-end\")\n    try\n        Main.stop_test_event(\"status-request\")\n        status = Client.request!",
    "        record[\"systemd_quit\"] = Dict" => "        Main.stop_test_event(\"status-complete\")\n        record[\"systemd_quit\"] = Dict",
    "        completion = Client.request!" => "        Main.stop_test_event(\"quit-request\")\n        completion = Client.request!",
    "        record[\"systemd_quit\"][\"accepted\"] = true" => "        Main.stop_test_event(\"quit-complete\")\n        record[\"systemd_quit\"][\"accepted\"] = true",
    "    finally\n        close(client)\n    end" => "    finally\n        Main.stop_test_event(\"client-close-begin\")\n        close(client)\n        Main.stop_test_event(\"client-close-end\")\n    end",
    "        current[\"MainPID\"] == \"0\" && return nothing" => "        if current[\"MainPID\"] == \"0\"\n            Main.stop_test_event(\"mainpid-exit-observed\")\n            return nothing\n        end",
]
    global body = insert_once(body, before, after)
end
source = source[1:first(first_byte)-1] * body * source[first(last_byte):end]
sandbox = Module(:InstrumentedStopCLI)
for name in (:PipeWireAORTC, :WirePlumberConfiguration, :WirePlumberLaunch, :WirePlumberInstall)
    value = name === :PipeWireAORTC ? PipeWireAORTC : getproperty(PipeWireAORTC, name)
    Core.eval(sandbox, Expr(:const, Expr(:(=), name, value)))
end
include_string(sandbox, source, source_path)
const WirePlumberCLI = sandbox.WirePlumberCLI
stop_test_event("helper-loaded")
try
    WirePlumberCLI.main(ARGS[3:end])
finally
    stop_test_event("helper-finish")
end
