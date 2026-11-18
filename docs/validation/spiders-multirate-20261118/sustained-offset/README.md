# Interrupted sustained-offset trial

The 100 Hz LLOWFS and 33⅓ Hz SCC branches used the normal-flat seed-17
112-mode application. The stepped run held an artificial +441.96 µm tip
reference from ticks 1651–1770. The calibrated gain and projection set the
first requested increment to twice the installed ±0.5 actuator limit. This
is a limiter stress test far outside the normal optical operating range.

All 160 demands during the offset clipped. The largest reconstructed
actuator request was 1.6141 native units. After the original reference
became active at tick 1771, all 141 subsequent received commands remained
clipped through tick 1876. Over those 106 model ticks mean unfringed
contrast was 4.82 × 10⁻⁴ and the two-axis LLOWFS residual RMS was 2.86 µm
OPD. The receiving HIL command stream timed out waiting for the SCC demand
at tick 1876. The independent graph taps observed the SCC residual,
shared command and constraint feedback. The wait expired after 800 ms
of host time. The cause of the missing receipt was undetermined. This
trial cannot establish the eventual optical or actuator recovery time.

The JSON files are the original partial receipts. The CSVs retain the
headers and witness ticks 1050, 1201, 1204, 1650, 1651, 1770, 1771, 1875
and 1876 from the full traces. The terminal error is in [timeout.txt](timeout.txt).
The original pair summary counted both intentionally silent priming events
(ticks 1 and 1201) and the final interrupted SCC event as missing. The raw
camera and native receipts show that the first valid resumed pair was
tick 1204. Shared command/constraint records have unspecified PipeWire
timestamps. Their identity, producing event and sequence establish the
join; the timestamp on a camera acquisition is its model exposure time.
