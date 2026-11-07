# Standalone simulation configuration

AdaptiveOpticsSimPipeWireHIL runs configured simulations over PipeWire without
an RTC runtime dependency. AOS owns numerical models, graphs and model time.
A separate session authority owns admission and links to the selected RTC or
SPA protocol plugins.

Schema 1 retains the lockstep frame/command product. Schema 2 supports current
external-pupil and clocked-optical execution, independent camera exposures,
chopping, detector responses and compiled optical models. Both use ordinary AOS
graph YAML and exact typed FITS bindings. No graph language or numerical
executor is added. The higher-level instrument/settings resolver remains in RTC
for cold export; HIL neither imports nor copies it.

## Export existing authoring once

For an external pupil, write a transport selection such as `hil.yaml`:

```yaml
schema_version: 2
mode: external_pupil
pipewire:
  remote: simulation-core
  pupil_node_name: simulation-pupil
  sensor_node_names:
    llowfs: simulation-llowfs
    scc: simulation-scc
  sensor_buffers: 3
  reference_clock: realtime
```

Names must match the physical paths in the authored simulation. Optional
`chopping` selects an existing unfringed graph, initial optical phase and
independent electrical trigger polarity:

```yaml
chopping:
  scc:
    unfringed_graph: scc_unfringed
    initial_phase: fringed
    trigger_high_is_fringed: true
```

Resolve the authoring with the existing compiler:

```julia
using PipeWireAORTC, AdaptiveOpticsSim, AdaptiveOpticsSimPipeWireHIL

manifest = PipeWireAORTC.InstrumentConfiguration.export_simulation(
    "instrument/generated/simulation.yaml",
    "build/simulation";
    configuration = "hil.yaml",
)
```

Use the executable authored graph declaration when no generated optical model
is needed. The exporter loads optional Proper only when selected graphs need
it. Settings use the existing `settings` keyword. A mapping can also supply
`configuration` directly.

Export resolves the declared optical/response/source graphs and bindings once,
retains physical pupil/sensor contracts and copies compiled models with unchanged
content hashes. It verifies the independent HIL loader before exposing a new
directory. The destination must not exist. Authoring files remain unchanged;
export opens no core and starts no services. Regenerate products from authoring
rather than editing generated payloads or hashes.

For the earlier lockstep product, pass the existing `PipeWireHILConfiguration`
instead of a mapping or filename. `simulation_graph="production"` selects its
ordinary AOS graph; its schemas and command scale must match the authored wire
contract.

## Clocked optical source

A clocked selection replaces the pupil input with a command sink and a declared
AOS source graph. It has no `pupil_node_name`, because that node does not exist:

```yaml
schema_version: 2
mode: clocked_optical
pipewire:
  remote: simulation-core
  sensor_node_names:
    llowfs: simulation-llowfs
    scc: simulation-scc
  sensor_buffers: 3
  reference_clock: realtime
  command:
    node_name: simulation-command
    schema: example.mirror-command/1
    buffers: 3
    properties:
      optics.command-units: m
source:
  graph: source
  command_input: command
  amplitude_binding: source_amplitude
  pupil_axes: [2, 1]
  period_ns: 2000000
  command_limit: 0.000001
  pacing_period_ns: 2000000
```

These example graph/binding names, schema and command limit must match the
actual simulation. Commands are copied without unit conversion. `period_ns`
advances model time; `pacing_period_ns` delays the next permitted step after
actual completion, so it is not a wall-cadence guarantee. The source graph stays
on the host; selected optical/response graphs use the requested compute target.
Accelerator optics require captured execution, with no stream fallback.

The loader checks source-command and detector-response schemas against public
AOS boundary contracts before numerical preparation. Raw or relative intensity
cannot acquire calibrated-pixel meaning merely by changing a schema string.
Model axes, physical planes and detector response remain scientific declarations.

## Run independently

An optical consumer needs HIL and the declared scientific dependencies:

```julia
using AdaptiveOpticsSimPipeWireHIL: Simulation, ExternalPupil
using Proper # when the configured optical graph requires it

prepared = Simulation.prepare(Simulation.load("build/simulation/simulation.yaml"))
Simulation.run!(prepared; frames = 100) do execution, streams, now_ns
    # A separate session authority admits and links these endpoints.
    ExternalPupil.Run(ExternalPupil.snapshot(execution).deadline_ns)
end
```

The optical callback returns `Run(deadline)`, `Hold()` or `Stop()`. Return the
execution's deadline to retain its configured completion-relative pacing.
Controls run serially with science; `reset!` belongs at this boundary. The frame
budget counts actual source advances, including an upstream generation change;
Hold and reset do not consume it. Lockstep retains its Boolean admission callback.
Stream lifetime is closed on completion, stopped admission or failure. Create
caller-owned links through a separate session connection.

Loading checks bounded YAML, confined paths, hashes, exact array types and
logical dimensions. It owns snapshots of graph, binding and compiled model
assets; each graph role receives independent mutable numerical state. Compiled
assets are materialized privately for AOS construction/preparation and then
removed; repeated preparation recreates them from the verified snapshots. The
product can be moved and loaded after the original source has been deleted.
Preparation opens no core, quietly warms and resets the optical models, and
publishes no synthetic camera frames. Science runs outside PipeWire callbacks.

Sensor and source streams honor the selected reference clock. These labels
identify host timestamp readings; they do not establish clock synchronization
or physical acquisition time. Execution/capture properties are refreshed from
actual prepared owners, including after changing the compute target.

## SPA protocol compatibility and verification

SPA plugins own protocol packetization and decoding. Their schemas, encoding,
units, actuator order, metadata requirements and clock meaning must agree with
the simulation ports. The inspected HEART revision `9aeea533` advertises retired
monolithic acquisition metadata, and its UDP protocol does not preserve the
complete identity/exposure facts required by modern lockstep HIL. Its migration
and an actual protocol roundtrip remain deferred by the user's selected order.
No correlation requirement is weakened or fabricated here.

The [optical configuration record](reviews/20261107-hil-optical-configuration/REVIEW.md)
records exact source cohorts and CPU/CUDA, relocation, schema and private-core
checks. RTC selectors are `test/simulation_export.jl`,
`test/simulation_optical_export.jl` and `test/simulation_compiled_export.jl`.
HIL owns parser, optical preparation, compiled asset and native runner checks.
These establish software behavior, not hardware or real-time qualification.
