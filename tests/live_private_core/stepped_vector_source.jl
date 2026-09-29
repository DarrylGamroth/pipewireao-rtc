using Base.Threads: Atomic
using PipeWireAO

length(ARGS) == 5 || error("expected CORE NODE SCHEMA CONTROL VARIANT")
core_name, node_name, schema, control, variant = ARGS
variant in ("a", "b") || error("unknown stepped source variant $variant")

const FRAMES_A = (
    Float32[1, -1],
    Float32[0.25, 2.5],
    Float32[-3, 0.125],
    Float32[4.5, -2.25],
    Float32[1.5, -0.75],
    Float32[-1.25, 3.25],
    Float32[2, -4],
    Float32[0.375, 1.125],
)
const FRAMES_B = (
    Float32[-0.5, 3],
    Float32[2.25, -1.5],
    Float32[0.75, 4],
    Float32[-2, 0.5],
    Float32[3.5, -2],
    Float32[-0.125, 1.75],
    Float32[4.25, -3],
    Float32[-2.5, 0.625],
)

struct SteppedSource{F}
    frames::F
    requested::Atomic{Int}
    published::Atomic{Int}
    ended::Atomic{Bool}
end

function (source::SteppedSource)(filter, inputs, outputs)
    output = only(outputs)
    index = source.requested[]
    if !source.ended[] && index > source.published[]
        copyto!(reinterpret(Float32, PipeWireAO.bytes(output)), source.frames[index])
        set_output_available!(output, true)
        source.published[] = index
    else
        set_output_available!(output, false)
    end
    return nothing
end

frames = variant == "a" ? FRAMES_A : FRAMES_B
source = SteppedSource(frames, Atomic{Int}(0), Atomic{Int}(0), Atomic{Bool}(false))
format = NdArrayFormat(
    NdArray.F32_LE,
    (2,);
    layout=NdArray.ROW_MAJOR,
    rate=SPA.Fraction(1_000, 1),
)
filter = NdArrayFilter(
    node_name,
    (NdArrayFilterPort("output", PipeWireAO.DIRECTION_OUTPUT, format; schema),);
    remote=core_name,
    on_process=source,
)
finished = Atomic{Bool}(false)

monitor = Threads.@spawn begin
    while !finished[]
        if PipeWireAO.isrunning(filter) && !isnothing(node_id(filter))
            println("STEPPED_SOURCE_READY node=$node_name")
            flush(stdout)
            break
        end
        Base.Libc.systemsleep(0.001)
    end
    for index in eachindex(frames)
        step = joinpath(control, "step-$index")
        while !finished[] && !isfile(step)
            Base.Libc.systemsleep(0.001)
        end
        finished[] && return
        source.requested[] = index
        while !finished[] && source.published[] != index
            Base.Libc.systemsleep(0.001)
        end
        finished[] && return
        write(joinpath(control, "step-$index.ack"), "published $index\n")
        if index == 4
            while !finished[] && !isfile(joinpath(control, "source-end"))
                Base.Libc.systemsleep(0.001)
            end
            finished[] && return
            source.ended[] = true
            write(joinpath(control, "source-end.ack"), "quiescent\n")
            while !finished[] && !isfile(joinpath(control, "source-resume"))
                Base.Libc.systemsleep(0.001)
            end
            finished[] && return
            source.ended[] = false
            write(joinpath(control, "source-resume.ack"), "resumed\n")
        end
    end
    while !finished[] && !isfile(joinpath(control, "stop"))
        Base.Libc.systemsleep(0.001)
    end
    finished[] || quit!(filter)
    return nothing
end

try
    connect!(filter)
    run!(filter)
finally
    finished[] = true
    wait(monitor)
    close(filter)
end
