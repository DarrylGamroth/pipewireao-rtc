using Test

include(joinpath(@__DIR__, "integration", "quit_queue_counters.jl"))
using .QuitQueueCounters: quit_queue_counters

@testset "Queue capture loans balance across Quit" begin
    function snapshot(; quit = false)
        objects = [Dict{String,Any}(
            "type" => "PipeWire:Interface:Core", "id" => 0, "info" => Dict("cookie" => 245),
        )]
        for (serial, queue, publications) in
            ((24, "detector-images", 18), (27, "wavefront-slopes", 4))
            props = Dict(
                "node.name" => queue, "object.serial" => serial,
                "queue.state.capture-generation" => 2,
                "queue.state.capture-buffers" => (quit ? 0 : 3),
                "queue.state.pending-depth" => (quit ? 0 : 1),
                "queue.state.playback-buffers" => 0, "queue.state.completion-depth" => 0,
                "queue.stats.publications" => publications + quit,
                "queue.stats.replacements" => publications - 2 + quit,
                "queue.stats.withdrawal-returns" => Int(quit),
                "queue.stats.protocol-errors" => 0, "queue.stats.deliveries" => 0,
                "queue.stats.completions" => 0, "queue.stats.dropped-arrivals" => 0,
            )
            push!(objects, Dict(
                "id" => serial, "type" => "PipeWire:Interface:Module",
                "info" => Dict("name" => "libpipewire-module-queue", "props" => props),
            ))
        end
        return objects
    end
    before, after = snapshot(), snapshot(; quit = true)
    # Each captured queue had one publication outside the known accounting
    # categories before Quit. Only changes within this interval must balance.
    for queue in ("detector-images", "wavefront-slopes")
        result = quit_queue_counters(before, after, queue)
        @test result["capture_buffers_before"] == 3
        @test result["capture_buffers_after"] == 0
        @test result["pending_after"] == 0
        @test result["counter_changes"]["withdrawal-returns"] == 1
    end
    for (key, value) in (
        ("queue.state.capture-buffers", 1), ("queue.state.pending-depth", 1),
        ("queue.state.capture-generation", 3), ("object.serial", 25),
        ("queue.stats.withdrawal-returns", 0), ("queue.stats.protocol-errors", 1),
        ("queue.stats.publications", 20), ("queue.stats.replacements", 15),
        ("queue.stats.deliveries", 1), ("queue.stats.dropped-arrivals", true),
    )
        invalid = deepcopy(after)
        invalid[2]["info"]["props"][key] = value
        @test_throws ArgumentError quit_queue_counters(before, invalid, "detector-images")
    end
    different_core = deepcopy(after)
    different_core[1]["info"]["cookie"] += 1
    @test_throws ArgumentError quit_queue_counters(before, different_core, "detector-images")
    missing_counter = deepcopy(after)
    delete!(missing_counter[2]["info"]["props"], "queue.stats.withdrawal-returns")
    @test_throws ArgumentError quit_queue_counters(before, missing_counter, "detector-images")
end
