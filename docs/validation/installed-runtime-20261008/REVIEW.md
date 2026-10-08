# Independent installed-runtime review

Source review and targeted investigation were performed separately from the
exporter implementation. Final disposition was checked against the source and
executed tests. This record does not establish latency or hardware qualification.

## IR-01 — row-return test invokes its gated publisher inline

Severity: medium (test deadlock). Confidence: high. Disposition: corrected.
Affected code: PipeWire `src/tests/test-row-return-lifetime.c`.
Evidence: [captured thread backtrace](row-return-deadlock.txt).
`pw_data_loop_start` does not wait for loop entry. An early invoke can run on
main, where the test publisher waits for a release only main can issue after the
invoke returns. Probe success now requires `pw_data_loop_in_thread`; callback
results propagate in inline and queued invokes. Both loops remain running until
the later publisher finishes. Validation: full suite and 200 replacement/20
removal repetitions passed. Each blocking probe still relies on the outer test
timeout; the readiness retry count is bounded.

## IR-02 — FIFO endpoint teardown precedes retention verification

Severity: medium (false failure of data-path proof). Confidence: high.
Disposition: corrected. Affected code: PipeWire
`src/tests/test-ndarray-filter-fifo-client.c` and `test-ndarray-filter-fifo.py`.
The client quit after its seventh output, contrary to the harness's required
helper-first shutdown. Recorded callbacks/outputs completed before Broken pipe.
The client now retains its pools until the helper exits, then accepts a bounded
completion-checked Quit command. A historical 16-buffer negotiation latch remains
valid when deliberate teardown changes the live count. Validation: both positive
and disabled-backlog variants passed ten repetitions each.

## IR-03 — stale metadata sentinel assertion

Severity: low (test expectation). Confidence: high. Disposition: corrected.
Affected code: PipeWire `test/test-spa-buffer.c`; authoritative header
`spa/include/spa/buffer/meta.h`. The header reserves retired ID 12 and sets the
sentinel to 13. The corrected assertion passes; no production ABI change.

## IR-04 — desktop test environment names in an AO build

Severity: medium (test setup). Confidence: high. Disposition: corrected.
Affected code: WirePlumber `tests/meson.build`.
AO ignores `PIPEWIRE_RUNTIME_DIR`; the original test's `/invalid` XDG path
therefore selected an unusable socket directory. AO environment names restore
the private test servers. The required optional audio test source was installed.
Validation: 57/57 native/Lua tests passed.

## Accepted integration constraints

- Missing/invalid required installed manager assets fail before replacement;
  the old staged manager remains intact. The validated remove-then-move directory
  replacement is not interruption-atomic. This limitation is retained explicitly.
- HIL/HEART exporters use the selected installed prefix; paired development
  inputs take precedence. Calibration inherits its sealed base manager.
- WirePlumberAO requires the AO pkg-config identities directly. A standard
  desktop-linked build was not qualified or added as a supported option.
- Manager `LD_LIBRARY_PATH` puts its packaged libwp first. Actual process maps
  confirm both required modules, packaged libwp and installed AO libpipewire.
  Compile configuration alone was not accepted as runtime loading evidence.
