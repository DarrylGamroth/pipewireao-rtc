# Native session discovery fixture

`record.pod` is the 192-byte seven-field SPA Struct emitted by Julia
`NativeSessionDiscovery.encode_record` on 2026-10-06. It carries label
`Classic α`, UUID `12345678-1234-1234-1234-123456789abc`, PID `typemax(UInt32)`,
incarnation `typemax(Int64)`, remote `/tmp/private/core` and node
`rtc.supervisor-1`. Rust decodes it and verifies byte equality with the public
SPA serializer in its test. The record is a listing hint, not a live endpoint.
