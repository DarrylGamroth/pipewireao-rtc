# Native parameter ndarray op17 golden records

`request.pod` is a fixed, schema-absent F32_LE column-major 2 × 3 ndarray with
samples `[-0.0, 1.25, -2.5, 0.125, 64.0, -64.0]`. The request carries
controller global ID 9, serial `0x8000000000000011`, instance 13, endpoint
instance 24, token 25 and a 5,000,000,000 ns budget. It targets `graph` and
`reference`.

`completion.pod` reports submission in Ready with matching correlation and an
unknown active generation.

Regenerate both records from the RTC checkout with
`julia --startup-file=no --project=. test/test_parameter_ndarray.jl --write-golden`.
