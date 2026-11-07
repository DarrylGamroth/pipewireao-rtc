# Standalone simulation configuration

AdaptiveOpticsSimPipeWireHIL owns the configuration for running a prepared
simulation over PipeWire. The simulation does not need an RTC processing graph
or an RTC runtime dependency. A separate session authority owns links to the
selected RTC or SPA protocol plugins.

The first portable product supports lockstep AOS graphs. It contains a standard
AOS graph YAML file, exact typed FITS binding arrays and a small HIL manifest.
It does not introduce another graph language, numerical executor or supervisor.
The higher-level instrument/settings resolver remains in RTC for cold export;
HIL never imports or copies it.

## Export existing authoring once

Load AOS/HIL and supply the simulation's existing transport contract:

```julia
using PipeWireAORTC, AdaptiveOpticsSim, AdaptiveOpticsSimPipeWireHIL, PipeWireAO

wire = PipeWireHILConfiguration(;
    remote = "simulation-core",
    frame_node_name = "simulation-frame",
    command_node_name = "simulation-command",
    frame_schema = "example.detector-frame/1",
    command_schema = "example.mirror-command/1",
    rate = PipeWireAO.SPA.Fraction(500, 1),
    exposure_duration_ns = 2_000_000,
)
manifest = PipeWireAORTC.InstrumentConfiguration.export_simulation(
    "instrument/simulation/definition.yaml",
    "build/simulation";
    configuration = wire,
    simulation_graph = "production",
)
```

These example schemas must be replaced by the simulation's declared wire
contract. The exporter checks that contract, uses the existing authored settings
and graph/binding preparation, then verifies the independent HIL reader before
exposing the output directory. The destination must not already exist. Export
does not open a PipeWire core, start services or modify the authored source.

The product uses generated-file headers and content hashes. Change authoring
or export options and regenerate it; do not edit generated payloads or hashes.
Standalone users can also author the documented HIL manifest around existing
standard AOS graphs and bindings without using RTC as a build tool.

## Run independently

In an environment containing HIL and its scientific dependencies:

```julia
using AdaptiveOpticsSimPipeWireHIL: Simulation

configuration = Simulation.load("build/simulation/simulation.yaml")
prepared = Simulation.prepare(configuration)
Simulation.run!(prepared; frames = 100) do science, transport
    # The session authority admits and links these endpoints independently.
    true
end
```

Loading validates bounded configuration, hashes, binding element types and
logical dimensions. It retains verified graph/array snapshots; preparation
opens no core. Paths remain inside the portable product, so it can be relocated
and loaded after the original authoring files have been removed. Numerical
preparation delegates to public AOS APIs. Node sample periods must agree with
the model-time driver; the nominal SPA rate remains independently declared.

`run!` opens ordinary HIL endpoints and closes them on completion, stopped
admission or control failure. The callback runs before activation and before
each exchange; `false` ends the finite run. Native timeouts bound readiness and
exchange waits. Links belong to a separate session connection, so their proxy
lifetime cannot prevent the simulation from closing its own connection.

## SPA protocol compatibility

The simulation exposes ordinary ndarray ports. Native SPA plugins own protocol
packetization and decoding. Schemas, encoding, physical units, actuator order,
metadata requirements and clock meaning must agree at each link. Configuration
cannot turn an incompatible protocol into a compatible one by changing names.

The inspected HEART plugin revision `9aeea533` advertises the retired monolithic
acquisition metadata rather than the current compact records. Its UDP wire
protocol does not carry the complete acquisition identity and exposure facts
required by modern lockstep HIL. This is an observed compatibility gap; the
older October bridge evidence does not qualify the current package cohort.
Preserve lockstep correlation checks. Do not fabricate identity or relabel raw
ADC values as calibrated pixels.

External-pupil and clocked-optical **prepared execution APIs** are available in
HIL, but this initial configuration schema does not serialize those compositions
or compiled optical model assets. Those need portable graph/model assets and
explicit pupil/sensor/source contracts. Current HEART interoperability additionally
needs the plugin metadata migration, an explicit wire encoding/unit selection
and an actual private-core roundtrip. Neither the initial manifest nor its
generic ndarray test establishes that interoperability.

The [extraction record](reviews/20261107-hil-extraction/REVIEW.md) records the
preceding ownership migration. Focused checks are `test/simulation_export.jl`
in RTC, and `test/simulation.jl` / `test/simulation_private_core.jl` in HIL.
Software checks do not establish hardware behavior or real-time qualification.
