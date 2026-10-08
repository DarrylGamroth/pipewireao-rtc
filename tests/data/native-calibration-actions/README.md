# Calibration action SPA test data

These 43 binary SPA Props PODs were produced by
`deployment/julia/test/test_native_calibration_action_codec.jl` on Linux x86_64
(little endian). The Julia test compares its encoder output byte for byte with
each sample. The Rust test decodes and re-encodes the same samples.

There are 22 valid records: nine requests (including all three settling rules),
seven success results, four typed failure reasons, one negative transport
completion with None, and one transport rejection. Every valid request and
completion carries run=UInt64 max and serial=2⁶³. Cursor domain/sequence are
UInt64 max, generation is 2⁶³, and model_ns is Int64 max. The Responses exposure
has start=2⁶³ and duration=Int64 max, so its checked end is UInt64 max. Captured
payload bytes are UInt64 max and metadata bytes are 2⁶³. Float arrays include
negative zero where useful to establish bit-preserving interoperability.

The 21 `bad-*` records are correctly formed common envelopes with invalid
action payloads: wrong arity or child type, unknown operations/results/rules/
lifecycle/reasons, nonfinite floats, out-of-range counts or cursors, and invalid
exposure duration/end. Both action codecs must reject them. Separate pure tests
mutate common-envelope metadata and exercise request/reply byte limits.

The wire contract and validation limits are recorded in
[`NATIVE_CALIBRATION_ACTION_CONTROL.md`](../../../docs/NATIVE_CALIBRATION_ACTION_CONTROL.md).
These samples verify serialization behavior only.
