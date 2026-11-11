# Live detector flux labels

The instrument data came from `ee87162`. The private CPU simulator
deployments use Julia 1.13.3, RTC 0.7.9, FilterGraphPipeWire 0.5.5 and
PipeWireAO SDK 4.0.2. Chromium used the loopback observation bridge and
a WASM review build of the shared GUI. Real pointer clicks selected
the views. The review build records rendered glyphs and the live
sample headers without changing GUI or RTC state.

## Classic

Classic reached Ready in 504.81 s and entered Running. The test
started the installed optional WFS analysis graph through the existing
analysis launcher after the required owners were ready. A first cold
analysis launch exhausted the helper deadline. The private test archived
its incomplete receipt and directory before starting the analysis once
with a longer diagnostic deadline.

The rendered plot displayed **Mean flux (calibrated ADU per exposure)**.
The plot grew from 42 to 55 points while the WFS summary queue advanced
from publication 4099 to 4112. The live Shack–Hartmann tooltip originally
showed a number without a unit. GUI commit `1b865b6` uses the configured
flux unit and renders the compact **ADU** suffix for the recognized
detector labels. The new build showed an ADU flux value over
subaperture 28 with detector and flux publication 4053. The browser
reported Running and no page errors.
[Plot](classic-plot.png) · [Overlay](classic-overlay.png)

The browser detached before the stop hook sent native Quit. The RTC
accepted Quit and exited successfully. The required and optional owners
stopped without SIGKILL. Cleanup removed the socket and unit files.
