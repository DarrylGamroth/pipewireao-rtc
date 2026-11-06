using Test, PipeWireAORTC
const R = PipeWireAORTC.RuntimeExport

@testset "application data copy excludes selected development files" begin
    mktempdir() do root
        source = joinpath(root, "source")
        mkpath(joinpath(source, "nested"))
        write(joinpath(source, "instrument.yaml"), "instrument data")
        write(joinpath(source, "nested", "graph.yaml"), "graph data")
        write(joinpath(source, "nested", "scratch.tmp"), "ignored")
        target = joinpath(root, "application")
        @test R.copy_tree(source, target; ignored = Set(["scratch.tmp"])) == target
        @test read(joinpath(target, "instrument.yaml"), String) == "instrument data"
        @test read(joinpath(target, "nested", "graph.yaml"), String) == "graph data"
        @test !ispath(joinpath(target, "nested", "scratch.tmp"))
        @test_throws ArgumentError R.copy_tree(source, target)
        symlink(joinpath(source, "instrument.yaml"), joinpath(source, "linked.yaml"))
        @test_throws ArgumentError R.copy_tree(source, joinpath(root, "linked application"))
        @test_throws ArgumentError R.copy_file(
            joinpath(source, "linked.yaml"), joinpath(root, "linked copy")
        )
    end
end
