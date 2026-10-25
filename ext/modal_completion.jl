# Provisional geometric control roles, independent of physical actuator health.
function modal_completion_index(value::Integer, extent)
    1 <= value <= extent || throw(ArgumentError("actuator position is outside its source grid"))
    return Int(value)
end
modal_completion_index(value::Bool, extent) = throw(ArgumentError("actuator positions must be integers"))
modal_completion_index(value, extent) = throw(ArgumentError("actuator positions must be integers"))

function modal_completion_position(position::Tuple, shape)
    length(position) == 2 || throw(ArgumentError("actuator positions require two source-grid indices"))
    return (modal_completion_index(position[1],shape[1]),modal_completion_index(position[2],shape[2]))
end
modal_completion_position(position, shape) = throw(ArgumentError("actuator positions must be source-grid tuples"))

function modal_completion_extent(rows, columns, width)
    rows > 0 && columns > 0 && rows <= div(GraphOwner.MAX_RETAINED_BYTES,columns * width) ||
        throw(ArgumentError("modal completion exceeds the 512 MiB array limit"))
    return nothing
end

"Prepare an annular direct set and finite thin-plate completion, with no correction beyond its guard."
function modal_completion(mirror, registration, policy; obstruction)
    IC.fields(policy,("kind","guard_width_pitches"),("kind",),"modal completion policy")
    policy["kind"] == "thin_plate_annulus" || throw(ArgumentError("unsupported modal completion policy"))
    guard = get(policy,"guard_width_pitches",2)
    IC.isfinite_real(guard) && isfinite(Float64(guard)) && guard >= 0 ||
        throw(ArgumentError("guard_width_pitches must be finite and nonnegative"))
    IC.isfinite_real(obstruction) && isfinite(Float64(obstruction)) && 0 <= obstruction < 1 ||
        throw(ArgumentError("central obstruction must be finite and in [0,1)"))
    hasproperty(mirror,:layout) && hasproperty(mirror.layout,:command_positions) &&
        hasproperty(mirror.layout,:grid_shape) || throw(ArgumentError("mirror requires a source-grid command map"))
    axis_count = modal_completion_index(IC._mirror_axis_count(mirror),typemax(UInt16))
    modal_completion_extent(axis_count,axis_count,sizeof(UInt16))
    positions = map(position -> modal_completion_position(position,(axis_count,axis_count)),mirror.layout.command_positions)
    length(unique(positions)) == length(positions) || throw(ArgumentError("actuator source-grid positions must be unique"))
    count = length(positions)
    0 < count <= typemax(UInt16) || throw(ArgumentError("mirror command count exceeds the source-grid map bounds"))
    registered = IC._pupil_registration(registration)
    outer_radius = 1 + Float64(guard) * registered.actuator_pitch_pupil_radius
    isfinite(outer_radius) || throw(ArgumentError("outer guard radius must be finite"))
    coordinates = IC.actuator_coordinates(mirror,Float64;pupil_registration=registered)
    all(isfinite,coordinates) || throw(ArgumentError("actuator coordinates must be finite"))
    radii = map(index -> hypot(coordinates[1,index],coordinates[2,index]),1:count)
    controlled = findall(radius -> obstruction <= radius <= 1,radii)
    length(controlled) >= 3 || throw(ArgumentError("annulus requires at least three directly controlled coordinates"))
    support = permutedims(coordinates[:,controlled])
    centered = support .- sum(support;dims=1) ./ length(controlled)
    scale = maximum(abs,centered)
    scale > 0 && LA.rank(hcat(ones(length(controlled)),centered ./ scale)) == 3 ||
        throw(ArgumentError("directly controlled coordinates must span a two-dimensional affine basis"))
    supported = findall(<=(outer_radius),radii)
    modal_completion_extent(count,length(controlled),sizeof(Float64))
    modal_completion_extent(length(controlled)+3,length(controlled)+3,sizeof(Float64))
    roles = zeros(UInt8,count)
    roles[supported] .= 2
    roles[controlled] .= 1
    # Fixed FGA coordinates enter the spline fit. Exclude far channels entirely
    # before preparation so their zero corrections impose no artificial boundary.
    partition = FGA.VdmActuatorPartition([roles[index] == 1 ?
        FGA.ControlledVdmActuator : FGA.ExtrapolatedVdmActuator for index in supported])
    calibration = FGA.VdmCompletionCalibration(partition,permutedims(coordinates[:,supported]))
    plan = FGA.ThinPlateVdmCompletionPlan{Float64}()
    artifacts = FGA.VdmCompletionArtifacts(plan,calibration)
    FGA.process!(artifacts,FGA.VdmCompletionWorkspace(plan,calibration),plan,calibration)
    completion = zeros(Float32,count,length(controlled))
    selector = zeros(Float32,length(controlled),count)
    for (column,index) in pairs(controlled)
        completion[index,column] = 1
        selector[column,index] = 1
    end
    extrapolated = supported[FGA.extrapolated_vdm_indices(partition)]
    completion[extrapolated,:] = Float32.(artifacts.extrapolated_from_controlled)
    all(isfinite,completion) || throw(ArgumentError("modal completion must preserve finite Float32 coefficients"))
    # The reverse projection fits all physical constraint residuals, including
    # slave-only clipping. Far zero rows carry no observable correction residual.
    feedback = Float32.(LA.pinv(Float64.(completion)))
    feedback[:,findall(iszero,roles)] .= 0
    all(isfinite,feedback) || throw(ArgumentError("modal reverse projection must preserve finite Float32 coefficients"))
    return (; completion,controlled,selector,feedback,roles)
end
