# Authored measurement prefix shared by focused calibration selectors.
function chopped_calibration_document(shape=(2,3))
    nodes = [
        Dict("name"=>"pixels","type"=>"ndarray","label"=>"pixel-selection-f32","config"=>Dict(
            "image_size"=>collect(shape),"mask"=>fill(true,prod(shape)),"input_schema"=>"test.relative-image/1","output_schema"=>"test.relative-pixels/1")),
        Dict("name"=>"validity","type"=>"ndarray","label"=>"pixel-validity-f32","config"=>Dict(
            "extent"=>prod(shape),"input_schema"=>"test.relative-pixels/1")),
        Dict("name"=>"pair","type"=>"ndarray","label"=>"chopped-image-difference-f32","config"=>Dict(
            "pixel_count"=>prod(shape),"input_schema"=>"test.relative-pixels/1","trigger_high_is_fringed"=>true,"require_acquisition_identity"=>true)),
        Dict("name"=>"residual","type"=>"ndarray","label"=>"scc-pixel-residual-f32","config"=>Dict(
            "pixel_count"=>prod(shape),"mask"=>fill(true,prod(shape)),"initial_reference_image"=>nothing,"minimum_valid_fraction"=>1)),
    ]
    links = [Dict("output"=>output,"input"=>input) for (output,input) in (
        ("pixels:selected-pixels","validity:input"),("pixels:selected-pixels","pair:image"),
        ("validity:validity","pair:input-validity"),("pair:difference","residual:difference"),
        ("pair:output-validity","residual:difference-validity"),("pair:pair-status","residual:pair-status"))]
    return Dict("node.name"=>"test.chopped-calibration","filter.graph"=>Dict("nodes"=>nodes,"links"=>links,
        "inputs"=>[Dict("name"=>"image","endpoint"=>"pixels:image"),
            Dict("name"=>"scc-reference-difference","endpoint"=>"residual:reference-image")],
        "outputs"=>[Dict("name"=>"measurements","endpoint"=>"residual:selected-residuals")]))
end
